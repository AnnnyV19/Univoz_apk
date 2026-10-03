"""Copia el motor de captura Kotlin de senas_core a univoz/android.

univoz/ es la app producto y no puede depender del codigo Android de
senas_core por Gradle, asi que lleva una COPIA de estos archivos. Este
script la regenera para que nunca deriven (como inline_viewer_modules.py
hace con el visor).

  python3 tools/sincronizar_kotlin.py          # copia
  python3 tools/sincronizar_kotlin.py --check  # falla si difieren
"""

import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORIGEN = os.path.normpath(os.path.join(
    HERE, "..", "android", "app", "src", "main", "kotlin", "com", "univoz", "senas"))
DESTINO = os.path.normpath(os.path.join(
    HERE, "..", "..", "univoz", "android", "app", "src", "main", "kotlin"))
ARCHIVOS = ["LandmarkPlugin.kt", "LandmarkEngine.kt", "HandTrackCoordinator.kt",
            "HandCandidateGate.kt"]


def main(check):
    if not os.path.isdir(DESTINO):
        print("sin univoz/android; nada que sincronizar")
        return 0
    distintos = []
    for nombre in ARCHIVOS:
        a, b = os.path.join(ORIGEN, nombre), os.path.join(DESTINO, nombre)
        if not os.path.exists(b) or open(a, "rb").read() != open(b, "rb").read():
            distintos.append(nombre)
            if not check:
                shutil.copy2(a, b)
    if check:
        for n in distintos:
            print("DERIVA Kotlin:", n)
        return 1 if distintos else 0
    print("Kotlin sincronizado;", len(distintos), "archivos copiados")
    return 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv))
