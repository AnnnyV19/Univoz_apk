# Sesión real S22+ (2026-10-29): detector de captura y manos

Sesión: `20261029T171842Z-wgy2tf.jsonl` (219 s, 1762 frames, 21 reconocimientos de la app).
Herramienta: `senas_core/tools/evaluar_sesion.py` (replay del detector + captura + DTW sobre `vec`).
Sin lista de señas del usuario: no hay top-1/top-5 real; solo estructura y estabilidad.

## Hallazgos
- Cadencia fija ~10 fps (inferencia p50 74 ms). MediaPipe sin mano en 77 % de los frames; solo 7.5 % con candidata sin asignar. Cobertura mano izq 4.8 %, der 10.3 %. Visibilidad de muñecas 0.2–0.7 (brazos fuera de cuadro).
- Códigos de rechazo `hand_position_held` / `hand_position_jump` / `hand_surface_flip`: 13 frames cada uno de 1762. No explican la pérdida de manos. `hand_occluded` 119, `hand_recovered` 48.
- 9 de 22 capturas salían de 1–2 frames de "movimiento" (término de cuerpo + parpadeo de dedos).

## Cambios aplicados (sin commit)
1. `MovimientoTipoVisor(usarCuerpo: false)` en Traducir: el cuerpo ya no cuenta como movimiento.
2. `DetectorAutomatico(msMovimientoParaIniciar: 100)`: movimiento sostenido ~100 ms para abrir captura.
3. `kPreRollMs` 200 → 300: compensa los 100 ms de espera para que la captura conserve el mismo inicio que antes.

## Resultados del replay
| Configuración | Capturas | Con predicción | Falsas de 1–2 frames |
|---|---|---|---|
| App vieja (`--inicio-ms 0 --con-cuerpo`, pre-roll 200) | 26 | 12 | 9 |
| Nueva con pre-roll 200 | 16 | ~11 | 0 (pero pierde inicio: HOLA→U) |
| Nueva con pre-roll 300 | 16 | 11 | 0 (HOLA recuperada) |

Pre-roll ≥ 500 fusiona señas consecutivas y supera `kAnilloMs` (400 ms); la cola (100/300/500) casi no cambia nada.

## Descartado / pendiente
- Limpieza de landmarks (Fase B): offline ningún filtro sobre 32×152 mueve top-1/top-5 (ver baseline). Con la sesión real no hay etiquetas para medirlo; no se escribe código de limpieza sin evidencia.
- Umbrales MediaPipe 0.4→0.3, guía de encuadre y tope de 100 ms (Fase C): solo se pueden juzgar en el teléfono; el cuello de botella es la detección (77 % sin mano), no los rechazos del tracker. Pendiente de prueba con APK.
- Para medir top-1/top-5 reales: lista de señas del experimento en orden → `evaluar_sesion.py --etiquetas`.
