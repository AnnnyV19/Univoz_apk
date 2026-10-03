# PROMPT PARA CLAUDE CODE — Sistema Único de Reconocimiento de Movimiento y Señas

## CONTEXTO

Proyecto en `/home/javier-karim/ReconocerUnivoz`. Analicé el chat de investigación
`chat-Mejora Detección Señas VRM.txt` (6 intercambios: filtros/reconstrucción/OneEuro/
MAD/IK/pulgar, filosofía Apple → "kinematic embedding", roadmap 4 fases, informe con
16 fórmulas + inclusión de amputaciones/deformidades + Audit Sentinel (Mahalanobis),
entregable PDF, y rediseño "Anatomically Resilient Perception Engine" con 11 módulos:
Sensor Guardian, Frame Normalizer, Detection Router, Landmark Hospital, Temporal
Association Engine, Anatomical Model Engine, Fast User Capture, Motion Solver,
VRM Retargeting, Semantic Feature Extractor, Audit Sentinel — 6 fases, con Nivel 1:
envolver MediaPipe, NO reescribirlo).

Veredicto de auditoría: el chat y `docs/01-arquitectura-pipeline.md` describen el MISMO
pipeline. El diseño ya está decidido; lo que falta es unificación de árbol + ejecución.

## DECISIONES YA TOMADAS (no preguntar, no cambiar)

1. **Árbol canónico:** TODO el trabajo vive en https://github.com/AnnnyV19/Univoz_apk
   (directorio local: `/home/javier-karim/ReconocerUnivoz/Univoz_apk`, git propio,
   remoto AnnnyV19/Univoz_apk, HEAD `e9604a2`). El repo raíz `Xavier82h8/ReconocerUnivoz`
   queda como HISTÓRICO: no editar, no migrar nada de vuelta, tocarlo solo 1 línea
   opcional en su README señalando el nuevo canónico.
2. **Entregables en docs/ del canónico:** `Univoz_apk/docs/` (no existe todavía; hay que
   migrar ahí el docs/ del raíz primero).
3. **PLAN_HEAD_TRACKING.md:** fase futura documentada; anotar su contradicción interna
   (pide kFrameDim 155 vs contrato 152) y corregirla hacia 152 en la copia migrada.
   El original del raíz queda intacto.

## ESTADO VERIFICADO DEL CÓDIGO (auditoría ya hecha — usarla, no repetir exploración)

### Estructura

- 2 repos git anidados. `senas_core` duplicado: `Univoz_apk/senas_core` ADELANTADO sobre
  el del raíz (avance ECC 16 archivos modificados sin commitear + `?? AUDITORIA_ECC.md`
  y `?? senas_core/test/camera_state_test.dart`). Avance exclusivo del canónico:
  lib `avatar_view*.dart` y `avatar_web_bridge*.dart` (7 archivos), test/
  `avatar_surface_contract_test.dart` y `camera_state_test.dart`, tools/ `configurar_env.py`,
  `ejemplo_segmentos.csv`, `hoja_contactos.py`, `ingest_video_segmentos.py`,
  `probar_conexion.py`, `segmentar_video.py`, `test_manos.py`.
- `Univoz_apk/senas_core` LACKS `senas_core/android/app/src/main/assets/*.task`
  (`hand_landmarker.task`, `pose_landmarker_lite.task`) que sí existen en el raíz y en
  `univoz/android/app/src/main/assets` → migrarlos.
- `_staging_kotlin/` contiene 5 `.kt`; `HandTrackCoordinator.kt` y `LandmarkEngine.kt`
  idénticos a los vivos; `LandmarkPlugin.kt` ≠ copia viva en `univoz/` NI en `senas_core/`
  (ambas están en el commit sin commitear) → resolver cuál gana con `git diff` y unificar.
- 3 `avatar_viewer`: `rig_*.mjs` idénticos; `index.html` en 2 linajes (raíz = imports
  modulares + editor embebido; canónico = inlineados para WebView Android con banner
  offline). El canónico además tiene 2 `index.html` distintos entre
  `senas_core/assets/avatar_viewer` y `univoz/assets/avatar_viewer` → converger en UNO
  (lineal, sirve en WebView `file://`). El editor dev ya existe en `tools/editor_pose.html`.
- `univoz/` depende de `senas_core` vía `path: ../senas_core` en pubspec → 1 lib de
  reconocimiento + 2 shells (`senas_core` lab, `univoz` producto). NO fusionar apps.
- Solo el raíz tiene: `docs/` (00-10, README, evidence, superpowers), `backend/`
  (ai-engine FastAPI 127.0.0.1:8000, `/health` + `/v1/classify`, SVM→kNN→centroide,
  float16 BYTEA), `scripts/univoz.sh`, `PLAN_HEAD_TRACKING.md`, `pose_*.json` 138D + `aut.png`
  (históricos del usuario: NO borrar, NO migrar).
- `plantillas.json` del checkout = 138D stale; 5 `sample_embeddings` HNSW en schema sin usar.

### Huecos (H) — evidencia

- **H1** duplicación 2 repos/2 senas_core/3 avatar_viewer, cambios hechos ×2 divergen.
- **H2** docs/01 dice semántica TRAS suavizado; `index.html:1791` manda RAW a reconocimiento/DTW.
- **H3** PalmFrameV2 duplicado: render usa `marcoMano` propio (`index.html:1010`) en vez de
  importar `palmFrameV2` de `rig_tracking.mjs` (import en `index.html:276-281`).
- **H4** One Euro no aplica a forma de mano 3D (`group==='shape'` crudo) y MAD solo retiene,
  bypassea si "intencional" (`rig_math.mjs:459,453`).
- **H5** Límites articulares solo dedos (±1.6); brazo/torso = ±π (`index.html:455,1658`).
- **H6** Kalman por track pendiente; solo EMA de velocidad (`docs/07` Fase 4).
- **H7** Audit = solo WebView, volátil 45 s, numérico, sin score/Mahalanobis ni
  persistencia; 0 audit en ruta Dart/Python (`rig_diagnostics.mjs` vs chat §10/§18).
- **H8** `HandCapabilityModel` + `CapabilityMask`: 0 código (grep vacío) — chat §8 inclusión.
- **H9** Perfil antropométrico / Fast User Capture: solo `RigCalibration` de rig (`docs/07` F5).
- **H10** Evidencia física: 0 baselines; 1 sesión web parcial (`docs/evidence/`).
- **H11** Sin métricas de clasificador (F1/matriz), dataset pendiente; iOS sin cámara y sin
  `NSCameraUsageDescription`.
- **H12** `PLAN_HEAD_TRACKING` abandonado, contradicción 155 dims.

### Mapa chat→repo (módulos ya existentes bajo otros nombres)

- Temporal Association Engine = FSM + cadena brazo (hecho, `rig_tracking.mjs:246,310,330,580`)
- Motion Solver = IK 2-huesos + Safety Gate (hecho, `index.html:1328`, `rig_safety.mjs:73`)
- Semantic Feature Extractor = `sign_norm` 2.0.0 (hecho, ver H2)
- Landmark Hospital = validación + MAD + gates (parcial, render-only: `rig_math.mjs:295`)
- Anatomical Model Engine = `RigCalibration` (parcial, sin capacidad)
- Sensor Guardian/Detection Router = backpressure Kotlin + pose scheduler (parcial, sin luz/exposición)
- Audit Sentinel = `AuditSnapshotV1` (parcial: `rig_diagnostics.mjs:19`)
- Fast User Capture = no existe

## TAREA — ENTREGABLE INMEDIATO

Trabajar SOLO en `/home/javier-karim/ReconocerUnivoz/Univoz_apk` (respetar su git):

1. Migrar: `cp -r ../../docs ./docs` (00–10, README, evidence, superpowers) y copiar
   `../../PLAN_HEAD_TRACKING.md ./docs/`.
2. Migrar `backend/` y `scripts/` del raíz al canónico; ajustar en `scripts/univoz.sh` las
   rutas al nuevo layout (`senas_core/`, `univoz/`, `docs/`, `backend/`).
3. Migrar `*.task` a `senas_core/android/app/src/main/assets/`.
4. Crear `docs/11-auditoria-sistema-unico.md` con: bloques del chat → sistema objetivo
   (tabla 6 bloques + 11 módulos Perception Engine), estado del repo, tabla de huecos
   H1–H12 con evidencia file:line, mapa módulo-chat→componente→estado.
5. Crear `docs/12-plan-sistema-unico.md` con el plan por fases (tabla abajo), reglas
   inamovibles y head tracking como futuro con la nota 155→152.
6. Actualizar `docs/README.md` enlazando 11 y 12. Ejecutar los tests
   (`./scripts/univoz.sh test` o equivalente) antes de commitear.
7. Commit en `Univoz_apk`; NO hacer push sin confirmación explícita del usuario.

## PLAN POR FASES (contenido del doc 12)

- **Fase U — Árbol único:** (a) commit del avance ECC (16 M + 2 ??); (b) migraciones de
  los puntos 2-3; (c) resolver `_staging_kotlin/LandmarkPlugin.kt` con `git diff` y unificar
  (no borrar `_staging_kotlin/` hasta confirmar); (d) converger los `index.html` en uno
  lineal (editor dev = `tools/editor_pose.html`); (e) `univoz.sh` con rutas nuevas;
  (f) raíz = histórico. **Salida:** diff entre copias = 0, tests verdes, 1 solo git limpio.
- **Fase 0 — Baseline físico:** protocolo `docs/09` en web + Android, 300 frames/dispositivo,
  JSON numérico (p50/p95/p99, jitter, drops, skew, swaps) sin filtro.
- **Fase 1 — Validación/filtrado:** resolver H2 (documentar decisión: capa semántica con
  ángulos filtrados, raw intacto para evidencia); medir One Euro/MAD sobre shape (H4).
- **Fase 2 — Palma/pulgar:** H3, un solo `palmFrameV2`, eliminar `marcoMano`; 7 maniobras/lado.
- **Fase 3 — Rig:** H5, `jointLimits` reales hombro/codo/torso; 0 transforms inválidos.
- **Fase 4 — Oclusión:** H6, Kalman por track; 0 swaps en fixture.
- **Fase 5 — Perfil/capacidad:** H8+H9, `HandCapabilityModel`, `CapabilityMask` EXTERNO al
  vector, Fast User Capture (3 poses), perfil local versionado y borrable, DTW con
  máscara, tests sintéticos (dedo ausente/amputación/movilidad reducida), usuario→VRM.
- **Fase 6 — IA + Audit Sentinel:** H7 (score de anomalía: longitud ósea, límite, jitter,
  swap, desacople MediaPipe↔VRM, Mahalanobis; severidad; acciones; reporte JSON
  persistente; cobertura Dart); H11 (F1/precisión/recall/matriz vs baseline, activar
  `sample_embeddings`, regenerar `plantillas.json` 152D).
- **Fase 7 — Avanzada:** solo si métrica fallida (Huber/RANSAC, EKF/UKF, TCN/Transformer,
  MANO, profundidad, Nivel 2-3 de MediaPipe, head tracking).

## REGLAS INAMOVIBLES

- MotionFrameV2: numérico, finito, `32×152`, `norm_version 2.0.0`, sin cambio de dimensión.
- MAD solo Validated/Render; raw, grabación e IA intactos.
- Ausencia anatómica = CapabilityMask externo; nunca cero/null semántico dentro de 152D.
- Sin guardar video; perfil biométrico local, borrable, con consentimiento.
- Evidencia sintética NO sustituye física; cada gate reporta dispositivo, resolución,
  luz y tamaño de muestra.
- No avanzar de fase si los gates de `docs/07` fallan. No revertir ni borrar trabajo
  previo del usuario (`pose_*.json`, `aut.png`, `PLAN_HEAD_TRACKING` original) sin pedirlo.
- MediaPipe NO se reescribe (Nivel 1: capa envolvente de validación/anatomía/auditoría).

## FORMATO DE LOS DOCS

Español, markdown, seguir numeración y estilo de los docs 00–10 existentes, referencias
con `file:line` verificadas (no inventar líneas).
