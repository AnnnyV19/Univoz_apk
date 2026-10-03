# Plan — sistema único

## Principio

Un solo árbol, una sola librería de reconocimiento, un solo visor. Cada fase
cierra huecos de [11-auditoria-sistema-unico.md](11-auditoria-sistema-unico.md)
con evidencia medible y respeta los gates de [07-roadmap.md](07-roadmap.md).
La arquitectura de mapeo corporal (cualquier cuerpo → avatar) está en
[13-mapeo-corporal-universal.md](13-mapeo-corporal-universal.md).

Cada fase: rama propia + PR. No avanzar si los gates de la fase anterior fallan.

## Fases

| Fase | Objetivo | Huecos | Salida medible |
|---|---|---|---|
| U | Árbol único | H1, H12, H13 | 1 git limpio, visores idénticos, tests verdes |
| 0 | Baseline físico + cuerpos diversos | H10 | JSON por dispositivo y sujeto en `docs/evidence/baseline/` |
| 1 | MediaPipe envuelto mejor | H2, H4 | manos world landmarks, modo tren superior, sin frames perdidos por encuadre |
| 2 | Fast User Capture + perfil | H8, H9 | `BodyProfileV1` + `CapabilityMask` local, borrable |
| 3 | `SignSpaceFrame` + retargeter | H3, H5 | mano llega a la misma ancla del avatar con esqueleto 0.6×–1.4× |
| 4 | Biblioteca de señas reproducible | — | seña grabada por una persona reproducida en cualquier VRM |
| 5 | Cara y cabeza (`FaceFrameV1`) | H12 | cabeza, cejas, boca del avatar; 152D intacto |
| 6 | Oclusión + IA + Audit Sentinel | H6, H7, H11 | Kalman por track, 0 swaps en fixture, F1/matriz, audit persistente |
| 7 | Avanzada | — | solo si una métrica anterior falla |

### Fase U — Árbol único

- [x] Commit aislado del avance ECC.
- [x] Migrar `docs/`, `backend/`, `scripts/`, `PLAN_HEAD_TRACKING.md` (solo
  archivos versionados; sin `.venv`).
- [x] Modelos `*.task` versionados en `senas_core` (Android y visor).
- [x] Visor único: los dos `index.html` idénticos, modelos junto al visor (H13).
- [x] `univoz.sh test` también corre los tests de `univoz/`.
- [x] `_staging_kotlin/` auditado: obsoleto, ganan copias vivas.
- [x] `_staging_kotlin/` borrado (recuperable desde `863af3b`).
- [x] Nota en el README del repo histórico apuntando al canónico.

Pendiente estructural: `univoz/` podría consumir el visor del paquete
`senas_core` en vez de una copia; hasta entonces, todo cambio del visor se
aplica en ambas copias y se verifica con `diff -r`.

### Fase 0 — Baseline físico

Protocolo [09-pruebas-camara.md](09-pruebas-camara.md) en web y Android, 300
frames por dispositivo, sin filtro. Matriz mínima de sujetos: niño, adulto
alto, adulto bajo, sentado, silla de ruedas, encuadre de medio cuerpo, zurdo.
Fixtures sintéticos: dedo ausente, mano ausente, movilidad reducida.

Métricas: p50/p95/p99 de latencia, jitter, drops, skew pose↔manos, swaps,
error de ubicación mano↔ancla corporal. Cada JSON reporta dispositivo,
resolución, luz y tamaño de muestra.

### Fase 1 — MediaPipe envuelto mejor (Nivel 1)

- Hand world landmarks en Kotlin y web; image landmarks siguen alimentando 152D.
- Flag para `pose_landmarker_full` vs `lite`; medir FPS y precisión por dispositivo.
- Modo tren superior: raíz en el centro de hombros; caderas solo con visibilidad
  suficiente.
- Encuadre parcial: reconstruir hombro o codo ausente con longitudes del perfil
  en lugar de descartar el frame o mandar el brazo a reposo.
- H2: documentar decisión — capa semántica con ángulos filtrados, raw intacto
  para evidencia; cualquier cambio regenera golden (`tools/gen_golden.py`) con
  test de regresión.
- H4: medir One Euro y MAD sobre forma de mano antes de cambiar.
- Mano dominante configurable en vivo (espejo en reconocimiento y avatar).

### Fase 2 — Fast User Capture + perfil

3 poses guiadas (~5 s) reutilizando el flujo de calibración del pulgar.
Produce `BodyProfileV1` (longitudes, anclas, alcance) y `HandCapabilityModel`
+ `CapabilityMask` externo al vector. Perfil local, versionado, borrable y con
consentimiento. Sin video.

### Fase 3 — `SignSpaceFrame` + retargeter

Contrato nuevo versionado en [02](02-contratos-y-datos.md), implementación dual
Dart/Python con golden tests. Retargeter por direcciones de segmento + anclas
corporales + contactos. Un solo `palmFrameV2` (eliminar `marcoMano`, H3).
`jointLimits` anatómicos de hombro, codo, muñeca y torso (H5); 0 transforms
inválidos.

### Fase 4 — Biblioteca de señas

Grabar = secuencia `SignSpaceFrame` (+ `FaceFrameV1`). Reproducir en cualquier
VRM vía retargeter. Puente texto/voz → glosa (`senas_core/tools/glosa.py`) →
secuencia con transiciones.

### Fase 5 — Cara y cabeza

Face landmarker con blendshapes como canal `FaceFrameV1`, separado de 152D.
Absorbe [PLAN_HEAD_TRACKING.md](PLAN_HEAD_TRACKING.md) con la corrección
155 → 152: la cabeza nunca entra en `MotionFrameV2`.

### Fase 6 — Oclusión, IA y Audit Sentinel

- H6: Kalman por track; 0 swaps en fixture.
- H7: score de anomalía (longitud ósea contra el perfil, límite articular,
  jitter, swap, desacople MediaPipe↔VRM, Mahalanobis), severidad, acciones,
  reporte JSON persistente, cobertura Dart.
- H11: F1/precisión/recall/matriz contra baseline; DTW con máscara; activar
  `sample_embeddings`; regenerar `plantillas.json` 152D solo cuando exista
  dataset suficiente (gate explícito).

### Fase 7 — Avanzada

Solo si una métrica falla: Huber/RANSAC, EKF/UKF, TCN/Transformer, ajuste
MANO/SMPL-X, profundidad, Nivel 2–3 de MediaPipe.

## Reglas inamovibles

- `MotionFrameV2`: numérico, finito, `32×152`, `norm_version 2.0.0`, sin cambio
  de dimensión. `SignSpaceFrame` y `FaceFrameV1` son contratos aparte.
- MAD solo Validated/Render; raw, grabación e IA intactos.
- Ausencia anatómica = `CapabilityMask` externo; nunca cero o `null` semántico
  dentro de 152D.
- Sin guardar video; perfil biométrico local, borrable, con consentimiento.
- Evidencia sintética no sustituye física; cada gate reporta dispositivo,
  resolución, luz, sujeto y tamaño de muestra.
- No revertir ni borrar trabajo previo del usuario sin pedirlo.
- MediaPipe no se reescribe: capa envolvente de validación, anatomía y auditoría.
