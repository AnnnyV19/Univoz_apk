"""Pruebas de sign_space.py (SignSpaceFrame v1) y body_profile.py.

Correr:  python3 tools/test_sign_space.py   (o pytest)
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import body_profile as bp  # noqa: E402
import sign_space as ss  # noqa: E402
from sintetico_cuerpo import esqueleto  # noqa: E402


def cerca(a, b, tol=1e-6):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


def test_contrato_basico():
    pose, mundo = esqueleto()
    f = ss.sign_space_frame(pose, mundo)
    assert f is not None
    assert f["version"] == ss.SIGN_SPACE_VERSION
    assert len(f["values"]) == ss.SIGN_SPACE_DIM
    assert all(math.isfinite(v) for v in f["values"])
    assert f["mode"] == "full"
    assert f["mask"] == {"armL": True, "armR": True, "handL": True,
                         "handR": True, "face": True}


def test_invariante_a_posicion_giro_y_escala():
    pose, mundo = esqueleto()
    base = ss.sign_space_frame(pose, mundo)["values"]
    for kw in ({"mover": (0.3, -0.2, 1.1)}, {"giro": 0.6},
               {"escala": 1.7}, {"giro": -0.4, "escala": 0.6}):
        pose, mundo = esqueleto(**kw)
        otro = ss.sign_space_frame(pose, mundo)["values"]
        assert cerca(base, otro, 1e-6), kw


def test_direcciones_unitarias_y_brazo_colgando():
    pose, mundo = esqueleto()
    v = ss.sign_space_frame(pose, mundo)["values"]
    for off in (ss.OFF_UPPER_L, ss.OFF_FORE_L, ss.OFF_UPPER_R, ss.OFF_FORE_R,
                ss.OFF_HANDDIR_L, ss.OFF_HANDDIR_R):
        largo = math.sqrt(sum(x * x for x in v[off:off + 3]))
        assert abs(largo - 1.0) < 1e-6
    # brazo izquierdo colgando: apunta hacia abajo (-y en ejes persona)
    assert cerca(v[ss.OFF_UPPER_L:ss.OFF_UPPER_L + 3], [0.0, -1.0, 0.0])


def test_proporciones_no_cambian_direcciones():
    """Mismo gesto, brazos de distinto largo: la palma toca la misma
    boca, las direcciones del antebrazo cambian poco, el contacto se
    conserva. Es la base del retarget a cualquier cuerpo."""
    boca = (0.0, 0.22 - 0.05, 0.10)
    for brazo, antebrazo in ((0.30, 0.26), (0.20, 0.17), (0.40, 0.35)):
        pose, mundo = esqueleto(brazo=brazo, antebrazo=antebrazo, palma=boca)
        f = ss.sign_space_frame(pose, mundo)
        assert f["values"][ss.OFF_CONTACT + ss.C_FACE_R] == 1.0, brazo
        assert f["values"][ss.OFF_CONTACT + ss.C_FACE_L] == 0.0


def test_modo_tren_superior_sin_caderas():
    """Sentado o encuadre de medio cuerpo: caderas no visibles. La base
    usa la vertical de la camara y el resultado coincide con el de pie."""
    pose, mundo = esqueleto()
    de_pie = ss.sign_space_frame(pose, mundo)
    pose, mundo = esqueleto(caderas=False)
    # caderas estimadas mal por MediaPipe: corridas al frente
    for i in (ss.L_HIP, ss.R_HIP):
        mundo[i][2] -= 0.35
    sentado = ss.sign_space_frame(pose, mundo)
    assert sentado["mode"] == "upper"
    assert cerca(de_pie["values"], sentado["values"], 1e-6)


def test_mascara_brazo_oculto_sin_ceros_semanticos():
    pose, mundo = esqueleto()
    pose[ss.L_ELBOW][3] = 0.1
    f = ss.sign_space_frame(pose, mundo)
    assert f["mask"]["armL"] is False
    assert f["mask"]["armR"] is True
    # bloque enmascarado = 0.0; la mascara, no el valor, dice "ausente"
    assert f["values"][ss.OFF_UPPER_L:ss.OFF_FORE_L + 3] == [0.0] * 6


def test_sin_hombros_no_hay_frame():
    pose, mundo = esqueleto()
    pose[ss.L_SHOULDER][3] = 0.2
    assert ss.sign_space_frame(pose, mundo) is None


def _captura(n=30, **kw):
    """n frames con la palma derecha recorriendo un arco."""
    frames = []
    for k in range(n):
        t = k / max(1, n - 1)
        palma = (0.25 - 0.3 * t, -0.25 + 0.4 * t, 0.15 + 0.1 * t)
        frames.append(esqueleto(palma=palma, **kw))
    return frames


def test_perfil_mide_el_cuerpo():
    p = bp.estimate(_captura(brazo=0.31, antebrazo=0.27, ancho=0.38))
    m = p["measures"]
    assert p["samples"] == 30
    assert abs(m["shoulderWidth"] - 0.38) < 1e-9
    assert abs(m["upperL"] - 0.31) < 1e-9
    assert abs(m["foreL"] - 0.27) < 1e-9
    assert abs(m["upperR"] - 0.31) < 1e-6
    assert abs(m["foreR"] - 0.27) < 1e-6
    assert p["capability"] == {"armL": "ok", "armR": "ok", "handL": "ok",
                               "handR": "ok"}
    assert 0.0 < p["rom"]["armR"] <= 1.0


def test_perfil_nino_proporciones_distintas():
    p = bp.estimate(_captura(brazo=0.19, antebrazo=0.16, ancho=0.26,
                             cuello=0.15))
    m = p["measures"]
    assert abs(m["upperL"] / m["shoulderWidth"] - 0.19 / 0.26) < 1e-9


def test_perfil_capacidad_declarada_gana():
    frames = _captura()
    for pose, _ in frames:
        pose[ss.L_ELBOW][3] = 0.05
        pose[ss.L_WRIST][3] = 0.05
    p = bp.estimate(frames)
    assert p["capability"]["armL"] == "not_observed"
    assert p["capability"]["handL"] == "not_observed"
    assert p["measures"]["upperL"] is None
    p = bp.estimate(frames, declared={"handL": "absent"})
    assert p["capability"]["handL"] == "absent"
    assert p["declared"] == {"handL": "absent"}


def test_perfil_pocas_muestras_no_inventa():
    p = bp.estimate(_captura(n=5))
    assert p["measures"]["upperL"] is None
    assert p["capability"]["armL"] == "partial"


def test_perfil_rechaza_declaracion_invalida():
    try:
        bp.estimate(_captura(n=3), declared={"cola": "absent"})
    except ValueError:
        return
    raise AssertionError("debia rechazar")


def test_golden():
    import json
    ruta = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                        "test", "golden", "sign_space_cases.json")
    with open(ruta) as fh:
        data = json.load(fh)
    assert data["version"] == ss.SIGN_SPACE_VERSION
    assert data["profile_version"] == bp.BODY_PROFILE_VERSION
    for case in data["profiles"]:
        got = bp.estimate([(f["pose"], f["pose_mundo"]) for f in
                           case["frames"]], declared=case["declared"],
                          min_samples=case["min_samples"])
        assert got["capability"] == case["expected"]["capability"]
        for k, v in case["expected"]["measures"].items():
            if v is None:
                assert got["measures"][k] is None, k
            else:
                assert abs(got["measures"][k] - v) <= data["tolerance"], k
    for case in data["cases"]:
        got = ss.sign_space_frame(case["pose"], case["pose_mundo"],
                                  profile=case.get("profile"))
        exp = case["expected"]
        if exp is None:
            assert got is None, case["name"]
            continue
        assert got["mode"] == exp["mode"], case["name"]
        assert got["mask"] == exp["mask"], case["name"]
        assert got["reconstructed"] == exp["reconstructed"], case["name"]
        assert cerca(got["values"], exp["values"], data["tolerance"]), \
            case["name"]


def _perfil(brazo=0.30, antebrazo=0.26):
    m = {"upperL": brazo, "foreL": antebrazo, "upperR": brazo,
         "foreR": antebrazo}
    return {"version": "1.0.0", "measures": m}


def test_codo_oculto_se_reconstruye_con_el_perfil():
    pose, mundo = esqueleto(palma=(0.10, 0.05, 0.20))
    visto = ss.sign_space_frame(pose, mundo)
    pose[ss.R_ELBOW][3] = 0.1
    sin = ss.sign_space_frame(pose, mundo)
    assert sin["mask"]["armR"] is False
    con = ss.sign_space_frame(pose, mundo, profile=_perfil())
    assert con["mask"]["armR"] is True
    assert con["reconstructed"] == {"armL": False, "armR": True}
    # longitudes reales + plano del codo estimado => misma direccion
    for off in (ss.OFF_UPPER_R, ss.OFF_FORE_R):
        assert cerca(con["values"][off:off + 3], visto["values"][off:off + 3], 1e-6)


def test_sin_muneca_no_se_reconstruye():
    pose, mundo = esqueleto()
    pose[ss.R_ELBOW][3] = 0.1
    pose[ss.R_WRIST][3] = 0.1
    f = ss.sign_space_frame(pose, mundo, profile=_perfil())
    assert f["mask"]["armR"] is False
    assert f["reconstructed"]["armR"] is False


def test_reconstruccion_respeta_largos_del_usuario():
    # perfil con brazos distintos al esqueleto: el codo cae a la distancia
    # del perfil, la direccion cambia pero sigue unitaria y finita
    pose, mundo = esqueleto(palma=(0.10, 0.05, 0.20))
    pose[ss.R_ELBOW][3] = 0.1
    f = ss.sign_space_frame(pose, mundo, profile=_perfil(0.34, 0.30))
    for off in (ss.OFF_UPPER_R, ss.OFF_FORE_R):
        v = f["values"][off:off + 3]
        assert abs(math.sqrt(sum(x * x for x in v)) - 1) < 1e-9


if __name__ == "__main__":
    for nombre, fn in sorted(globals().items()):
        if nombre.startswith("test_"):
            fn()
            print("ok", nombre)
    print("todo en orden")
