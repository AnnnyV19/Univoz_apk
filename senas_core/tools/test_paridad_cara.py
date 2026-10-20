"""Los 17 puntos de cara que manda Android deben ser los mismos en Kotlin,
Dart y el visor; si derivan, la cabeza y las expresiones se calculan con
puntos equivocados sin ningun error visible."""

import os
import re

RAIZ = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def _leer(ruta):
    with open(os.path.join(RAIZ, ruta), encoding="utf-8") as f:
        return f.read()


def _enteros(patron, texto):
    m = re.search(patron, texto, flags=re.S)
    assert m, patron
    return [int(x) for x in re.findall(r"\d+", m.group(1))]


def test_puntos_de_cara_iguales_en_kotlin_dart_y_visor():
    kt = _enteros(r"FACE_KEYPOINTS = intArrayOf\(([^)]*)\)", _leer(
        "android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt"))
    js = _enteros(r"FACE_KEYPOINTS = Object\.freeze\(\[([^\]]*)\]", _leer(
        "assets/avatar_viewer/rig_face.mjs"))
    dart = _enteros(r"kFaceKeypoints = \[([^\]]*)\]", _leer("lib/camera_bridge.dart"))
    assert len(kt) == 17
    assert kt == js == dart
