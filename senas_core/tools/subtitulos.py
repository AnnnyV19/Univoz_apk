#!/usr/bin/env python3
"""Arma los segmentos a partir de la pista de subtitulos del video.

    python tools/subtitulos.py --video "videos/descargados/algo.mp4" \\
        --url "https://www.youtube.com/watch?v=..."

    python tools/subtitulos.py --video "algo.mp4" --archivo "algo.es.vtt"

Deja el mismo <video>.segmentos.csv que produce segmentar_video.py, pero
con la columna `palabra` YA LLENA.

POR QUE ES EL MEJOR CAMINO CUANDO EXISTE: segmentar_video.py deduce los
cortes mirando pixeles, y despues hay que escribir a mano que dice cada
uno. Una pista de subtitulos trae las dos cosas exactas y de una vez: el
texto y los tiempos que el autor puso. No hay ROI que adivinar, ni
umbral, ni OCR.

SOBRE LOS AUTOMATICOS: YouTube los genera transcribiendo el AUDIO. Si el
video es mudo, o si quien habla dice otra cosa, no sirven -- por eso hay
que pedirlos a proposito con --aceptar-automaticos. Pero en los videos de
ensenanza es comun que la persona DIGA la palabra en voz alta mientras la
senaliza, y ahi la transcripcion coincide con la sena y ahorra escribir
todo a mano. Vienen de reconocimiento de voz, asi que hay que revisarlos:
confunden palabras parecidas y se comen los acentos.

Si el video no tiene pista, este script no sirve y hay que volver a
tools/autoencuadre.py + tools/segmentar_video.py.
"""

import argparse
import csv
import html
import os
import re
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, AQUI)

# Idiomas que se prueban, en orden. Se aceptan variantes: 'es-MX' entra por
# 'es', y asi no hay que enumerar cada region.
IDIOMAS = ("es", "es-MX", "es-419", "es-ES")

# Cues que no son una sena: cortinillas de audio y marcas del transcriptor.
BASURA = re.compile(r"^\s*[\[\(](musica|música|aplausos|risas|silencio)[\]\)]\s*$", re.I)


def _limpiar(texto):
    """Quita el marcado de VTT y deja una linea de texto plano."""
    texto = re.sub(r"<[^>]+>", "", texto)          # <c>, <00:00:01.000>, <i>
    texto = html.unescape(texto)
    texto = texto.replace("\n", " ").replace("\r", " ")
    return re.sub(r"\s+", " ", texto).strip()


def _a_segundos(marca):
    """'00:01:23.450' o '00:01:23,450' -> 83.45"""
    marca = marca.strip().replace(",", ".")
    partes = marca.split(":")
    try:
        if len(partes) == 3:
            h, m, s = partes
        elif len(partes) == 2:
            h, m, s = "0", partes[0], partes[1]
        else:
            return None
        return int(h) * 3600 + int(m) * 60 + float(s)
    except ValueError:
        return None


_TIEMPOS = re.compile(
    r"(\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}(?::\d{2})?[.,]\d{1,3})"
)


def parsear(texto):
    """Lee VTT o SRT y devuelve [(inicio_s, fin_s, texto)].

    Los dos formatos comparten la linea de tiempos ('inicio --> fin') y se
    diferencian en poco mas, asi que un solo lector cubre ambos: se busca
    esa linea y se toma como texto lo que sigue hasta el renglon en blanco.
    """
    cues = []
    lineas = texto.splitlines()
    i = 0
    while i < len(lineas):
        m = _TIEMPOS.search(lineas[i])
        if not m:
            i += 1
            continue
        a, b = _a_segundos(m.group(1)), _a_segundos(m.group(2))
        i += 1
        cuerpo = []
        while i < len(lineas) and lineas[i].strip():
            cuerpo.append(lineas[i])
            i += 1
        t = _limpiar(" ".join(cuerpo))
        if a is not None and b is not None and b > a and t and not BASURA.match(t):
            cues.append((a, b, t))
    return cues


def unir_repetidos(cues, hueco_max=0.8):
    """Junta cues consecutivos con el mismo texto.

    Un subtitulo largo suele venir partido en varios cues (o repetido
    mientras sigue en pantalla). Sin unirlos, la misma sena entraria varias
    veces a la base como muestras distintas del mismo tramo.
    """
    unidos = []
    for a, b, t in cues:
        if unidos and unidos[-1][2].lower() == t.lower() and a - unidos[-1][1] <= hueco_max:
            unidos[-1] = (unidos[-1][0], b, unidos[-1][2])
        else:
            unidos.append((a, b, t))
    return unidos


def bajar_de_youtube(url, destino, idiomas=IDIOMAS, aceptar_automaticos=False):
    """Devuelve el texto de la pista de subtitulos, o levanta ValueError."""
    try:
        from yt_dlp import YoutubeDL
    except ImportError:
        raise ValueError(
            "falta yt-dlp para leer los subtitulos: pip install yt-dlp")

    with YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True}) as ydl:
        info = ydl.extract_info(url, download=False)

    propios = info.get("subtitles") or {}
    automaticos = info.get("automatic_captions") or {}

    fuente, cual = propios, "del autor"
    if not propios:
        if not aceptar_automaticos:
            if automaticos:
                raise ValueError(
                    "este video no tiene subtitulos del autor, pero SI tiene "
                    f"{len(automaticos)} pista(s) automatica(s).\n"
                    "Esas transcriben el audio: sirven si quien senaliza dice "
                    "la palabra en voz alta.\n"
                    "Volve a correr marcando 'Aceptar los automaticos' "
                    "(o con --aceptar-automaticos).")
            raise ValueError(
                "este video no tiene ninguna pista de subtitulos, ni del "
                "autor ni automatica.\n"
                "Usa tools/autoencuadre.py + tools/segmentar_video.py.")
        fuente, cual = automaticos, "AUTOMATICOS: son el audio transcrito, revisalos"

    elegido = None
    for pref in idiomas:
        for codigo in fuente:
            if codigo.lower() == pref.lower() or codigo.lower().startswith(pref.lower() + "-"):
                elegido = codigo
                break
        if elegido:
            break
    if elegido is None:
        elegido = next(iter(fuente), None)
    if elegido is None:
        raise ValueError("el video no trae ninguna pista de subtitulos")

    formatos = fuente[elegido]
    # vtt primero: es el que YouTube sirve siempre y el que mejor se parsea.
    url_sub = None
    for f in formatos:
        if f.get("ext") == "vtt":
            url_sub = f.get("url")
            break
    if url_sub is None and formatos:
        url_sub = formatos[0].get("url")
    if not url_sub:
        raise ValueError(f"no encontre un archivo descargable para '{elegido}'")

    print(f"  pista: {elegido} ({cual})")
    import urllib.request
    with urllib.request.urlopen(url_sub, timeout=60) as r:
        texto = r.read().decode("utf-8", "replace")

    if destino:
        try:
            with open(destino, "w", encoding="utf-8") as f:
                f.write(texto)
            print(f"  guardada en: {destino}")
        except OSError:
            pass
    return texto


def escribir_csv(video, cues, categoria=None):
    ruta = os.path.splitext(video)[0] + ".segmentos.csv"
    with open(ruta, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["n", "inicio_s", "fin_s", "duracion_s", "palabra", "categoria"])
        for k, (a, b, t) in enumerate(cues, start=1):
            w.writerow([k, round(a, 2), round(b, 2), round(b - a, 2), t, categoria or ""])
    return ruta


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True,
                    help="el video local; el CSV se deja a su lado")
    ap.add_argument("--url", help="link del que bajar la pista de subtitulos")
    ap.add_argument("--archivo", help="un .vtt o .srt ya descargado")
    ap.add_argument("--categoria")
    ap.add_argument("--min-duracion", type=float, default=0.4,
                    help="descarta cues mas cortos que esto (default 0.4s)")
    ap.add_argument("--aceptar-automaticos", action="store_true",
                    help="usa los subtitulos automaticos de YouTube aunque "
                         "transcriban el audio y no las senas")
    args = ap.parse_args()

    if not args.url and not args.archivo:
        # Ultimo intento: un .vtt/.srt que este al lado del video.
        base = os.path.splitext(args.video)[0]
        for suf in (".es.vtt", ".vtt", ".es.srt", ".srt"):
            if os.path.exists(base + suf):
                args.archivo = base + suf
                print(f"  usando el subtitulo que estaba al lado: {args.archivo}")
                break
    if not args.url and not args.archivo:
        sys.exit("pasa --url (para bajar la pista) o --archivo (un .vtt/.srt)")

    if args.archivo:
        with open(args.archivo, encoding="utf-8-sig") as f:
            texto = f.read()
    else:
        try:
            texto = bajar_de_youtube(
                args.url, os.path.splitext(args.video)[0] + ".es.vtt",
                aceptar_automaticos=args.aceptar_automaticos)
        except ValueError as e:
            sys.exit(str(e))

    cues = parsear(texto)
    if not cues:
        sys.exit("no pude leer ningun subtitulo de esa pista "
                 "(no parece un VTT ni un SRT)")

    cues = unir_repetidos(cues)
    cues = [c for c in cues if c[1] - c[0] >= args.min_duracion]
    if not cues:
        sys.exit("todos los subtitulos quedaron por debajo de --min-duracion")

    ruta = escribir_csv(args.video, cues, args.categoria)
    print(f"\n{len(cues)} segmento(s) con texto:")
    for k, (a, b, t) in enumerate(cues[:40], start=1):
        print(f"  #{k:<3} {a:7.2f} - {b:7.2f}  {t[:60]}")
    if len(cues) > 40:
        print(f"  ... y {len(cues) - 40} mas")
    print(f"\n  {ruta}")
    print("\nRevisa el CSV (o la tabla de la pagina) y borra las filas que no "
          "sean una sena:\nintros, creditos y cortinillas suelen venir como "
          "subtitulo tambien.")


if __name__ == "__main__":
    main()
