"""Paridad del vector 152D con la web.

sign_norm.normalize_frame debe reproducir normalizeMotionFrame
(assets/avatar_viewer/rig_motion_frame.mjs) sobre el banco de paridad
test/golden/paridad_manos.jsonl.gz: vector de reconocimiento, vector de
render (con munecas estabilizadas) y motivos de rechazo. Las manos de cada
lado salen de la salida esperada de la captura web (indice de candidata).

Correr:  python3 -m pytest -q tools/test_paridad_manos.py
"""

import gzip
import json
import os

import sign_norm as sn

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "test", "golden", "paridad_manos.jsonl.gz")


def _lineas():
    with gzip.open(FIXTURE, "rt") as f:
        return [json.loads(l) for l in f if l.strip()]


def _cerca(esperado, obtenido):
    return abs(esperado - obtenido) <= 1e-9 * max(1.0, abs(esperado))


def _diferencia(esperado, obtenido):
    """None si son iguales; si no, una descripcion corta."""
    if esperado is None or obtenido is None:
        return None if esperado is obtenido else "%s vs %s" % (
            "null" if esperado is None else "vector",
            "None" if obtenido is None else "vector")
    if len(esperado) != len(obtenido):
        return "largo %d vs %d" % (len(esperado), len(obtenido))
    for k, (e, o) in enumerate(zip(esperado, obtenido)):
        if not _cerca(e, o):
            return "[%d] %r vs %r" % (k, e, o)
    return None


def _lado(linea, lado):
    """(mano para reconocimiento, mano de render) de un lado."""
    cand = [c["lm"] for c in linea["in"]["cand"]]
    e = linea["esp"][lado]
    indice = e["raw"] if e["raw"] is not None else e["detected"]
    mano = cand[indice] if indice is not None else None
    r = e["render"]
    render = None if r is None else cand[e["raw"]] if r == "raw" else r
    return mano, render


def _render_esperado(esp):
    """Decodifica `vec_render` (ver replay.esperadoDe)."""
    r, vec = esp["vec_render"], esp["vec"]
    if r is None:
        return vec
    if r == "null":
        return None
    if "all" in r:
        return r["all"]
    out = list(vec)
    for k, v in r.items():
        out[int(k)] = v
    return out


def _errores(motivos):
    return sorted(json.dumps([m["stage"], m["code"], m["side"]],
                             separators=(",", ":")) for m in motivos)


def _errores_esperados(esp):
    return sorted(json.dumps(e, separators=(",", ":")) for e in esp["err_vector"])


def test_vector_y_motivos_reproducen_la_web():
    desajustes = []
    n = 0
    for linea in _lineas():
        esp = linea["esp"]
        if "vec" not in esp:
            continue
        n += 1
        pose, mundo = linea["in"]["pose"], linea["in"]["world"]
        left, render_left = _lado(linea, "left")
        right, render_right = _lado(linea, "right")
        donde = "%s#%d" % (linea["tramo"], linea["i"])

        motivos = []
        vec = sn.normalize_frame(pose, mundo, left, right, motivos=motivos)
        d = _diferencia(esp["vec"], vec)
        if d:
            desajustes.append("%s vec %s" % (donde, d))
        if _errores(motivos) != _errores_esperados(esp):
            desajustes.append("%s err_vector web=%s py=%s" % (
                donde, esp["err_vector"], _errores(motivos)))

        render = sn.normalize_frame(
            pose, mundo, render_left or left, render_right or right,
            render_wrists={
                "left": render_left[0] if render_left else None,
                "right": render_right[0] if render_right else None,
            })
        d = _diferencia(_render_esperado(esp), render)
        if d:
            desajustes.append("%s vec_render %s" % (donde, d))
    assert n > 300, "fixture casi sin vectores: %d" % n
    assert not desajustes, "%d desajustes; primeros:\n%s" % (
        len(desajustes), "\n".join(desajustes[:20]))
