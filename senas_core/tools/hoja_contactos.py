#!/usr/bin/env python3
"""Arma una hoja de contactos: una sola imagen con N fotogramas del video,
cada uno con su tiempo escrito encima.

Sirve para MIRAR un video antes de escribir codigo que lo procese -- donde
esta el rotulo, si la persona sale entera o solo las manos, cuanto dura cada
sena, si hay transiciones. Es mas barato que deducirlo y equivocarse.

Uso:
    python tools/hoja_contactos.py --video "videos/descargados/algo.mp4"
    python tools/hoja_contactos.py --video "..." --n 24 --salida contactos.png

Con --desde y --hasta mira solo un tramo (en segundos), para ampliar una
zona concreta:
    python tools/hoja_contactos.py --video "..." --desde 10 --hasta 20 --n 12
"""

import argparse
import os
import sys

import cv2
import numpy as np


def guardar_imagen(path, img):
    """cv2.imwrite() no escribe bien en rutas con acentos o ñ en Windows:
    deja el nombre con caracteres rotos, o directamente no escribe."""
    ok, buf = cv2.imencode(os.path.splitext(path)[1] or ".png", img)
    if not ok:
        return False
    with open(path, "wb") as f:
        f.write(buf.tobytes())
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--video", required=True)
    ap.add_argument("--n", type=int, default=12, help="cuantos fotogramas (default 12)")
    ap.add_argument("--columnas", type=int, default=4)
    ap.add_argument("--ancho", type=int, default=420, help="ancho de cada miniatura en px")
    ap.add_argument("--desde", type=float, default=0.0, help="segundo inicial")
    ap.add_argument("--hasta", type=float, help="segundo final (default: fin del video)")
    ap.add_argument("--salida", default="contactos.png")
    args = ap.parse_args()

    if not os.path.exists(args.video):
        sys.exit(f"no existe el video: {args.video}")

    cap = cv2.VideoCapture(args.video)
    if not cap.isOpened():
        sys.exit("OpenCV no pudo abrir el video (codec no soportado?)")

    fps = cap.get(cv2.CAP_PROP_FPS) or 0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    if fps <= 0 or total <= 0:
        sys.exit("el video no reporta fps/frames: OpenCV lo abrio pero no lo puede leer")
    duracion = total / fps
    print(f"{os.path.basename(args.video)}: {duracion:.1f}s, {total} frames a {fps:.1f} fps")

    hasta = args.hasta if args.hasta is not None else duracion
    desde = max(0.0, args.desde)
    hasta = min(hasta, duracion)
    if hasta <= desde:
        sys.exit("--hasta tiene que ser mayor que --desde")

    tiempos = np.linspace(desde, hasta, args.n, endpoint=False)
    miniaturas = []
    for t in tiempos:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(t * fps))
        ok, frame = cap.read()
        if not ok:
            continue
        alto = int(frame.shape[0] * args.ancho / frame.shape[1])
        chica = cv2.resize(frame, (args.ancho, alto))
        etiqueta = f"{int(t // 60)}:{t % 60:05.2f}"
        cv2.putText(chica, etiqueta, (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 0), 4)
        cv2.putText(chica, etiqueta, (8, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
        miniaturas.append(chica)
    cap.release()

    if not miniaturas:
        sys.exit("no pude leer ningun fotograma")

    cols = args.columnas
    filas = []
    for i in range(0, len(miniaturas), cols):
        grupo = miniaturas[i:i + cols]
        while len(grupo) < cols:
            grupo.append(np.zeros_like(miniaturas[0]))
        filas.append(np.hstack(grupo))
    hoja = np.vstack(filas)

    guardar_imagen(args.salida, hoja)
    print(f"Listo: {args.salida}  ({hoja.shape[1]}x{hoja.shape[0]} px)")


if __name__ == "__main__":
    main()
