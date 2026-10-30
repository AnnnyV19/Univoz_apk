"""Candidatos de limpieza para una secuencia 32x152 antes del DTW (prototipos).

Todos reciben y devuelven una lista de frames (listas de 152 floats) y solo
tocan las dimensiones continuas (ubicacion 24-29, forma 32-151). Cuerpo y
presencia quedan igual. Sin dependencias, para poder portarlos 1:1 a Dart.

Un candidato solo pasa a Dart si el evaluador lo prefiere (evaluar_reconocimiento.py).
"""

import math

DIMS = tuple(range(24, 30)) + tuple(range(32, 152))
# Manos: (presencia, ubicacion, forma). Solo se corrige donde la mano existe.
MANOS = ((30, range(24, 27), range(32, 92)), (31, range(27, 30), range(92, 152)))


def _copia(seq):
    return [list(f) for f in seq]


def _mediana(v):
    s = sorted(v)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


# --- 1. frames repetidos -> interpolacion -----------------------------------

def interp_duplicados(seq, eps=1e-9):
    """Un frame igual al anterior en todas las dims continuas es un hueco que
    fillGaps relleno copiando: se trata como faltante y se interpola linealmente
    entre el ultimo y el siguiente frame distintos."""
    n = len(seq)
    out = _copia(seq)
    falta = [False] * n
    for i in range(1, n):
        if all(abs(seq[i][d] - seq[i - 1][d]) <= eps for d in DIMS):
            falta[i] = True
    i = 1
    while i < n:
        if not falta[i]:
            i += 1
            continue
        j = i
        while j < n and falta[j]:
            j += 1
        if j >= n:
            break  # cola repetida: no hay frame posterior para interpolar
        a, b = i - 1, j
        for k in range(i, j):
            t = (k - a) / (b - a)
            for d in DIMS:
                out[k][d] = seq[a][d] + (seq[b][d] - seq[a][d]) * t
        i = j
    return out


# --- 2. picos ---------------------------------------------------------------

def hampel(seq, ventana=2, k=3.0, piso=0.04):
    """Filtro de Hampel por dimension: si un valor se aleja de la mediana de su
    ventana mas de max(k*1.4826*MAD, piso), se reemplaza por esa mediana."""
    n = len(seq)
    out = _copia(seq)
    for d in DIMS:
        col = [f[d] for f in seq]
        for i in range(n):
            w = col[max(0, i - ventana):min(n, i + ventana + 1)]
            m = _mediana(w)
            mad = _mediana([abs(x - m) for x in w])
            if abs(col[i] - m) > max(k * 1.4826 * mad, piso):
                out[i][d] = m
    return out


def picos_frame(seq, factor=4.0, piso=0.03):
    """Un frame es pico si su desviacion media contra la interpolacion de sus
    vecinos supera factor * la mediana de esas desviaciones. Se reemplaza el
    frame completo (un pico real, p.ej. volteo de palma, mueve toda la mano)."""
    n = len(seq)
    if n < 3:
        return _copia(seq)
    dev = [0.0] * n
    for i in range(1, n - 1):
        dev[i] = sum(abs(seq[i][d] - 0.5 * (seq[i - 1][d] + seq[i + 1][d]))
                     for d in DIMS) / len(DIMS)
    umbral = max(factor * _mediana(dev[1:-1]), piso)
    out = _copia(seq)
    for i in range(1, n - 1):
        if dev[i] > umbral and dev[i - 1] <= umbral and dev[i + 1] <= umbral:
            continue  # vecinos tambien altos: es movimiento real, no pico
        if dev[i] > umbral:
            for d in DIMS:
                out[i][d] = 0.5 * (seq[i - 1][d] + seq[i + 1][d])
    return out


# --- 3. suavizado sin desfase ----------------------------------------------

# Savitzky-Golay, orden 2, ventana 5: coeficientes (-3, 12, 17, 12, -3) / 35.
_SG5 = (-3 / 35, 12 / 35, 17 / 35, 12 / 35, -3 / 35)


def sg5(seq):
    n = len(seq)
    out = _copia(seq)
    for i in range(2, n - 2):
        for d in DIMS:
            out[i][d] = sum(c * seq[i + o][d] for c, o in zip(_SG5, (-2, -1, 0, 1, 2)))
    return out


def gauss(seq, sigma=1.0):
    r = max(1, int(math.ceil(2 * sigma)))
    w = [math.exp(-0.5 * (o / sigma) ** 2) for o in range(-r, r + 1)]
    n = len(seq)
    out = _copia(seq)
    for i in range(n):
        lo, hi = max(0, i - r), min(n - 1, i + r)
        pesos = [w[o + r] for o in range(lo - i, hi - i + 1)]
        s = sum(pesos)
        for d in DIMS:
            out[i][d] = sum(p * seq[lo + k][d] for k, p in enumerate(pesos)) / s
    return out


# --- combinaciones ----------------------------------------------------------

def hampel_sg5(seq):
    return sg5(hampel(seq))


def picos_sg5(seq):
    return sg5(picos_frame(seq))


def completo(seq):
    return sg5(picos_frame(hampel(interp_duplicados(seq))))


CANDIDATOS = {
    'interp': interp_duplicados,
    'hampel': hampel,
    'picos': picos_frame,
    'sg5': sg5,
    'gauss1': gauss,
    'hampel+sg5': hampel_sg5,
    'picos+sg5': picos_sg5,
    'completo': completo,
}
