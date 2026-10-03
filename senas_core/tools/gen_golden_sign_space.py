"""Genera test/golden/sign_space_cases.json desde las implementaciones de
Python (sign_space.py y body_profile.py). Ese archivo es el contrato que Dart
y JS deben cumplir.

Correr desde senas_core/:  python3 tools/gen_golden_sign_space.py
"""

import json
import os
import random

import body_profile as bp
import sign_space as ss
from sintetico_cuerpo import esqueleto

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "golden", "sign_space_cases.json")


def ruido(rng, pose, mundo, amp=0.01):
    """Ruido fijo para que el golden no dependa de simetrias perfectas."""
    mundo = [[round(v + rng.uniform(-amp, amp), 6) for v in p] for p in mundo]
    pose = [[round(v, 6) for v in p] for p in pose]
    return pose, mundo


def frame_case(rng, name, pose_mundo, mutar=None, profile=None):
    pose, mundo = ruido(rng, *pose_mundo)
    if mutar:
        mutar(pose, mundo)
    case = {"name": name, "pose": pose, "pose_mundo": mundo,
            "expected": ss.sign_space_frame(pose, mundo, profile=profile)}
    if profile is not None:
        case["profile"] = profile
    return case


def build():
    rng = random.Random(11)
    cases = [
        frame_case(rng, "de_pie", esqueleto()),
        frame_case(rng, "girado_escalado",
                   esqueleto(giro=0.5, escala=1.3, mover=(0.2, -0.1, 0.4),
                             palma=(0.1, 0.0, 0.25))),
        frame_case(rng, "toca_boca", esqueleto(palma=(0.0, 0.17, 0.10))),
        frame_case(rng, "nino", esqueleto(ancho=0.26, brazo=0.19,
                                          antebrazo=0.16, cuello=0.15,
                                          palma=(0.0, -0.06, 0.10))),
        frame_case(rng, "sentado_sin_caderas", esqueleto(caderas=False)),
    ]

    def codo_oculto(pose, _):
        pose[ss.L_ELBOW][3] = 0.1

    def sin_cara(pose, _):
        pose[ss.NOSE][3] = 0.2

    def sin_hombro(pose, _):
        pose[ss.R_SHOULDER][3] = 0.2

    cases.append(frame_case(rng, "codo_oculto", esqueleto(), codo_oculto))
    cases.append(frame_case(rng, "sin_cara", esqueleto(), sin_cara))
    cases.append(frame_case(rng, "sin_hombro", esqueleto(), sin_hombro))

    def codo_der_oculto(pose, _):
        pose[ss.R_ELBOW][3] = 0.1

    perfil = {"version": "1.0.0", "measures": {
        "upperL": 0.30, "foreL": 0.26, "upperR": 0.30, "foreR": 0.26}}
    perfil_largo = {"version": "1.0.0", "measures": {
        "upperL": 0.34, "foreL": 0.30, "upperR": 0.34, "foreR": 0.30}}
    cases.append(frame_case(rng, "codo_oculto_con_perfil",
                            esqueleto(palma=(0.10, 0.05, 0.20)),
                            codo_der_oculto, perfil))
    cases.append(frame_case(rng, "codo_oculto_perfil_largo",
                            esqueleto(palma=(0.10, 0.05, 0.20)),
                            codo_der_oculto, perfil_largo))

    def captura(n, **kw):
        frames = []
        for k in range(n):
            t = k / max(1, n - 1)
            palma = (0.25 - 0.3 * t, -0.25 + 0.4 * t, 0.15 + 0.1 * t)
            pose, mundo = ruido(rng, *esqueleto(palma=palma, **kw), amp=0.005)
            frames.append({"pose": pose, "pose_mundo": mundo})
        return frames

    profiles = []
    for name, frames, declared, mutar in (
            ("adulto", captura(24), {}, None),
            ("nino", captura(24, ancho=0.26, brazo=0.19, antebrazo=0.16,
                             cuello=0.15), {}, None),
            ("mano_izq_declarada", captura(24), {"handL": "absent"},
             "ocultar_izq"),
            ("pocas_muestras", captura(6), {}, None)):
        if mutar == "ocultar_izq":
            for f in frames:
                f["pose"][ss.L_ELBOW][3] = 0.05
                f["pose"][ss.L_WRIST][3] = 0.05
        got = bp.estimate([(f["pose"], f["pose_mundo"]) for f in frames],
                          declared=declared, min_samples=20)
        profiles.append({"name": name, "frames": frames, "declared": declared,
                         "min_samples": 20,
                         "expected": {"measures": got["measures"],
                                      "capability": got["capability"],
                                      "rom": got["rom"],
                                      "samples": got["samples"]}})

    # Mismo gesto (palma en la boca) con cuerpos de proporciones distintas:
    # el retargeter debe llevar la palma del avatar al mismo lugar de SU
    # cara en todos (rig-tests/rig_retarget.test.mjs).
    contact_cases = []
    for name, kw in (("adulto", {}),
                     ("brazos_cortos", {"brazo": 0.20, "antebrazo": 0.17}),
                     ("brazos_largos", {"brazo": 0.40, "antebrazo": 0.35}),
                     ("nino", {"ancho": 0.26, "brazo": 0.19, "antebrazo": 0.16,
                               "cuello": 0.15}),
                     ("sentado", {"caderas": False})):
        cuello = kw.get("cuello", 0.22)
        pose, mundo = esqueleto(palma=(0.0, cuello - 0.05, 0.10), **kw)
        contact_cases.append({"name": name, "pose": pose, "pose_mundo": mundo})

    return {
        "contact_cases": contact_cases,
        "version": ss.SIGN_SPACE_VERSION,
        "profile_version": bp.BODY_PROFILE_VERSION,
        "dim": ss.SIGN_SPACE_DIM,
        "tolerance": 1e-5,
        "cases": cases,
        "profiles": profiles,
    }


if __name__ == "__main__":
    data = build()
    with open(OUT, "w") as fh:
        json.dump(data, fh, separators=(",", ":"))
    print("escrito:", os.path.normpath(OUT))
    print("casos:", len(data["cases"]), "| perfiles:", len(data["profiles"]))
