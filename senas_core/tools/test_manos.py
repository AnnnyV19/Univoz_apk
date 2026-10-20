#!/usr/bin/env python3
"""Comprueba que izquierda y derecha se asignen por anatomia, no por la
etiqueta de MediaPipe.

Por que existe este test: el lado nativo de la app
(HandTrackCoordinator.kt) decide el lado comparando cada mano contra las
munecas del modelo de pose, y trata la etiqueta "Left"/"Right" como mucho
como evidencia secundaria. El Python usaba solo la etiqueta. Como la
convencion de MediaPipe supone una imagen espejada, en un video grabado con
camara trasera sale al reves -- y entonces la MISMA sena ingerida por video
y capturada en vivo quedaba con las manos cruzadas entre si, que es
justamente lo que el reconocimiento compara.

Este test no necesita MediaPipe ni los modelos .task: arma munecas y manos
a mano y comprueba solo la decision.

    python tools/test_manos.py
"""

import os
import sys

AQUI = os.path.dirname(os.path.abspath(__file__))


def cargar_asignar_manos():
    """Saca asignar_manos() de extraer_landmarks.py sin importar el modulo
    entero, que arrastraria mediapipe y cv2 solo para esto."""
    src = open(os.path.join(AQUI, "extraer_landmarks.py"), encoding="utf-8").read()
    cabeza = src.split("class ExtractorLandmarks")[0]
    cabeza = "\n".join(
        l for l in cabeza.splitlines()
        if not l.startswith(("import cv2", "import mediapipe", "from mediapipe"))
    )
    ns = {}
    exec(compile(cabeza, "extraer_landmarks(parcial)", "exec"), ns)
    return ns["asignar_manos"]


def mano(x, y):
    """21 puntos. Solo pesa el [0], que es la muneca de la propia mano."""
    return [[x, y, 0.0]] + [[x + i * 0.001, y, 0.0] for i in range(1, 21)]


def pose_con(muneca_izq, muneca_der):
    p = [[0.5, 0.5, 0.0, 1.0] for _ in range(33)]
    p[15] = [muneca_izq[0], muneca_izq[1], 0.0, 1.0]   # L_WRIST
    p[16] = [muneca_der[0], muneca_der[1], 0.0, 1.0]   # R_WRIST
    return p


def main():
    asignar = cargar_asignar_manos()

    # Ojo con la intuicion: mirando a camara, la mano IZQUIERDA de la
    # persona sale a la DERECHA del cuadro. Da igual -- lo que decide es
    # contra que muneca de la pose cae mas cerca, no en que mitad esta.
    pose = pose_con(muneca_izq=(0.75, 0.5), muneca_der=(0.25, 0.5))
    izq = mano(0.74, 0.51)
    der = mano(0.26, 0.49)

    # Dos manos muy juntas frente al pecho: decidir de a una las mandaria a
    # la misma muneca. Por eso se compara el emparejamiento completo.
    pose_juntas = pose_con(muneca_izq=(0.55, 0.40), muneca_der=(0.45, 0.40))
    ja = mano(0.56, 0.41)
    jb = mano(0.46, 0.41)

    casos = [
        ("dos manos, orden normal",        asignar([izq, der], pose),      (izq, der)),
        ("dos manos, orden invertido",     asignar([der, izq], pose),      (izq, der)),
        ("solo la izquierda",              asignar([izq], pose),           (izq, None)),
        ("solo la derecha",                asignar([der], pose),           (None, der)),
        ("sin manos",                      asignar([], pose),              (None, None)),
        ("una mano sin pose se descarta",  asignar([izq], None),           (None, None)),
        ("manos juntas al centro",         asignar([jb, ja], pose_juntas), (ja, jb)),
    ]

    fallos = 0
    for nombre, obtenido, esperado in casos:
        ok = obtenido[0] is esperado[0] and obtenido[1] is esperado[1]
        fallos += not ok
        print(f"  {'ok   ' if ok else 'FALLA'} {nombre}")

    print()
    if fallos:
        print(f"FALLARON {fallos} comprobaciones")
        sys.exit(1)
    print("todo en orden")


if __name__ == "__main__":
    main()
