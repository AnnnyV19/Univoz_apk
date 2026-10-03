"""Analiza un rig_diagnostic_*.json exportado desde el visor (boton Exportar).

Uso:  python3 tools/analizar_diagnostico.py ~/Descargas/rig_diagnostic_XXXX.json

Diagnostico de PROFUNDIDAD: en el vector 152D el cuerpo esta en 3D (anchos
de hombro, +z al frente). Si MediaPipe estima bien la profundidad, el largo
3D del antebrazo y del brazo es casi constante aunque el brazo apunte a la
camara. Si la subestima, al estirar el brazo hacia la camara el segmento se
"encoge" (su proyeccion x,y se acorta y z no compensa) y la muneca casi no
avanza en z: el avatar no se mueve hacia adelante.
"""

import json
import math
import sys

# puntos del bloque de cuerpo (indices de punto, x3 para la dimension)
HOMBRO_I, HOMBRO_D, CODO_I, CODO_D, MUN_I, MUN_D = range(6)


def punto(frame, i):
    return frame[i * 3:i * 3 + 3]


def dist(a, b):
    return math.sqrt(sum((a[k] - b[k]) ** 2 for k in range(3)))


def dist_xy(a, b):
    return math.hypot(a[0] - b[0], a[1] - b[1])


def pct(xs, p):
    if not xs:
        return float("nan")
    s = sorted(xs)
    return s[min(len(s) - 1, int(p * (len(s) - 1) + 0.5))]


def analizar(ruta):
    with open(ruta) as fh:
        rep = json.load(fh)
    frames = [f for f in rep.get("frames", []) if f.get("raw_frame")]
    print("archivo:", ruta)
    print("frames con vector:", len(frames), "de", len(rep.get("frames", [])))
    if not frames:
        return
    modos = sorted({f.get("retarget_mode") for f in frames} - {None})
    print("retarget:", modos or "(sin dato)")

    t0 = frames[0]["t"]
    for lado, h, c, m in (("izq", HOMBRO_I, CODO_I, MUN_I),
                          ("der", HOMBRO_D, CODO_D, MUN_D)):
        brazo, ante, ante_xy, munz, filas = [], [], [], [], []
        for f in frames:
            v = f["raw_frame"]
            ph, pc, pm = punto(v, h), punto(v, c), punto(v, m)
            brazo.append(dist(ph, pc))
            ante.append(dist(pc, pm))
            ante_xy.append(dist_xy(pc, pm))
            munz.append(pm[2] - ph[2])
            filas.append((f["t"] - t0, dist(ph, pc), dist(pc, pm), pm[2] - ph[2],
                          dist_xy(ph, pm)))
        ref = pct(ante, 0.9)  # antebrazo "de perfil", sin escorzo
        print("\nbrazo", lado)
        print("  largo brazo   p10/p50/p90: %.2f / %.2f / %.2f anchos de hombro"
              % (pct(brazo, .1), pct(brazo, .5), pct(brazo, .9)))
        print("  largo antebr. p10/p50/p90: %.2f / %.2f / %.2f"
              % (pct(ante, .1), pct(ante, .5), pct(ante, .9)))
        print("  muneca z (frente) p10/p50/p90: %.2f / %.2f / %.2f"
              % (pct(munz, .1), pct(munz, .5), pct(munz, .9)))
        encogido = [r for r in filas if r[2] < 0.7 * ref]
        print("  frames con antebrazo < 70%% de su largo: %d (%.0f%%)"
              % (len(encogido), 100.0 * len(encogido) / len(filas)))
        if encogido:
            print("  -> MediaPipe subestima la profundidad en esos frames.")
        # linea de tiempo cada ~0.5 s
        print("  t(s)  brazo  antebr  munZ  alcanceXY")
        ultimo = -1e9
        for t, b, a, z, r in filas:
            if t - ultimo >= 500:
                print("  %5.1f  %.2f   %.2f   %+.2f  %.2f" % (t / 1000, b, a, z, r))
                ultimo = t

    ss = [f["sign_space"] for f in frames if f.get("sign_space")]
    if ss:
        modos = {}
        for s in ss:
            modos[s["mode"]] = modos.get(s["mode"], 0) + 1
        print("\nSignSpace frames:", len(ss), "modos:", modos)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for ruta in sys.argv[1:]:
        analizar(ruta)
