# Baseline de reconocimiento (evaluador offline), 2026-10-29

Herramienta: `senas_core/tools/evaluar_reconocimiento.py`. Leave-one-out sobre
`senas_core/assets/plantillas.json` (1296 plantillas, 541 señas, `forma=iso1`,
`curado=v2`), umbrales 0.50 / 0.32, diccionario con espejos como en la app,
semilla 1. Commit de partida: c84756d.

Consultas: **795** plantillas reales de las señas que tienen al menos otra
grabación distinta. Las 323 señas con una sola plantilla quedan solo como
distractores del diccionario.

## Resultados (sin filtro)

| Ruido simulado | top-1 | top-5 | aceptada correcta | aceptada errónea |
|---|---|---|---|---|
| ninguno | 46.4 % | 59.5 % | 23.8 % | 3.0 % |
| mixto ×1 | 46.2 % | 59.4 % | 22.1 % | 2.1 % |
| mixto ×3 | 44.4 % | 60.0 % | 18.0 % | 1.3 % |
| mixto ×6 | 37.1 % | 55.1 % | 6.8 % | 0.9 % |
| mixto ×10 | 36.4 % | 55.0 % | 2.4 % | 0.4 % |

`mixto ×1` = jitter gaussiano σ 0.02 + 15 % de frames perdidos (relleno con el
anterior, como `fillGaps`) + 6 % de frames con picos ±0.25, sobre las
dimensiones de ubicación y forma de mano.

Para comparar filtros usar **mixto ×6**: es el primer nivel donde el ruido
mueve las métricas. Con ×1 el DTW apenas se inmuta y no discrimina nada.

## Cómo reproducir

```bash
cd senas_core/tools
python3 evaluar_reconocimiento.py --ruido mixto --intensidad 6 --salida a.json
python3 evaluar_reconocimiento.py --ruido mixto --intensidad 6 --filtro <f> --salida b.json
python3 evaluar_reconocimiento.py --comparar a.json b.json
```

Mismo `--semilla`, `--ruido` e `--intensidad` en A y B (la comparación avisa si
difieren). Tarda unos 35 s con 14 procesos.

## Lo que aprendimos al construirlo

1. **Fuga por gemelas espejo.** El diccionario guarda muchas señas como par
   izquierda/derecha y la app suma además el espejo de cada plantilla. Con
   leave-one-out ingenuo el top-1 daba 73.1 % porque el espejo de la gemela
   reconstruía la consulta (d1 = 0 en 443 de 686 aciertos). Se excluye todo el
   grupo de equivalencia de cada consulta (igual o espejo, max |dif| < 0.02). Es
   el 46.4 % de arriba el que vale.
2. **Orden de magnitud acorde con `dtw.dart`** (34 % top-1, 17.4 % aceptada
   correcta, 3.3 % errónea, 620 consultas): no es el mismo conjunto, pero el
   evaluador no está inflado.
3. **Filtro de control `suavizar3`** (media móvil de 3 frames) con ruido ×6:
   top-1 sin cambio (4 ganadas, 4 perdidas), aceptada errónea 7 → 8. Un
   suavizado simple no basta; no es un candidato.

## Fase 2: candidatos de limpieza en espacio 32×152

Prototipos en `senas_core/tools/limpieza_sena.py` (`interp` duplicados→interpolación,
`hampel`, `picos` por frame, `sg5` Savitzky-Golay, `gauss1`, y combinaciones),
795 consultas, semilla 1. Con 795 consultas, 1 consulta = 0.13 puntos: diferencias
menores de ±0.4 son ruido de medición.

| Escenario | sin filtro (top-1 / top-5 / acept.corr / acept.err) | mejor candidato |
|---|---|---|
| sin ruido | 46.4 / 59.5 / 23.8 / 3.0 | ninguno mueve top-1/top-5 más de 0.3 |
| jitter ×6 (σ 0.12) | 45.5 / 60.5 / 15.7 / 1.0 | `gauss1`: 45.8 / 60.6 / **19.4** / 1.4 |
| picos ×5 (30 % de frames) | 46.2 / 60.0 / 19.6 / 1.6 | `hampel`: 46.2 / 59.7 / **21.3** / 1.8 |
| huecos ×2 (30 % perdidos) | 45.9 / 59.9 / 23.3 / 2.4 | `interp`: sin cambio |
| mixto ×6 (90 % perdidos) | 37.1 / 55.1 / 6.8 / 0.9 | ninguno recupera (información destruida) |

Conclusión: en el espacio normalizado **la limpieza no mejora el ranking** (top-1
y top-5 no se mueven con ningún ruido ni filtro). Lo único que cambia es la tasa
de aceptación: suavizar acerca las distancias a las plantillas y más consultas
cruzan el umbral 0.50 (jitter: +3.7 puntos con `gauss1`), a costa de unas
décimas más de aceptadas erróneas (1.0 → 1.4). El DTW con banda 4 y firma por
segmentos ya absorbe este ruido. Esto no descarta limpiar en la etapa cruda
(recorte de cabeza, interpolación real de huecos), que no se puede medir offline.

## Límites

- `plantillas.json` ya está normalizado a 32×152. Este evaluador solo prueba
  filtros sobre ese espacio. Recorte de cabeza y relleno de huecos sobre frames
  crudos no se pueden medir aquí: el repo no tiene landmarks crudos etiquetados
  (las 21 sesiones de `senas_core/sesiones/` no traen la seña esperada).
- El ruido es simulado: una suposición, no una medición de la cámara. Un filtro
  que gane aquí debe confirmarse con sesiones reales del S22+
  (`analizar_sesion.py --gates`, `replay_sesion.mjs`).
- 1 o 2 grabaciones por seña en la mayoría de los casos: juzgar por top-1 y
  top-5, no por tasa de aceptación.
