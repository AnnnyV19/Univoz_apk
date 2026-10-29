"""Pruebas de la decisión del recolector nocturno (sin base ni red)."""
from recolector_nocturno import decidir, es_licencia_abierta, titulo_sirve

U = dict(max_distancia=0.5, min_margen=0.32)


def test_aprueba_solo_lo_seguro():
    assert decidir("HOLA", "HOLA", 0.2, 0.6, True, 0.95, hay_aprobadas=True, **U)[0] == "aprobar"


def test_queda_pendiente_si_dice_otra_sena():
    assert decidir("ADIOS", "HOLA", 0.2, 0.6, True, 0.95, hay_aprobadas=True, **U)[0] == "pendiente"


def test_queda_pendiente_sin_aprobadas_de_esa_sena():
    assert decidir("HOLA", "HOLA", 0.1, 0.9, True, 1.0, hay_aprobadas=False, **U)[0] == "pendiente"


def test_queda_pendiente_con_poca_seguridad():
    assert decidir("HOLA", "HOLA", 0.45, 0.6, True, 0.95, hay_aprobadas=True, **U)[0] == "pendiente"
    assert decidir("HOLA", "HOLA", 0.2, 0.4, True, 0.95, hay_aprobadas=True, **U)[0] == "pendiente"
    assert decidir("HOLA", "HOLA", 0.2, 0.6, True, 0.7, hay_aprobadas=True, **U)[0] == "pendiente"
    assert decidir("HOLA", "HOLA", 0.2, 0.6, False, 0.95, hay_aprobadas=True, **U)[0] == "pendiente"


def test_licencia_y_titulo():
    assert es_licencia_abierta("Creative Commons Attribution license (reuse allowed)")
    assert not es_licencia_abierta("")
    assert not es_licencia_abierta("Standard YouTube License")
    assert titulo_sirve("Cómo decir GRACIAS en LSM", "gracias")
    assert titulo_sirve("Lengua de señas: Mañana", "mañana")
    assert not titulo_sirve("Saludos en LSM", "gracias")


# ---------------------------------------------------------------- aprendizaje
import random  # noqa: E402

import aprendizaje_recolector as ar  # noqa: E402


def _ev(i, buena):
    """Un evento con medidas que se parecen a las de una buena o mala."""
    r = random.Random(i)
    return {"sample_id": f"s{i}", "gloss": "CASA",
            "prediccion": "CASA" if buena or r.random() < .4 else "OTRA",
            "distancia": r.uniform(.05, .25) if buena else r.uniform(.3, .6),
            "margen": r.uniform(.4, .9) if buena else r.uniform(.02, .3),
            "aceptada": buena, "calidad": r.uniform(.9, 1) if buena else r.uniform(.7, .95),
            "max_distancia": .55, "min_margen": .12, "fuente": "youtube",
            "canal": "Malo" if not buena and i % 2 else "Bueno",
            "n_frames": 60, "frames_invalidos": 2, "hay_aprobadas": True,
            "decision": "pendiente"}


def _datos(n=40):
    ev, rv = [], []
    for i in range(n):
        buena = i % 3 != 0
        ev.append(_ev(i, buena))
        rv.append({"sample_id": f"s{i}", "decision": "aprobar" if buena else "rechazar",
                   "motivos": [] if buena else (["mano_mal"] if i % 2 == 0 else ["otra_sena"]),
                   "acciones": ["suavizado"] if buena and i % 4 == 1 else []})
    return ev, rv


def test_aprende_umbral_y_canales():
    ev, rv = _datos()
    apr = ar.aprender(ev, rv)
    assert apr["revisadas"] == 40 and apr["modelo"]
    assert "Malo" in apr["canales_bloqueados"] and "Bueno" not in apr["canales_bloqueados"]
    assert apr["umbral"] is not None
    # Lo que aprende se parece a lo que ella decide.
    assert ar.probabilidad_evento(apr, _ev(100, True)) > ar.probabilidad_evento(apr, _ev(99, False))
    assert any("IA" in l for l in apr["lecciones"])


def test_sin_revisiones_usa_reglas_fijas():
    apr = ar.aprender([_ev(1, True)], [])
    assert apr["modelo"] is None
    fija = ("aprobar", "el reconocedor la confirma")
    assert ar.decidir_aprendido(_ev(1, True), apr, fija) == fija


def test_lo_aprendido_nunca_aprueba_otra_sena_ni_sin_aprobadas():
    ev, rv = _datos()
    apr = ar.aprender(ev, rv)
    otra = dict(_ev(5, True), prediccion="OTRA")
    assert ar.decidir_aprendido(otra, apr, ("aprobar", ""))[0] == "pendiente"
    nueva = dict(_ev(5, True), hay_aprobadas=False)
    assert ar.decidir_aprendido(nueva, apr, ("aprobar", ""))[0] == "pendiente"


def test_la_revision_mas_reciente_manda():
    ev = [_ev(1, True)]
    rv = [{"sample_id": "s1", "decision": "rechazar", "motivos": ["temblor"]},
          {"sample_id": "s1", "decision": "aprobar"}]
    apr = ar.aprender(ev, rv)
    assert apr["aprobadas"] == 1 and apr["rechazadas"] == 0


def test_suavizado_quita_brincos_sin_mover_mesetas():
    seq = [[0.0], [0.0], [5.0], [0.0], [1.0], [1.0], [1.0], [2.0]]
    out = ar.suavizar_mediana(seq)
    assert [f[0] for f in out] == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 2.0]
    subida = [[float(i)] for i in range(6)]
    assert ar.suavizar_mediana(subida) == subida   # una subida no se aplana


if __name__ == "__main__":
    # Corre sin pytest:  python tools\test_recolector.py
    for nombre, fn in list(globals().items()):
        if nombre.startswith("test_") and callable(fn):
            fn()
            print(f"  ok    {nombre}")
    print("todo en orden")
