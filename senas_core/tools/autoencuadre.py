#!/usr/bin/env python3
"""Encuentra solo la ROI y el modo de medicion de un video con rotulos.

    python tools/autoencuadre.py --video "videos/descargados/algo.mp4"

Imprime la mejor combinacion encontrada y, con --json, la devuelve como
JSON para que la use tools/servidor_ingesta.py.

POR QUE EXISTE: segmentar_video.py necesita que le digan DONDE mirar
(--roi) y QUE medir (--senal). Eso cambia con cada video: el alfabeto de
la SEP tiene el rotulo en una franja a la derecha, y otros traen el
subtitulo en una cajita negra encima de la persona. Averiguarlo a mano
significa abrir el video, buscar el texto y traducir posiciones a
fracciones -- justo el paso que obliga a pedir ayuda por cada video
nuevo.

COMO LO HACE: prueba franjas horizontales a lo largo de todo el alto, con
las dos formas de medir, y se queda con la que produce una senal que
PARECE un rotulo: mucho tiempo pegada al piso (sin rotulo) y excursiones
claras y separadas por encima (con rotulo). Despues afina el ancho
mirando en que columnas cambia la imagen entre los momentos con y sin
rotulo.

Lo que NO hace: leer el texto. Eso sigue siendo tarea de quien revisa la
hoja de contactos (o de los subtitulos del video, cuando los trae).
"""

import argparse
import json
import sys

import os

import cv2
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# El umbral lo decide segmentar_video.py, no este script. Importarlo (en vez
# de reimplementarlo) es lo unico que garantiza que lo que aca se estima sea
# lo que despues pasa de verdad: una franja puede verse prometedora en
# muestras sueltas y comportarse distinto cuando se mide frame por frame.
from segmentar_video import MASCARA_SEP, parse_rect, umbral_sobre_piso  # noqa: E402


# Cuantos frames se muestrean para decidir. Con 240 alcanza: un rotulo
# dura entre 1 y 5 segundos, asi que a ~1 muestra por segundo se ven
# varias decenas de encendidos y apagados, que es lo que hace falta para
# juzgar la forma de la senal. Leer el video entero solo para elegir la
# ROI seria minutos de espera antes de la corrida de verdad.
N_MUESTRAS = 240

# Varias alturas: un subtitulo de una linea ocupa ~0.10 del alto, pero un
# rotulo grande (el alfabeto de la SEP) puede ocupar casi la mitad del
# cuadro. Con una sola altura, la franja que no encaja se mide a medias y
# la senal queda sucia.
ALTOS_BANDA = (0.10, 0.18, 0.30, 0.45)
PASO_BANDA = 0.05


def _senal_tinta(recorte):
    """Cuanto se sale del fondo. Para rotulos oscuros sobre franja clara."""
    gris = cv2.cvtColor(recorte, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
    fondo = np.percentile(gris, 90)
    return float(np.mean(np.abs(gris - fondo) > 0.15))


def _senal_caja(recorte):
    """Pixeles oscuros Y sin color: la cajita negra del subtitulo.

    La ropa oscura tambien es oscura, pero tiene color; el negro de la
    caja es neutro. Sin el filtro de saturacion las dos se confunden.
    """
    hsv = cv2.cvtColor(recorte, cv2.COLOR_BGR2HSV)
    return float(np.mean((hsv[..., 2] < 45) & (hsv[..., 1] < 70)))


SENALES = {"tinta": _senal_tinta, "caja": _senal_caja}


def tapar_pip(frame):
    """Devuelve una copia con el recuadro del interprete tapado en blanco.

    Muchos videos institucionales traen a un interprete en un recuadro fijo
    (arriba a la derecha). Ese recuadro cambia en CADA frame, asi que
    cualquier franja que lo toque produce una senal que nunca baja al piso
    -- y entonces el rotulo de verdad queda invisible para el detector. Es
    la misma mascara que aplica segmentar_video.py con --mascara-sep.
    """
    x0, y0, x1, y1 = parse_rect(MASCARA_SEP, "--mascara-sep")
    alto, ancho = frame.shape[:2]
    f = frame.copy()
    f[int(alto * y0):int(alto * y1), int(ancho * x0):int(ancho * x1)] = 255
    return f


def leer_muestras(video, n=N_MUESTRAS, ancho=320):
    """Devuelve (frames_reducidos, tiempos, fps, duracion)."""
    cap = cv2.VideoCapture(video)
    if not cap.isOpened():
        sys.exit(f"OpenCV no pudo abrir el video: {video}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    if fps <= 0 or total <= 0:
        cap.release()
        sys.exit("el video no reporta fps/frames: OpenCV no lo puede leer bien")

    # Lectura SECUENCIAL con salto, no cap.set() por muestra: buscar una
    # posicion obliga al decodificador a volver al keyframe anterior y
    # decodificar hasta ahi. Con 240 saltos eso puede tardar minutos en
    # videos largos, mientras que leer derecho y descartar frames tarda
    # segundos.
    salto = max(1, total // max(n, 1))
    frames, tiempos = [], []
    i = 0
    while True:
        ok = cap.grab()          # grab no decodifica: descarta barato
        if not ok:
            break
        if i % salto == 0:
            ok, f = cap.retrieve()
            if ok:
                alto = int(f.shape[0] * ancho / f.shape[1])
                frames.append(cv2.resize(f, (ancho, alto)))
                tiempos.append(i / fps)
        i += 1
    cap.release()
    tiempos = tiempos
    if len(frames) < 20:
        sys.exit("no pude leer suficientes frames del video")
    return frames, np.array(tiempos), fps, total / fps


def _pulsos(sen, umbral, tiempos, min_dur=0.6, min_hueco=0.35):
    """Tramos continuos por encima del umbral, uniendo los muy pegados."""
    on = sen > umbral
    crudos, ini = [], None
    for k, v in enumerate(on):
        if v and ini is None:
            ini = k
        if not v and ini is not None:
            crudos.append((ini, k - 1))
            ini = None
    if ini is not None:
        crudos.append((ini, len(on) - 1))

    unidos = []
    for a, b in crudos:
        if unidos and tiempos[a] - tiempos[unidos[-1][1]] < min_hueco:
            unidos[-1] = (unidos[-1][0], b)
        else:
            unidos.append((a, b))
    return [(a, b) for a, b in unidos if tiempos[b] - tiempos[a] >= min_dur]


def puntaje(sen, tiempos):
    """Que tanto se parece esta senal a "un rotulo que aparece y desaparece".

    Devuelve (puntaje, umbral, n_pulsos). Puntaje 0 = no sirve.

    Lo que se premia:
      - contraste entre el piso (sin rotulo) y las mesetas (con rotulo)
      - que el piso sea de verdad un piso: buena parte del video sin rotulo
      - que los pulsos sean varios y de duracion razonable

    Lo que se castiga: senales planas (la ROI mira algo que no cambia) y
    senales siempre encendidas (la ROI agarro a la persona o el fondo).
    """
    piso = float(np.percentile(sen, 5))
    techo = float(np.percentile(sen, 95))
    contraste = techo - piso
    if contraste < 0.02:
        return 0.0, 0.0, 0

    umbral = piso + 0.35 * contraste
    frac_piso = float(np.mean(sen <= piso + 0.15 * contraste))
    # Menos del 8% del video sin rotulo, o mas del 97%, no es un patron de
    # rotulos: es una escena fija, o un rotulo que casi nunca aparece.
    if not (0.08 <= frac_piso <= 0.97):
        return 0.0, umbral, 0

    tr = _pulsos(sen, umbral, tiempos)
    if len(tr) < 3:
        return 0.0, umbral, len(tr)

    duraciones = [tiempos[b] - tiempos[a] for a, b in tr]
    media = float(np.mean(duraciones))
    # Un rotulo dura entre medio segundo y medio minuto. Fuera de ahi
    # normalmente es ruido (parpadeos) o una escena entera.
    if not (0.5 <= media <= 30):
        return 0.0, umbral, len(tr)

    # Regularidad: en estos videos las senas duran algo parecido entre si,
    # asi que una desviacion chica respecto de la media es buena senal.
    regular = 1.0 / (1.0 + float(np.std(duraciones)) / max(media, 1e-6))
    return contraste * regular * min(len(tr), 60) / 60.0, umbral, len(tr)


def afinar_ancho(frames, banda, sen, umbral, margen=0.02):
    """Recorta la ROI a lo ancho, quedandose con las columnas que cambian.

    La franja horizontal ya acerto en el alto, pero suele sobrar ancho (el
    rotulo puede ocupar un tercio del cuadro). Comparando el promedio de
    los frames CON rotulo contra los SIN rotulo, las columnas del rotulo
    son las que difieren.
    """
    alto = frames[0].shape[0]
    y0, y1 = int(alto * banda[0]), int(alto * banda[1])
    con = [f[y0:y1] for f, s in zip(frames, sen) if s > umbral]
    sin = [f[y0:y1] for f, s in zip(frames, sen) if s <= umbral]
    if len(con) < 3 or len(sin) < 3:
        return 0.0, 1.0

    mc = np.mean([cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in con], axis=0)
    ms = np.mean([cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) for f in sin], axis=0)
    dif = np.abs(mc - ms).mean(axis=0)
    if dif.max() <= 1e-6:
        return 0.0, 1.0

    activas = np.nonzero(dif > dif.max() * 0.25)[0]
    if len(activas) == 0:
        return 0.0, 1.0
    ancho = frames[0].shape[1]
    return (max(0.0, activas[0] / ancho - margen),
            min(1.0, (activas[-1] + 1) / ancho + margen))


def _senal_densa(video, bandas, ancho=320, fps_objetivo=10.0):
    """Mide las bandas candidatas leyendo el video a ~10 fps.

    La pasada gruesa usa 240 muestras para descartar rapido, pero esa
    densidad no alcanza para decidir: umbral_sobre_piso estima el ruido a
    partir del cambio entre muestras consecutivas, y con muestras muy
    separadas ese ruido se infla y el umbral queda demasiado alto. A 10 fps
    el numero de segmentos ya predice bien el de la corrida real.
    """
    cap = cv2.VideoCapture(video)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    salto = max(1, int(round(fps / fps_objetivo)))
    series = {k: [] for k in range(len(bandas))}
    tiempos = []
    i = 0
    while True:
        if not cap.grab():
            break
        if i % salto == 0:
            ok, f = cap.retrieve()
            if ok:
                alto_f = int(f.shape[0] * ancho / f.shape[1])
                ch = cv2.resize(f, (ancho, alto_f))
                ch_tapado = None
                for k, (banda, nombre, x0, x1, mascara) in enumerate(bandas):
                    if mascara:
                        if ch_tapado is None:
                            ch_tapado = tapar_pip(ch)
                        base = ch_tapado
                    else:
                        base = ch
                    y0, y1 = int(alto_f * banda[0]), int(alto_f * banda[1])
                    rx0, rx1 = int(ancho * x0), int(ancho * x1)
                    series[k].append(SENALES[nombre](base[y0:y1, rx0:rx1]))
                tiempos.append(i / fps)
        i += 1
    cap.release()
    return {k: np.array(v) for k, v in series.items()}, np.array(tiempos)


def buscar(video, verboso=True, esperado=None, max_finalistas=6):
    frames, tiempos, fps, duracion = leer_muestras(video)
    alto = frames[0].shape[0]
    if verboso:
        print(f"  {len(frames)} muestras de {duracion:.0f}s "
              f"({frames[0].shape[1]}x{alto} reducido)")

    candidatos = []
    for alto_b in ALTOS_BANDA:
        y = 0.0
        while y + alto_b <= 1.0001:
            candidatos.append((round(y, 3), round(y + alto_b, 3)))
            y += PASO_BANDA

    # --- pasada 1: descartar rapido, quedarse con unos pocos finalistas ---
    tapados = [tapar_pip(f) for f in frames]
    puntuados = []
    for banda in candidatos:
        y0, y1 = int(alto * banda[0]), int(alto * banda[1])
        for con_mascara, lote in ((False, frames), (True, tapados)):
            for nombre, fn in SENALES.items():
                sen = np.array([fn(f[y0:y1]) for f in lote])
                p, umbral, n = puntaje(sen, tiempos)
                if p > 0:
                    x0, x1 = afinar_ancho(lote, banda, sen, umbral)
                    puntuados.append({"p": p, "banda": banda, "senal": nombre,
                                      "x0": x0, "x1": x1,
                                      "mascara_sep": con_mascara})
    if not puntuados:
        return None
    puntuados.sort(key=lambda c: -c["p"])
    # Sin repetir la misma banda con las dos senales: gastaria un finalista
    # en una variante casi identica en vez de probar otra franja.
    finalistas, vistas = [], set()
    for c in puntuados:
        clave = (c["banda"], c["mascara_sep"])
        if clave in vistas:
            continue
        vistas.add(clave)
        finalistas.append(c)
        if len(finalistas) == max_finalistas:
            break
    if verboso:
        print(f"  {len(puntuados)} franjas prometedoras; "
              f"midiendo {len(finalistas)} a fondo ...")

    # --- pasada 2: medir densamente y aplicar el umbral REAL ---
    bandas = [(c["banda"], c["senal"], c["x0"], c["x1"], c["mascara_sep"])
              for c in finalistas]
    series, t2 = _senal_densa(video, bandas)

    medidos = []
    for k, c in enumerate(finalistas):
        sen = series[k]
        if len(sen) < 30:
            continue
        u = umbral_sobre_piso(sen)
        tr = _pulsos(sen, u, t2, min_dur=1.0, min_hueco=0.15)
        if len(tr) < 3:
            if verboso:
                print(f"    descarto {c['banda']} {c['senal']}: "
                      f"solo {len(tr)} tramo(s)")
            continue
        dur = [t2[b] - t2[a] for a, b in tr]
        # Un solo tramo gigante (la ROI nunca vuelve al piso) es la falla
        # tipica de una franja mal elegida: se castiga fuerte.
        if max(dur) > 0.35 * duracion:
            if verboso:
                print(f"    descarto {c['banda']} {c['senal']}: un tramo de "
                      f"{max(dur):.0f}s (la ROI no vuelve al piso)")
            continue
        regular = 1.0 / (1.0 + float(np.std(dur)) / max(float(np.mean(dur)), 1e-6))
        if esperado:
            # Cuando se sabe cuantas senas trae el video, ese dato vale mas
            # que cualquier heuristica: se premia acercarse al numero.
            cal = regular * 100.0 / (1.0 + abs(len(tr) - esperado))
        else:
            cal = len(tr) * regular
        if verboso:
            print(f"    {c['banda']} {c['senal']:<6}"
                  f"{' +mascara' if c['mascara_sep'] else '         '}"
                  f" -> {len(tr):>3} segmentos, dur media {np.mean(dur):.1f}s")
        medidos.append({
            "cal": cal,
            "roi": f"{c['x0']:.3f},{c['banda'][0]:.3f},{c['x1']:.3f},{c['banda'][1]:.3f}",
            "senal": c["senal"],
            "mascara_sep": c["mascara_sep"],
            "segmentos_estimados": len(tr),
            "duracion_media_s": round(float(np.mean(dur)), 2),
        })

    if not medidos:
        return None

    medidos.sort(key=lambda m: -m["cal"])
    for m in medidos:
        m.pop("cal", None)
    mejor = dict(medidos[0])
    mejor["duracion_s"] = round(duracion, 1)
    mejor["opciones"] = medidos
    return mejor


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--esperado", type=int,
                    help="cuantas senas trae el video, si lo sabes. Es el dato "
                         "que mas ayuda: entre varias franjas plausibles se "
                         "queda con la que da ese numero de segmentos.")
    ap.add_argument("--json", action="store_true",
                    help="imprime solo el resultado como JSON")
    args = ap.parse_args()

    if not args.json:
        print("Buscando donde esta el rotulo ...")
    r = buscar(args.video, verboso=not args.json, esperado=args.esperado)

    if r is None:
        if args.json:
            print(json.dumps({"error": "no encontre ninguna franja con rotulos"}))
        else:
            print("\nNo encontre ninguna franja que se comporte como un rotulo.")
            print("Puede que el video no tenga texto en pantalla. En ese caso")
            print("hay que poner los tiempos a mano, o usar los subtitulos del")
            print("video si los trae.")
        sys.exit(1)

    if args.json:
        print(json.dumps(r, ensure_ascii=False))
        return

    print(f"\n  ROI    : {r['roi']}")
    print(f"  senal  : {r['senal']}")
    print(f"  mascara del interprete: {'si' if r['mascara_sep'] else 'no'}")
    print(f"  estimo : {r['segmentos_estimados']} segmentos")
    if len(r.get("opciones", [])) > 1:
        print("\n  otras franjas que tambien sirven:")
        for o in r["opciones"][1:]:
            print(f"    {o['segmentos_estimados']:>3} segmentos  "
                  f"roi {o['roi']}  senal {o['senal']}"
                  f"{'  +mascara' if o['mascara_sep'] else ''}")
    print(f"\npython tools/segmentar_video.py --video \"{args.video}\" \\\n"
          f"    --roi {r['roi']} --senal {r['senal']} --formato palabra"
          + (" \\\n    --mascara-sep" if r["mascara_sep"] else ""))


if __name__ == "__main__":
    main()
