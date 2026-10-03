"""Resume una sesion grabada por el visor (SessionLogV1, JSONL).

Uso:  python3 tools/analizar_sesion.py [sesiones/<id>.jsonl ...]
      (sin argumentos analiza la sesion mas reciente de senas_core/sesiones)
      python3 tools/analizar_sesion.py --baseline [sesion.jsonl]
      (guarda docs/evidence/baseline/<id>-<plataforma>.json, Fase 0)
      python3 tools/analizar_sesion.py --comparar A B

Reporta cobertura (pose, manos, cara), rechazos de la compuerta de manos,
modos de asignacion de lado, errores mas frecuentes, tiempos, eventos,
perfil corporal y el diagnostico de profundidad (antebrazo encogido).
"""

import collections
import glob
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SESIONES = os.path.join(HERE, "..", "sesiones")


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None and math.isfinite(x))
    if not xs:
        return float("nan")
    return xs[min(len(xs) - 1, int(p * (len(xs) - 1) + 0.5))]


def leer(ruta):
    """Lee el JSONL y quita duplicados por `seq` (al cerrar la pagina un
    bloque puede llegar dos veces)."""
    vistos, out = set(), []
    with open(ruta, encoding="utf-8") as fh:
        for l in fh:
            if not l.strip():
                continue
            r = json.loads(l)
            if "seq" in r:
                if r["seq"] in vistos:
                    continue
                vistos.add(r["seq"])
            out.append(r)
    out.sort(key=lambda r: r.get("seq", 0))
    return out


def resumir(registros):
    """Devuelve un dict con el resumen (usado tambien por las pruebas)."""
    cab = next((r for r in registros if r.get("kind") == "session_start"), {})
    fin = next((r for r in registros if r.get("kind") == "session_end"), None)
    frames = [r for r in registros if r.get("kind") == "frame"]
    eventos = [r for r in registros if r.get("kind") == "event"]
    n = len(frames)
    out = {"session_id": cab.get("session_id"), "meta": cab.get("meta", {}),
           "frames": n, "closed": fin is not None,
           "dropped": (fin or {}).get("dropped", 0)}
    if n:
        ts = [f["t"] for f in frames if isinstance(f.get("t"), (int, float))]
        dur = (ts[-1] - ts[0]) / 1000 if len(ts) > 1 else 0
        out["duration_s"] = round(dur, 1)
        out["fps"] = round((len(ts) - 1) / dur, 1) if dur > 0 else 0
        cuenta = lambda pred: round(100.0 * sum(1 for f in frames if pred(f)) / n, 1)
        out["coverage_pct"] = {
            "pose": cuenta(lambda f: f.get("pose")),
            "left_hand": cuenta(lambda f: (f.get("tracked") or {}).get("left")),
            "right_hand": cuenta(lambda f: (f.get("tracked") or {}).get("right")),
            "face": cuenta(lambda f: f.get("face")),
            "vector": cuenta(lambda f: f.get("vec")),
        }
        rech = collections.Counter()
        asign = collections.Counter()
        dup_frames = 0
        for f in frames:
            h = f.get("hands") or {}
            for r in h.get("rejected", []):
                rech[r.get("code")] += 1
            if any(r.get("code") == "hand_duplicate" for r in h.get("rejected", [])):
                dup_frames += 1
            if h.get("assignment"):
                asign[h["assignment"].get("mode")] += 1
            elif (h.get("association") or {}).get("hand_assignment_mode"):
                # sesiones Android: el modo viene del motor Kotlin
                asign[h["association"]["hand_assignment_mode"]] += 1
        out["hand_rejects"] = dict(rech)
        out["assignment_modes"] = dict(asign)
        errs = collections.Counter(c for f in frames for c in f.get("errors", []))
        # En Android los rechazos de la compuerta llegan como errores.
        for codigo in ("hand_duplicate", "hand_far_from_arm",
                       "hand_scale_implausible", "hand_landmarks_invalid"):
            if errs.get(codigo) and codigo not in rech:
                rech[codigo] = errs[codigo]
        out["hand_rejects"] = dict(rech)
        out["top_errors"] = errs.most_common(10)
        ms = [f.get("ms", {}) for f in frames]
        out["timing_ms"] = {k: {"p50": round(pct([m.get(k) for m in ms], .5), 1),
                                "p95": round(pct([m.get(k) for m in ms], .95), 1)}
                            for k in ("pose", "hand", "proc")}
        # profundidad: antebrazo 3D dentro del 152D (puntos codo 2/3, muneca 4/5)
        prof = {}
        for lado, c, m in (("left", 2, 4), ("right", 3, 5)):
            largos, zs = [], []
            for f in frames:
                v = f.get("vec")
                if not v:
                    continue
                pc, pm = v[c * 3:c * 3 + 3], v[m * 3:m * 3 + 3]
                largos.append(math.dist(pc, pm))
                zs.append(pm[2] - v[(0 if lado == "left" else 1) * 3 + 2])
            if largos:
                ref = pct(largos, .9)
                prof[lado] = {
                    "forearm_p50": round(pct(largos, .5), 2),
                    "collapsed_pct": round(100.0 * sum(1 for x in largos
                                                       if x < .7 * ref) / len(largos), 1),
                    "wrist_front_p90": round(pct(zs, .9), 2),
                }
        out["depth"] = prof
        cabezas = [f["face"]["head"] for f in frames
                   if f.get("face") and f["face"].get("head")]
        if cabezas:
            out["head_range_deg"] = {k: [round(math.degrees(pct([h[k] for h in cabezas], q)), 0)
                                         for q in (.05, .95)]
                                     for k in ("yaw", "pitch", "roll")}
    out["events"] = dict(collections.Counter(e.get("type") for e in eventos))
    perfil = next((e.get("profile") for e in eventos
                   if e.get("type") == "body_profile"), None)
    if perfil:
        out["body_profile"] = {"measures": perfil.get("measures"),
                               "capability": perfil.get("capability")}
    return out


def imprimir(res):
    print(json.dumps(res, indent=1, ensure_ascii=False))


BASELINE_DIR = os.path.join(HERE, "..", "..", "docs", "evidence", "baseline")


def baseline(res):
    """Registro de Fase 0: metricas comparables + contexto del dispositivo.
    Cada gate reporta dispositivo, resolucion y tamano de muestra."""
    meta = res.get("meta", {})
    return {
        "schema": "BaselineV1",
        "session_id": res.get("session_id"),
        "platform": meta.get("platform"),
        "screen": meta.get("screen"),
        "capture_mode": meta.get("capture_mode"),
        "device": meta.get("user_agent") or meta.get("device"),
        "video": meta.get("video"),
        "frames": res.get("frames", 0),
        "duration_s": res.get("duration_s"),
        "fps": res.get("fps"),
        "coverage_pct": res.get("coverage_pct"),
        "timing_ms": res.get("timing_ms"),
        "hand_rejects": res.get("hand_rejects"),
        "assignment_modes": res.get("assignment_modes"),
        "depth": res.get("depth"),
        "head_range_deg": res.get("head_range_deg"),
        "top_errors": res.get("top_errors"),
    }


def _plano(d, prefijo=""):
    out = {}
    for k, v in (d or {}).items():
        clave = prefijo + k
        if isinstance(v, dict):
            out.update(_plano(v, clave + "."))
        elif isinstance(v, (int, float)) and not isinstance(v, bool):
            out[clave] = v
    return out


def comparar(a, b):
    """Diferencias numericas b - a entre dos resumenes (o baselines)."""
    pa, pb = _plano(a), _plano(b)
    return {k: {"a": pa[k], "b": pb[k], "delta": round(pb[k] - pa[k], 3)}
            for k in sorted(set(pa) & set(pb)) if pa[k] != pb[k]}


def _ultima():
    todas = sorted(glob.glob(os.path.join(SESIONES, "*.jsonl")))
    if not todas:
        print("no hay sesiones en", os.path.normpath(SESIONES))
        sys.exit(1)
    return todas[-1]


def _cargar(ruta):
    if ruta.endswith(".json"):
        with open(ruta, encoding="utf-8") as fh:
            return json.load(fh)
    return resumir(leer(ruta))


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--comparar"]:
        if len(args) != 3:
            print("uso: --comparar A B (jsonl o baseline .json)")
            sys.exit(1)
        imprimir(comparar(_cargar(args[1]), _cargar(args[2])))
        sys.exit(0)
    if args[:1] == ["--baseline"]:
        ruta = args[1] if len(args) > 1 else _ultima()
        b = baseline(resumir(leer(ruta)))
        os.makedirs(BASELINE_DIR, exist_ok=True)
        nombre = "%s-%s.json" % (b["session_id"] or "sesion", b["platform"] or "x")
        destino = os.path.normpath(os.path.join(BASELINE_DIR, nombre))
        with open(destino, "w", encoding="utf-8") as fh:
            json.dump(b, fh, indent=1, ensure_ascii=False)
        print("baseline:", destino)
        sys.exit(0)
    for ruta in args or [_ultima()]:
        print("==", ruta)
        imprimir(resumir(leer(ruta)))
