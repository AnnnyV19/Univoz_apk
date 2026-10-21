"""Tests del clasificador DTW.  Correr:  python3 tools/test_dtw.py

Se generan senas sinteticas: una "sena" es una trayectoria suave de
landmarks. Las plantillas son la misma trayectoria con ruido, y las consultas
llevan ruido distinto y otra duracion, para verificar que el DTW absorbe la
diferencia de velocidad.
"""

import math
import random
import sys

import sign_norm as sn
import dtw as D
import gen_golden as G

fallos = []


def check(cond, msg):
    if cond:
        print("  ok   ", msg)
    else:
        print("  FALLA", msg)
        fallos.append(msg)


def hacer_sena(semilla, n_frames, ruido=0.0, manos=2):
    """Trayectoria determinista por semilla, con ruido opcional."""
    rng = random.Random(semilla)
    fase = rng.uniform(0, 6.28)
    amp = rng.uniform(0.05, 0.12)
    dx = rng.uniform(-0.12, 0.12)
    dy = rng.uniform(-0.10, 0.10)
    forma = random.Random(semilla + 1000)
    dedos = [(forma.uniform(-0.07, 0.07), forma.uniform(-0.07, 0.07))
             for _ in range(21)]

    jitter = random.Random(semilla * 31 + int(ruido * 1e6))
    raw = []
    for k in range(n_frames):
        t = k / max(1, n_frames - 1)
        pose = G.make_pose(random.Random(7), 0.5, 0.45, 0.24)
        pose_mundo = G.make_pose_mundo(random.Random(17), 0.32, 0.10)
        ang = fase + t * 3.0

        def mano(base_x, base_y, signo):
            cx = base_x + dx * t + amp * math.cos(ang) * signo
            cy = base_y + dy * t + amp * math.sin(ang)
            h = []
            for i, (ox, oy) in enumerate(dedos):
                h.append([
                    cx + ox + jitter.gauss(0, ruido),
                    cy + oy + jitter.gauss(0, ruido),
                    jitter.gauss(0, ruido),
                ])
            h[sn.HAND_WRIST] = [cx, cy, 0.0]
            h[sn.HAND_MIDDLE_MCP] = [cx + 0.01, cy - 0.06, 0.0]
            return h

        izq = mano(0.38, 0.60, -1) if manos == 2 else None
        der = mano(0.63, 0.58, 1)
        raw.append((pose, pose_mundo, izq, der))

    return sn.normalize_sequence(raw)


def test_frame_distance():
    print("test_frame_distance")
    a = hacer_sena(1, 20)[0]
    check(D.frame_distance(a, a) == 0.0, "distancia de un frame consigo mismo es 0")

    b = list(a)
    b[sn.OFF_PRES_L] = 0.0
    d_pres = D.frame_distance(a, b)
    c = list(a)
    c[sn.OFF_SHAPE_L] += 0.01
    d_forma = D.frame_distance(a, c)
    check(d_pres > d_forma * 5,
          "perder una mano pesa mucho mas que mover un dedo (%.3f vs %.3f)"
          % (d_pres, d_forma))


def test_dtw_basico():
    print("test_dtw_basico")
    s = hacer_sena(2, 32)
    check(D.dtw_distance(s, s) == 0.0, "DTW de una secuencia consigo misma es 0")

    lenta = hacer_sena(2, 60)
    rapida = hacer_sena(2, 18)
    d_misma = D.dtw_distance(lenta, rapida)
    otra = hacer_sena(9, 32)
    d_otra = D.dtw_distance(lenta, otra)
    check(d_misma < d_otra,
          "la misma sena a otra velocidad se parece mas que una distinta (%.4f vs %.4f)"
          % (d_misma, d_otra))


def test_clasificacion():
    print("test_clasificacion")
    glosas = ["CASA", "AGUA", "GRACIAS", "HOLA", "COMER", "TRABAJO"]
    clf = D.DtwClassifier()
    for i, g in enumerate(glosas):
        for r in range(4):
            clf.add(i, g, hacer_sena(100 + i, 28 + r * 3, ruido=0.004))

    aciertos = 0
    for i, g in enumerate(glosas):
        for dur in (20, 32, 45):
            p = clf.classify(hacer_sena(100 + i, dur, ruido=0.006))
            if p.gloss == g and p.aceptada:
                aciertos += 1
    total = len(glosas) * 3
    check(aciertos == total, "clasifica %d/%d consultas conocidas" % (aciertos, total))


def test_rechazo():
    print("test_rechazo")
    clf = D.DtwClassifier()
    for i, g in enumerate(["CASA", "AGUA", "GRACIAS"]):
        for r in range(4):
            clf.add(i, g, hacer_sena(200 + i, 30, ruido=0.004))

    rechazadas = 0
    for s in range(900, 906):
        p = clf.classify(hacer_sena(s, 30, ruido=0.006))
        if not p.aceptada:
            rechazadas += 1
    check(rechazadas >= 5,
          "rechaza %d/6 senas que no estan en el lexico" % rechazadas)


def test_prefiltro():
    print("test_prefiltro")
    glosas = ["S%02d" % i for i in range(30)]
    completo = D.DtwClassifier(prefilter=0)
    filtrado = D.DtwClassifier(prefilter=8)
    for i, g in enumerate(glosas):
        for r in range(3):
            seq = hacer_sena(300 + i, 30, ruido=0.004)
            completo.add(i, g, seq)
            filtrado.add(i, g, seq)

    iguales = 0
    for i in range(10):
        q = hacer_sena(300 + i, 30, ruido=0.006)
        if completo.classify(q).gloss == filtrado.classify(q).gloss:
            iguales += 1
    check(iguales >= 9,
          "el prefiltro da el mismo resultado en %d/10 casos" % iguales)


def test_una_mano_vs_dos():
    print("test_una_mano_vs_dos")
    dos = hacer_sena(400, 30, manos=2)
    una = hacer_sena(400, 30, manos=1)
    d = D.dtw_distance(dos, una)
    check(d > 0.3,
          "la misma trayectoria con una o dos manos queda lejos (%.3f)" % d)


def _sin_mano_der(seq, desde, hasta):
    """Copia de la secuencia con la mano derecha 'perdida' en [desde, hasta):
    es lo que pasa cuando la camara parpadea y no la detecta unos frames."""
    out = [list(f) for f in seq]
    for k in range(desde, hasta):
        out[k][sn.OFF_PRES_R] = 0.0
        for i in range(sn.OFF_LOC_R, sn.OFF_LOC_R + 3):
            out[k][i] = 0.0
        for i in range(sn.OFF_SHAPE_R, sn.OFF_SHAPE_R + 60):
            out[k][i] = 0.0
    return out


def _constante(delta):
    """Secuencia de 32 frames iguales con la mano izquierda presente y UNA
    dimension de su forma desplazada. El DTW entre dos constantes es
    exactamente la distancia entre sus frames."""
    f = [0.0] * sn.FRAME_DIM
    f[sn.OFF_PRES_L] = 1.0
    f[sn.OFF_SHAPE_L] = delta
    return [list(f) for _ in range(32)]


def test_abandono_no_altera_el_margen():
    print("test_abandono_no_altera_el_margen")
    # Distancia de frame = delta * sqrt(W_SHAPE / N_SHAPE); se eligen deltas para
    # que la mejor plantilla quede a 0.100 y la de otra glosa a 0.160: margen
    # (0.160 - 0.100) / 0.160 = 0.375. Con un minimo de 0.45 hay que RECHAZAR.
    k = math.sqrt(D.W_SHAPE / D.N_SHAPE)
    clf = D.DtwClassifier(max_distance=1.0, min_margin=0.45, prefilter=0)
    clf.add(1, "A", _constante(0.100 / k))
    clf.add(2, "B", _constante(0.160 / k))
    p = clf.classify(_constante(0.0))
    check(abs(p.distance - 0.100) < 1e-9 and p.gloss == "A",
          "la mejor es A a 0.100 (%s)" % p)
    check(abs(p.margin - 0.375) < 1e-9,
          "el margen es el real, 0.375, y no 1.0 por abandono temprano (%.3f)"
          % p.margin)
    check(not p.aceptada, "con minimo 0.45 se rechaza un margen de 0.375")


def _desplazada(seq, dx, dy):
    """La misma sena hecha mas arriba/abajo/a un lado: mueve la muneca."""
    out = [list(f) for f in seq]
    for f in out:
        for off_loc, off_pres in ((sn.OFF_LOC_L, sn.OFF_PRES_L),
                                  (sn.OFF_LOC_R, sn.OFF_PRES_R)):
            if f[off_pres] >= 0.5:
                f[off_loc] += dx
                f[off_loc + 1] += dy
    return out


def test_altura_no_cuenta():
    print("test_altura_no_cuenta")
    glosas = ["CASA", "AGUA", "GRACIAS", "HOLA"]
    clf = D.DtwClassifier(prefilter=0)
    for i, g in enumerate(glosas):
        clf.add(i, g, hacer_sena(500 + i, 30, ruido=0.004))
    bien = 0
    for i, g in enumerate(glosas):
        q = _desplazada(hacer_sena(500 + i, 32, ruido=0.006), 0.45, -0.35)
        p = clf.classify(q)
        if p.gloss == g and p.aceptada:
            bien += 1
    check(bien == len(glosas),
          "la misma sena hecha mucho mas arriba y a un lado se reconoce "
          "(%d/%d)" % (bien, len(glosas)))


def test_centrar_ubicacion():
    print("test_centrar_ubicacion")
    base = hacer_sena(77, 32)
    copia = [list(f) for f in base]
    c = D.centrar_ubicacion(base)
    check(base == copia, "centrar no modifica la secuencia original")
    for off_loc, off_pres in ((sn.OFF_LOC_L, sn.OFF_PRES_L),
                              (sn.OFF_LOC_R, sn.OFF_PRES_R)):
        n = sum(1 for f in c if f[off_pres] >= 0.5)
        mx = sum(f[off_loc] for f in c if f[off_pres] >= 0.5) / n
        check(abs(mx) < 1e-12, "la posicion media en X queda en 0 (%.1e)" % mx)
    sin_mano = [[0.0] * sn.FRAME_DIM for _ in range(4)]
    check(D.centrar_ubicacion(sin_mano) == sin_mano,
          "sin ninguna mano presente no cambia nada")


def test_umbrales_por_defecto():
    print("test_umbrales_por_defecto")
    clf = D.DtwClassifier()
    check(clf.max_distance == D.DEFAULT_MAX_DISTANCE
          and clf.min_margin == D.DEFAULT_MIN_MARGIN,
          "el clasificador usa los umbrales por defecto de dtw.py "
          "(%.2f / %.2f)" % (clf.max_distance, clf.min_margin))


def test_mano_perdida_unos_frames():
    print("test_mano_perdida_unos_frames")
    glosas = ["CASA", "AGUA", "GRACIAS", "HOLA", "COMER", "TRABAJO"]
    clf = D.DtwClassifier()
    for i, g in enumerate(glosas):
        for r in range(2):
            clf.add(i, g, hacer_sena(100 + i, 30 + r * 4, ruido=0.004))

    bien = 0
    for i, g in enumerate(glosas):
        q = hacer_sena(100 + i, 32, ruido=0.006)
        # 9 de 32 frames sin la mano: en las grabaciones reales faltan entre 10% y
        # 50% de los frames de la mano dominante. Con los pesos viejos de
        # presencia (2.0 / 1.0) esta prueba se rechazaba 6/6.
        p = clf.classify(_sin_mano_der(q, 10, 19))
        if p.gloss == g and p.aceptada:
            bien += 1
    check(bien == len(glosas),
          "reconoce y acepta %d/%d senas aunque la camara pierda una mano 9 frames"
          % (bien, len(glosas)))


if __name__ == "__main__":
    test_frame_distance()
    test_dtw_basico()
    test_clasificacion()
    test_rechazo()
    test_prefiltro()
    test_una_mano_vs_dos()
    test_umbrales_por_defecto()
    test_mano_perdida_unos_frames()
    test_abandono_no_altera_el_margen()
    test_altura_no_cuenta()
    test_centrar_ubicacion()
    print()
    if fallos:
        print("FALLARON %d comprobaciones" % len(fallos))
        sys.exit(1)
    print("todo en orden")
