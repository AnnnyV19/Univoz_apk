"""SignSpaceFrame v1: representacion de la sena independiente del cuerpo.

Implementacion CANONICA. Dart (lib/sign_space.dart) y JS
(assets/avatar_viewer/rig_sign_space.mjs) deben coincidir con
test/golden/sign_space_cases.json (tolerancia 1e-5).

MotionFrameV2 152D (sign_norm.py) NO cambia: conserva las proporciones de
cada persona y alimenta al clasificador. SignSpaceFrame separa "que sena es"
de "como es el cuerpo" para que el avatar copie o reproduzca la sena con SUS
proporciones:

  - direcciones UNITARIAS de brazo, antebrazo y mano: no dependen del largo
    de los huesos, se aplican a cualquier esqueleto;
  - palma y anclas de la cara (nariz, boca) en el marco del cuerpo, en anchos
    de hombro: el retargeter resuelve la palma contra el ancla equivalente
    del avatar (tocar SU menton, no un punto en metros);
  - contactos explicitos mano-cara, mano-pecho, mano-mano.

La ausencia (brazo oculto, mano amputada, cara fuera de cuadro) va en
`mask`, nunca como cero con significado: un bloque enmascarado vale 0.0 y la
mascara dice que no existe.

Modo tren superior: si las caderas no son visibles (sentado, silla de ruedas,
encuadre de medio cuerpo) MediaPipe las inventa y la vertical del tronco se
inclina. En ese caso "arriba" sale de la vertical de la camara, no de las
caderas.

Entrada: pose (33 x [x, y, z, visibility], coordenadas de imagen) y
pose_mundo (33 x [x, y, z] metricos, worldLandmarks). Ejes MediaPipe world:
X a la derecha de la imagen, Y hacia abajo, Z se aleja de la camara.
"""

import math

SIGN_SPACE_VERSION = "1.0.0"

NOSE = 0
MOUTH_L, MOUTH_R = 9, 10
L_SHOULDER, R_SHOULDER = 11, 12
L_ELBOW, R_ELBOW = 13, 14
L_WRIST, R_WRIST = 15, 16
L_PINKY, R_PINKY = 17, 18
L_INDEX, R_INDEX = 19, 20
L_HIP, R_HIP = 23, 24

MIN_VISIBILITY = 0.5
HIP_VISIBILITY = 0.5
EPS = 1e-6

# LAYOUT (35 valores, marco del cuerpo: +x derecha de la persona, +y arriba,
# +z al frente; posiciones en anchos de hombro desde el centro de hombros)
OFF_UPPER_L = 0      # 3 direccion hombro -> codo izquierdo
OFF_FORE_L = 3       # 3 direccion codo -> muneca izquierda
OFF_UPPER_R = 6      # 3
OFF_FORE_R = 9       # 3
OFF_PALM_L = 12      # 3 centro de palma izquierda (posicion)
OFF_PALM_R = 15      # 3
OFF_NOSE = 18        # 3 ancla nariz (posicion)
OFF_MOUTH = 21       # 3 ancla boca (posicion)
OFF_HANDDIR_L = 24   # 3 direccion muneca -> nudillos izquierda
OFF_HANDDIR_R = 27   # 3
OFF_CONTACT = 30     # 5 contactos 0/1
SIGN_SPACE_DIM = 35

C_FACE_L, C_FACE_R, C_CHEST_L, C_CHEST_R, C_HANDS = range(5)

# Ancla del pecho en el marco del cuerpo (no hay landmark de pecho).
CHEST = (0.0, -0.40, 0.10)
# Umbrales de contacto, en anchos de hombro.
CONTACT_FACE = 0.30
CONTACT_CHEST = 0.30
CONTACT_HANDS = 0.25


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


def _medio(*ps):
    n = float(len(ps))
    return [sum(p[i] for p in ps) / n for i in range(3)]


def _visible(pose, idx, minimo):
    p = pose[idx]
    return len(p) >= 4 and p[3] >= minimo


def _base(pose, w, hip_visibility):
    """(der, arr, fre, origen, escala, modo) o None si es degenerada."""
    hi, hd = w[L_SHOULDER], w[R_SHOULDER]
    der = _unitario(_resta(hd, hi))
    if der is None:
        return None
    escala = _largo(_resta(hd, hi))
    origen = _medio(hi, hd)

    if (_visible(pose, L_HIP, hip_visibility) and
            _visible(pose, R_HIP, hip_visibility)):
        tronco = _resta(origen, _medio(w[L_HIP], w[R_HIP]))
        modo = "full"
    else:
        tronco = [0.0, -1.0, 0.0]  # vertical de la camara (Y crece abajo)
        modo = "upper"

    proy = _pto(tronco, der)
    arr = _unitario([tronco[i] - der[i] * proy for i in range(3)])
    if arr is None:
        return None
    fre = _unitario(_cruz(arr, der))
    if fre is None:
        return None
    return der, arr, fre, origen, escala, modo


def _dir(base, a, b):
    der, arr, fre = base[0], base[1], base[2]
    d = _unitario(_resta(b, a))
    if d is None:
        return None
    return [_pto(d, der), _pto(d, arr), _pto(d, fre)]


def _pos(base, p):
    der, arr, fre, origen, escala = base[:5]
    q = _resta(p, origen)
    return [_pto(q, der) / escala, _pto(q, arr) / escala,
            _pto(q, fre) / escala]


def _codo_por_ik(hombro, muneca, largo_brazo, largo_antebrazo, guia):
    """Codo con las longitudes reales del usuario: IK de dos huesos entre
    hombro y muneca (metros). El plano del codo sale de [guia] (el codo que
    estimo MediaPipe aunque no lo vea); si es degenerado, hacia abajo."""
    d = _resta(muneca, hombro)
    dist = _largo(d)
    if dist < EPS:
        return None
    u = [v / dist for v in d]
    dist = min(max(dist, abs(largo_brazo - largo_antebrazo) + 1e-4),
               largo_brazo + largo_antebrazo - 1e-4)
    a = (largo_brazo ** 2 - largo_antebrazo ** 2 + dist ** 2) / (2 * dist)
    h = math.sqrt(max(0.0, largo_brazo ** 2 - a * a))
    perp = None
    for polo in (_resta(guia, hombro), [0.0, 1.0, 0.0]):  # Y world = abajo
        pr = _pto(polo, u)
        perp = _unitario([polo[i] - u[i] * pr for i in range(3)])
        if perp is not None:
            break
    if perp is None:
        return None
    return [hombro[i] + u[i] * a + perp[i] * h for i in range(3)]


def sign_space_frame(pose, pose_mundo, min_visibility=MIN_VISIBILITY,
                     hip_visibility=HIP_VISIBILITY, profile=None):
    """Devuelve {"version", "mode", "scale", "values", "mask",
    "reconstructed"} o None si los hombros no son visibles o el esqueleto es
    degenerado.

    Con [profile] (BodyProfileV1), un codo no visible con hombro y muneca
    visibles se reconstruye con las longitudes medidas del usuario y el brazo
    queda en la mascara con reconstructed[armX] = True (no se oculta como
    ausente ni se inventa como visto)."""
    if pose is None or len(pose) < 33:
        return None
    if pose_mundo is None or len(pose_mundo) < 33:
        return None
    if not (_visible(pose, L_SHOULDER, min_visibility) and
            _visible(pose, R_SHOULDER, min_visibility)):
        return None
    for p in pose_mundo[:25]:
        if len(p) < 3 or not all(math.isfinite(v) for v in p[:3]):
            return None

    base = _base(pose, pose_mundo, hip_visibility)
    if base is None:
        return None

    w = pose_mundo
    out = [0.0] * SIGN_SPACE_DIM
    mask = {"armL": False, "armR": False, "handL": False, "handR": False,
            "face": False}
    reconstruido = {"armL": False, "armR": False}
    medidas = (profile or {}).get("measures") or {}
    palmas = {}

    for lado, hombro, codo, muneca, menique, indice, off_u, off_f, off_p, \
            off_h in (
                ("L", L_SHOULDER, L_ELBOW, L_WRIST, L_PINKY, L_INDEX,
                 OFF_UPPER_L, OFF_FORE_L, OFF_PALM_L, OFF_HANDDIR_L),
                ("R", R_SHOULDER, R_ELBOW, R_WRIST, R_PINKY, R_INDEX,
                 OFF_UPPER_R, OFF_FORE_R, OFF_PALM_R, OFF_HANDDIR_R)):
        if (_visible(pose, codo, min_visibility) and
                _visible(pose, muneca, min_visibility)):
            du = _dir(base, w[hombro], w[codo])
            df = _dir(base, w[codo], w[muneca])
            if du is not None and df is not None:
                out[off_u:off_u + 3] = du
                out[off_f:off_f + 3] = df
                mask["arm" + lado] = True
        elif (_visible(pose, muneca, min_visibility) and
              medidas.get("upper" + lado) and medidas.get("fore" + lado)):
            codo_ik = _codo_por_ik(w[hombro], w[muneca],
                                   medidas["upper" + lado],
                                   medidas["fore" + lado], w[codo])
            if codo_ik is not None:
                du = _dir(base, w[hombro], codo_ik)
                df = _dir(base, codo_ik, w[muneca])
                if du is not None and df is not None:
                    out[off_u:off_u + 3] = du
                    out[off_f:off_f + 3] = df
                    mask["arm" + lado] = True
                    reconstruido["arm" + lado] = True
        if _visible(pose, muneca, min_visibility):
            nudillos = _medio(w[menique], w[indice])
            dh = _dir(base, w[muneca], nudillos)
            if dh is not None:
                palma = _pos(base, _medio(w[muneca], w[menique], w[indice]))
                out[off_p:off_p + 3] = palma
                out[off_h:off_h + 3] = dh
                mask["hand" + lado] = True
                palmas[lado] = palma

    if _visible(pose, NOSE, min_visibility):
        out[OFF_NOSE:OFF_NOSE + 3] = _pos(base, w[NOSE])
        out[OFF_MOUTH:OFF_MOUTH + 3] = _pos(base, _medio(w[MOUTH_L],
                                                          w[MOUTH_R]))
        mask["face"] = True

    nariz = out[OFF_NOSE:OFF_NOSE + 3]
    boca = out[OFF_MOUTH:OFF_MOUTH + 3]
    for lado, c_face, c_chest in (("L", C_FACE_L, C_CHEST_L),
                                  ("R", C_FACE_R, C_CHEST_R)):
        palma = palmas.get(lado)
        if palma is None:
            continue
        if mask["face"] and min(_largo(_resta(palma, nariz)),
                                _largo(_resta(palma, boca))) < CONTACT_FACE:
            out[OFF_CONTACT + c_face] = 1.0
        if _largo(_resta(palma, list(CHEST))) < CONTACT_CHEST:
            out[OFF_CONTACT + c_chest] = 1.0
    if "L" in palmas and "R" in palmas and \
            _largo(_resta(palmas["L"], palmas["R"])) < CONTACT_HANDS:
        out[OFF_CONTACT + C_HANDS] = 1.0

    return {
        "version": SIGN_SPACE_VERSION,
        "mode": base[5],
        "scale": base[4],
        "values": out,
        "mask": mask,
        "reconstructed": reconstruido,
    }
