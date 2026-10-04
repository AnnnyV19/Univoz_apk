"""Resume una sesion grabada por el visor (SessionLogV1, JSONL).

Uso:  python3 tools/analizar_sesion.py [sesiones/<id>.jsonl ...]
      (sin argumentos analiza la sesion mas reciente de senas_core/sesiones)
      python3 tools/analizar_sesion.py --baseline [sesion.jsonl]
      (guarda docs/evidence/baseline/<id>-<plataforma>.json, Fase 0)
      python3 tools/analizar_sesion.py --comparar A B
      python3 tools/analizar_sesion.py --gates [sesion.jsonl]
      (veredicto por fase contra docs/10; guarda docs/evidence/gates/)

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
sys.path.insert(0, HERE)

import auditoria  # noqa: E402
SESIONES = os.path.join(HERE, "..", "sesiones")


def pct(xs, p):
    xs = sorted(x for x in xs if x is not None and math.isfinite(x))
    if not xs:
        return float("nan")
    return xs[min(len(xs) - 1, int(p * (len(xs) - 1) + 0.5))]


def leer(ruta):
    """Lee el JSONL y quita duplicados por `seq` (al cerrar la pagina un
    bloque puede llegar dos veces)."""
    with open(ruta, encoding="utf-8") as fh:
        return leer_registros(json.loads(l) for l in fh if l.strip())


def leer_registros(registros):
    vistos, out = set(), []
    for r in registros:
        if "seq" in r:
            if r["seq"] in vistos:
                continue
            vistos.add(r["seq"])
        out.append(r)
    out.sort(key=lambda r: r.get("seq", 0))
    return out


def por_modo(frames, campo):
    """Metricas por valor de un campo del frame (p. ej. retarget legacy vs
    anchors activados a mitad de sesion)."""
    grupos = collections.defaultdict(list)
    for f in frames:
        if f.get(campo) is not None:
            grupos[f[campo]].append(f)
    if len(grupos) < 2:
        return {}
    out = {}
    for valor, fs in sorted(grupos.items()):
        out[valor] = resumir([{"kind": "session_start"}] + fs)
        out[valor].pop("by_step", None)
        out[valor].pop("by_retarget", None)
        out[valor].pop("meta", None)
    return out


def por_paso(frames, eventos):
    """Agrupa frames por la ultima marca de protocolo (teclas 1-9) vista
    antes de cada frame, usando el orden de `seq`. Resume cobertura y
    errores mas comunes de cada paso."""
    marcas = sorted((e.get("seq", 0), e.get("step")) for e in eventos
                    if e.get("type") == "marker")
    if not marcas:
        return {}
    grupos = collections.defaultdict(list)
    for f in frames:
        paso = None
        for seq, step in marcas:
            if seq < f.get("seq", 0):
                paso = step
        if paso is not None:
            grupos[paso].append(f)
    out = {}
    for paso, fs in sorted(grupos.items()):
        n = len(fs)
        cub = lambda pred: round(100.0 * sum(1 for f in fs if pred(f)) / n, 1)
        out[str(paso)] = {
            "frames": n,
            "pose_pct": cub(lambda f: f.get("pose")),
            "left_pct": cub(lambda f: (f.get("tracked") or {}).get("left")),
            "right_pct": cub(lambda f: (f.get("tracked") or {}).get("right")),
            "face_pct": cub(lambda f: f.get("face")),
            "top_errors": collections.Counter(
                c for f in fs for c in f.get("errors", [])).most_common(5),
        }
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
                            for k in ("pose", "hand", "proc", "rt")
                            if any(m.get(k) is not None for m in ms)}
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
    out["by_step"] = por_paso(frames, eventos)
    out["by_retarget"] = por_modo(frames, "retarget")
    perfil = next((e.get("profile") for e in eventos
                   if e.get("type") == "body_profile"), None)
    if perfil:
        out["body_profile"] = {"measures": perfil.get("measures"),
                               "capability": perfil.get("capability")}
    # Audit Sentinel: perfil medido en esta sesion, o el que traia la meta.
    perfil_audit = perfil or (cab.get("meta") or {}).get("body_profile")
    if n and perfil_audit:
        res = [r for r in auditoria.auditar(frames, perfil_audit) if r]
        if res:
            ds = [r["d"] for r in res]
            out["audit"] = {
                "frames": len(res),
                "d_p50": round(pct(ds, .5), 2),
                "d_p95": round(pct(ds, .95), 2),
                "anomalous_pct": round(100.0 * sum(1 for d in ds if d > 2) / len(ds), 1),
                "codes": dict(collections.Counter(c for r in res for c in r["codes"])),
            }
    return out


# ---- Gates por fase (docs/10-metricas-y-criterios.md) -------------------
# Umbrales copiados de docs/10; si cambian alla, cambian aqui.
GATES = {
    "frames_min": 300,
    "tracking_fps_min": 30,
    "render_fps_min": 60,
    "latency_p95_ms": 50,             # objetivo final
    "latency_p95_provisional_ms": 120,  # solo diagnostico en Fase 0
    "inversion_pct_max": 1.0,
    "jitter_deg_max": 2.0,
}
# Paso (tecla) de cada maniobra segun el protocolo de la marca.
PASOS = {
    "manos": {"estatica": 1, "pulgar": 2, "giro": 3, "puno": 4,
              "pronacion": 5, "cruce": 6, "tapar_200": 7, "tapar_500": 8,
              "salir": 9},
    # "quieto" (brazos abajo) sirve para jitter, no para orientacion de mano.
    "cuerpo": {"quieto": 1, "cruce": 4, "salir": 9},
}
# Pasos donde la palma no deberia cambiar de cara: un cambio es inversion.
SIN_GIRO = ("estatica", "pulgar", "puno")
IDENTIDAD = ("cruce", "tapar_200", "tapar_500", "salir")
CAUSAS_PERDIDA = {
    "hand_occluded": "oclusion", "wrist_out_of_frame": "fuera_de_cuadro",
    "hand_duplicate": "compuerta", "hand_far_from_arm": "compuerta",
    "hand_scale_implausible": "compuerta", "hand_landmarks_invalid": "compuerta",
}


def _maniobras(registros):
    """{nombre_maniobra: [registros]} asignando cada frame/perf a la ultima
    marca previa (por seq). Marcas viejas sin protocolo = 'cuerpo'."""
    cab = next((r for r in registros if r.get("kind") == "session_start"), {})
    por_defecto = (cab.get("meta") or {}).get("protocol") or "cuerpo"
    actual, out = None, collections.defaultdict(list)
    for r in registros:
        if r.get("kind") == "event" and r.get("type") == "marker":
            prot = r.get("protocol") or por_defecto
            nombres = {v: k for k, v in PASOS.get(prot, {}).items()}
            actual = nombres.get(r.get("step"))
            continue
        if actual and (r.get("kind") == "frame" or r.get("type") == "perf"):
            out[actual].append(r)
    return out


def _deltas(perfs, clave):
    """Suma de incrementos de un contador acumulado (se reinicia al
    reencender la camara: un descenso cuenta como nuevo origen)."""
    total, prev = 0, None
    for p in perfs:
        v = (p.get("counters") or {}).get(clave)
        if not isinstance(v, (int, float)):
            continue
        if prev is not None and v >= prev:
            total += v - prev
        prev = v
    return total


def _inversiones(frames):
    """Cambios palma<->dorso entre frames consecutivos con cara conocida."""
    cambios = conocidos = 0
    for lado in ("left_surface", "right_surface"):
        prev = None
        for f in frames:
            sup = (f.get("tracked") or {}).get(lado)
            if sup not in ("palm", "dorsum"):
                continue
            conocidos += 1
            if prev is not None and sup != prev:
                cambios += 1
            prev = sup
    return cambios, conocidos


def _jitter_deg(frames, codo, muneca, ventana=15, bloque=30):
    """Jitter (grados) del antebrazo: residuo contra su media movil centrada
    (~0.5 s a 30 FPS), RMS por bloques de ~1 s y mediana de los bloques.
    La mediana descarta los segundos en que el brazo se movio de verdad."""
    dirs = []
    for f in frames:
        v = f.get("vec")
        if not v:
            continue
        d = [v[muneca * 3 + k] - v[codo * 3 + k] for k in range(3)]
        n = math.sqrt(sum(x * x for x in d))
        if n > 1e-6:
            dirs.append([x / n for x in d])
    if len(dirs) < ventana:
        return None
    errs, h = [], ventana // 2
    for i in range(h, len(dirs) - h):
        m = [sum(d[k] for d in dirs[i - h:i + h + 1]) for k in range(3)]
        nm = math.sqrt(sum(x * x for x in m)) or 1
        cos = sum(dirs[i][k] * m[k] / nm for k in range(3))
        errs.append(math.degrees(math.acos(max(-1.0, min(1.0, cos)))))
    rms = [math.sqrt(sum(e * e for e in errs[i:i + bloque]) / len(errs[i:i + bloque]))
           for i in range(0, len(errs), bloque) if len(errs[i:i + bloque]) >= bloque // 2]
    return round(pct(rms, .5), 3) if rms else None


def _perdida(frames):
    n = len(frames)
    sin_mano = [f for f in frames if not any(
        (f.get("tracked") or {}).get(k) for k in ("left", "right"))]
    causas = collections.Counter()
    for f in sin_mano:
        cs = {CAUSAS_PERDIDA[c] for c in f.get("errors", []) if c in CAUSAS_PERDIDA}
        causas.update(cs or {"modelo"})
    return {"loss_pct": round(100.0 * len(sin_mano) / n, 1) if n else None,
            "causas": dict(causas)}


def gates(registros):
    """Veredicto PASS / PROVISIONAL / FAIL / SIN_DATOS por fase (docs/10)."""
    cab = next((r for r in registros if r.get("kind") == "session_start"), {})
    meta = cab.get("meta") or {}
    frames = [r for r in registros if r.get("kind") == "frame"]
    perfs = [r for r in registros if r.get("type") == "perf"]
    mans = _maniobras(registros)
    solo = lambda nombre, tipo="frame": [r for r in mans.get(nombre, [])
                                         if (r.get("kind") == "frame") == (tipo == "frame")]
    out = {"schema": "GatesV1", "session_id": cab.get("session_id"),
           "umbrales": GATES,
           "contexto": {"platform": meta.get("platform"),
                        "device": meta.get("user_agent") or meta.get("device"),
                        "video": meta.get("video"),
                        "capture_worker": _worker(meta)[0],
                        "capture_worker_mode": _worker(meta)[1],
                        "capture_mode": meta.get("capture_mode"),
                        "protocol": meta.get("protocol") or "cuerpo",
                        "frames": len(frames),
                        "maniobras": {k: len(solo(k)) for k in sorted(mans)}}}

    vec_ok = all(len(f["vec"]) == 152 for f in frames if f.get("vec"))
    out["fase_0_baseline"] = {
        "frames": len(frames), "vector_152": vec_ok,
        "veredicto": "PASS" if vec_ok and len(frames) >= GATES["frames_min"] else "FAIL"}

    lat = [x for p in perfs for x in p.get("latency_ms") or []]
    fps = lambda k: pct([(p.get("fps") or {}).get(k) for p in perfs], .5)
    # FPS de manos solo en segundos con alguna mano: con los brazos abajo
    # tracking = 0 por diseno, no por lentitud.
    con_manos = [(p.get("fps") or {}).get("tracking") for p in perfs]
    con_manos = [x for x in con_manos if isinstance(x, (int, float)) and x > 0]
    f1 = {"perf_events": len(perfs)}
    if not perfs or not lat:
        f1["veredicto"] = "SIN_DATOS"
    else:
        f1.update({"latency_ms": {"n": len(lat), "p50": pct(lat, .5),
                                  "p95": pct(lat, .95), "p99": pct(lat, .99)},
                   "tracking_fps_p50": pct(con_manos, .5) if con_manos else 0,
                   "segundos_con_manos": len(con_manos),
                   "pose_fps_p50": fps("pose"),
                   "render_fps_p50": fps("render"), "inference_fps_p50": fps("inference")})
        p95 = f1["latency_ms"]["p95"]
        if (f1["tracking_fps_p50"] < GATES["tracking_fps_min"] or
                f1["render_fps_p50"] < GATES["render_fps_min"] or
                p95 > GATES["latency_p95_provisional_ms"]):
            f1["veredicto"] = "FAIL"
        elif p95 >= GATES["latency_p95_ms"]:
            f1["veredicto"] = "PROVISIONAL"
        else:
            f1["veredicto"] = "PASS"
    out["fase_1_rendimiento"] = f1

    f2 = {"pasos": [k for k in SIN_GIRO if solo(k)]}
    cambios = conocidos = 0
    for k in SIN_GIRO:
        c, n = _inversiones(solo(k))
        cambios, conocidos = cambios + c, conocidos + n
    giro = _inversiones(solo("giro") + solo("pronacion"))
    f2["cambios_en_giro"] = giro[0]
    if not conocidos:
        f2["veredicto"] = "SIN_DATOS"
    else:
        f2["inversion_pct"] = round(100.0 * cambios / conocidos, 2)
        f2["veredicto"] = ("PASS" if f2["inversion_pct"] < GATES["inversion_pct_max"]
                           else "FAIL")
    out["fase_2_orientacion"] = f2

    # La compuerta congela la articulacion: un rechazo nunca se aplica al
    # avatar (transform invalido aplicado = 0 por diseno). Se reporta la
    # tasa y los codigos para saber cuanto se congela el avatar.
    rechazos = (_deltas(perfs, "safety_rejections") or
                _deltas(perfs, "invalid_transforms"))
    codigos_seg = collections.Counter()
    articulaciones = collections.Counter()
    for p in perfs:
        codigos_seg.update(p.get("safety_codes") or {})
        articulaciones.update(p.get("safety_joints") or {})
    f3 = {"rechazos_compuerta": rechazos,
          "rechazos_por_frame": round(rechazos / len(frames), 3) if frames else None,
          "codigos_compuerta": dict(codigos_seg.most_common()),
          "articulaciones_compuerta": dict(articulaciones.most_common(8)),
          "teleports": _deltas(perfs, "teleports")}
    if not any("safety_rejections" in (p.get("counters") or {}) for p in perfs):
        f3["nota"] = ("sesion anterior al 2026-10-04: rechazos contados por "
                      "repintado (inflados)")
    estatica = solo("estatica") or solo("quieto")
    f3["jitter_deg"] = {"left": _jitter_deg(estatica, 2, 4),
                        "right": _jitter_deg(estatica, 3, 5)} if estatica else None
    jit = [v for v in (f3["jitter_deg"] or {}).values() if v is not None]
    if not perfs:
        f3["veredicto"] = "SIN_DATOS"
    elif f3["teleports"] or any(j > GATES["jitter_deg_max"] for j in jit):
        f3["veredicto"] = "FAIL"
    else:
        f3["veredicto"] = "PASS"
    out["fase_3_rig"] = f3

    ident = {k: solo(k) for k in IDENTIDAD if solo(k)}
    codigos = collections.Counter(c for fs in ident.values() for f in fs
                                  for c in f.get("errors", []))
    # Un salto detectado se retiene (hand_position_held) hasta verlo dos
    # veces y luego avanza con paso acotado: solo cuenta como fallo el salto
    # que llego al avatar sin retencion.
    aplicados = sum(1 for fs in ident.values() for f in fs
                    if "hand_position_jump" in f.get("errors", []) and
                    "hand_position_held" not in f.get("errors", []))
    f4 = {"pasos": sorted(ident), "swaps": codigos.get("hand_identity_swap", 0),
          "saltos_retenidos": codigos.get("hand_position_jump", 0) - aplicados,
          "saltos_aplicados": aplicados,
          "recuperaciones": codigos.get("hand_recovered", 0),
          "perdida": {k: _perdida(fs) for k, fs in ident.items()}}
    if not ident:
        f4["veredicto"] = "SIN_DATOS"
    else:
        f4["veredicto"] = ("FAIL" if f4["swaps"] or f4["saltos_aplicados"]
                           else "PASS")
    out["fase_4_identidad"] = f4
    return out


GATES_DIR = os.path.join(HERE, "..", "..", "docs", "evidence", "gates")


def imprimir(res):
    print(json.dumps(res, indent=1, ensure_ascii=False))


BASELINE_DIR = os.path.join(HERE, "..", "..", "docs", "evidence", "baseline")


def _worker(meta):
    """(en worker?, modo). Sesiones viejas: holistic_worker (solo Holistic)."""
    if "capture_worker" in meta:
        return meta["capture_worker"], meta.get("capture_worker_mode")
    viejo = meta.get("holistic_worker")
    return viejo, "holistic" if viejo else None


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
        "capture_worker": _worker(meta)[0],
        "capture_worker_mode": _worker(meta)[1],
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
        "audit": res.get("audit"),
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
    if args[:1] == ["--gates"]:
        ruta = args[1] if len(args) > 1 else _ultima()
        g = gates(leer(ruta))
        os.makedirs(GATES_DIR, exist_ok=True)
        nombre = "%s-%s.json" % (g["session_id"] or "sesion",
                                 g["contexto"]["platform"] or "x")
        destino = os.path.normpath(os.path.join(GATES_DIR, nombre))
        with open(destino, "w", encoding="utf-8") as fh:
            json.dump(g, fh, indent=1, ensure_ascii=False)
        for fase in sorted(k for k in g if k.startswith("fase_")):
            print("%-22s %s" % (fase, g[fase]["veredicto"]))
        print("gates:", destino)
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
