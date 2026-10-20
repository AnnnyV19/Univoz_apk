"""Normalizacion de referencia para reconocimiento de senas.

Esta es la implementacion CANONICA. La version de Dart debe producir
resultados identicos (tolerancia 1e-5) contra golden/golden_cases.json.

Entrada por frame:
  pose:      lista de 33 landmarks de MediaPipe Pose en coordenadas de imagen,
             cada uno (x, y, z, visibility)
  pose_mundo:lista de 33 landmarks METRICOS (worldLandmarks), cada uno
             (x, y, z) en metros, con origen en el punto medio de las caderas
  left:      lista de 21 landmarks de mano izquierda (x, y, z) o None
  right:     lista de 21 landmarks de mano derecha (x, y, z) o None

Las coordenadas de imagen vienen normalizadas por MediaPipe al rango [0,1]
respecto al tamano de la imagen. Y crece hacia abajo.

Salida por frame: vector de 152 floats. Ver LAYOUT abajo.

VERSION 2.0.0: el cuerpo pasa de 2D a 3D, calculado desde el esqueleto
METRICO y no desde las coordenadas de imagen.

Se intento primero usar la Z de los landmarks de imagen, y no sirve: sus
valores son incoherentes entre puntos vecinos. Medido en una captura real, un
antebrazo de 0.8 anchos de hombro daba 3.5 de recorrido en Z, y las caderas
quedaban dos anchos de hombro detras de los hombros. MediaPipe la documenta
como profundidad relativa aproximada y no da para reconstruir una postura.
Los mismos segmentos medidos con worldLandmarks dieron 0.73, 0.65, 0.67 y
0.83: coherentes entre si y con la anatomia.

El bloque de cuerpo ya no son coordenadas de imagen rotadas, sino
proyecciones sobre una base ortonormal sacada del propio esqueleto:
  +X  hacia la derecha de la persona (hombro izq -> hombro der)
  +Y  hacia arriba (caderas -> hombros, ortogonalizado)
  +Z  hacia el frente de la persona
todo dividido por la distancia entre hombros. Eso lo hace invariante a donde
este la persona, a que tan lejos, y a hacia donde este girada.
"""

import math
import struct

NORM_VERSION = "2.0.0"
T_FRAMES = 32
FRAME_DIM = 152

# indices de MediaPipe Pose
L_SHOULDER, R_SHOULDER = 11, 12
L_HIP, R_HIP = 23, 24
L_WRIST, R_WRIST = 15, 16
# hombros, codos, munecas, caderas
POSE_BODY_IDX = [11, 12, 13, 14, 15, 16, 23, 24]
# pares izquierda/derecha dentro de POSE_BODY_IDX, para el espejeo
BODY_MIRROR_PAIRS = [(0, 1), (2, 3), (4, 5), (6, 7)]

# indices de MediaPipe Hand
HAND_WRIST, HAND_MIDDLE_MCP = 0, 9
N_HAND_PTS = 20  # 21 menos la muneca, que siempre queda en el origen

MIN_VISIBILITY = 0.5
EPS = 1e-6

# Validaciones de rig_motion_frame.mjs (handUsable / poseGeometry): una mano
# o un cuerpo geometricamente imposibles no entran al vector.
HAND_MARGIN = 0.15
BODY_MARGIN = 0.15
HAND_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 4),
    (0, 5), (5, 6), (6, 7), (7, 8),
    (0, 9), (9, 10), (10, 11), (11, 12),
    (0, 13), (13, 14), (14, 15), (15, 16),
    (0, 17), (17, 18), (18, 19), (19, 20),
    (5, 9), (9, 13), (13, 17),
]
# Las munecas estabilizadas del render mueven la ubicacion a lo sumo esto
# (en anchos de hombro).
RENDER_WRIST_CLAMP = 0.75

# LAYOUT del vector de 152 dimensiones
OFF_BODY = 0        # 24 = 8 puntos x (x, y, z)
OFF_LOC_L = 24      # 3  = muneca izq en marco del cuerpo
OFF_LOC_R = 27      # 3  = muneca der en marco del cuerpo
OFF_PRES_L = 30     # 1  = 1.0 si la mano izq fue detectada
OFF_PRES_R = 31     # 1
OFF_SHAPE_L = 32    # 60 = 20 puntos x (x, y, z) relativos a la muneca
OFF_SHAPE_R = 92    # 60

# Dimensiones que llevan profundidad del CUERPO. El clasificador las ignora
# (ver BODY_DIST_DIMS en dtw.py): aunque worldLandmarks es mucho mejor que la
# Z de imagen, sigue siendo una estimacion y al comparar aporta menos que lo
# que ensucia. La Z de la FORMA de las manos si se usa.
Z_BODY_DIMS = ([OFF_BODY + i * 3 + 2 for i in range(len(POSE_BODY_IDX))]
               + [OFF_LOC_L + 2, OFF_LOC_R + 2])


def _pto(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _resta(a, b):
    return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]


def _cruz(a, b):
    return [a[1] * b[2] - a[2] * b[1],
            a[2] * b[0] - a[0] * b[2],
            a[0] * b[1] - a[1] * b[0]]


def _largo(a):
    return math.sqrt(_pto(a, a))


def _unitario(a):
    m = _largo(a)
    if m < EPS:
        return None
    return [a[0] / m, a[1] / m, a[2] / m]


def _base_cuerpo(w):
    """Base ortonormal sacada del esqueleto metrico.

    Devuelve (der, arr, fre, origen, escala) o None si esta degenerado."""
    hi, hd = w[L_SHOULDER], w[R_SHOULDER]
    ci, cd = w[L_HIP], w[R_HIP]

    der = _unitario(_resta(hd, hi))
    if der is None:
        return None
    escala = _largo(_resta(hd, hi))

    origen = [(hi[i] + hd[i]) * 0.5 for i in range(3)]
    centro_caderas = [(ci[i] + cd[i]) * 0.5 for i in range(3)]

    # Arriba = caderas -> hombros, ortogonalizado contra la linea de hombros
    # (Gram-Schmidt) para que la base sea ortonormal aunque la persona este
    # inclinada de lado.
    tronco = _resta(origen, centro_caderas)
    proy = _pto(tronco, der)
    arr = _unitario([tronco[i] - der[i] * proy for i in range(3)])
    if arr is None:
        return None

    # Frente = arriba x derecha. Con los ejes de MediaPipe (X a la derecha de
    # la imagen, Y hacia abajo, Z creciendo al alejarse de la camara) este
    # producto apunta hacia el pecho de la persona.
    fre = _unitario(_cruz(arr, der))
    if fre is None:
        return None

    return (der, arr, fre, origen, escala)


def _proyectar(base, p):
    der, arr, fre, origen, escala = base
    q = _resta(p, origen)
    return [_pto(q, der) / escala, _pto(q, arr) / escala, _pto(q, fre) / escala]


def _rot(x, y, cos_t, sin_t):
    """Rota (x, y) por -theta, dado cos(theta) y sin(theta)."""
    return (x * cos_t + y * sin_t, -x * sin_t + y * cos_t)


def _num(p, i, defecto=float("nan")):
    try:
        v = p[i]
    except (IndexError, TypeError):
        return defecto
    return defecto if v is None else float(v)


def _coord(p):
    """(x, y, z, visibility) como coord() de la web: sin visibility, 0."""
    return (_num(p, 0), _num(p, 1), _num(p, 2), _num(p, 3, 0.0))


def _finito(p):
    return math.isfinite(p[0]) and math.isfinite(p[1]) and math.isfinite(p[2])


def _dist(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2])


def hand_usable(hand):
    """(ok, code, landmark). Rechaza manos parcialmente corruptas: en una
    oclusion MediaPipe puede devolver un punto aislado fuera de cuadro que
    deforma angulo y orientacion de toda la mano."""
    if hand is None or len(hand) != 21:
        return (False, "hand_landmarks_incomplete", None)
    pts = [_coord(p) for p in hand]
    for i, p in enumerate(pts):
        if not _finito(p):
            return (False, "point_non_finite", i)
    w = pts[0]
    # La muneca debe verse; las puntas pueden salirse un margen chico.
    if not (0 <= w[0] <= 1 and 0 <= w[1] <= 1):
        return (False, "wrist_out_of_frame", 0)

    def dentro(p):
        return (-HAND_MARGIN <= p[0] <= 1 + HAND_MARGIN and
                -HAND_MARGIN <= p[1] <= 1 + HAND_MARGIN)
    if sum(1 for p in pts if dentro(p)) < 15:
        fuera = next((i for i, p in enumerate(pts) if not dentro(p)), None)
        return (False, "hand_out_of_frame", fuera)
    escala = math.hypot(pts[9][0] - w[0], pts[9][1] - w[1])
    if not math.isfinite(escala) or escala < 0.015 or escala > 0.65:
        return (False, "hand_scale_invalid", 9)
    # Cada conexion plausible respecto de la escala del MCP medio: atrapa
    # puntos intercambiados o picos sin rechazar manos abiertas o cerradas.
    for a, b in HAND_CONNECTIONS:
        d = _dist(pts[a], pts[b])
        if not math.isfinite(d) or d < escala * 0.018 or d > escala * 2.2:
            return (False, "hand_segment_invalid", b)
    return (True, None, None)


def pose_geometry(pose, pose_mundo):
    """(ok, code, landmark). Cuerpo con anclas visibles y segmentos del
    esqueleto metrico plausibles respecto del ancho de hombros."""
    if (pose is None or len(pose) < 33 or
            pose_mundo is None or len(pose_mundo) < 33):
        return (False, "pose-formato", None)
    for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP):
        p = _coord(pose[i])
        hombro = i in (L_SHOULDER, R_SHOULDER)
        # Los hombros deben verse en la imagen; las caderas pueden quedar
        # fuera del recorte: sus worldLandmarks siguen dando el eje del torso.
        en_margen = (-BODY_MARGIN <= p[0] <= 1 + BODY_MARGIN and
                     -BODY_MARGIN <= p[1] <= 1 + BODY_MARGIN)
        if hombro and (not _finito(p) or not en_margen):
            return (False, "shoulder_out_of_frame", i)
        if (not _finito(p) or
                (hombro and (not math.isfinite(p[3]) or p[3] < 0.2)) or
                not _finito(_coord(pose_mundo[i]))):
            return (False, "pose_anchor_unsafe", i)
    w = [_coord(p) for p in pose_mundo]
    hombros = _dist(w[L_SHOULDER], w[R_SHOULDER])
    if not math.isfinite(hombros) or hombros < 1e-3:
        return (False, "hombros-degenerados", None)
    for a, b in ((11, 13), (13, 15), (12, 14), (14, 16), (23, 24)):
        d = _dist(w[a], w[b])
        if not math.isfinite(d) or d < hombros * 0.08 or d > hombros * 2.5:
            return (False, "pose_segment_invalid", b)

    def medio(a, b):
        return ((a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5, (a[2] + b[2]) * 0.5)
    tronco = _dist(medio(w[L_SHOULDER], w[R_SHOULDER]), medio(w[L_HIP], w[R_HIP]))
    if (not math.isfinite(tronco) or tronco <= hombros * 0.25 or
            tronco >= hombros * 4.0):
        return (False, "tronco-invalido", None)
    return (True, None, None)


def normalize_frame(pose, pose_mundo=None, left=None, right=None,
                    min_visibility=MIN_VISIBILITY, render_wrists=None,
                    motivos=None):
    """Normaliza un frame. Devuelve lista de 152 floats, o None si el frame
    no es utilizable (hombros no visibles, cuerpo imposible o sin esqueleto
    metrico). Espejo de normalizeMotionFrame (rig_motion_frame.mjs).

    [render_wrists] ({"left": punto, "right": punto} en imagen) desplaza solo
    la UBICACION de la mano hacia la muneca estabilizada del render (la de la
    pose puede ir uno o dos frames atrasada), acotado a +-0.75 anchos de
    hombro. Solo para el vector del avatar; el de reconocimiento no lo usa.
    [motivos], si se pasa, recibe {stage, code, side, landmark} por cada
    rechazo (mano o frame), con los codigos de la web.
    """
    def motivo(code, side=None, landmark=None):
        if motivos is not None:
            motivos.append({"stage": "capture", "code": code, "side": side,
                            "landmark": landmark})

    if (pose is None or len(pose) < 33 or
            pose_mundo is None or len(pose_mundo) < 33):
        motivo("pose_format")
        return None

    ls, rs = _coord(pose[L_SHOULDER]), _coord(pose[R_SHOULDER])
    if (not _finito(ls) or not _finito(rs) or
            not ls[3] >= min_visibility or not rs[3] >= min_visibility):
        motivo("shoulder_confidence_low")
        return None

    for idx in POSE_BODY_IDX:
        if not _finito(_coord(pose_mundo[idx])):
            motivo("pose_world_non_finite")
            return None

    ok, code, landmark = pose_geometry(pose, pose_mundo)
    if not ok:
        motivo(code, None, landmark)
        return None

    mundo = [_coord(p)[:3] for p in pose_mundo]
    base = _base_cuerpo(mundo)
    if base is None:
        return None

    # Marco 2D de imagen: se sigue usando para la FORMA de las manos, que solo
    # existe en coordenadas de imagen. Alinea la linea de hombros con la
    # horizontal para que inclinar el cuerpo no cambie la forma detectada.
    dx = rs[0] - ls[0]
    dy = rs[1] - ls[1]
    escala_img = math.sqrt(dx * dx + dy * dy)
    if escala_img < EPS:
        return None
    cos_t = dx / escala_img
    sin_t = dy / escala_img

    out = [0.0] * FRAME_DIM

    for i, idx in enumerate(POSE_BODY_IDX):
        q = _proyectar(base, mundo[idx])
        out[OFF_BODY + i * 3] = q[0]
        out[OFF_BODY + i * 3 + 1] = q[1]
        out[OFF_BODY + i * 3 + 2] = q[2]

    for hand, side, off_loc, off_pres, off_shape, idx_muneca in (
        (left, "left", OFF_LOC_L, OFF_PRES_L, OFF_SHAPE_L, L_WRIST),
        (right, "right", OFF_LOC_R, OFF_PRES_R, OFF_SHAPE_R, R_WRIST),
    ):
        if hand is None or len(hand) != 21:
            continue
        ok, code, landmark = hand_usable(hand)
        if not ok:
            motivo(code, side, landmark)
            continue

        # Ubicacion: la muneca del modelo de POSE, no la del detector de
        # manos, para que quede en el mismo espacio metrico que el cuerpo.
        # Son practicamente el mismo punto anatomico.
        q = _proyectar(base, mundo[idx_muneca])
        # Muneca estabilizada del render: residuo de imagen llevado a los
        # ejes del cuerpo y acotado.
        estable = _coord((render_wrists or {}).get(side))
        muneca_img = _coord(pose[idx_muneca])
        if _finito(estable) and _finito(muneca_img):
            ix = (estable[0] - muneca_img[0]) / escala_img
            iy = (estable[1] - muneca_img[1]) / escala_img
            bx, by = _rot(ix, iy, cos_t, sin_t)
            q[0] += max(-RENDER_WRIST_CLAMP, min(RENDER_WRIST_CLAMP, bx))
            q[1] += max(-RENDER_WRIST_CLAMP, min(RENDER_WRIST_CLAMP, by))
        out[off_loc] = q[0]
        out[off_loc + 1] = q[1]
        out[off_loc + 2] = q[2]
        out[off_pres] = 1.0

        # La FORMA si viene del detector de manos: relativa a su propia
        # muneca y escalada por el tamano de la mano, asi que no depende de
        # donde este el brazo.
        w = hand[HAND_WRIST]
        m = hand[HAND_MIDDLE_MCP]
        hdx, hdy = m[0] - w[0], m[1] - w[1]
        hand_scale = math.sqrt(hdx * hdx + hdy * hdy)
        if hand_scale < EPS:
            hand_scale = escala_img * 0.25

        for j in range(1, 21):
            p = hand[j]
            qx, qy = _rot(p[0] - w[0], p[1] - w[1], cos_t, sin_t)
            k = off_shape + (j - 1) * 3
            out[k] = qx / hand_scale
            out[k + 1] = qy / hand_scale
            out[k + 2] = (p[2] - w[2]) / hand_scale

    return out if all(math.isfinite(v) for v in out) else None


def fill_gaps(frames):
    """Sustituye frames None por el ultimo valido. Devuelve None si no hay
    ningun frame utilizable en toda la secuencia."""
    valid = [f for f in frames if f is not None]
    if not valid:
        return None
    out, last = [], valid[0]
    for f in frames:
        if f is not None:
            last = f
        out.append(last)
    return out


def resample(frames, t=T_FRAMES):
    """Remuestrea linealmente a t frames. Cada seña queda con la misma forma
    sin importar cuanto duro."""
    n = len(frames)
    if n == 0:
        return None
    if n == 1:
        return [list(frames[0]) for _ in range(t)]

    out = []
    for i in range(t):
        pos = i * (n - 1) / (t - 1)
        lo = int(math.floor(pos))
        hi = min(lo + 1, n - 1)
        w = pos - lo
        a, b = frames[lo], frames[hi]
        out.append([a[d] + (b[d] - a[d]) * w for d in range(FRAME_DIM)])
    return out


def normalize_sequence(raw_frames, t=T_FRAMES):
    """raw_frames: lista de tuplas (pose, pose_mundo, left, right).
    Devuelve una matriz t x 152, o None si la toma no sirve."""
    norm = [normalize_frame(p, pm, l, r) for (p, pm, l, r) in raw_frames]
    filled = fill_gaps(norm)
    if filled is None:
        return None
    return resample(filled, t)


def mirror_frame(v):
    """Espejea un frame ya normalizado: invierte X y cruza izquierda/derecha.
    Sirve como augmentation para cubrir personas zurdas.

    La Z no se toca: espejear a alguien de lado a lado no cambia que tan
    cerca esta de la camara."""
    out = [0.0] * FRAME_DIM

    for a, b in BODY_MIRROR_PAIRS:
        for (src, dst) in ((b, a), (a, b)):
            out[OFF_BODY + dst * 3] = -v[OFF_BODY + src * 3]
            out[OFF_BODY + dst * 3 + 1] = v[OFF_BODY + src * 3 + 1]
            out[OFF_BODY + dst * 3 + 2] = v[OFF_BODY + src * 3 + 2]

    out[OFF_LOC_L] = -v[OFF_LOC_R]
    out[OFF_LOC_L + 1] = v[OFF_LOC_R + 1]
    out[OFF_LOC_L + 2] = v[OFF_LOC_R + 2]
    out[OFF_LOC_R] = -v[OFF_LOC_L]
    out[OFF_LOC_R + 1] = v[OFF_LOC_L + 1]
    out[OFF_LOC_R + 2] = v[OFF_LOC_L + 2]

    out[OFF_PRES_L] = v[OFF_PRES_R]
    out[OFF_PRES_R] = v[OFF_PRES_L]

    for j in range(N_HAND_PTS):
        sl, sr = OFF_SHAPE_L + j * 3, OFF_SHAPE_R + j * 3
        out[sl], out[sl + 1], out[sl + 2] = -v[sr], v[sr + 1], v[sr + 2]
        out[sr], out[sr + 1], out[sr + 2] = -v[sl], v[sl + 1], v[sl + 2]

    return out


def mirror_sequence(seq):
    return [mirror_frame(f) for f in seq]


def pack_f16(seq):
    """Empaqueta t x 152 floats a bytes float16, para la columna BYTEA.
    Una seña de 32 frames pesa ~8.8 KB."""
    flat = [x for row in seq for x in row]
    return struct.pack("<%de" % len(flat), *flat)


def unpack_f16(blob, dim=FRAME_DIM):
    n = len(blob) // 2
    flat = struct.unpack("<%de" % n, blob)
    return [list(flat[i:i + dim]) for i in range(0, n, dim)]
