"""Audit Sentinel offline: anomalias por frame contra el perfil corporal.

Trabaja sobre sesiones grabadas (SessionLogV1, web o Android), que guardan
landmarks crudos de pose en metros. Para cada frame:

  - longitud osea vs BodyProfileV1 (brazo, antebrazo, ancho de hombros):
    desvio relativo / tolerancia, combinado como distancia de Mahalanobis
    diagonal (raiz de la media de z^2). El perfil solo guarda medianas, asi
    que la varianza se modela como una tolerancia relativa fija.
  - teletransporte de muneca: velocidad en anchos de hombro por segundo.

Solo se miden segmentos visibles (visibility de la pose >= 0.5).
"""

import math

TOLERANCIA = 0.12       # desvio relativo que cuenta como 1 sigma
VEL_TELEPORT = 8.0      # anchos de hombro por segundo
MIN_VIS = 0.5

SEGMENTOS = {
    "shoulderWidth": (11, 12),
    "upperL": (11, 13), "foreL": (13, 15),
    "upperR": (12, 14), "foreR": (14, 16),
}


def _dist(a, b):
    return math.sqrt(sum((a[i] - b[i]) ** 2 for i in range(3)))


def _vis(pose, i):
    try:
        return pose[i][3] >= MIN_VIS
    except (IndexError, TypeError):
        return False


def auditar_frame(frame, medidas, previo=None):
    """{'d': distancia, 'z': {segmento: z}, 'codes': [...]}, o None si el
    frame no trae pose/mundo."""
    pose, mundo = frame.get("pose"), frame.get("world")
    if not pose or not mundo or len(mundo) < 17 or len(pose) < 17:
        return None
    zs, codes = {}, []
    for nombre, (a, b) in SEGMENTOS.items():
        ref = (medidas or {}).get(nombre)
        if not ref or not (_vis(pose, a) and _vis(pose, b)):
            continue
        z = abs(_dist(mundo[a], mundo[b]) / ref - 1.0) / TOLERANCIA
        zs[nombre] = round(z, 3)
        if z > 3:
            codes.append("bone_length_" + nombre)
    d = math.sqrt(sum(z * z for z in zs.values()) / len(zs)) if zs else 0.0
    if previo and previo.get("world") and isinstance(frame.get("t"), (int, float)):
        dt = (frame["t"] - previo["t"]) / 1000.0
        ancho = _dist(mundo[11], mundo[12]) or 1.0
        if dt > 0:
            for lado, i in (("L", 15), ("R", 16)):
                if _vis(pose, i) and _vis(previo.get("pose") or [], i):
                    v = _dist(mundo[i], previo["world"][i]) / ancho / dt
                    if v > VEL_TELEPORT:
                        codes.append("wrist_teleport_" + lado)
    return {"d": round(d, 3), "z": zs, "codes": codes}


def auditar(frames, perfil):
    """Lista de resultados por frame (None donde no hay datos)."""
    medidas = (perfil or {}).get("measures") or {}
    out, previo = [], None
    for f in frames:
        r = auditar_frame(f, medidas, previo)
        out.append(r)
        if r is not None:
            previo = f
    return out
