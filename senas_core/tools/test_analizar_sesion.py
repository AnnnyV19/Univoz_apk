"""Pruebas del resumen de sesiones."""

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
