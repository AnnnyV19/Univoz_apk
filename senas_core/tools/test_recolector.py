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


if __name__ == "__main__":
    # Corre sin pytest:  python tools\test_recolector.py
    for nombre, fn in list(globals().items()):
        if nombre.startswith("test_") and callable(fn):
            fn()
            print(f"  ok    {nombre}")
    print("todo en orden")
