# Auditoría del movimiento del avatar

Herramienta de desarrollo, **no va a la app**. Corre el visor real (`assets/avatar_viewer/index.html`) en un Chromium sin ventana. Le da cada seña por el mismo camino que la app (`reproducirSecuencia` / `reproducirFrase`) con un reloj exacto de 60 Hz, y mide cuadro por cuadro lo que hace el avatar.

El reloj del arnés también maneja `performance.now()`. Las transiciones y el suavizado del visor usan ese reloj, así que sin esto medirían mal.

## Requisitos

- Python 3.10+.
- `pip install playwright numpy`.
- `python -m playwright install chromium` (descarga unos 150 MB).

## Uso

```
cd univoz\herramientas\auditoria_manos
python primeras.py ..\..\assets\plantillas.json primeras.npz
python armar.py                              (crea www\avatar_viewer\auditoria.html)
python corrida.py primeras.npz corrida.npz   (unos 5 minutos para las 541 señas)
python analizar_ajuste.py corrida.npz primeras.npz
python suavidad.py corrida.npz
python frases.py primeras.npz auditoria.html
```

## Qué mide

| Archivo | Qué |
|---|---|
| `analizar_ajuste.py` | Error de la muñeca (cm) y de la palma (grados), y "latigazos" de palma. Antes de medir ajusta escala y traslado por seña, así que no depende de cómo cada visor ubica el espacio. |
| `suavidad.py` | Velocidad y aceleración pico al entrar desde reposo, al terminar y cuando una mano aparece o se va a media seña. |
| `frases.py` | 40 frases al azar: los picos en las uniones. |
| `dedos.py` | Error de flexión por articulación de cada dedo. |
| `datos_malos.py` | Plantillas con problemas de **datos**: palma volteada en un cuadro y ángulos de dedo imposibles. |
| `volteos_referencia.py` | Referencia en Python de `rig_replay.repararVolteosPalma`; la paridad la prueba `rig-tests/rig_volteos.test.mjs`. |
| `analizar.py`, `perfil.py` | Medidas contra el cuadro alimentado. Solo valen en un visor que mapea el espacio como el visor original de 2026-10-20. |

## Resultado (integracion-final, 2026-10-27)

Visor de `integracion-anny` con `MODELO_UNIVOZ_v0`, antes → después, sobre las 541 señas:

| Medida | Antes | Después |
|---|---|---|
| Entrada desde reposo, velocidad pico (p50) | 5.3 m/s | 2.3 m/s |
| Mano que aparece a media seña (p50) | 16.6 m/s | 2.5 m/s |
| Peor error de muñeca por seña (p50 / p99) | 11.6 / 37.9 cm | 2.2 / 10.0 cm |
| Palma, error típico por seña (p99) | 62.9° | 27.6° |
| Latigazos de palma >30° en 1/60 s | 354 | 76 |
| Compuerta congelada | 508 veces | 37 veces |
| Frases, velocidad pico (p90 / máx) | 22.8 / 29.6 m/s | 4.2 / 5.3 m/s |

Detalle en `docs/19-integracion-final.md`.
