"""BodyProfileV1: medidas del cuerpo del usuario + modelo de capacidad.

Implementacion CANONICA (Dart: lib/body_profile.dart, JS:
assets/avatar_viewer/rig_body_profile.mjs; golden en
test/golden/sign_space_cases.json).

Se estima con Fast User Capture: unos segundos de frames (pose de imagen +
worldLandmarks) en poses guiadas. Toma la MEDIANA de cada medida sobre los
frames donde el segmento es visible, para que un frame malo no la mueva.

Capacidad: cada miembro queda como
  "ok"            visto en la mayoria de los frames
  "partial"       visto a veces (oclusion, movilidad reducida)
  "not_observed"  casi nunca visto durante la captura
  "absent"        SOLO si el usuario lo declara (amputacion); la camara no
                  puede distinguir "ausente" de "fuera de cuadro"
Lo declarado por el usuario siempre gana. El perfil vive fuera de 152D y de
SignSpaceFrame (CapabilityMask externo), es local, versionado y borrable.
"""

import math

import sign_space as ss

BODY_PROFILE_VERSION = "1.0.0"
MIN_SAMPLES = 20
OK_RATIO = 0.6
SEEN_RATIO = 0.1

LIMBS = ("armL", "armR", "handL", "handR")
STATUSES = ("ok", "partial", "not_observed", "absent")


def _dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def _mediana(xs):
    s = sorted(xs)
    n = len(s)
    if n == 0:
        return None
    m = n // 2
    return s[m] if n % 2 else (s[m - 1] + s[m]) * 0.5


def estimate(frames, declared=None, min_samples=MIN_SAMPLES,
             min_visibility=ss.MIN_VISIBILITY):
    """frames: lista de (pose, pose_mundo). declared: dict miembro->estado
    declarado por el usuario (p. ej. {"handL": "absent"})."""
    declared = dict(declared or {})
    for k, v in declared.items():
        if k not in LIMBS or v not in STATUSES:
            raise ValueError("declaracion invalida: %s=%s" % (k, v))

    muestras = {k: [] for k in ("shoulderWidth", "upperL", "upperR", "foreL",
                                "foreR", "handL", "handR", "neck")}
    alcance = {"armL": [], "armR": []}
    vistos = {k: 0 for k in LIMBS}
    n = 0

    def vis(pose, i):
        return len(pose[i]) >= 4 and pose[i][3] >= min_visibility

    for pose, w in frames:
        if pose is None or w is None or len(pose) < 33 or len(w) < 33:
            continue
        if not (vis(pose, ss.L_SHOULDER) and vis(pose, ss.R_SHOULDER)):
            continue
        n += 1
        muestras["shoulderWidth"].append(_dist(w[ss.L_SHOULDER],
                                               w[ss.R_SHOULDER]))
        for lado, hombro, codo, muneca, menique, indice in (
                ("L", ss.L_SHOULDER, ss.L_ELBOW, ss.L_WRIST, ss.L_PINKY,
                 ss.L_INDEX),
                ("R", ss.R_SHOULDER, ss.R_ELBOW, ss.R_WRIST, ss.R_PINKY,
                 ss.R_INDEX)):
            if vis(pose, codo) and vis(pose, muneca):
                brazo = _dist(w[hombro], w[codo])
                antebrazo = _dist(w[codo], w[muneca])
                muestras["upper" + lado].append(brazo)
                muestras["fore" + lado].append(antebrazo)
                vistos["arm" + lado] += 1
                if brazo + antebrazo > ss.EPS:
                    alcance["arm" + lado].append(
                        _dist(w[hombro], w[muneca]) / (brazo + antebrazo))
            if vis(pose, muneca):
                nudillos = [(w[menique][i] + w[indice][i]) * 0.5
                            for i in range(3)]
                muestras["hand" + lado].append(_dist(w[muneca], nudillos))
                vistos["hand" + lado] += 1
        if vis(pose, ss.NOSE):
            origen = [(w[ss.L_SHOULDER][i] + w[ss.R_SHOULDER][i]) * 0.5
                      for i in range(3)]
            boca = [(w[ss.MOUTH_L][i] + w[ss.MOUTH_R][i]) * 0.5
                    for i in range(3)]
            muestras["neck"].append(_dist(origen, boca))

    medidas = {k: (_mediana(v) if len(v) >= min_samples else None)
               for k, v in muestras.items()}

    capacidad = {}
    for limb in LIMBS:
        if limb in declared:
            capacidad[limb] = declared[limb]
            continue
        ratio = vistos[limb] / n if n else 0.0
        if n >= min_samples and ratio >= OK_RATIO:
            capacidad[limb] = "ok"
        elif n >= min_samples and ratio < SEEN_RATIO:
            capacidad[limb] = "not_observed"
        else:
            capacidad[limb] = "partial"

    rom = {k: (max(v) if len(v) >= min_samples else None)
           for k, v in alcance.items()}

    return {
        "version": BODY_PROFILE_VERSION,
        "samples": n,
        "measures": medidas,
        "rom": rom,
        "capability": capacidad,
        "declared": declared,
    }
