"""Tests de la normalizacion.  Correr:  python3 tools/test_norm.py

test_golden          -> la implementacion coincide con el archivo golden
test_invariancia     -> mover, alejar o inclinar a la persona no cambia el vector
test_espejo_doble    -> espejear dos veces devuelve el original
test_empaquetado     -> el round trip float16 conserva precision suficiente
test_validaciones    -> motivos de rechazo y munecas de render (golden)
test_isotropica      -> la correccion de aspecto deja la misma forma en cualquier camara
"""

import json
import math
import os
import random
import sys

import sign_norm as sn
import gen_golden

HERE = os.path.dirname(os.path.abspath(__file__))
GOLDEN = os.path.join(HERE, "..", "test", "golden", "golden_cases.json")
TOL = 1e-5

fallos = []


def check(cond, msg):
    if cond:
        print("  ok   ", msg)
    else:
        print("  FALLA", msg)
        fallos.append(msg)


def max_diff(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def test_golden():
    print("test_golden")
    if not os.path.exists(GOLDEN):
        check(False, "falta golden_cases.json, corre gen_golden.py")
        return
    data = json.load(open(GOLDEN))
    check(data["norm_version"] == sn.NORM_VERSION,
          "version %s coincide" % data["norm_version"])
    for c in data["cases"]:
        raw = [(f["pose"], f["pose_mundo"], f["left"], f["right"])
               for f in c["frames"]]
        got = [sn.normalize_frame(p, pm, l, r) for (p, pm, l, r) in raw]
        d = max(max_diff(g, e) for g, e in zip(got, c["expected_frames"]))
        check(d < TOL, "%s: frames (max diff %.2e)" % (c["name"], d))
        d = max_diff(sn.mirror_frame(got[0]), c["expected_mirror_frame0"])
        check(d < TOL, "%s: espejo (max diff %.2e)" % (c["name"], d))
        rs = sn.resample(got, 5)
        d = max(max_diff(g, e) for g, e in zip(rs, c["expected_resample_5"]))
        check(d < TOL, "%s: remuestreo (max diff %.2e)" % (c["name"], d))
    iso = data.get("iso")
    if iso:
        check(iso["forma"] == sn.FORMA_ISO, "forma isotropica %s coincide" % iso["forma"])
        check(tuple(iso["ref_palma"]) == sn.REF_PALMA and tuple(iso["idx_palma"]) == sn.IDX_PALMA,
              "referencias de la palma coinciden")
        for clave, esperado in iso["aspectos"].items():
            origen = data["cases"][0]["expected_frames"] if clave == "0.75" else data["cases"][1]["expected_frames"]
            got = sn.isotropizar_secuencia(origen, float(clave))
            d = max(max_diff(g, e) for g, e in zip(got, esperado))
            check(d < TOL, "isotropica a=%s (max diff %.2e)" % (clave[:6], d))


def test_validaciones():
    """Cada motivo de rechazo y las munecas de render (bloque `validaciones`
    del golden; Dart y la web lo comprueban con los mismos datos)."""
    print("test_validaciones")
    data = json.load(open(GOLDEN))
    for c in data.get("validaciones", []):
        f = c["frame"]
        motivos = []
        v = sn.normalize_frame(f["pose"], f["pose_mundo"], f["left"], f["right"],
                               render_wrists=f.get("render_wrists"),
                               motivos=motivos)
        got = [[m["stage"], m["code"], m["side"], m["landmark"]] for m in motivos]
        check(got == c["motivos"], "%s: motivos %s" % (c["name"], got))
        if c["expected"] is None:
            check(v is None, "%s: frame descartado" % c["name"])
        else:
            d = max_diff(v, c["expected"]) if v else float("inf")
            check(d < TOL, "%s: vector (max diff %.2e)" % (c["name"], d))


def _transformar(pts, dx, dy, s, ang, cx=0.5, cy=0.5):
    ca, sa = math.cos(ang), math.sin(ang)
    out = []
    for p in pts:
        x, y = p[0] - cx, p[1] - cy
        x, y = x * ca - y * sa, x * sa + y * ca
        q = [x * s + cx + dx, y * s + cy + dy, p[2] * s]
        if len(p) > 3:
            q.append(p[3])
        out.append(q)
    return out


def _transformar_mundo(pts, s, giro):
    """Escala el esqueleto metrico y lo GIRA sobre el eje vertical.

    Girar a la persona es la prueba fuerte de la version 2.0.0: el bloque de
    cuerpo se proyecta sobre una base sacada del propio esqueleto, asi que
    ponerse de perfil no deberia cambiar el vector.
    """
    cg, sg = math.cos(giro), math.sin(giro)
    out = []
    for p in pts:
        x, y, z = p[0] * s, p[1] * s, p[2] * s
        out.append([x * cg + z * sg, y, -x * sg + z * cg])
    return out


def test_invariancia():
    print("test_invariancia")
    rng = random.Random(11)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    mundo = gen_golden.make_pose_mundo(rng, 0.32, 0.12)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    base = sn.normalize_frame(pose, mundo, left, right)

    for nombre, (dx, dy, s, ang, giro) in {
        "trasladado":  (0.15, -0.10, 1.0, 0.0, 0.0),
        "mas lejos":   (0.0, 0.0, 0.55, 0.0, 0.0),
        "mas cerca":   (0.0, 0.0, 1.7, 0.0, 0.0),
        "inclinado":   (0.0, 0.0, 1.0, 0.35, 0.0),
        "girado 40":   (0.0, 0.0, 1.0, 0.0, 0.70),
        "todo junto":  (-0.12, 0.08, 0.7, -0.25, -0.5),
    }.items():
        p2 = _transformar(pose, dx, dy, s, ang)
        m2 = _transformar_mundo(mundo, s, giro)
        l2 = _transformar(left, dx, dy, s, ang)
        r2 = _transformar(right, dx, dy, s, ang)
        got = sn.normalize_frame(p2, m2, l2, r2)
        # Solo el bloque de cuerpo: la forma de las manos se calcula en
        # coordenadas de imagen y girar a la persona si la cambia.
        d = max(abs(got[i] - base[i]) for i in range(sn.OFF_PRES_L))
        check(d < 1e-4, "%s: cuerpo identico (max diff %.2e)" % (nombre, d))


def test_espejo_doble():
    print("test_espejo_doble")
    rng = random.Random(3)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    mundo = gen_golden.make_pose_mundo(rng, 0.32, 0.08)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    v = sn.normalize_frame(pose, mundo, left, right)
    d = max_diff(sn.mirror_frame(sn.mirror_frame(v)), v)
    check(d < 1e-9, "doble espejo devuelve el original (max diff %.2e)" % d)

    solo_der = sn.normalize_frame(pose, mundo, None, right)
    esp = sn.mirror_frame(solo_der)
    check(esp[sn.OFF_PRES_L] == 1.0 and esp[sn.OFF_PRES_R] == 0.0,
          "el espejo cruza la presencia de manos")


def test_empaquetado():
    print("test_empaquetado")
    rng = random.Random(5)
    pose = gen_golden.make_pose(rng, 0.5, 0.45, 0.24)
    mundo = gen_golden.make_pose_mundo(rng, 0.32, 0.05)
    left = gen_golden.make_hand(rng, 0.38, 0.60)
    right = gen_golden.make_hand(rng, 0.63, 0.58)
    seq = sn.normalize_sequence([(pose, mundo, left, right)] * 4)
    blob = sn.pack_f16(seq)
    back = sn.unpack_f16(blob)
    d = max(max_diff(a, b) for a, b in zip(seq, back))
    check(len(seq) == sn.T_FRAMES, "la secuencia quedo en %d frames" % sn.T_FRAMES)
    check(d < 2e-3, "round trip float16 (max diff %.2e)" % d)
    print("       peso de una seña: %.1f KB" % (len(blob) / 1024))


def _mano_realista(rng):
    """Forma 3D plausible, ya con la escala de la palma en 1 (palma3d)."""
    base = [(-0.00, 0.00, 0.00)]
    pts = []
    refs = [0.41, 0.31, 0.24, 0.43, 0.25, 0.20, 0.45, 0.26, 0.20,
            0.42, 0.24, 0.18, 0.33, 0.19, 0.15]
    # cuatro dedos largos + pulgar, cada nudillo a REF_PALMA de la muneca
    dirs = [(-0.55, 0.78), (-0.15, 0.97), (0.22, 0.93), (0.55, 0.78)]
    for (dx, dy), ref in zip(dirs, sn.REF_PALMA):
        n = math.hypot(dx, dy)
        pts.append((dx / n * ref * 0.97, dy / n * ref * 0.97, rng.uniform(-0.15, 0.15) * ref))
    out = [(0.0, 0.0, 0.0)] * 20
    out = list(out)
    # posiciones de MCP5,9,13,17 -> 4, 8, 12, 16; el resto, aleatorio y estable
    for i in range(20):
        out[i] = (rng.uniform(-0.8, 0.8), rng.uniform(0.0, 1.8), rng.uniform(-0.3, 0.3))
    for j, p in zip(sn.IDX_PALMA, pts):
        out[j] = p
    flat = [c for q in out for c in q]
    return sn.isotropizar_forma(flat, 1.0)       # canonica: escala de palma exactamente 1


def test_isotropica():
    print("test_isotropica")
    rng = random.Random(21)
    for a in (16.0 / 9.0, 4.0 / 3.0, 0.75, 9.0 / 16.0):
        s0 = _mano_realista(rng)
        # Lo que guardaria la version 2.0.0 de la MISMA mano filmada con un
        # aspecto a: x y z divididos por a, y todo por la escala 2D muneca->MCP9.
        aniso = [list(s0[i * 3:i * 3 + 3]) for i in range(20)]
        for q in aniso:
            q[0] /= a
            q[2] /= a
        h2d = math.hypot(aniso[8][0], aniso[8][1])
        flat = [c / h2d for q in aniso for c in q]
        back = sn.isotropizar_forma(flat, a)
        d = max_diff(back, s0)
        check(d < 1e-9, "aspecto %.3f: vuelve a la forma original (max diff %.1e)" % (a, d))

    # dos camaras con aspecto distinto dan la misma forma tras corregir
    s0 = _mano_realista(random.Random(4))
    vistas = []
    for a in (16.0 / 9.0, 0.75):
        aniso = [list(s0[i * 3:i * 3 + 3]) for i in range(20)]
        for q in aniso:
            q[0] /= a
            q[2] /= a
        h2d = math.hypot(aniso[8][0], aniso[8][1])
        vistas.append(sn.isotropizar_forma([c / h2d for q in aniso for c in q], a))
    check(max_diff(vistas[0], vistas[1]) < 1e-9, "16:9 y 3:4 coinciden despues de corregir")

    # el frame: solo cambia la forma de las manos presentes
    v = [0.0] * sn.FRAME_DIM
    for i in range(sn.OFF_LOC_L):
        v[i] = 0.1 * i
    v[sn.OFF_PRES_R] = 1.0
    v[sn.OFF_SHAPE_R:sn.OFF_SHAPE_R + 60] = s0
    w = sn.isotropizar_frame(v, 0.75)
    check(w[:sn.OFF_SHAPE_L] == v[:sn.OFF_SHAPE_L], "cuerpo, ubicacion y presencia no cambian")
    check(w[sn.OFF_SHAPE_L:sn.OFF_SHAPE_R] == v[sn.OFF_SHAPE_L:sn.OFF_SHAPE_R],
          "una mano ausente queda intacta")
    check(max_diff(w[sn.OFF_SHAPE_R:], v[sn.OFF_SHAPE_R:]) > 1e-3, "la mano presente si cambia")
    check(sn.isotropizar_forma([0.0] * 60, 0.75) == [0.0] * 60, "forma vacia no explota")


if __name__ == "__main__":
    test_golden()
    test_invariancia()
    test_espejo_doble()
    test_empaquetado()
    test_validaciones()
    test_isotropica()
    print()
    if fallos:
        print("FALLARON %d comprobaciones" % len(fallos))
        sys.exit(1)
    print("todo en orden")
