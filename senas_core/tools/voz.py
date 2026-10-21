#!/usr/bin/env python3
"""Saca las palabras de un video escuchandolo: transcribe el audio con
Whisper y deja un <video>.segmentos.csv con la columna `palabra` llena.

    pip install faster-whisper
    python tools/voz.py --video "videos/descargados/algo.mp4"

CUANDO SIRVE: en los videos de ensenanza donde la persona DICE la palabra
mientras la senaliza. Corre en tu computadora (no manda el audio a ningun
servicio) y funciona con cualquier video local, tenga o no subtitulos.

CUANDO NO: si el video es mudo, tiene musica encima o habla otra persona.
Y ojo con el tiempo: la voz suele ir un poco antes o despues de la sena, no
exactamente encima. Por eso cada tramo se ensancha --margen segundos de cada
lado, y en la pagina de revision puedes ver el clip y ajustar inicio y fin.

La primera vez baja el modelo (small ~ 460 MB; base ~ 140 MB si la maquina
es lenta). Despues funciona sin internet.
"""

import argparse
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

import segmentos_csv  # noqa: E402

# Frases que Whisper inventa cuando oye silencio o musica. No son senas.
ALUCINACIONES = re.compile(
    r"(subt[ií]tulos? (por|realizados|de)|amara\.org|gracias por (ver|vernos)|"
    r"suscr[ií]bete|no olvides (suscribirte|dar)|m[uú]sica|aplausos)", re.I)


def agrupar_palabras(palabras, pausa=0.6, max_seg=6.0):
    """palabras: [(inicio, fin, texto, prob)] -> [(inicio, fin, texto, conf)].

    Una pausa mas larga que `pausa` separa dos senas. Asi "hola" y
    "buenas tardes" salen como dos tramos aunque Whisper los haya dado en
    una sola oracion. Ningun tramo pasa de max_seg: una sena dura uno o dos
    segundos, y un tramo de 20 s esta mal casi seguro.
    """
    grupos = []
    actual = []
    for w in palabras:
        if actual and (w[0] - actual[-1][1] > pausa or w[1] - actual[0][0] > max_seg):
            grupos.append(actual)
            actual = []
        actual.append(w)
    if actual:
        grupos.append(actual)

    out = []
    for g in grupos:
        texto = re.sub(r"\s+", " ", "".join(
            (x[2] if x[2].startswith(" ") else " " + x[2]) for x in g)).strip()
        texto = texto.strip(" ,;:.¡!¿?\"'")
        if not texto:
            continue
        conf = sum(x[3] for x in g) / len(g)
        out.append((g[0][0], g[-1][1], texto, conf))
    return out


def transcribir(video, modelo="small", idioma="es"):
    try:
        from faster_whisper import WhisperModel
    except ImportError:
        sys.exit("falta faster-whisper:  pip install faster-whisper")

    print(f"  cargando el modelo '{modelo}' (la primera vez se descarga)...")
    m = WhisperModel(modelo, device="cpu", compute_type="int8")
    print("  escuchando el video (puede tardar: un video de 10 min toma unos minutos)...")
    segmentos, info = m.transcribe(
        video, language=idioma, vad_filter=True, word_timestamps=True,
        beam_size=5, condition_on_previous_text=False)

    palabras = []
    descartados = 0
    for s in segmentos:
        # no_speech_prob alto o logprob muy bajo = Whisper esta adivinando.
        if (getattr(s, "no_speech_prob", 0) or 0) > 0.6 or \
           (getattr(s, "avg_logprob", 0) or 0) < -1.3 or \
           ALUCINACIONES.search(s.text or ""):
            descartados += 1
            continue
        for w in (s.words or []):
            palabras.append((w.start, w.end, w.word, w.probability))
    if descartados:
        print(f"  (descarte {descartados} tramo(s) que parecian silencio o musica)")
    return palabras, getattr(info, "duration", None)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--categoria")
    ap.add_argument("--modelo", default="small",
                    help="tiny | base | small | medium (default small)")
    ap.add_argument("--pausa", type=float, default=0.6,
                    help="silencio que separa una sena de otra (default 0.6 s)")
    ap.add_argument("--max-seg", type=float, default=6.0)
    ap.add_argument("--margen", type=float, default=0.3,
                    help="se ensancha cada tramo esto de cada lado (default 0.3 s)")
    ap.add_argument("--min-duracion", type=float, default=1.0)
    args = ap.parse_args()

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")

    palabras, dur = transcribir(args.video, args.modelo)
    if not palabras:
        sys.exit("no oi ninguna palabra en el audio (¿el video es mudo?)")

    tramos = agrupar_palabras(palabras, args.pausa, args.max_seg)
    tramos = [(a - args.margen, b + args.margen, t, c) for a, b, t, c in tramos]
    tramos = segmentos_csv.normalizar_tramos(tramos, args.min_duracion, dur)

    filas = [{"inicio_s": a, "fin_s": b, "palabra": t, "categoria": args.categoria,
              "fuente": "voz", "confianza": c} for a, b, t, c in tramos]
    ruta = segmentos_csv.escribir(args.video, filas)

    print(f"\n{len(filas)} tramo(s) con texto:")
    for k, f in enumerate(filas[:40], start=1):
        print(f"  #{k:<3} {f['inicio_s']:7.2f} - {f['fin_s']:7.2f}  "
              f"{f['palabra'][:50]}  ({f['confianza']:.0%})")
    if len(filas) > 40:
        print(f"  ... y {len(filas) - 40} mas")
    print(f"\n  {ruta}")
    print("\nEs reconocimiento de voz: revisa cada palabra y el corte viendo el clip.")


if __name__ == "__main__":
    main()
