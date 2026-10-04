"""Pruebas del resumen de sesiones."""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import analizar_sesion as an  # noqa: E402


def _frame(t, vec=None, rejected=(), left=True, face=None):
    return {"kind": "frame", "t": t, "pose": [[0, 0, 0, 1]],
            "hands": {"rejected": [{"index": 0, "code": c} for c in rejected],
                      "assignment": {"mode": "pose_arm_chain"}},
            "tracked": {"left": left, "right": False},
            "face": face, "vec": vec, "errors": ["x"] if rejected else [],
            "ms": {"pose": 20, "hand": 0, "proc": 25}}


def test_resumen_basico():
    vec = [0.0] * 152
    vec[2 * 3:2 * 3 + 3] = [0, -0.5, 0]  # codo izq
    vec[4 * 3:4 * 3 + 3] = [0, -1.2, 0]  # muneca izq: antebrazo 0.7
    regs = [{"kind": "session_start", "session_id": "s", "meta": {"capture_mode": "holistic"}}]
    regs += [_frame(i * 33, vec, rejected=("hand_duplicate",) if i % 2 else ())
             for i in range(10)]
    regs += [{"kind": "event", "type": "body_profile",
              "profile": {"measures": {"upperL": .3}, "capability": {"armL": "ok"}}},
             {"kind": "session_end", "frames": 10, "dropped": 0}]
    r = an.resumir(regs)
    assert r["frames"] == 10 and r["closed"]
    assert r["coverage_pct"]["left_hand"] == 100.0
    assert r["coverage_pct"]["face"] == 0.0
    assert r["hand_rejects"] == {"hand_duplicate": 5}
    assert r["assignment_modes"] == {"pose_arm_chain": 10}
    assert r["depth"]["left"]["forearm_p50"] == 0.7
    assert r["depth"]["left"]["collapsed_pct"] == 0.0
    assert r["body_profile"]["capability"] == {"armL": "ok"}
    assert r["timing_ms"]["proc"]["p50"] == 25


def test_sesion_vacia_no_rompe():
    r = an.resumir([{"kind": "session_start", "session_id": "v"}])
    assert r["frames"] == 0 and r["closed"] is False


def test_leer_quita_duplicados_por_seq(tmp_path):
    ruta = tmp_path / "s.jsonl"
    ruta.write_text("\n".join([
        '{"seq":0,"kind":"session_start","session_id":"d"}',
        '{"seq":1,"kind":"frame","t":1}',
        '{"seq":2,"kind":"frame","t":2}',
        '{"seq":1,"kind":"frame","t":1}',
        '{"seq":3,"kind":"session_end","frames":2}',
    ]) + "\n")
    regs = an.leer(str(ruta))
    assert [r["seq"] for r in regs] == [0, 1, 2, 3]
    assert an.resumir(regs)["frames"] == 2


def test_sesion_android_lee_asignacion_y_rechazos():
    f = {"kind": "frame", "t": 1, "pose": [[0, 0, 0, 1]],
         "hands": {"association": {"hand_assignment_mode": "pose_arm_chain"}},
         "tracked": {"left": True, "right": True},
         "errors": ["hand_duplicate"], "ms": {}}
    r = an.resumir([{"kind": "session_start", "session_id": "a"}, f, dict(f, t=2)])
    assert r["assignment_modes"] == {"pose_arm_chain": 2}
    assert r["hand_rejects"] == {"hand_duplicate": 2}


def test_baseline_y_comparar():
    vec = [0.0] * 152
    regs = [{"kind": "session_start", "session_id": "b1",
             "meta": {"platform": "web", "video": {"width": 360}}}]
    regs += [_frame(i * 33, vec) for i in range(5)]
    r = an.resumir(regs)
    b = an.baseline(r)
    assert b["schema"] == "BaselineV1"
    assert b["platform"] == "web" and b["frames"] == 5
    assert b["video"] == {"width": 360}
    r2 = dict(r, fps=r["fps"] + 10)
    d = an.comparar(r, r2)
    assert d["fps"]["delta"] == 10
    assert "frames" not in d


def test_resumen_incluye_auditoria_con_perfil():
    from sintetico_cuerpo import esqueleto
    regs = [{"kind": "session_start", "session_id": "au"}]
    for i, brazo in enumerate([0.30, 0.30, 0.42]):
        pose, mundo = esqueleto(brazo=brazo)
        regs.append({"kind": "frame", "t": i * 33, "pose": pose, "world": mundo,
                     "errors": [], "ms": {}})
    regs.append({"kind": "event", "type": "body_profile", "profile": {
        "measures": {"upperL": 0.30, "foreL": 0.26, "upperR": 0.30,
                     "foreR": 0.26, "shoulderWidth": 0.36}}})
    r = an.resumir(regs)
    assert r["audit"]["frames"] == 3
    assert r["audit"]["codes"]["bone_length_upperL"] == 1
    assert 30 < r["audit"]["anomalous_pct"] < 40


def test_frames_agrupados_por_marca_de_protocolo():
    regs = [{"seq": 0, "kind": "session_start", "session_id": "m"},
            {"seq": 1, "kind": "event", "type": "marker", "step": 1},
            dict(_frame(0), seq=2), dict(_frame(33), seq=3),
            {"seq": 4, "kind": "event", "type": "marker", "step": 2},
            dict(_frame(66, rejected=("hand_duplicate",)), seq=5)]
    r = an.resumir(regs)
    assert r["by_step"]["1"]["frames"] == 2
    assert r["by_step"]["2"]["frames"] == 1
    assert r["by_step"]["2"]["top_errors"] == [["x", 1]] or \
        r["by_step"]["2"]["top_errors"] == [("x", 1)]


def test_metricas_por_modo_de_retarget():
    regs = [{"kind": "session_start", "session_id": "r"}]
    regs += [dict(_frame(i * 33), retarget="legacy") for i in range(3)]
    regs += [dict(_frame(100 + i * 33, rejected=("hand_duplicate",)),
                  retarget="anchors") for i in range(2)]
    r = an.resumir(regs)
    assert r["by_retarget"]["legacy"]["frames"] == 3
    assert r["by_retarget"]["anchors"]["hand_rejects"] == {"hand_duplicate": 2}
    solo = an.resumir(regs[:4])
    assert solo["by_retarget"] == {}


def test_tiempos_del_worker_holistic():
    regs = [{"kind": "session_start", "session_id": "w",
             "meta": {"platform": "web", "holistic_worker": True}}]
    for i in range(5):
        f = _frame(i * 40)
        f["ms"]["rt"] = 36 + i
        regs.append(f)
    r = an.resumir(regs)
    assert r["timing_ms"]["rt"]["p50"] == 38
    assert an.baseline(r)["capture_worker"] is True
    assert an.baseline(r)["capture_worker_mode"] == "holistic"
    # Sesiones del hilo principal no traen "rt": no aparece en el resumen.
    sin = an.resumir([regs[0], _frame(0), _frame(40)])
    assert "rt" not in sin["timing_ms"]


def _sesion_gates(protocolo="manos", pasos=(), perf=True, n_por_paso=60,
                  swap_en=None, flip_en=None):
    """Sesion sintetica con marcas: `pasos` = numeros de tecla en orden."""
    vec = [0.0] * 152
    vec[2 * 3:2 * 3 + 3] = [0, -0.5, 0]
    vec[4 * 3:4 * 3 + 3] = [0, -1.2, 0]
    regs = [{"kind": "session_start", "session_id": "g", "seq": 0,
             "meta": {"platform": "web", "protocol": protocolo,
                      "video": {"width": 640, "height": 480},
                      "holistic_worker": True}}]
    seq, t = 1, 0
    contadores = {"swaps": 0, "surface_flips": 0, "invalid_transforms": 0,
                  "teleports": 0}
    for paso in pasos:
        regs.append({"kind": "event", "type": "marker", "step": paso,
                     "protocol": protocolo, "seq": seq})
        seq += 1
        for i in range(n_por_paso):
            f = _frame(t, vec)
            f["seq"] = seq
            superficie = "palm"
            if flip_en == paso and i % 30 == 15:
                superficie = "dorsum"
            f["tracked"]["left_surface"] = superficie
            if swap_en == paso and i == 10:
                f["errors"] = ["hand_identity_swap"]
            regs.append(f)
            seq += 1
            t += 33
            if perf and i % 30 == 29:
                regs.append({"kind": "event", "type": "perf", "seq": seq,
                             "latency_ms": [30.0] * 30,
                             "fps": {"tracking": 31, "render": 60, "pose": 31,
                                     "inference": 31, "input": 30},
                             "counters": dict(contadores)})
                seq += 1
    return regs


def test_gates_sin_marcas_ni_perf_da_sin_datos():
    regs = [{"kind": "session_start", "session_id": "v", "meta": {}}]
    regs += [_frame(i * 33, [0.0] * 152) for i in range(10)]
    g = an.gates(an.leer_registros(regs))
    assert g["fase_1_rendimiento"]["veredicto"] == "SIN_DATOS"
    assert g["fase_2_orientacion"]["veredicto"] == "SIN_DATOS"
    assert g["fase_4_identidad"]["veredicto"] == "SIN_DATOS"
    # 10 frames < 300: baseline falla por muestra, no por contrato.
    assert g["fase_0_baseline"]["veredicto"] == "FAIL"
    assert g["fase_0_baseline"]["vector_152"] is True


def test_gates_sesion_limpia_pasa():
    regs = _sesion_gates(pasos=range(1, 10))
    g = an.gates(an.leer_registros(regs))
    assert g["fase_0_baseline"]["veredicto"] == "PASS"
    r = g["fase_1_rendimiento"]
    assert r["veredicto"] == "PASS", r
    assert r["latency_ms"]["p95"] == 30 and r["render_fps_p50"] == 60
    assert g["fase_2_orientacion"]["veredicto"] == "PASS"
    assert g["fase_2_orientacion"]["inversion_pct"] == 0.0
    assert g["fase_3_rig"]["veredicto"] == "PASS"
    assert g["fase_3_rig"]["jitter_deg"]["left"] < 0.01
    assert g["fase_4_identidad"]["veredicto"] == "PASS"
    assert g["contexto"]["capture_worker"] is True


def test_gates_swap_en_cruce_falla_identidad():
    regs = _sesion_gates(pasos=range(1, 10), swap_en=6)
    g = an.gates(an.leer_registros(regs))
    assert g["fase_4_identidad"]["veredicto"] == "FAIL"
    assert g["fase_4_identidad"]["swaps"] == 1


def test_gates_flip_en_paso_estatico_es_inversion():
    # Paso 1 (estatica) con cambios palma->dorso: inversion; en paso 3
    # (girar palma/dorso) los cambios son esperados y no cuentan.
    malo = an.gates(an.leer_registros(_sesion_gates(pasos=range(1, 10), flip_en=1)))
    assert malo["fase_2_orientacion"]["veredicto"] == "FAIL"
    assert malo["fase_2_orientacion"]["inversion_pct"] > 1
    bueno = an.gates(an.leer_registros(_sesion_gates(pasos=range(1, 10), flip_en=3)))
    assert bueno["fase_2_orientacion"]["veredicto"] == "PASS"


def test_gates_latencia_provisional_entre_50_y_120():
    regs = _sesion_gates(pasos=range(1, 10))
    for r in regs:
        if r.get("type") == "perf":
            r["latency_ms"] = [90.0] * 30
    g = an.gates(an.leer_registros(regs))
    assert g["fase_1_rendimiento"]["veredicto"] == "PROVISIONAL"


def test_gates_protocolo_cuerpo_sin_maniobras_de_mano():
    g = an.gates(an.leer_registros(_sesion_gates(protocolo="cuerpo",
                                                 pasos=range(1, 10))))
    assert g["fase_2_orientacion"]["veredicto"] == "SIN_DATOS"
    # El protocolo corporal si tiene cruce (4) y salir/volver (9).
    assert g["fase_4_identidad"]["veredicto"] == "PASS"


def _frames_brazo(angulos_deg):
    out = []
    for i, a in enumerate(angulos_deg):
        v = [0.0] * 152
        r = math.radians(a)
        v[2 * 3:2 * 3 + 3] = [0, 0, 0]
        v[4 * 3:4 * 3 + 3] = [math.sin(r), -math.cos(r), 0]
        out.append(_frame(i * 33, v))
    return out


def test_jitter_ignora_un_segundo_de_movimiento_real():
    quieto = [0.3 * (-1) ** i for i in range(150)]          # ruido +-0.3 grados
    barrido = [60 * math.sin(i / 3) for i in range(30)]     # 1 s moviendo el brazo
    j = an._jitter_deg(_frames_brazo(quieto + barrido + quieto), 2, 4)
    assert j < 1, j
    ruidoso = [4 * (-1) ** i for i in range(150)]
    assert an._jitter_deg(_frames_brazo(ruidoso), 2, 4) > 2


def test_fps_de_manos_solo_en_segundos_con_manos_y_rechazos_informativos():
    regs = _sesion_gates(pasos=range(1, 10))
    perfs = [r for r in regs if r.get("type") == "perf"]
    for i, p in enumerate(perfs):
        if i % 2:
            p["fps"] = dict(p["fps"], tracking=0)  # brazos abajo
        p["counters"] = {"safety_rejections": i * 5, "teleports": 0}
        p["safety_codes"] = {"joint_limit_violation": 5}
        p["safety_joints"] = {"leftLowerArm": 5}
    g = an.gates(an.leer_registros(regs))
    assert g["fase_1_rendimiento"]["tracking_fps_p50"] == 31
    f3 = g["fase_3_rig"]
    assert f3["rechazos_compuerta"] == 5 * (len(perfs) - 1)
    assert f3["codigos_compuerta"] == {"joint_limit_violation": 5 * len(perfs)}
    assert f3["articulaciones_compuerta"] == {"leftLowerArm": 5 * len(perfs)}
    assert f3["veredicto"] == "PASS" and "nota" not in f3


def test_salto_retenido_no_falla_identidad_y_sin_retener_si():
    regs = _sesion_gates(pasos=range(1, 10))
    cruce = [r for r in regs if r.get("kind") == "frame"][5 * 60 + 10]
    cruce["errors"] = ["hand_position_jump", "hand_position_held"]
    g = an.gates(an.leer_registros(regs))["fase_4_identidad"]
    assert g["veredicto"] == "PASS" and g["saltos_retenidos"] == 1
    cruce["errors"] = ["hand_position_jump"]
    g = an.gates(an.leer_registros(regs))["fase_4_identidad"]
    assert g["veredicto"] == "FAIL" and g["saltos_aplicados"] == 1


def test_rendimiento_limitado_por_la_camara():
    regs = _sesion_gates(pasos=range(1, 10))
    for r in regs:
        if r.get("type") == "perf":
            r["fps"] = dict(r["fps"], input=15, tracking=15, inference=15)
    f1 = an.gates(an.leer_registros(regs))["fase_1_rendimiento"]
    assert f1["veredicto"] == "FAIL"
    assert f1["camara_fps_p50"] == 15 and f1["limitado_por_camara"] is True
    sano = an.gates(an.leer_registros(_sesion_gates(pasos=range(1, 10))))
    assert "limitado_por_camara" not in sano["fase_1_rendimiento"]
