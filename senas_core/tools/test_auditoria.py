"""Pruebas del Audit Sentinel offline."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import auditoria as au  # noqa: E402
from sintetico_cuerpo import esqueleto  # noqa: E402

PERFIL = {"measures": {"shoulderWidth": 0.36, "upperL": 0.30, "foreL": 0.26,
                       "upperR": 0.30, "foreR": 0.26}}


def _frame(t, **kw):
    pose, mundo = esqueleto(**kw)
    return {"t": t, "pose": pose, "world": mundo}


def test_cuerpo_como_el_perfil_no_es_anomalo():
    r = au.auditar([_frame(0), _frame(33)], PERFIL)
    assert all(x["d"] < 0.1 for x in r)
    assert all(not x["codes"] for x in r)


def test_brazo_mas_largo_que_el_perfil_se_marca():
    r = au.auditar([_frame(0, brazo=0.42)], PERFIL)[0]
    assert r["z"]["upperL"] > 3
    assert "bone_length_upperL" in r["codes"]
    assert r["d"] > 1


def test_segmento_no_visible_no_se_mide():
    f = _frame(0, brazo=0.42)
    f["pose"][13][3] = 0.1  # codo izquierdo oculto
    r = au.auditar([f], PERFIL)[0]
    assert "upperL" not in r["z"] and "foreL" not in r["z"]


def test_teletransporte_de_muneca():
    a = _frame(0, palma=(0.10, -0.30, 0.10))
    b = _frame(33, palma=(0.10, 0.20, 0.40))
    r = au.auditar([a, b], PERFIL)
    assert "wrist_teleport_R" in r[1]["codes"]
    assert not r[0]["codes"]


def test_frames_sin_pose_y_sin_perfil():
    assert au.auditar([{"t": 0}], PERFIL) == [None]
    r = au.auditar([_frame(0)], None)[0]
    assert r["d"] == 0.0 and r["z"] == {}
