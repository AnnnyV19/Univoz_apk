"""Genera golden/golden_cases.json a partir de la implementacion de Python.
Ese archivo es el contrato que la implementacion de Dart debe cumplir.

Correr desde la raiz del proyecto:  python3 python/gen_golden.py
"""

import json
import os
import random

import sign_norm as sn
import dtw as D

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "test", "golden", "golden_cases.json")


def make_pose(rng, cx, cy, w):
    """Cuerpo sintetico pero plausible: hombros separados w, resto colgando."""
    pose = []
    for i in range(33):
        pose.append([
            round(cx + rng.uniform(-0.3, 0.3), 6),
            round(cy + rng.uniform(-0.3, 0.3), 6),
            round(rng.uniform(-0.1, 0.1), 6),
            round(rng.uniform(0.7, 1.0), 6),
        ])
    pose[sn.L_SHOULDER] = [round(cx - w / 2, 6), round(cy, 6), 0.0, 0.99]
    pose[sn.R_SHOULDER] = [round(cx + w / 2, 6), round(cy + 0.02, 6), 0.0, 0.98]
    return pose


def make_pose_mundo(rng, w=0.32, inclinacion=0.0):
    """Esqueleto METRICO sintetico, en metros, con origen en las caderas.

    Ejes de MediaPipe worldLandmarks: X a la derecha de la imagen, Y hacia
    abajo, Z creciendo al alejarse de la camara. La persona mira a la camara,
    asi que su hombro IZQUIERDO (indice 11) cae del lado +X.

    [inclinacion] inclina el tronco hacia adelante en radianes, para que los
    casos no tengan la base perfectamente vertical y el golden ejercite la
    ortogonalizacion.
    """
    import math
    alto_tronco = 0.50
    ca, sa = math.cos(inclinacion), math.sin(inclinacion)

    w3 = []
    for i in range(33):
        w3.append([
            round(rng.uniform(-0.4, 0.4), 6),
            round(rng.uniform(-0.9, 0.2), 6),
            round(rng.uniform(-0.3, 0.3), 6),
        ])
    # Caderas en el origen, hombros arriba (Y negativa) y algo adelantados.
    w3[sn.L_HIP] = [round(w / 2 * 0.8, 6), 0.0, 0.0]
    w3[sn.R_HIP] = [round(-w / 2 * 0.8, 6), 0.0, 0.0]
    w3[sn.L_SHOULDER] = [round(w / 2, 6), round(-alto_tronco * ca, 6),
                         round(-alto_tronco * sa, 6)]
    w3[sn.R_SHOULDER] = [round(-w / 2, 6), round(-alto_tronco * ca, 6),
                         round(-alto_tronco * sa, 6)]
    # Brazos conectados (pose_geometry exige segmentos plausibles): codo
    # ~0.28 m bajo el hombro y muneca ~0.25 m bajo el codo, con ruido.
    for hombro, codo, muneca, lado in ((sn.L_SHOULDER, 13, sn.L_WRIST, 1),
                                       (sn.R_SHOULDER, 14, sn.R_WRIST, -1)):
        h = w3[hombro]
        c = [h[0] + lado * rng.uniform(0.0, 0.06), h[1] + 0.28,
             h[2] + rng.uniform(-0.05, 0.05)]
        m = [c[0] + rng.uniform(-0.12, 0.12), c[1] + rng.uniform(0.10, 0.25),
             c[2] + rng.uniform(-0.15, 0.0)]
        w3[codo] = [round(v, 6) for v in c]
        w3[muneca] = [round(v, 6) for v in m]
    return w3


# Mano abierta relativa a la muneca, con el MCP medio a 0.10 (rig_motion_frame
# .test.mjs): hand_usable exige conexiones plausibles.
MANO = [(0.0, 0.0), (-0.06, -0.05), (-0.11, -0.10), (-0.14, -0.16),
        (-0.16, -0.22), (-0.04, -0.08), (-0.05, -0.16), (-0.06, -0.24),
        (-0.06, -0.32), (0.0, -0.10), (0.0, -0.20), (0.0, -0.30),
        (0.0, -0.40), (0.04, -0.09), (0.06, -0.18), (0.07, -0.26),
        (0.08, -0.34), (0.08, -0.06), (0.11, -0.13), (0.13, -0.19),
        (0.14, -0.24)]


def make_hand(rng, cx, cy, tam=0.6):
    """Mano plausible con la muneca en (cx, cy): forma abierta, algo girada,
    con ruido chico en cada punto."""
    import math
    ang = rng.uniform(-0.4, 0.4)
    ca, sa = math.cos(ang), math.sin(ang)
    hand = []
    for i, (dx, dy) in enumerate(MANO):
        x = (dx * ca - dy * sa) * tam
        y = (dx * sa + dy * ca) * tam
        if i:
            x += rng.uniform(-0.003, 0.003)
            y += rng.uniform(-0.003, 0.003)
        hand.append([round(cx + x, 6), round(cy + y, 6),
                     0.0 if i == 0 else round(rng.uniform(-0.03, 0.0), 6)])
    return hand


def _frame_base(rng):
    return {
        "pose": make_pose(rng, 0.5, 0.45, 0.24),
        "pose_mundo": make_pose_mundo(rng, 0.32, 0.10),
        "left": make_hand(rng, 0.38, 0.72),
        "right": make_hand(rng, 0.63, 0.70),
    }


def build_validaciones():
    """Un frame por motivo de rechazo de normalize_frame (mismos codigos que
    normalizeMotionFrame en la web) y las munecas de render."""
    import copy
    rng = random.Random(23)
    base = _frame_base(rng)
    casos = []

    def caso(nombre, cambiar=None, render_wrists=None):
        f = copy.deepcopy(base)
        if cambiar:
            cambiar(f)
        if render_wrists is not None:
            f["render_wrists"] = render_wrists
        motivos = []
        v = sn.normalize_frame(f["pose"], f["pose_mundo"], f["left"], f["right"],
                               render_wrists=f.get("render_wrists"),
                               motivos=motivos)
        casos.append({
            "name": nombre,
            "frame": f,
            "expected": v,
            "motivos": [[m["stage"], m["code"], m["side"], m["landmark"]]
                        for m in motivos],
        })

    def punto(lista, i, x, y, z=0.0):
        lista[i] = [x, y, z] + lista[i][3:]

    caso("valido")
    caso("mano_segmento_roto", lambda f: punto(f["left"], 12, 0.38, 0.05))
    caso("mano_muneca_fuera", lambda f: punto(f["right"], 0, 1.05, 0.70))
    caso("mano_escala_invalida", lambda f: f.update(left=[
        [0.38 + (p[0] - 0.38) * 0.05, 0.72 + (p[1] - 0.72) * 0.05, p[2]]
        for p in f["left"]]))
    caso("mano_incompleta", lambda f: f.update(right=f["right"][:20]))
    caso("hombro_tenue", lambda f: f["pose"][sn.L_SHOULDER].__setitem__(3, 0.3))
    caso("hombro_fuera_de_cuadro",
         lambda f: punto(f["pose"], sn.R_SHOULDER, 1.3, 0.47))
    caso("brazo_desconectado",
         lambda f: punto(f["pose_mundo"], sn.L_WRIST, 3.0, 2.0, 1.0))
    caso("tronco_invalido", lambda f: [
        punto(f["pose_mundo"], i, f["pose_mundo"][i][0],
              f["pose_mundo"][sn.L_SHOULDER][1] + 0.01, 0.0)
        for i in (sn.L_HIP, sn.R_HIP)])
    wl, wr = base["pose"][sn.L_WRIST], base["pose"][sn.R_WRIST]
    caso("munecas_render", render_wrists={
        "left": [wl[0] + 0.03, wl[1] + 0.01, 0.0],
        "right": [5.0, wr[1], 0.0],  # acotado a 0.75 anchos de hombro
    })
    return casos


def build_cases():
    rng = random.Random(7)
    cases = []

    # caso 1: las dos manos presentes en los 3 frames
    frames = []
    for k in range(3):
        frames.append({
            "pose": make_pose(rng, 0.5, 0.45 + 0.01 * k, 0.24),
            "pose_mundo": make_pose_mundo(rng, 0.32, 0.10 + 0.02 * k),
            "left": make_hand(rng, 0.38, 0.60 - 0.03 * k),
            "right": make_hand(rng, 0.63, 0.58 - 0.02 * k),
        })
    cases.append({"name": "dos_manos", "frames": frames})

    # caso 2: mano izquierda ausente, cuerpo mas chico y descentrado
    frames = []
    for k in range(3):
        frames.append({
            "pose": make_pose(rng, 0.32, 0.55 + 0.02 * k, 0.15),
            "pose_mundo": make_pose_mundo(rng, 0.28, -0.05 * k),
            "left": None,
            "right": make_hand(rng, 0.40, 0.66 - 0.04 * k),
        })
    cases.append({"name": "una_mano", "frames": frames})

    for c in cases:
        raw = [(f["pose"], f["pose_mundo"], f["left"], f["right"])
               for f in c["frames"]]
        norm = [sn.normalize_frame(p, pm, l, r) for (p, pm, l, r) in raw]
        assert all(f is not None for f in norm), c["name"]
        c["expected_frames"] = norm
        c["expected_mirror_frame0"] = sn.mirror_frame(norm[0])
        c["expected_resample_5"] = sn.resample(norm, 5)

    # Expectativas del DTW, calculadas sobre los frames ya normalizados de
    # los casos de arriba. Asi el golden no crece: reutiliza los mismos datos.
    a = cases[0]["expected_frames"]
    b = cases[1]["expected_frames"]
    dtw_block = {
        "frame_distances": [[D.frame_distance(fa, fb) for fb in b] for fa in a],
        "dtw_a_a": D.dtw_distance(a, a),
        "dtw_a_b": D.dtw_distance(a, b),
        "dtw_b_a": D.dtw_distance(b, a),
        "signature_a": D.signature(a),
        "pesos": {
            "body": D.W_BODY, "loc": D.W_LOC,
            "pres": D.W_PRES, "shape": D.W_SHAPE,
            "shape_penalty": D.SHAPE_PENALTY, "band": D.BAND,
        },
    }

    return {
        "norm_version": sn.NORM_VERSION,
        "frame_dim": sn.FRAME_DIM,
        "tolerance": 1e-5,
        "cases": cases,
        "validaciones": build_validaciones(),
        "dtw": dtw_block,
    }


if __name__ == "__main__":
    data = build_cases()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        json.dump(data, f, indent=1)
    print("escrito:", os.path.normpath(OUT))
    print("casos:", len(data["cases"]), "| dim:", data["frame_dim"])
