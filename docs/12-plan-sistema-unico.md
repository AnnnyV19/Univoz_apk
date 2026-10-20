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

### Avance en código (rama `fase-1-mediapipe`)

Hecho con tests automáticos; **sin validar aún en cámara física** (gate de
Fase 0 pendiente):

- [x] `SignSpaceFrame` v1 en Python/Dart/JS con golden compartido, incluido
  modo tren superior (Fase 1 + Fase 3).
- [x] `BodyProfileV1` + capacidad con declaración del usuario (Fase 2).
- [x] Fast User Capture con consentimiento en visor web y clase Dart (Fase 2).
- [x] Retargeter por anclas: contacto mano–boca conservado con brazos cortos,
  largos, niño y sentado (< 5 % del ancho de hombros) (Fase 3).
- [x] Cableado en `resolverBrazo` tras flag (`?retarget=anchors`,
  `window.configurarRetarget`, casilla del panel). Por defecto `legacy`.
- [x] Biblioteca: pista `sign_space` pareada al grabar, reproducir y en
  `AvatarBridge.reproducir` (Fase 4).
- [x] `tools/inline_viewer_modules.py`: los bloques inline del visor se
  generan desde los `.mjs`; `univoz.sh test` falla si derivan.
- [x] Filtro One Euro sobre `SignSpaceFrame` (respeta "Suavizar movimiento").
- [x] Captura única **Holistic** (cuerpo + manos con landmarks métricos +
  cara) en web y Android nativo (`tasks-vision` 1.0.0), modelo empaquetado,
  respaldo automático a Pose + Hand. Sustituye a hand world landmarks y al
  flag `pose_landmarker_full` (Fase 1).
- [x] Corrección `invertZ` (brazos detrás del avatar) y RigCalibration v3.
- [x] Compuerta anti-alucinación de manos (duplicados, lejos del brazo,
  tamaño imposible, confirmación sin ancla) en JS y Kotlin, y costo de lado
  que penaliza muñecas no visibles (Fase 1).
- [x] Codo oculto reconstruido con el perfil corporal (`reconstructed`)
  (Fase 1).
- [x] Mano dominante: cubierta por `espejoAutomatico` del diccionario.
- [x] Cara al avatar: giro de cabeza y expresiones geométricas; Android manda
  17 puntos clave y la proporción real de la imagen (Fase 5).
- [x] Vista espejo solo para uno mismo; traducción en vista interlocutor.
- [x] Sesión automática con consentimiento en todas las pantallas con
  cámara: mide el cuerpo y graba `SessionLogV1` (web: servidor local;
  Android: archivo en el teléfono, compartir/borrar en Ajustes) (Fase 2/0).
- [x] Anclas de cara del retarget desde los huesos de ojos del VRM.
- [x] `tools/analizar_sesion.py` (cobertura, rechazos, errores, tiempos,
  profundidad, `--baseline`, `--comparar`) y Audit Sentinel offline contra el
  perfil (`tools/auditoria.py`) (Fase 0/6).
- [x] `tools/sincronizar_kotlin.py`: copias Kotlin de `univoz` sin deriva.
- [x] Holistic web en Web Worker (`rig_holistic_worker.mjs`, solo GPU; cae
  al hilo principal GPU→CPU si falla; `?worker=0` para comparar). Smoke con
  cámara falsa: render del avatar 37 → 61 FPS, `proc` del hilo principal
  24.5 → 2.1 ms. Falta medirlo con cámara física (Fase 0/1).
- [x] Asignación de lado por cadena de brazo en x/y de imagen (como
  Kotlin): la z de pose (cadera) y la de mano (muñeca) no son comparables;
  en sesiones reales 11–24 % de frames iban al lado de la muñeca más lejana.
- [x] Worker de captura lee la cámara directo (stream) y modo separado
  (Pose + Hand + Face) medido: más lento que Holistic con video real.
- [x] Niveles por dispositivo en Android (`DeviceTier.kt`: resolución,
  modelo, FPS, cara y render según RAM, GPU, inferencia y calor) y evento
  `perf` desde Android (`rig_embedded_perf.mjs` → Dart). Falta validarlo en
  teléfonos de gama baja y media.
- [ ] Baselines físicos reales (requieren sesiones del usuario) (Fase 0).
- [ ] Retarget `anchors` por defecto tras validación visual (Fase 3).
- [ ] Un solo `palmFrameV2` y `jointLimits` anatómicos (Fase 3; requieren
  validación visual).
- [ ] Audit en vivo en el visor, Kalman por track, métricas del clasificador
  (Fase 6).

### Próxima sesión (estado al 2026-10-20, sin commit)

Android ya corre la captura web de manos verificada frame a frame (ver
"Paridad Android (2026-10-20)" en [14](14-auditoria-movimiento.md)):
`CapturaManos.kt` más `HandTrackCoordinator.kt` como espejo de
`rig_tracking.mjs`, y el banco `test/golden/paridad_manos.jsonl.gz`, que leen
JS, Kotlin, Dart y Python. Las validaciones de mano y de pose existen en
todas las plataformas, y Traducir reconoce con pre-roll y con la cola
recortada. `univoz.sh test` incluye Gradle.

Plan ejecutado y su registro (decisiones incluidas):
[2026-10-20-android-paridad.md](superpowers/plans/2026-10-20-android-paridad.md).

Siguiente:

1. Sesión de Traducir en el S22+ (auto y manual, cruce, tapar 200/500 ms,
   palma/dorso, salir y volver, seña muy corta). Instalar con
   `adb install -r`.
2. Pasar esa sesión por `analizar_sesion.py --gates` y por
   `paridad/replay_sesion.mjs`.
3. Afinar `kColaMs`/`kPreRollMs` con los eventos `reconocimiento`.
4. H1 (aspecto) con la distribución de escala de mano del teléfono.

### Próxima sesión anterior (estado al 2026-10-19, sin commit)

Mejoras de movimiento hechas en web/JS: ver "Cambios 2026-10-19" en
[14](14-auditoria-movimiento.md) (H2, H8, H9, H13, H14, estados de avatar,
reposo suave, perfil de tracking). `univoz.sh test` verde. Grafo del pipeline
con graphify (`graphifyy` 0.9.92 en `~/.local/share/graphify-venv`, sin
extras LLM): `graphify update <carpeta>` sobre una copia de los `.mjs`, `.kt`
y el script inline de `index.html`; no se guarda en el repo.

Sesiones del 2026-10-19 (`8ttkmb` sensible, `gq000m` estable) analizadas:
ver "Validación con sesiones web 2026-10-19" en
[14](14-auditoria-movimiento.md). Decidido: `bone_length_drift` se queda en
`audit` (z monocular demasiado ruidoso), default `sensible`, gracia 250 ms
sin cambio. Sin marcas: fases 2 y 4 y jitter siguen sin medir.

1. Fijar la webcam a 30 FPS: instalar `v4l-utils` y quitar la prioridad de
   exposición (`v4l2-ctl -d /dev/video0 --list-ctrls` para ver el nombre:
   `exposure_dynamic_framerate` o `exposure_auto_priority` = 0), o más luz.
2. Sesión web con `&protocolo=manos` y teclas 1–9 **en orden** (2–3 min con
   manos en cuadro) para fases 2, 3 y 4. Deadband 1.5° se decide con el
   jitter del avatar (punto 3), no con el de entrada.
3. ~~Registrar la pose aplicada al avatar y medir jitter sobre ella.~~ Hecho
   2026-10-19 (`jitter_avatar_deg`, `jitter_auto`): con la sesión del punto 2
   comparar entrada contra avatar para decidir zona muerta y One Euro.
4. Fluidez web resuelta con suavizado de salida (ver 14, "Fluidez"). Probarlo
   en vivo: sensación de retraso en la muñeca (~65 ms añadidos).
5. Android (primera prueba en Galaxy S22+ hecha, ver 14 "Primera prueba en
   teléfono": crash de protobuf, niveles recalibrados, Traducir con el
   visor). Siguiente: probar Traducir y Espejo en el S22+ con el APK nuevo y
   luego en un teléfono de gama baja y uno
   de gama media, correr el protocolo de `docs/09` y
   `analizar_sesion.py --gates`; ajustar umbrales de `DeviceTier.kt` con lo
   medido. El plan de niveles ya está implementado (2026-10-19) con suavizado
   de salida, `render_motion`/`avatar_state` en el `perf` embebido y render en
   reposo a 15 FPS; nivel bajo verificado reproduciendo `dnrzh8` (render 31,
   100 % de renders con movimiento, jitter de mano 1.3–1.7°).
6. Sigue pendiente todo lo de la lista del 2026-10-14 (abajo): sesión
   Android, H1, H3, H4–H7.

### Próxima sesión anterior (estado al 2026-10-14, `51caf00`)

Auditoría de movimiento web ↔ Android hecha: ver
[14-auditoria-movimiento.md](14-auditoria-movimiento.md) (hallazgos H1–H12,
umbrales propuestos PROVISIONALES, backlog Android primero). No se cambió
código. `univoz.sh test` verde; tests Kotlin 20/20.

1. **Mapear el trabajo con graphify** antes de tocar código: grafo del
   pipeline (captura → compuerta → asociación → seguridad → rig) en web y
   Kotlin, para ubicar las piezas duplicadas de H6/H12. No está instalado
   aún: buscar con `npx skills find graphify` / revisar el paquete y
   confirmar con el usuario antes de instalar.
2. Sesión Android real (teléfono USB, `adb` en
   `~/Android/Sdk/platform-tools/adb`): pasos en la sección "Sesión Android"
   de [14](14-auditoria-movimiento.md). Paquete `com.example.univoz`,
   sesiones en `app_flutter/sesiones/`.
3. Tests Kotlin: `./gradlew :app:testDebugUnitTest` verde 20/20 (el
   `testDebugUnitTest` de todos los módulos falla por minSdk de
   `path_provider_android`, ajeno; ver 14).
4. Confirmar o ajustar umbrales de [14](14-auditoria-movimiento.md) con la
   sesión Android + una web con buena luz; luego ejecutar el backlog de 14.
5. Los puntos 2–5 de la lista del 2026-10-04 (abajo) quedan explicados en
   14: `stage_desync` = caché de pose viejo cuando falta pose, contado por articulación (H9); muñecas
   congeladas = volteos palma/dorso (H2); `hand_scale_implausible` = mano
   cerca de cámara + aspecto sin corregir (H1); `perf` Android (H3).

### Próxima sesión anterior (estado al 2026-10-04, `b07188e`)

Gates de la última sesión física (`20261004T093623Z-wddae4`, manos): fases
0, 2, 3 y 4 PASS; fase 1 FAIL **limitada por la cámara** (webcam ACER HD a
15 FPS con 30 pedidos; inferencia 33 ms, latencia p95 44 ms, render 144).

1. Sesión con buena luz de frente (`&protocolo=manos`, teclas 1–9 sin
   saltar 6 y 8, pestaña siempre al frente) → `analizar_sesion.py --gates`.
   Si la cámara sigue en 15 FPS: fijar 30 FPS con `v4l-utils`
   (exposición sin prioridad de cuadro) o probar otra cámara.
2. Investigar `stage_desync` (48 congelamientos en wddae4) en
   `rig_safety.mjs`.
3. Muñecas congeladas por `angular_velocity_exceeded` (`left:hand` 44,
   `right:hand` 33): revisar el límite contra giros reales de seña.
4. Pérdida de mano al tapar 200 ms (37 %): causas `modelo` y `compuerta`
   (`hand_scale_implausible` 83, `hand_duplicate` 78).
5. ~~Android: emitir evento `perf` para que la fase 1 deje de ser SIN_DATOS.~~
   Hecho 2026-10-19 (`rig_embedded_perf.mjs` → Dart).
6. Pendientes de antes: anchors por defecto, `palmFrameV2`/`jointLimits`,
   pasos 5–6 del plan `docs/superpowers/plans/2026-09-14-tracking-fases.md`.

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
