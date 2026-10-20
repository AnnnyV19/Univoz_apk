# Plan — Llevar a Android el sistema de movimiento y reconocimiento calibrado en web

## Contexto

La app Android (`univoz`, Galaxy S22+ `RFCT60VQ0QZ`) sigue con el sistema viejo de
captura de manos y reconocimiento. Lo de dentro del visor (compuerta, suavizado,
transiciones, estados) ya corre igual en el WebView. Lo que **no** llegó es la
captura web (manos/seguimiento/validaciones):

- `HandTrackCoordinator.kt` es un port parcial de `rig_tracking.mjs`: faltan
  palma/dorso + `hand_surface_ambiguous`, `gateAssignmentMode` (3 frames, .15),
  retención de saltos, recuperación de 3 frames, render acotado,
  `track_ambiguous`; más H4 (exige 6 puntos de brazo), H5 (sw fijo .4), N5
  (`renderAt` marca OCCLUDED falsos), N6, N7, N9, N10, N12, H7.
- **N1 (grave):** el vector 152D de reconocimiento pierde la mano cuando el
  seguimiento la retiene (Kotlin usa `detected`; web usa `track.raw`).
- `webManoUtilizable` y `webPoseGeometriaValida` (index.html:7348-7446) no existen
  en Dart, Kotlin ni Python. Render sin `renderWrists`; calidad distinta.
- Reconocimiento: el DTW de la app es lo mejor disponible (backend más débil). Se
  mejora con datos iguales a la web y mejor corte de seña: sin pre-roll, cola quieta
  incluida, manual sin mínimo, DTW 2 veces, plantillas del paquete sin espejo.

Decisiones del usuario: portar a Kotlin con **banco de paridad** (JS genera la
salida esperada frame a frame; Kotlin la reproduce en JUnit); reconocimiento =
paridad de vector/validaciones (también Python) + corte de seña; **corregir H10
en la web**; sin marcas de protocolo en Android; Gradle dentro de
`univoz.sh test` si hay SDK. Claude no commitea.

## Decisiones técnicas

1. Sacar la lógica inline de index.html (7348-7990) a módulos nuevos para que la
   página, node y el port compartan contrato:
   - `rig_motion_frame.mjs`: `handUsable`, `poseGeometry`, `normalizeMotionFrame`
     (con `renderWrists`), `frameQuality`.
   - `rig_hand_capture.mjs`: `createHandCapture()` → gate → birth gate → cadena de
     brazo → usable → hint solo en `pose_arm_chain` → tracker → wrist disagreement
     (3 frames); `countHandEvents()`.
   index.html queda con wrappers de mismo nombre; registrar en
   `inline_viewer_modules.py`.
2. Fixture único `senas_core/test/golden/paridad_manos.jsonl.gz` leído por node,
   Kotlin (GZIP + Gson `testImplementation 'com.google.code.gson:gson:2.10.1'`, ya
   en caché; org.json en JVM es stub), Dart y Python. Segmentos de sesiones web
   reales (dnrzh8 pasos 1–9, wddae4 3/5/7, 9qwtjc histéresis/track_ambiguous) +
   escenarios sintéticos (cruce, swap, 3 candidatas, salto, volteo, oclusión
   200/300/500 ms, sin anclar, duplicados separado). La salida esperada se
   **regenera** reproduciendo con el JS actual (los logs son de JS viejo).
   Comparación: discretos exactos; render/costos/restBlend 1e-9; vec 1e-9.
   Candado: `paridad_manos.test.mjs` (replay == fixture).
3. **Sin subir `norm_version`**: las validaciones solo anulan frames/manos; los
   valores aceptados no cambian (subirla huérfana todas las plantillas). Sí se
   regenera `golden_cases.json` (sus entradas sintéticas fallan las validaciones).
4. Recomendado: el usuario commitea el WIP actual (34 archivos) antes de T1.

## Tareas (TDD: test primero en cada una)

- **T0 Base (S):** suite + Gradle verdes; en `senas_core/android/app/build.gradle`
  `test.resources.srcDirs += '../../test/golden'` y Gson de test.
- **T1 Fixture desde el código web de hoy (M):** `tools/rig-tests/paridad/`
  (`sesion_jsonl.mjs` convierte arrays → `{x,y,z,visibility}` — si no,
  `visibility` cae a 1; `escenarios.mjs`; `replay.mjs`; temporal
  `inline_actual.mjs` vía `vm` como `motion.test.mjs:23-47`) +
  `gen_paridad_manos.mjs` (ventanas por cobertura, falla si un código requerido no
  aparece; ~800 frames) + `paridad_manos.resumen.json` revisable + test candado.
- **T2 Módulos (M-L):** `rig_motion_frame.mjs`, `rig_hand_capture.mjs` + tests
  (mover tests de geometría de `motion.test.mjs`); replay sobre módulos ⇒
  fixture **idéntico byte a byte** a v0; borrar `inline_actual.mjs`.
- **T3 H10 en web (S):** `rig_tracking.mjs:705,708` `contactBefore` →
  `contactBefore.active`; test primero; regenerar fixture e informar cuántos
  frames cambian.
- **T4 Port Kotlin (L, mayor riesgo):** en orden, con tests espejo:
  1. `CapturaManos.kt`: `ManoUtilizable`.
  2. Asignación por cadena de brazo + lado anatómico fuera de `LandmarkEngine`
     (sin el umbral de 6 puntos → H4; nombres de modo web: `fallback`,
     `pose_arm_chain`, `ambiguous`).
  3. Reescribir `HandTrackCoordinator.kt` espejo de `rig_tracking.mjs`
     (superficie, transición con sw real H5, costo 3D N9, contacto objeto, salto,
     recuperación, render acotado, `gateAssignmentMode`, `track_ambiguous`, swap
     por frame N6; borrar `renderAt` N5). Reemplazar los 13 tests viejos por
     espejo de los 29 de `rig_tracking.test.mjs`.
  4. `CapturaManos` completo + `PoseCache(120 ms)`.
  5. `ParidadManosTest.kt` + `FixtureParidad.kt` (primeros 20 desajustes con
     tramo/frame/campo).
- **T5 Integración LandmarkEngine/Plugin (M):** `LandmarkEngine` = adaptador fino;
  mismo caché de pose en ambos modos; t del frame = t de manos; separado emite
  solo con resultados de manos; Holistic conserva etiquetas y manda manos ≠21 a
  la compuerta (N12); `FrameResult.left/right = raw` (N1); quitar
  `wrist_disagreement` por frame (N10); H7 GPU→CPU en separado con `gpuOk`
  honesto; payload nuevo (`hands_in`, `surfaces`, `track`, `pose_ran`);
  `CapturaManos.kt` a `sincronizar_kotlin.py`.
- **T6 Validaciones en Dart y Python + golden (M, en paralelo con T4):**
  `sign_norm.dart`/`sign_norm.py`: `manoUtilizable`, `poseGeometriaValida`,
  chequeo final finito, `munecasRender` (clamp ±.75), `motivos`. `gen_golden.py`
  con anatomía plausible + casos nuevos; regenerar golden; arreglar fixtures
  sintéticos (`landmark_frame_contract_test`, `test_invariancia`); golden JS en
  `rig_motion_frame.test.mjs`; `paridad_manos_test.dart`, `test_paridad_manos.py`.
- **T7 Consumo en Dart (S-M):** `camera_bridge.dart` parsea claves nuevas,
  `calidad` con fórmula web, `normalizeForRender` con muñecas de render;
  `avatar_vivo.dart` usa esa calidad.
- **T8 Sesiones Android analizables (M):** `sesion_captura.dart` escribe esquema
  web (`hands.{candidates,accepted,unanchored,rejected,passed,assignment}`,
  `tracked.*_surface`, `quality`, `pose_ran`, `ms.infer`, `profile`); perf
  embebido cuenta swaps/flips/holds/recuperaciones con `countHandEvents`;
  `analizar_sesion.py` une `fallback`/`pose_pending` y resume `reconocimiento`;
  `replay_sesion.mjs` (paridad sobre sesión del teléfono). Sin marcas.
- **T9 Reconocimiento y corte de seña (M, en paralelo tras T0):**
  `classifyRanking(rank)` y una sola `_reconocer()` en Traducir (DTW una vez);
  `ControladorCaptura({CameraBridge? camara})` + anillo de ~400 ms y
  `empezar({preRollMs})` (Traducir auto usa 200); recorte de cola con
  `DetectorAutomatico.ultimoMovimientoMs` + `terminarCaptura({hastaMs})`
  (`kColaMs` ~66–100, ajustable); mínimo 8 frames válidos también en manual
  ("seña muy corta"); espejo de plantillas del paquete/sincronizadas con
  `armarClasificador()` puro (omite si ya hay espejo); evento de sesión
  `reconocimiento`. Medir leave-one-out del paquete con y sin espejos.
- **T10 Gradle en `univoz.sh test` (S):** `:app:testDebugUnitTest` si hay SDK/JDK;
  si no, aviso.
- **T11 Docs (S):** docs/14 (H3–H7, H10, N1–N12 resueltos, banco de paridad),
  docs/02 (campos de frame/sesión), docs/12; `adb install -r` en vez de
  `flutter install`.

Orden: T0 → T1 → T2 → T3 → T4 → T5 → T7 → T8; T6 tras T2; T9 en paralelo; T12 al
final. ~8–11 jornadas.

## Archivos críticos

- `senas_core/assets/avatar_viewer/rig_tracking.mjs` (fuente de verdad), `index.html`
  (7333-7990 → módulos nuevos), `rig_hand_gate.mjs`
- `senas_core/android/app/src/main/kotlin/com/univoz/senas/HandTrackCoordinator.kt`,
  `LandmarkEngine.kt`, `LandmarkPlugin.kt`, nuevo `CapturaManos.kt`
- `senas_core/lib/sign_norm.dart`, `camera_bridge.dart`, `controlador_captura.dart`,
  `skeleton_painter.dart`, `dtw.dart`, `plantillas.dart`, `sesion_captura.dart`,
  `avatar_vivo.dart`
- `senas_core/tools/sign_norm.py`, `gen_golden.py`, `analizar_sesion.py`,
  `scripts/univoz.sh`

Reusar: `HandCandidateGate.kt`/`BirthGate` (ya iguales), harness `vm` de
`motion.test.mjs`, `sintetico_cuerpo.esqueleto` para golden, `analizar_sesion`
`_maniobras` para cortar sesiones.

## T12 — Verificación de punta a punta

1. `./scripts/univoz.sh test` verde (incluye Gradle, paridad node, golden
   Dart/Python, checks de sincronía).
2. `cd univoz && flutter build apk --debug`;
   `adb -s RFCT60VQ0QZ install -r build/app/outputs/flutter-apk/app-debug.apk`
   (**nunca** `flutter install`: borra los datos). Respaldar antes las sesiones del
   teléfono.
3. En el S22+: Traducir ~5 min (auto y manual, cruce, tapar 200/500 ms, palma/dorso,
   salir y volver, seña muy corta).
4. Bajar la sesión (`adb exec-out run-as com.example.univoz cat
   app_flutter/sesiones/<id>.jsonl`) y correr `analizar_sesion.py` (+ `--gates`,
   `--comparar` contra dnrzh8): menos `pose_pending`/`fallback`; aparecen
   `hand_surface_ambiguous`, `hand_position_held`, `hand_recovered`; contadores
   perf ≠ 0; eventos `reconocimiento`.
5. `node senas_core/tools/rig-tests/paridad/replay_sesion.mjs <sesión>`: 100 %
   exacto en discretos y render ≤ 1e-9 sobre datos reales del teléfono.
6. H1 (aspecto): comparar distribución de escala y tasa de `hand_scale_implausible`
   Android vs web antes de tocar umbrales.

## Estado de ejecución (2026-10-20)

T0–T11 hechos y verificados (`./scripts/univoz.sh test` verde, con Gradle). T12
parcial: APK instalado en el S22+ con `adb install -r`; falta la sesión de
Traducir en el teléfono y su análisis (`analizar_sesion.py --gates` y
`node senas_core/tools/rig-tests/paridad/replay_sesion.mjs <sesión>`).
Resumen técnico en [docs/14](../../14-auditoria-movimiento.md), "Paridad Android
(2026-10-20)"; siguiente sesión en [docs/12](../../12-plan-sistema-unico.md).

Registro de ejecución (ledger), con las decisiones tomadas (`Ruling`):

```text
Setup: Ruling: no se espera al commit del WIP (34 archivos sin commit) — el usuario no respondió y el plan lo marca recomendado — cuesta: diff mezclado con el trabajo del 2026-10-19.
Setup: Ruling: ejecución inline con TDD y ledger manual (el plan no tiene formato de briefs para task-start) — cuesta: nada.
T0: complete — build.gradle: test.resources ../../test/golden + Gson 2.10.1 test; JUnit 40/40.
T1: complete — paridad/{sesion_jsonl,inline_actual,replay,escenarios,captura_actual}.mjs, gen_paridad_manos.mjs, paridad_manos.test.mjs; fixture 1270 frames (dnrzh8 640, wddae4 150, 9qwtjc 155, 13 sinteticos 325), 26 codigos, 1.0 MB; candado 27/27 y detecta un estado alterado.
T1: Ruling: vector guardado en 1 de cada 4 frames + todos los nulos o con errores (sin estado; 540 KB→~150 KB); salidas calculadas a 12 cifras; world sin visibilidad (no se usa) — cuesta: la paridad Dart/Python del vector se mide en ~1/3 de los frames.
T1: nota: algunas ventanas no reproducen su codigo motivo desde estado limpio (p. ej. dnrzh8-895 hand_position_held) pero la cobertura total cumple REQUERIDOS.
T2: complete — rig_motion_frame.mjs (handUsable, poseGeometry, normalizeMotionFrame, frameQuality) y rig_hand_capture.mjs (createHandCapture, countHandEvents) con tests (6 + 5); index.html con envoltorios; fixture regenerado desde modulos IDENTICO byte a byte (md5 7dfa43c6…); inline_actual.mjs borrado; npm 229/229; univoz.sh test verde.
T2: Ruling: el hallazgo "la web nunca reinicia el tracker" era incorrecto (se reinicia al iniciar/detener camara); webHandCapture.reset() reinicia ademas la compuerta de nacimiento, que antes no — cuesta: tras reencender camara las manos necesitan 3 frames para nacer (antes podian heredar la racha).
T2: Ruling: contratos Dart que buscaban nombres inline (candidatosPuerta, hombroI, centroHombros, wristDisagreementState) apuntan a los equivalentes del modulo inlineado — misma intencion.
T3: complete — rig_tracking.mjs costos neutrales usan contactBefore.active (2 llamadas); test nuevo en rig_tracking.test.mjs; fixture regenerado: 34/1270 frames cambian, solo left/right.cost (9qwtjc-2239, sint-cruce); asignaciones, estados y errores iguales.
T4: complete — HandTrackCoordinator.kt reescrito espejo de rig_tracking.mjs; CapturaManos.kt (captura + handUsable + cadena de brazo); JsMath.kt (Math.hypot de V8, verificado bit a bit vs node en 9M casos); ParidadManosTest + FixtureParidad: 1270/1270 frames sin desajuste; mutacion H10 en Kotlin => 68 desajustes (34 frames x 2 lados, = T3); HandTrackCoordinatorTest 25 (espejo JS + tsv), CapturaManosTest 11; gradle 64/64.
T4: Ruling: HandCandidateGate.kt valida solo x/y finitos (como el JS) y la z la rechaza handUsable; antes Kotlin rechazaba z NaN en la compuerta — paridad — costo: ninguno (z NaN no llega de MediaPipe).
T4: Ruling: hypot de V8 en vez de java.lang.Math.hypot — con Math.hypot el fixture tambien pasa (diferencias de 1 ulp no cruzan umbrales hoy) pero se deja exacto — costo: ~2 asignaciones por llamada.
T5: complete — LandmarkEngine adaptador fino sobre CapturaManos: cache de pose 120 ms en ambos modos, t del frame = t de manos, separado emite solo por resultado de manos (onPose solo cachea; N5), left/right = raw (N1), sin wrist_disagreement por frame (N10), Holistic manda todas las manos a la compuerta con etiqueta Left/Right (N12), sin umbral de 6 puntos (H4), pista solo en pose_arm_chain (N7), separado GPU->CPU con gpuOk honesto (H7); payload hands_in/track/pose_ran; CapturaManos.kt y JsMath.kt en sincronizar_kotlin.py.
T5: Ruling: Holistic no da score por mano => confianza 1.0 (antes igual) — la web usa score ?? .5 — costo: peso .05 en el costo y orden de duplicados.
T5: Ruling: association.hand_assignment_mode mapea fallback -> pose_pending como webCameraState.handAssignmentMode; el modo crudo va en hands_in.assignment.mode — costo: dos nombres para lo mismo (T8 los une en analizar_sesion).
T6: complete — sign_norm.py/.dart: hand_usable/manoUtilizable, pose_geometry/poseGeometriaValida, motivos (codigos web), render_wrists/munecasRender (tope .75), mano != 21 se ignora, chequeo final finito; test_paridad_manos.py y paridad_manos_test.dart sobre el fixture (vec, vec_render, err_vector) verdes; mutaciones Python (tope .05 => 234 desajustes; ignorar validacion => 6) detectadas; golden regenerado con anatomia plausible + bloque `validaciones` (10 casos) verificado por Python, Dart y JS (rig_motion_frame.test.mjs); norm_version sin cambio; univoz.sh test verde.
T6: Ruling: test_dtw.py y landmark_frame_contract_test usaban manos/brazos imposibles (dedos al azar +-.07, codos en el origen) que ahora se descartan — se cambiaron por anatomia plausible (gen_golden.MANO deformada por sena) — costo: los numeros del DTW sintetico cambian (18/18, 5/6, 10/10 siguen).
T7: complete — calidadFrame (sign_norm.dart, formula web) en paridad Dart (quality del fixture); LandmarkFrame: hands_in/track/pose_ran, calidad, normalizeForRender con munecasRender, toJson con quality; AlimentadorAvatar manda la calidad web (antes hombro minimo); univoz.sh test verde.
T8: complete — frameDeSesion con esquema web (hands.candidates lm 4 cifras/conf 3, accepted/unanchored/rejected{index,code}/passed/assignment/usable; tracked.*_surface/*_state; quality web; pose_ran; ms.infer; tier/thermal); sourceMeta.hand_track + nativeTracking (rig_hand_capture.mjs) alimentan countHandEvents en el visor embebido; analizar_sesion une pose_pending->fallback; paridad/replay_sesion.mjs (compararSesion + CLI) con 2 tests; univoz.sh test verde.
T8: Ruling: la sesion guarda landmarks a 4 cifras como la web; replay_sesion informa coincidencia por campo en vez de exigir 100 % (un valor pegado a un umbral puede decidir distinto) — guardar precision completa triplicaria el tamano — costo: desajustes raros explicables por redondeo.
T8: Ruling: el resumen de eventos `reconocimiento` en analizar_sesion pasa a T9, donde se define el evento — costo: ninguno.
T9: complete — DtwClassifier.classifyRanking (Traducir: un solo rank por intento, _reconocer unico); ControladorCaptura({camara}) con anillo 400 ms, empezar(preRollMs) (auto usa kPreRollMs=200) y terminarCaptura/terminar(hastaMs) (auto recorta en ultimoMovimientoMs + kColaMs=100); DetectorAutomatico.ultimoMovimientoMs; manual exige 8 frames validos ("Seña muy corta"); armarClasificador puro espeja paquete/sincronizadas/locales sin duplicar espejos; evento de sesion `reconocimiento` (modo, frames, motivo, aceptada, gloss, distancia, margen, top) resumido en analizar_sesion; tests nuevos (dtw, detector, plantillas_test, controlador_captura_preroll_test, contrato Traducir, analizador); univoz.sh test verde.
T9: Ruling: espejo del paquete y sincronizadas bajo el mismo ajuste espejoAutomatico (default on) — leave-one-out del paquete (146 plantillas, 44 glosas): diestro 66.4 -> 65.8 % top-1 (precision aceptadas 81.5 -> 79.6), zurdo 11.0 -> 65.8 % — costo: -0.6 pp para la mano habitual.
T9: Ruling: kColaMs=100 y kPreRollMs=200 fijos (constantes en skeleton_painter.dart) — sin datos de telefono para afinar aun — costo: si cortan de mas/de menos se ajustan tras T12.
T10: complete — univoz.sh run_gradle_tests (:app:testDebugUnitTest) dentro de `test` si hay SDK (local.properties sdk.dir / ANDROID_HOME) y JDK; sin ellos [WARN] y sigue (verificado con SENAS_DIR sin SDK); suite completa verde con Gradle.
T11: complete — docs/14 (seccion "Paridad Android (2026-10-20)", backlog 1/4/6/7/8 hechos, adb install -r, tests Kotlin 64), docs/02 (campos LandmarkFrame nuevos, validaciones 8-9 de normalizacion, sesion Android con esquema web, evento reconocimiento, counters nativos), docs/12 (proxima sesion 2026-10-20).
T12: partial — univoz.sh test verde (con Gradle); flutter build apk --debug OK; sesion 92b94s respaldada en senas_core/sesiones/telefono-respaldo-20261020/; adb -s RFCT60VQ0QZ install -r OK (datos intactos); arranque sin crash. Pendiente del usuario: sesion de Traducir en el S22+; luego analizar_sesion --gates + replay_sesion.mjs.
Final review: self-review (sin subagente: el usuario no pidio agentes) — sin hallazgos bloqueantes; verificado reloj comun motion/frames para el recorte de cola, codec del canal (Float64List en hands_in), lock de CapturaManos en LandmarkEngine.
```
