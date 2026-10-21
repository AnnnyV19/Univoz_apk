# Univoz — Beta pública Android (v0.9.0-beta)

## Context

c9fda9f portó el sistema de movimiento/reconocimiento web a Android (Kotlin nativo + Dart + visor WebView). Primera prueba en S22+ (captura 2026-10-20) muestra overlay rojo "No se pudo cargar un recurso necesario para el avatar 3D (Script error.)" con el avatar medio renderizado. Objetivo de la sesión: primera beta pública **Android** (iOS fase 2 con xtool, solo preparar), con UI/UX dinámica y pulida, errores manejados, reconocimiento más robusto, llamadas a BD seguras, y comparar nuestro motor de movimiento contra Kalidoface 3D usando REA.

Decisiones del usuario: Android ahora / iOS después con xtool (github.com/xtool-org/xtool); REA sobre Kalidoface 3D web; implementar SOS + TTS + dictado; distribución APK directo ya, dejar listo Play Store (keystore lo crea el usuario). Claude no commitea salvo pedido. Repo canónico `~/Proyectos/ReconocerUnivoz/Univoz_apk` rama KARIM. Regla vigente: cambio de captura = JS primero → regenerar fixture `paridad_manos` → portar a Kotlin.

Ejecución: subagent-driven, ledger en `.superpowers/sdd/beta-publica/progress.md`, un gate por fase (`./scripts/univoz.sh test` verde + verificación de la fase).

---

## Fase 0 — Estudio REA Kalidoface 3D (informe, sin código de producto)

1. Lanzar Brave headless con `--remote-debugging-port=9222 --use-angle=gl-egl` en `https://3d.kalidoface.com` (perfil temporal en scratchpad).
2. REA: `list_browser_targets` → `analyze_web_bundle` (fetch_source_maps on) → `inspect_analysis_view` por módulos → `trace_javascript_semantics`/`trace_application_feature` con seeds: `Kalidokit`, `Pose.solve`, `Hand.solve`, `lerp`, `slerp`, `rigRotation`, `requestAnimationFrame`, `holistic`, `modelComplexity`, `smoothLandmarks`.
3. Contrastar con fuente Kalidokit (MIT, github yeemachine/kalidokit) leída como repo normal.
4. Preguntas del ledger: (a) solver brazos/manos/dedos y clamps; (b) suavizado (factor lerp/dampener, ¿One Euro?); (c) ¿desacopla tracking de render?; (d) config MediaPipe (modelComplexity, smoothLandmarks, resolución) en móvil; (e) degradación en móvil; (f) manejo de mano perdida.
5. Salida: `docs/15-estudio-vtuber-rea.md` con observado / inferido / desconocido + Evidence IDs + lista de mejoras candidatas. Solo se aplican en Fase 2 las que mejoren métricas en replay bench.

## Fase 1 — Avatar confiable (bloqueante de la captura)

Causa probable (estática, confirmar con `adb logcat | grep -i chromium`): Dart llama `configurarVista`/`configurarManos`/`aplicarFrameVivo` antes de `js_listo`; `evaluateJavascript` da error saneado "Script error."; handler global de `index.html:183-188` trata cualquier error como fatal y para siempre.

- `senas_core/lib/avatar_bridge.dart`: guardas `_jsListo` en `configurarManos` (:249), `configurarVista` (:267), `mostrarFrame` (:320) — guardar último valor y reaplicar en `_cargarAvatar()` (como ya hace con `_sesion`/`_movimiento`). Exponer `ValueNotifier<EstadoAvatar> estado` (cargando/listo/error). Llamadas JS defensivas `window.f && window.f(...)`.
- `NavigationDelegate(onWebResourceError)` + mensaje `js_error:` → evento de sesión, no overlay.
- `index.html` (fuente `senas_core/assets/avatar_viewer/`, copia por `tools/inline_viewer_modules.py`): handler de arranque se quita al emitir `js_listo`; ignora `Script error.` sin `filename`; errores posteriores → `SenasChannel.postMessage('js_error:...')`. Emitir `avatar_listo` tras cargar VRM.
- **Offline**: vendorizar three@0.160.0 + GLTFLoader + OrbitControls + @pixiv/three-vrm (versión exacta que resuelve hoy `@2`, fijarla) con esbuild (ya en `~/.npm/_npx`) → `senas_core/assets/avatar_viewer/vendor/univoz_vendor.min.js` (IIFE `window.UnivozVendor`), generado por nuevo `senas_core/tools/build_viewer_vendor.mjs`; `inline_viewer_modules.py` lo inlinea como `<script>` clásico y reemplaza el importmap + imports por desestructuración. Quitar textos "necesita internet". MediaPipe web (solo web standalone) sigue en CDN.
- UI Flutter: placeholder animado (silueta + shimmer) hasta `avatar_listo`, fade-in; error real → tarjeta Flutter con Reintentar (`controller.reload()`), no overlay HTML.
- Aplicar igual en `pantalla_espejo.dart`, `pantalla_avatar.dart`, `comunicarse_screen.dart`.
- Tests: Dart test del bridge (llamadas antes de listo no llegan a JS y se reaplican); smoke Brave headless sin red (`--host-resolver-rules="MAP * ~NOTFOUND"`) → avatar carga.

## Fase 2 — Rendimiento de movimiento (medido)

Línea base primero: replay bench (`replay_sesion.mjs` + Brave GPU) y sesión S22+: FPS render, ms/frame JS, `infer_ms` p95, jitter_avatar_deg.

- Visor: `RigBodyEngine.aplicarFrame` solo cuando llega frame nuevo (frameId); ticks de render solo corren output smoother/transiciones (`index.html:9638`). Corregir `fingerRenderState.samples`/`measureFingerLag` duplicados por tick (`:6811-6817`). Reusar objetos THREE temporales (sin `new` por frame en IK/dedos).
- Dart: `normalize()` una vez por frame (5-6 hoy) — memo por identidad de `LandmarkFrame` compartido por `avatar_vivo.dart`, `controlador_captura.dart`, `skeleton_painter.dart`, sesión.
- Kotlin (`LandmarkEngine.kt`): liberar `holisticEnVuelo` en ruta de error (:136,:184) y flag in-flight antes de null-return en `analizarManos/analizarPose` (:280-300). Rotación vía `ImageProcessingOptions.setRotationDegrees` en vez de `Bitmap.createBitmap` (`LandmarkPlugin.kt:342-353`) **detrás de flag**, validar en teléfono que landmarks coinciden antes de activarlo por defecto.
- Aplicar mejoras de Fase 0 solo si mejoran métricas.
- Gate: replay bench ≥ igual jitter, menos ms/frame; Kotlin + node + Dart parity tests verdes.

## Fase 3 — Reconocimiento robusto + UX del reconocedor

Archivo central `senas_core/lib/skeleton_painter.dart` (`PantallaDeTranslacion`, :273-966) — extraer widgets a `senas_core/lib/reconocer/` (encabezado, guía de encuadre, tarjeta resultado) para bajar tamaño.

- Errores nativos: `onError` en listeners del stream fusionado (`controlador_captura.dart:234`, `skeleton_painter.dart:432`, `pantalla_espejo.dart:162`) → banner amigable + Reintentar + evento de sesión.
- Modo auto: `vacia`/`muy_corta` limpian resultado previo y muestran pista breve ("Seña muy corta, repítela") (:474-489).
- Guía de encuadre en vivo: mapear códigos ya existentes (validaciones hand usable / pose geometry / `calidadFrame`) a pistas ("Aléjate un poco", "No veo tus hombros", "Más luz", "Mano fuera de cuadro") con histéresis 1 s; silueta guía.
- Tarjeta resultado: seña grande + nivel de confianza (Alta/Media/Baja derivado de distancia/margen vs umbrales `dtw.dart:200-205`), alternativas como chips "¿Quisiste decir…?", botón repetir en avatar. Distancias, línea "Backend:" y conteos de plantillas solo en **Modo desarrollador**.
- Encabezado: "44 señas disponibles" (arreglar suma 146+146 espejadas en dev).
- Mensaje sin diccionario sin referencia a `tools/exportar_paquete.py`.
- Medir tiempo DTW en evento `reconocimiento`; mover a `Isolate.run` solo si p95 > 16 ms.
- Coach marks primera vez (3 pasos) persistidos.
- Consentimiento de sesión: recordar "No" (`sesion_automatica.dart:21-76`); `platform` real.

## Fase 4 — Datos / BD / backend

- `senas_core/lib/supabase_api.dart`, `backend_api.dart`: helper `_conTimeout` (10 s, 1 reintento con backoff en GET), mapear `SocketException`/`TimeoutException`/`ClientException` a mensajes humanos; `pantalla_sync.dart:69,115,154,191` sin `'$e'` crudo.
- Sync de plantillas en segundo plano al abrir app si última > 24 h, no bloqueante, fallback al paquete base; nunca deja diccionario vacío (validar antes de reemplazar `plantillas_sync.json`).
- Escrituras atómicas (tmp + rename) en `muestras_locales.dart` y `perfil_guardado.dart`.
- Rotación de sesiones JSONL (máx 50 MB / últimas N).
- `senas_core/sql/003_beta_limites.sql`: checks de tamaño, insert anónimo solo estado pendiente; **el usuario la aplica** en Supabase.
- Backend FastAPI queda opcional, fuera del camino de la beta; `usesCleartextTraffic` solo en debug (`src/debug/AndroidManifest.xml`).
- Log local de errores: `FlutterError.onError` + `PlatformDispatcher.onError` → archivo local + evento de sesión (sin servicio externo).

## Fase 5 — UI/UX unificada

- Tema único `senas_core/lib/tema_univoz.dart` (Material 3, seed `0xFF6C63FF`, superficies `F7F2FA`, texto `1A1A2E`, tipografía escalable) usado por `univoz/lib/main.dart:22` y `senas_core/lib/main.dart:24`; reemplazar colores hardcodeados en pantallas tocadas.
- Español neutro con "tú" en todo `senas_core` (hoy voseo).
- Implementar: "Leer en voz alta" (`flutter_tts`, `comunicarse_screen.dart:770`), "Dictar con voz" (`speech_to_text`, :790, permiso micrófono), **SOS** (`univoz_shared_widgets.dart:263`): pulsación larga → pantalla con mensaje grande para mostrar, llamar/SMS a contacto de emergencia guardado en `PerfilGuardado` (nuevo dep `url_launcher`), config del contacto en perfil.
- Permiso de cámara: un helper `pedirPermisoCamara(context)` (explicación previa + negado permanente → ajustes) reemplaza las 3 copias (`purpose_screen.dart:198`, `comunicarse_screen.dart:333`, `traducir_senas_screen.dart:38`).
- Modo desarrollador (7 toques en versión) oculta Captura/Espejo/diagnóstico/Backend.
- Accesibilidad: `Semantics`/tooltips en botones de ícono, objetivos ≥48 dp, probar con texto 1.3×.
- Microinteracciones: transiciones entre pantallas, estados vacíos/carga con skeletons, feedback háptico al reconocer.
- Borrar código muerto `aprender_screen.dart`, `refinement_screen.dart`.

## Fase 6 — Release Android + preparación iOS

- `applicationId = "com.univoz.app"` (namespace/paquete Kotlin sin cambio), label "Univoz", `version: 0.9.0+9`. Nota: se instala como app nueva (datos de `com.example.univoz` no migran).
- Firma: `key.properties` + `signingConfigs.release`; si falta, build falla con mensaje claro (no firmar release con debug). Doc `docs/RELEASE.md`: comando `keytool`, `flutter build apk --release --split-per-abi`, `flutter build appbundle`, checklist Play (política privacidad, data safety, capturas).
- Tamaño: excluir del bundle Flutter de `univoz` los `.task` y `rig_*.mjs` sueltos (Kotlin usa `android/app/src/main/assets`), y el VRM no usado (verificar `_kRutaAvatar`). R8 + reglas keep MediaPipe/protobuf.
- `uses-feature android.hardware.camera.any required=true` en vez de `camera`.
- Pantalla + `docs/PRIVACIDAD.md` (landmarks, nunca video, borrar datos).
- iOS mínimo: `NSCameraUsageDescription` en Info.plist; `MissingPluginException` → "Reconocimiento disponible pronto en iPhone"; `docs/16-ios-fase2.md` (Swift `HolisticLandmarker` vía MediaPipeTasksVision, xtool, puertos necesarios).

---

## Verificación end-to-end

1. `./scripts/univoz.sh test` (Dart, node, Python, Gradle `:app:testDebugUnitTest`) verde en cada gate; `flutter analyze` sin errores nuevos.
2. Smoke Brave headless: visor sin red carga avatar; frames antes de `js_listo` no muestran overlay.
3. Replay bench antes/después (ms/frame, jitter_avatar_deg, FPS) en `docs/15`.
4. `flutter build apk --release --split-per-abi` (con keystore de prueba local en scratchpad si el usuario aún no tiene); instalar SOLO con `adb -s RFCT60VQ0QZ install -r`.
5. En S22+: abrir Reconocer seña con y sin datos/wifi → sin overlay rojo; `adb logcat | grep -i chromium` sin `Uncaught`; sesión T12 (auto + manual, oclusiones, seña corta) → `analizar_sesion.py --gates` + `paridad/replay_sesion.mjs`.
6. Forzar tier `bajo` para simular gama baja; verificar FPS y fallback CPU.
7. Recorrido manual UX: onboarding, permisos (negar/permanente), SOS, TTS, dictado, sync sin red (mensajes humanos).

---

# Ledger de ejecución (copia de .superpowers/sdd)

# SDD ledger — plan: /home/javier-karim/.claude/plans/en-esta-sesion-nos-sequential-neumann.md

No separate spec; plan + user answers (2026-10-20) are authority. Rulings provisional.
Ruling: no commits; review packages diff git tree snapshots (snap.sh, temp index) — user commits Univoz work per memory — cost if wrong: user must commit in bulk.
Ruling: work in place on branch KARIM, no worktree — matches prior sessions, user file motion_sequence_v2.json untouched — cost if wrong: none (no commits).
Ruling: plan has no Task headings; tasks T0..T10 defined below, briefs written by hand in workspace.
Ruling: phone not connected (adb devices empty) — device steps (logcat confirm, T12 session, install) deferred to user at end — cost: Script-error root cause unconfirmed on device.
Tasks: T0 REA Kalidoface; T1 avatar bridge/error handling/placeholder; T2 vendor offline three; T3 viewer perf; T4 Dart normalize memo + Kotlin in-flight + rotation flag; T5 recognition robustness; T6 recognizer UX; T7 data/BD; T8 theme/tú/permisos/a11y/dead code; T9 SOS+TTS+dictado; T10 release+iOS prep.
Baseline tree: bcd1f0ce1354bf52c9848c7a09f767ac65b3447a

## Preflight scan
| Tasks | Shared surface | Finding |
|---|---|---|
| T1/T2 | index.html, inline_viewer_modules.py | T1 boot handler+avatar_listo; T2 swaps importmap for inlined vendor. Sequential OK. |
| T1/T3 | index.html | different regions (handler vs render loop). OK. |
| T1/T5/T6 | skeleton_painter.dart | T1 placeholder, T5 error/short-sign, T6 extracts widgets. Sequential OK. |
| T4/T5/T6 | avatar_vivo, controlador_captura, skeleton_painter | T4 memo normalize first; later tasks consume memo. OK. |
| T6/T8 | recognizer strings + theme | plan orders T6 before T8 but T6 should use theme + tú. Ruling below. |
| T8/T9 | comunicarse_screen, univoz_shared_widgets | T8 permission helper, T9 SOS/TTS. Sequential OK. |
| T7/T9 | perfil_guardado.dart | T7 atomic write, T9 adds emergency contact. OK in order. |
| T2/T10 | univoz/assets/avatar_viewer bundle | T10 must exclude .task/rig_*.mjs/vendor dir from Flutter bundle while keeping inlined index.html. Carry to T10. |
| T0/all | docs/15 only | no code. |
Per-task self-consistency: OK; T4 rotation flag default OFF (needs device validation).
Ruling: execution order T0(parallel, docs only),T1,T2,T3,T4,T5,T8,T6,T7,T9,T10 — T6 UI must be built on T8 theme and tú voice — cost if wrong: none.
Ruling: T0 runs in parallel with T1 — writes only docs/15 + scratchpad — cost: none.
Task 0: complete (docs/15-estudio-vtuber-rea.md; DONE_WITH_CONCERNS: no FPS numbers for Kalidoface, static+network evidence only)
Ruling: T0 not sent to code reviewer — report-only, no product code — cost: report errors uncaught until user reads docs/15.
Ruling: T0 candidates 1 (allocation-free output smoother, skip bones at rest) + 5 (gate diagnostics out of render hot path) folded into T3; candidates 2 (blink yaw comp), 3 (face every Nth frame separado), 4 (visibility arm signal) deferred as backlog in docs/15 — need sessions/contract change — cost: small perf left on table.
T1 head tree: e3d42b75d23c87d5797f381fefb3632932b3190b
Task 1: review: spec ✅, quality changes requested (1 Important: no load timeout). Fix round 1 dispatched incl. minors 2-4.
Task 1: minor (deferred): onErrorVisor closure duplicated in 2 screens; viewer contract test is string-matching; smoke script only in scratchpad; _recargas guard checked once after rootBundle.load.
Ruling: load timeout 45 s not 25 s — VRM goes as ~20 MB base64 through runJavaScript, slow on low-end — cost: user waits longer on a real hang.
Note for T10: VRM base64 via runJavaScript is a low-end-phone cost; prefer smaller VRM.
T1 fix1 tree: 48ae07413f4070b53725ac83c69fea727ea57f69
Task 1: fix round 1/5 (4 addressed, 0 open)
Task 1: complete (trees bcd1f0c..48ae074, review clean)
Task 1: minor (deferred): late avatar_listo after timeout flips to listo (recovers; acceptable).
T2 tree: 44feb0adcd2ca1518c175de188a585e3e8464c83
Task 2: complete (review clean, 5 minor)
Task 2: minor (deferred->T8): motivoErrorAvatar "Revisa tu conexión a internet" now misleading; cartel shows raw error text in parentheses.
Task 2: minor (deferred): </script escaping untested; offline smoke only in scratchpad; toDataURL privacy check skips vendor block.
T3 tree: 9daebfe3d5ba475b6233e47de9452750e979c9c1
Task 3: implementer DONE: JS/tick 4.69->3.66 ms, idle tick -25%, jitter identical. Remaining biggest cost vrm.update spring bones ~3.3 ms/tick (backlog: spring bones half-rate on tier bajo).
Ruling: start T4 while T3 under review — T4 files (Dart lib, Kotlin) disjoint from T3 (viewer) — cost if wrong: merge conflict in working tree, detectable.
T4 tree: 6e12a98f35cfaf5f3baf78782fa830e3b33ebdc6
Task 4: complete (review clean, 6 minor; ROTACION_MEDIAPIPE=false pending device validation)
Task 4: minor (deferred): Kotlin test name vs engine ordering; detectar catches Exception not Throwable; memo per stream (preview/fused separate); read-only contract by comment; Expando lifetime = ring buffer; import order nit.
Task 3: review spec ✅ quality approved, 6 minor; minor #1 (invalidate solve key on out-of-band bone writes) sent back as fix round 1; other minors in task-3-review.md deferred.
Task 3: fix round 1/5 (1 addressed, 0 open)
Task 3: complete (review clean; JS/tick 4.69->~3.0-3.66 ms; minors in task-3-review.md deferred: mirror view 2e-6 diff unexplained, finger-lag metric semantics changed)
T5 tree: 1b789f8c863767442887cfc5b3eae85c7ee13fa0
Task 5: review spec ✅, 1 Important (all native errors fatal, kills camera on tier_rebind_failed). Fix round 1 dispatched with minors 1-4.
Ruling: transient native errors log-only, escalate to blocking only if no valid frame 3 s — beta must not kill a working camera — cost: real failure surfaces 3 s later.
Task 5: minor (deferred->T8): pantalla_muestras.dart:51,167 mention tools/importar_muestras.py; pantalla_ajustes.dart:323 voseo "Desactivalo".
T5 fix1 tree: 753ffc3605b3527fc1ff3a9a6a5a27b427359117
Task 5: fix round 1/5 (5 addressed, 0 open)
Task 5: complete (review clean)
Task 5: minor (deferred): fusion errors with healthy preview never escalate (log only); backend-clear check is source-string test.
Ruling: mid-stream no-frame watchdog gap folded into T6 — recognizer screen owner — cost: none.
T8 tree: 5b144996780bf190366f5ae2b7cc44ab295048b5
Task 8: review spec ✅, 1 Important (pantalla_sync shows raw exceptions).
Ruling: T8 I1 parked to T7 — T7 brief item 1 already owns pantalla_sync raw '$e' — cost: none if T7 lands.
Ruling: Espejo visible in normal mode, only its diagnostics dev-only — mirror practice is a product feature — cost: none.
Task 8: minor (deferred): UnivozHeader resized app-wide + text scale cap 1.3; kVersionApp duplicates pubspec version (T10 sets 0.9.0+9); dark mode latent mismatches (ThemeMode.light kept).
T8 fix1 tree: 4993c1e1f8f8238535e0a5981102899168c88218
Task 8: fix round 1/5 (2 addressed, 1 new Important-low: senas_core dev app can't enable dev mode)
Ruling: senas_core standalone app activates dev mode at startup — it is a developer tool — cost: none for univoz users.
Task 8: fix round 2/5 (1 addressed, 0 open) — Ruling: 2-file in-memory flag fix verified by controller read instead of a re-review seat — cost: low.
Task 8: complete
Ruling: T7 runs in parallel with T6 — T7 files (supabase_api, backend_api, pantalla_sync, muestras_locales, perfil_guardado, univoz main, session writer) disjoint from T6 (skeleton_painter, reconocer/, controlador_captura) — cost: possible overlap if session writer lives in controlador_captura; agents told to avoid each other's files.
T6 tree: b8f435e0e7b8cb40541ab68d9ed3aaa2f9ef22a4
Task 6: review spec ✅ (portrait camera beside panel, not overlay — justified by WebView-over-Texture contract), 1 Important (small-phone layout). Fix round 1 dispatched with minors (watchdog stop order, rebind reset).
Task 6: minor (deferred): see task-6-review.md (10 minors; 2 taken into fix round).
Resume 2026-10-20 23:00 MST: T6 fix1 (a0262f850f7bf2cb9) + T7 (a7e9666ff0ac7f836) resumed after rate limit, sonnet 5.5 per user.
T7 tree: 90f4f5effc8b7d8f8e1ef058a76f2a500fdf4c8a
Task 7: implementer DONE_WITH_CONCERNS (suite green). Concerns: sign_samples return=representation vs RLS SELECT (unverified), 003 prefix collision, fixed sync cache t_frames/frame_dim bug. Review dispatched (sonnet), package review-t7.diff base T8 fix1 tree.
Task 7: review spec ✅, quality ❌ (1C pre-existing return=representation 42501, 3I tmp race / sync shrink / error flood, 8m). Fix round 1 dispatched to same implementer with C1,I1-I3 + minors (active-file rotation, aGlosa 1–64, toString throw, SQL renumber).
Ruling: fix C1 in T7 though pre-existing — uploads would fail 100% in beta, data layer is T7 scope — cost: none.
Ruling: I2 = shrink guard ≥50% not merge — simpler, cost: legit server shrink needs app update.
T6 fix1 tree: 5a42612531d9ec7509443e4a3e64b2782790111b
Task 6: fix1 re-review APPROVED (3/3 addressed, no new C/I). Device check: tier swap >4 s w/o error may trip stall watchdog.
Task 6: complete
Ruling: T9 waits for T7 fix round — T9 adds deps (pub get) + touches perfil_guardado while T7 runs suite — cost: some wall-clock.
T7 fix1 tree: a2fb173d8c8da9432d56a572989d3b1dc8c5e422
T9 base tree: a2fb173d8c8da9432d56a572989d3b1dc8c5e422. T9 dispatched (sonnet). T7 fix1 re-review dispatched (sonnet, read-only).
Task 7: fix1 re-review APPROVED conditional on I4 (error log first occurrence held 10 s in memory). Fix round 2 dispatched: write first occurrence immediately + volcar on paused/detached; M4 tmp sweep in AlmacenMuestras (perfil sweep skipped — T9 owns perfil_guardado). User action: anon curl check of sign_samples insert on real Supabase.
T7 fix2 tree: 14088dfc4eede679b518bccd47dd9ef8c949274b
Task 7: fix2 re-review APPROVED (I4, M4 addressed). Parked minor: instalarManejadores no idempotence guard / observer registered before handlers — final review wave.
Task 7: complete
T9 tree: 46e0957d82fb588b8421d1f28142363004865177
Task 9: implementer DONE_WITH_CONCERNS (suite green, 30 new tests). Review dispatched (sonnet). Concern: SOS "Soy una persona sorda" for all profiles — proposed per-profile identity sentence, pending review.
Ruling: T10 dispatched in parallel with T9 review — overlap only Configuración screen; T10 told to edit it last and re-read — cost: possible edit conflict, detectable.
T10 base tree = T9 tree.
Task 9: review spec ❌ narrow (I1 dictation error never shown, I3 SOS hold collapses with disabled animations), quality ❌ 0C/4I/6m. Fix round 1 dispatched: I1-I4 + M1, M2, M6.
Ruling: SOS identity sentence per profile (ConversationProfile.mine ?? PerfilGuardado.tipo), omit for oyente/prestar/null, no owner name for borrower — brief text wrong for non-deaf users — cost: copy tweak.
T9 fix1 tree: 0b61332806f063aa4c5052e76ebc5245c00c5996
User 2026-10-21: SOS message must be adaptive and respectful (no insult/belittling). Ruling: rewrite as helper-oriented guidance (say HOW to communicate, not a deficit), drop "No puedo hablar"/"mudo" deficit framing, LSM mention when user knows LSM, ciego asks helper to identify + ask before touching; SMS to contact uses a different short text (contact knows the user); user can edit message + toggle "mencionar mi condición" + restore suggested. Queued as T9 fix round 2 after re-review.
Task 9: fix1 re-review APPROVED (I1-I4, M1, M2, M6a fixed; new minors R1-R5). Fix round 2 dispatched = user SOS respectful/adaptive texts + switch + custom message + SMS text + R1. Parked: R2-R5, M3-M5, M6b/c for final review.
T10 tree: 3121052f698afada67f798f09927ef0d1987f6d3
Task 10: implementer DONE (suite green, release split arm64 149.2→74.6 MB, throwaway key deleted). Extra: excluded packages/senas_core/assets via copyFlutterAssets. Concerns: contact email/privacy URL needed, R8 APK untested on phone, Borrar mis datos partial. Review dispatched (sonnet).
T9 fix2 tree: 6932848964ca933841fbdd7bf0c7b5e9c12f37af
Ruling: borrower ignores owner's custom SOS message/switch — owner's text describes the owner, not the borrower — cost: borrower can't reuse it.
Task 10: review spec ✅, quality approved (0C/0I/9m). Minors parked for final wave: asset-exclusion no-op alarm, key.properties field validation, release-over-debug signature note, version +9 test, docs run-as package, INTERNET comment, UNIVOZ_BACKEND_URL note, mapping.txt + smoke in RELEASE.md.
Task 10: complete
Task 9: fix2 re-review APPROVED (0C/0I). New minors M7-M12 parked for final wave; Ruling M12: borrower SMS must say it's sent from <owner>'s phone by someone else needing help — contact would otherwise assume the owner — cost: copy tweak.
Task 9: complete
Final tree: 6932848964ca933841fbdd7bf0c7b5e9c12f37af
Final review dispatched (opus) on review-final.diff, baseline bcd1f0c.
User 2026-10-21 post-plan steps (after final review + fix wave): 1) commit all work on KARIM (user asked "guardar todo"; push NOT asked), 2) build + install new APK on S22+ (adb -s RFCT60VQ0QZ install -r; applicationId now com.univoz.app → installs alongside old), 3) graphify graph (scratchpad copy only), 4) analyze owner's new orphan branch origin/app-limpia (fd43dc5) vs ours, merge into KARIM, plan convergence. Analysis agent dispatched (sonnet, read-only). Phone connected (adb devices: RFCT60VQ0QZ).
Final review: 0C/6I/11m (I1 camera flip dead subs, I2 auto needs avatar, I3 TTS handler steal, I4 TTS_SERVICE query, I5 session growth, I6 borrower SMS). ONE fix wave dispatched (sonnet) incl. parked T9 M7, T7 idempotence, T10 RELEASE notes.
app-limpia analysis done: base 7c774e5 (origin/Lani head). 20 conflicts (9 trivial, 9 manual, 2 design). Strategy: re-parent her tree on 7c774e5 via commit-tree, 3-way merge into branch integracion-anny off committed KARIM. Report: scratchpad/analisis-app-limpia.md
Final fix tree: cf9fb50c55d69d7c7bf323f48b7cf3264a25f0d6
