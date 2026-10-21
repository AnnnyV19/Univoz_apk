"""Reconocimiento de senas por Dynamic Time Warping sobre plantillas.

No entrena nada. Agregar una sena nueva es agregar plantillas, y funciona
con pocas muestras por sena. Es la fase 1: sirve para tener el sistema
completo de punta a punta antes de meter un encoder entrenado.

La distancia entre dos frames NO es euclidiana plana. Los 152 numeros no
valen lo mismo: la forma de la mano ocupa 120 dimensiones y la ubicacion
solo 4, asi que una euclidiana normal dejaria que la forma se comiera todo
el peso. Aqui cada bloque se promedia por su numero de dimensiones y luego
se pondera, para que la ubicacion pese lo que le corresponde.

Lo que se compara NO es la secuencia guardada tal cual (ver el 2026-10-10 en
los pesos de abajo): la forma de la mano debe haberse pasado antes por
sign_norm.isotropizar_secuencia, y DtwClassifier le resta a cada mano su
posicion media (centrar_ubicacion) para comparar trayectorias.
"""

import math

from sign_norm import (
    FRAME_DIM, OFF_BODY, OFF_LOC_L, OFF_LOC_R,
    OFF_PRES_L, OFF_PRES_R, OFF_SHAPE_L, OFF_SHAPE_R,
)

# Dimensiones del bloque de cuerpo que entran en la distancia: codos, munecas
# y caderas, solo X e Y.
#
# Quedan fuera los hombros, cuya X e Y son constantes por construccion (-0.5 y
# +0.5) y sumarian siempre cero, y TODAS las Z del cuerpo: la profundidad que
# estima MediaPipe Pose es ruidosa, sirve para animar al avatar pero al
# comparar dos senas mete mas error que senal.
#
# Asi el clasificador compara EXACTAMENTE las mismas 12 dimensiones de cuerpo
# que antes del cambio a 3D en la version 2.0.0 de sign_norm.
BODY_DIST_DIMS = (
    6, 7,    # codo izq
    9, 10,   # codo der
    12, 13,  # muneca izq
    15, 16,  # muneca der
    18, 19,  # cadera izq
    21, 22,  # cadera der
)

N_BODY = 12
N_SHAPE = 60

# pesos por bloque
#
# 2026-10-10, medido con validacion cruzada por grabacion (620 consultas, 541
# senas, las 29 letras incluidas):
#   * W_BODY pasa de 0.5 a 0. Los codos/munecas/caderas del cuerpo dependen de
#     cuanto se separo del cuerpo cada persona y de la camara; con peso 0.15 el
#     acierto en letras cae de 43.6 % a 27.7 %. El bloque sigue en el vector
#     (lo usa el avatar y la explicacion de "Practicar"), solo no decide.
#   * La ubicacion de la mano se compara SIN su posicion absoluta (ver
#     centrar_ubicacion): cada persona sena a una altura distinta, y esa
#     altura es real y se respeta en el avatar, pero no identifica la sena.
#     Si se conserva el movimiento (la trayectoria) y se resta la posicion
#     media, W_LOC = 0.75 es lo mejor (1.5 baja letras de 43.6 % a 41 %).
#   * Combinado con la forma isotropica (isotropizar_secuencia en sign_norm):
#     todas 28.2 % -> 34.0 %, letras 21.8 % -> 43.6 %.
W_BODY = 0.0
W_LOC = 0.75
W_SHAPE = 1.0

# Presencia de mano. Estos dos valores eran 2.0 y 1.0 y se bajaron a 0.25 y
# 0.15 midiendo contra las 146 plantillas reales (44 senas): la camara pierde
# una mano unos frames incluso en grabaciones buenas, y con los valores viejos
# cada frame suelto costaba ~1.7 contra ~0.2 de un frame que coincide. Eso
# dominaba la distancia entre dos tomas de la MISMA sena. Con los nuevos, el
# acierto sube ~9 puntos con 1 muestra por sena y ~6 con 3, y las respuestas
# equivocadas aceptadas bajan. Si se vuelven a mover, hay que recalibrar
# DEFAULT_MAX_DISTANCE / DEFAULT_MIN_MARGIN (viven en la misma escala) y
# regenerar test/golden/golden_cases.json con gen_golden.py.
W_PRES = 0.25
SHAPE_PENALTY = 0.15   # castigo cuando una tiene la mano y la otra no

# Umbrales de aceptacion por defecto, en la escala de la distancia de arriba.
# Eran 0.55 / 0.12 y luego 0.65 / 0.32. Recalibrados el 2026-10-10 con la
# distancia nueva (validacion cruzada por grabacion, 620 consultas con la
# sena en el diccionario y 600 con la sena FUERA del diccionario):
#   0.65 / 0.32 antes:  acierta y acepta 15.3 %, acepta mal 4.5 %
#   0.50 / 0.32 ahora:  acierta y acepta 17.4 %, acepta mal 3.3 %,
#                       acepta 7 % de las senas que NO estan en el diccionario
# La distancia maxima casi no pesa (la distancia de los aciertos tiene mediana
# 0.17 y 90 % por debajo de 0.34; la de los errores, mediana 0.39); el que
# manda es el margen: subirlo a 0.40 deja 91 % de precision (13.9 % acierta y
# acepta, 1.3 % acepta mal) a cambio de aceptar menos. Con 1 muestra por sena
# (lo normal hoy) el margen siempre sale bajo; con 3 o mas mejora mucho.
DEFAULT_MAX_DISTANCE = 0.50
DEFAULT_MIN_MARGIN = 0.32

BAND = 4          # radio de la banda de Sakoe-Chiba, en frames

_HAND_BLOCKS = (
    (OFF_LOC_L, OFF_PRES_L, OFF_SHAPE_L),
    (OFF_LOC_R, OFF_PRES_R, OFF_SHAPE_R),
)


def frame_distance(a, b):
    """Distancia ponderada por bloques entre dos frames normalizados."""
    acc = 0.0

    s = 0.0
    for i in BODY_DIST_DIMS:
        d = a[i] - b[i]
        s += d * d
    acc += W_BODY * s / N_BODY

    for off_loc, off_pres, off_shape in _HAND_BLOCKS:
        pa, pb = a[off_pres], b[off_pres]
        dp = pa - pb
        acc += W_PRES * dp * dp

        # el remuestreo puede dejar presencias fraccionarias cuando la mano
        # aparece a media sena, por eso el umbral en vez de comparar con 1.0
        ha, hb = pa >= 0.5, pb >= 0.5
        if ha and hb:
            # Solo X e Y: la Z de la muneca es profundidad de cuerpo y queda
            # fuera por el mismo motivo que BODY_DIST_DIMS.
            d0 = a[off_loc] - b[off_loc]
            d1 = a[off_loc + 1] - b[off_loc + 1]
            acc += W_LOC * (d0 * d0 + d1 * d1) / 2.0
            s = 0.0
            for i in range(off_shape, off_shape + N_SHAPE):
                d = a[i] - b[i]
                s += d * d
            acc += W_SHAPE * s / N_SHAPE
        elif ha != hb:
            acc += W_SHAPE * SHAPE_PENALTY

    return math.sqrt(acc)


def dtw_distance(a, b, band=BAND, ceiling=None):
    """DTW con banda de Sakoe-Chiba, normalizado por la secuencia mas larga.

    band limita cuanto se puede deformar el tiempo. Sin banda, una sena lenta
    puede alinearse con cualquier cosa y todo se parece a todo.

    ceiling permite abandonar temprano: si toda la fila ya supera ese valor,
    esta plantilla no va a ganar y no vale la pena terminarla.
    """
    n, m = len(a), len(b)
    if n == 0 or m == 0:
        return float('inf')

    inf = float('inf')
    ratio = m / n
    prev = [inf] * (m + 1)
    prev[0] = 0.0

    for i in range(1, n + 1):
        center = (i - 1) * ratio
        lo = max(1, int(math.floor(center - band)) + 1)
        hi = min(m, int(math.ceil(center + band)) + 1)

        cur = [inf] * (m + 1)
        fila_min = inf
        for j in range(lo, hi + 1):
            best = prev[j - 1]
            if prev[j] < best:
                best = prev[j]
            if cur[j - 1] < best:
                best = cur[j - 1]
            if best == inf:
                continue
            cur[j] = best + frame_distance(a[i - 1], b[j - 1])
            if cur[j] < fila_min:
                fila_min = cur[j]

        if ceiling is not None and fila_min / max(n, m) > ceiling:
            return inf
        prev = cur

    d = prev[m]
    return d / max(n, m) if d != inf else inf


def signature(seq):
    """Vector promedio de la secuencia. Se usa como prefiltro barato:
    152 operaciones por plantilla en vez de los ~40 mil de un DTW completo."""
    n = len(seq)
    sig = [0.0] * FRAME_DIM
    for f in seq:
        for i in range(FRAME_DIM):
            sig[i] += f[i]
    return [x / n for x in sig]


_LOC_PRES = ((OFF_LOC_L, OFF_PRES_L), (OFF_LOC_R, OFF_PRES_R))


def centrar_ubicacion(seq):
    """Copia de la secuencia sin la posicion media de cada mano.

    A cada mano se le resta, en X e Y, el promedio de la posicion de su muneca
    sobre los frames en que esta presente. Queda solo la TRAYECTORIA: de donde
    a donde se movio, no a que altura sena esa persona. (La Z no entra en la
    distancia, se deja igual.) El original no se modifica: el avatar sigue
    dibujando la altura real de cada sena.
    """
    out = [list(f) for f in seq]
    for off_loc, off_pres in _LOC_PRES:
        idx = [t for t, f in enumerate(out) if f[off_pres] >= 0.5]
        if not idx:
            continue
        mx = sum(out[t][off_loc] for t in idx) / len(idx)
        my = sum(out[t][off_loc + 1] for t in idx) / len(idx)
        for t in idx:
            out[t][off_loc] -= mx
            out[t][off_loc + 1] -= my
    return out


N_SEGMENTOS = 8


def firma_segmentos(seq, n=N_SEGMENTOS):
    """n vectores promedio, uno por tramo consecutivo de la secuencia.

    Prefiltro del clasificador. Con UN solo vector promedio (signature), una
    biblioteca de ~2 200 plantillas (1 089 + espejos) y 80 candidatas, la
    plantilla que habria ganado quedaba fuera 13 % de las veces; con 8 tramos
    queda fuera 0.6 %. Cuesta n frame_distance por plantilla en vez de uno.
    """
    m = len(seq)
    if m == 0:
        return [[0.0] * FRAME_DIM for _ in range(n)]
    out = []
    for k in range(n):
        lo = k * m // n
        hi = max(lo + 1, (k + 1) * m // n)
        out.append(signature(seq[lo:hi]))
    return out


def _distancia_firmas(fa, fb):
    return sum(frame_distance(x, y) for x, y in zip(fa, fb)) / len(fa)


class Template:
    """seq es la secuencia tal cual llego (con su altura real); cseq es la que
    se compara (sin posicion absoluta de la mano) y segs su prefiltro."""
    __slots__ = ('sign_id', 'gloss', 'espanol', 'seq', 'cseq', 'segs')

    def __init__(self, sign_id, gloss, seq, espanol=''):
        self.sign_id = sign_id
        self.gloss = gloss
        self.espanol = espanol
        self.seq = seq
        self.cseq = centrar_ubicacion(seq)
        self.segs = firma_segmentos(self.cseq)


class Prediction:
    def __init__(self, gloss, sign_id, espanol, distance, margin, aceptada):
        self.gloss = gloss
        self.sign_id = sign_id
        self.espanol = espanol
        self.distance = distance
        self.margin = margin
        self.aceptada = aceptada

    def __repr__(self):
        return ('Prediction(%s, d=%.4f, margen=%.3f, %s)'
                % (self.gloss, self.distance, self.margin,
                   'aceptada' if self.aceptada else 'rechazada'))


class DtwClassifier:
    """Plantillas en memoria. En la app estas se cargan del paquete que
    sincroniza PostgreSQL (ver v_paquete_prototipos)."""

    def __init__(self, max_distance=DEFAULT_MAX_DISTANCE,
                 min_margin=DEFAULT_MIN_MARGIN, prefilter=80, band=BAND):
        self.templates = []
        self.max_distance = max_distance
        self.min_margin = min_margin
        self.prefilter = prefilter
        self.band = band

    def add(self, sign_id, gloss, seq, espanol=''):
        self.templates.append(Template(sign_id, gloss, seq, espanol=espanol))

    def _candidatos(self, segs):
        if self.prefilter <= 0 or len(self.templates) <= self.prefilter:
            return self.templates
        puntuadas = [(_distancia_firmas(segs, t.segs), t) for t in self.templates]
        puntuadas.sort(key=lambda x: x[0])
        return [t for _, t in puntuadas[:self.prefilter]]

    def _factor_abandono(self):
        """Cuanto puede alejarse una plantilla de la mejor antes de abandonarla.

        Una plantilla de OTRA glosa solo puede cambiar la decision si queda a
        menos de d1 / (1 - min_margin). Con un factor fijo de 1.5 el margen
        solo era exacto hasta 0.333 (1 - 1/1.5): por encima, una plantilla
        abandonada dejaba el margen en 1.0 y se aceptaba de mas. Con el margen
        por defecto (0.32) el factor sigue siendo 1.5."""
        return max(1.5, 1.0 / (1.0 - min(self.min_margin, 0.95)))

    def rank(self, seq):
        """Todas las distancias, de menor a mayor."""
        q = centrar_ubicacion(seq)
        cands = self._candidatos(firma_segmentos(q))
        out = []
        mejor = None
        factor = self._factor_abandono()
        for t in cands:
            d = dtw_distance(q, t.cseq, self.band,
                             ceiling=mejor * factor if mejor is not None else None)
            if d == float('inf'):
                continue
            if mejor is None or d < mejor:
                mejor = d
            out.append((d, t))
        out.sort(key=lambda x: x[0])
        return out

    def classify(self, seq):
        r = self.rank(seq)
        if not r:
            return Prediction(None, None, None, float('inf'), 0.0, False)

        d1, t1 = r[0]
        d2 = next((d for d, t in r if t.gloss != t1.gloss), None)

        if d2 is None or d2 == 0:
            margin = 1.0
        else:
            margin = (d2 - d1) / d2

        aceptada = d1 <= self.max_distance and margin >= self.min_margin
        return Prediction(t1.gloss, t1.sign_id, t1.espanol, d1, margin, aceptada)
