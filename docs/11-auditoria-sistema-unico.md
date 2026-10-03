# Auditoría — sistema único de reconocimiento y avatar

## Propósito

Contrastar el chat de investigación `chat-Mejora Detección Señas VRM.txt` con el
código real y dejar una sola fuente de verdad. Veredicto: el chat y
[01-arquitectura-pipeline.md](01-arquitectura-pipeline.md) describen el mismo
pipeline. El diseño está decidido; faltaba unificar el árbol y ejecutar.

Fecha: 2026-10-02. Referencias `archivo:línea` verificadas en este repo
(`Univoz_apk`) tras los commits de unificación. Abreviaturas:

- `H` = `senas_core/assets/avatar_viewer/index.html`
- `M` = `senas_core/assets/avatar_viewer/` (módulos `rig_*.mjs`)
- `K` = `senas_core/android/app/src/main/kotlin/com/univoz/senas/`

## Bloques del chat → sistema objetivo

| # | Bloque del chat | Resultado en el sistema |
|---|---|---|
| 1 | Filtros, reconstrucción, One Euro, MAD, IK, pulgar | Capa Validated/Render ([03](03-estabilizacion-y-pulgar.md), [04](04-rig-ik-y-avatar.md)) |
| 2 | Filosofía Apple → *kinematic embedding* | `MotionFrameV2` 152D + `SignSpaceFrame` futuro ([13](13-mapeo-corporal-universal.md)) |
| 3 | Roadmap 4 fases | Reordenado en fases U–7 ([12](12-plan-sistema-unico.md)) |
| 4 | Informe 16 fórmulas + inclusión + Audit Sentinel | Fases 2, 3 y 6 de [12](12-plan-sistema-unico.md) |
| 5 | Entregable PDF | Sustituido por estos docs versionados |
| 6 | *Anatomically Resilient Perception Engine* (11 módulos, Nivel 1) | Mapa de módulos abajo; MediaPipe envuelto, no reescrito |

## Mapa módulo del chat → componente → estado

| Módulo | Componente en repo | Estado | Evidencia |
|---|---|---|---|
| Sensor Guardian | Backpressure Kotlin + scheduler de pose | parcial (sin luz/exposición) | `H:3911` `createAdaptivePoseScheduler` |
| Frame Normalizer | `sign_norm` 2.0.0 Dart/Python | hecho | `senas_core/lib/sign_norm.dart:166` |
| Detection Router | Scheduler pose/manos | parcial | `H:3911` |
| Landmark Hospital | Validación + MAD + gates (solo render) | parcial | `M/rig_math.mjs:295`, `:450-458` |
| Temporal Association Engine | FSM + cadena de brazo | hecho | `H:1791` `assignHandsByArmChain`, `K/HandTrackCoordinator.kt` |
| Anatomical Model Engine | `RigCalibration` (ajustes de rig, no cuerpo) | parcial, sin capacidad | `senas_core/lib/motion_contract.dart:182` |
| Fast User Capture | — | no existe | solo calibración de pulgar `H:4135` |
| Motion Solver | IK 2 huesos + Safety Gate | hecho | `H:3439` `resolverBrazo`, `M/rig_safety.mjs` |
| VRM Retargeting | `medirRig` + escala por ancho de hombros | parcial | `H:3148`, `H:3439` |
| Semantic Feature Extractor | `sign_norm` 152D | hecho (ver H2) | `senas_core/lib/sign_norm.dart` |
| Audit Sentinel | `AuditSnapshotV1` volátil | parcial | `M/rig_diagnostics.mjs:36`, `:54` |

## Estado del repo

- **Árbol canónico:** `Univoz_apk` (remoto `AnnnyV19/Univoz_apk`). El repo
  `ReconocerUnivoz` queda como histórico; no se migra nada de vuelta.
- **Migrado aquí:** `docs/`, `backend/ai-engine`, `scripts/univoz.sh`,
  `PLAN_HEAD_TRACKING.md` (corregido a 152), modelos `*.task` de `senas_core`
  (ahora versionados, igual que `univoz/`).
- **No migrado a propósito:** `pose_*.json`, `pose_*.png`, `aut.png` del raíz
  (históricos del usuario).
- **Estructura:** 1 librería de reconocimiento (`senas_core`) + 2 shells
  (`senas_core` lab, `univoz` producto vía `path: ../senas_core`). No se fusionan.
- **Visor:** `senas_core/assets/avatar_viewer` y `univoz/assets/avatar_viewer`
  idénticos (`diff -r` vacío). `rig_*.mjs` iguales en las 3 copias. El visor del
  raíz es otro linaje (imports modulares, 3 899 líneas vs 5 800) y no se toca.
- **`_staging_kotlin/`:** snapshot obsoleto. `HandTrackCoordinator.kt` y
  `LandmarkEngine.kt` = vivos; `LandmarkPlugin.kt` = versión exacta previa al
  commit ECC (`e9604a2`); `MainActivity_univoz.kt` = versión sin plugin;
  `MainActivity_senas.kt` = vivo. Ganan las copias vivas. Se conserva hasta que
  el usuario confirme borrarlo. Borrado en Fase U con confirmación.
- **Datos:** `plantillas.json` del checkout es 138D obsoleto; 5
  `sample_embeddings` HNSW en el schema sin usar.

## Huecos

| H | Hueco | Evidencia |
|---|---|---|
| H1 | Duplicación de árbol (2 repos, 2 `senas_core`, 3 visores): cambios ×2 divergían | Resuelto en canónico; ver H13 |
| H2 | Doc 01 describe semántica tras suavizado; el visor manda RAW a reconocimiento/grabación | `H:3902-3903` ("Reconocimiento y grabación usan raw") |
| H3 | `palmFrameV2` existe en `rig_tracking.mjs` pero `H` lo redefine inline y el render usa `marcoMano` propio | `M/rig_tracking.mjs:34`, `H:1579`, `H:3121`, `H:3207`, `H:3837` |
| H4 | One Euro no filtra forma de mano 3D (`shape` pasa crudo); MAD solo retiene y se salta si el movimiento es "intencional" | `M/rig_math.mjs:450-458`, `:462-466` |
| H5 | Límites articulares reales solo en dedos (±1.6); por defecto ±π | `M/rig_safety.mjs:63-64`, `H:3770-3771` |
| H6 | Sin Kalman por track; solo predicción con velocidad | `M/rig_tracking.mjs:339`, `:366-368` |
| H7 | Audit solo en WebView, volátil 45 s, numérico, sin score/Mahalanobis ni persistencia; 0 audit en Dart/Python | `M/rig_diagnostics.mjs:54-55` |
| H8 | `HandCapabilityModel` y `CapabilityMask`: 0 código | `grep` vacío en `senas_core/` y `univoz/` |
| H9 | Sin perfil antropométrico / Fast User Capture; no se mide ningún hueso del usuario | `docs/06-calibracion-privacidad-y-hardware.md:32` |
| H10 | Evidencia física: 0 baselines; 1 sesión web parcial | `docs/evidence/` |
| H11 | Sin métricas de clasificador (F1/matriz); iOS sin `NSCameraUsageDescription` | `univoz/ios/Runner/Info.plist` (ausente) |
| H12 | `PLAN_HEAD_TRACKING` pedía `kFrameDim` 155 contra su propio contrato 152 | Corregido en `docs/PLAN_HEAD_TRACKING.md`; absorbido por Fase 5 |
| H13 | El visor de `senas_core` cargaba modelos web desde `../../android/...`: solo resolvía con el servidor dev y rompía el bundle Flutter web | Corregido: `H:2400` usa ruta junto al visor |

## Huecos del mapeo corporal (detalle en [13](13-mapeo-corporal-universal.md))

- El avatar se mueve con el mismo vector 152D del reconocimiento (`H:5494`);
  el cuerpo llega en "anchos de hombro" y la única adaptación al usuario es una
  regla de tres por ancho de hombros dentro de `resolverBrazo` (`H:3439`).
- Pose usa world landmarks (`K/LandmarkEngine.kt:276`); las manos no.
- Modelo de pose `lite` (`K/LandmarkEngine.kt:143`); sin face landmarker; el
  avatar solo parpadea de forma procedural (`H:3883`).
- Zurdos: `mirrorFrame` (`senas_core/lib/sign_norm.dart:300`) solo se usa como
  aumento de datos.
