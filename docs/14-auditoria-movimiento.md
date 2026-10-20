# Auditoría — sistema de movimiento (web ↔ Android)

## Propósito

Auditar las mejoras de movimiento desde 2026-09-01 (Holistic, compuerta de
manos, coordinador de lados, compuerta de seguridad, One Euro, BodyProfile,
SignSpace), revisar coherencia entre web y Android y proponer umbrales de
calibración de "punto medio": que no congelen señas reales ni dejen pasar
artefactos. Prioridad Android. Flujo ECC (`verification-loop`,
`production-audit`, `santa-method` con revisor independiente: H1, H5, H7,
H8 confirmados; H9 y H10 corregidos por el revisor).

Fecha: 2026-10-14, rama `KARIM` en `51caf00`. Abreviaturas:

- `H` = `senas_core/assets/avatar_viewer/index.html`
- `M` = `senas_core/assets/avatar_viewer/` (módulos `rig_*.mjs`)
- `K` = `senas_core/android/app/src/main/kotlin/com/univoz/senas/`

Entrega: informe y umbrales propuestos. **No se cambió código.** Los cambios
van en una fase aparte (backlog al final).

## Evidencia

- `./scripts/univoz.sh test`: verde (164 tests node, flutter, pytest, checks
  de sincronía `sincronizar_kotlin.py --check` e
  `inline_viewer_modules.py --check`).
- Tests Kotlin (`./gradlew :app:testDebugUnitTest` en `senas_core/android`):
  verde 20/20; ver sección "Tests Kotlin".
- Sesiones web analizadas (todas Holistic en worker, 360×270 a 15 FPS de
  cámara): `20261004T093623Z-wddae4` (protocolo manos), `20261004T075412Z-9qwtjc`,
  `20261006T003013Z-wiwucn`.
- **No hay sesiones Android** en el repo: las cifras Android de este
  documento son estáticas (código) hasta correr el paso "Sesión Android".
- Scripts de análisis: fuera del repo (scratchpad de la sesión); la fórmula
  se describe en cada hallazgo para poder reproducirla.

## Sincronía de archivos

Sin deriva de archivos: los 18 `.mjs` de `senas_core` y `univoz` son
idénticos, los bloques inline de `H` coinciden con los módulos y los 4 `.kt`
coinciden con la copia de `univoz/android`. La deriva es **lógica**: web y
Android son dos implementaciones del mismo pipeline.

## Hallazgos

Severidad: **A** = cambia lo que ve el usuario o rompe paridad Android;
**M** = degrada en casos concretos; **B** = cosmético u observabilidad.

| # | Sev | Hallazgo | Evidencia |
|---|---|---|---|
| H1 | **A** | La compuerta de manos mide escala, duplicado y distancia al brazo en coordenadas de imagen normalizadas **sin corregir aspecto**. Web captura 360×270 (4:3 apaisado) y Android 360×480 (3:4 vertical): el mismo cuerpo da un cociente mano/hombros ~1.78× distinto entre plataformas, así que un mismo umbral (`.12`–`.9`) significa cosas distintas: escala Android ≈ .56× web, `min .12` rechaza en Android manos que en web pasan (cociente real < ~.16) y `max .9` es casi inalcanzable en Android. Android rota el bitmap antes de analizar (`K/LandmarkPlugin.kt:216,256`). Exacto solo para segmentos alineados a ejes. | `M/rig_hand_gate.mjs:20,79`, `K/HandCandidateGate.kt:72,82`, `K/LandmarkPlugin.kt:52`. Web: mano aceptada p50 = .47, p99 = .81, máx .899 (pegado al tope) en wddae4. |
| H2 | **A** | Los picos de velocidad angular de muñeca que congelan la mano son, en su mayoría, **volteos palma/dorso de MediaPipe** (140–180° en un frame), no giros reales. El límite en rad/s no los distingue de un giro rápido verdadero. | Velocidad angular del marco de palma (muñeca→MCP medio, MCP meñique→MCP índice): p50 ≈ .6, p95 ≈ 5 rad/s; p99 salta a 22–36 rad/s. De los eventos > 18 rad/s en wddae4, 35 de 62 son ≥ 135° por frame. Congelamientos `angular_velocity_exceeded` en mano: 161 (wddae4), 932 (9qwtjc). |
| H3 | **A** | Android no puede evaluar fases 1–4: no emite `perf`, no escribe `tracked.*_surface`, no hay `marker` en Dart. El esquema de frame también difiere (web: `hands.candidates/passed/assignment`; Android: `hands.left/right/association`, `skew_ms`, `aspect`). | `senas_core/lib/sesion_captura.dart:150-180`; `perf` solo en `H` (`eventoPerfSesion`). |
| H4 | M | Kotlin exige visibilidad ≥ .35 en **los seis** puntos de ambos brazos para usar la asignación por cadena de brazo; si un brazo falla, ambas manos caen a `pose_pending`. Web pondera por brazo (muñeca no vista ×.6). | `K/LandmarkEngine.kt:116,580,658-663`. En sesiones web, 5.5 % (wddae4), 12.3 % (9qwtjc) y 3.4 % (wiwucn) de frames con mano seguida perderían la cadena en Android; casi todo por el brazo derecho. |
| H5 | M | `handSurfaceTransition` recibe ancho de hombros fijo `.4` en Kotlin; web usa el real. Con usuario lejos (sw ≈ .2) Kotlin acepta desplazamientos de muñeca 2× mayores como "giro"; cerca, al revés. | `K/HandTrackCoordinator.kt:262` vs `M/rig_tracking.mjs:479`. |
| H6 | M | Funciones solo web: `gateAssignmentMode` (3 frames, ventaja .15), `classifyHandSurface` + `hand_surface_ambiguous`, salto de posición, recuperación de 3 frames (`hand_recovered`), `track_ambiguous`. Solo Kotlin: ventana de fusión 120 ms, `wrist_disagreement` (.25 sw), timeout 2 s. | `M/rig_tracking.mjs:113-130,317,473-506,518-584,817`; `K/LandmarkEngine.kt:114,136,312`. |
| H7 | M | Modo `separado` en Kotlin crea pose y manos solo con GPU, sin respaldo CPU (Holistic sí prueba GPU→CPU). En teléfonos sin GPU delegate usable, `separado` falla, justo el modo previsto para el nivel `bajo`. | `K/LandmarkEngine.kt:196,212` vs `157`. |
| H8 | M | Compuerta de seguridad: el chequeo de edad nunca dispara en vivo porque `metaRigFrame` pone `nowMs = timestampMs`. La protección real contra frames viejos queda en `kFrameStaleMs = 450`. | `H:5076-5084`, `M/rig_safety.mjs:163`. |
| H9 | M | `stage_desync` en web Holistic viene de `webPoseCache` **viejo**: si un frame llega sin pose, el caché conserva pose y `timestampMs` anteriores sin caducar, el vector se arma con esa pose y el skew crece mientras falte pose; > 120 ms congela todas las articulaciones. En wddae4 fue un solo instante (t ≈ 213 s, sin manos) contado una vez por articulación (~25), de ahí "48". Android Holistic usa un solo timestamp (skew 0). | `H:7146-7158,7210,8412`, `H:3247` (`poseResult` null sin pose); revisor independiente. Web no registra `skew_ms` por frame, Android sí. |
| H10 | M | En la matriz neutral, `handCandidateCost` recibe el objeto `contactBefore` (siempre truthy) en vez de `.active`: peso de lado .02 aunque no haya contacto. Se cancela al comparar normal vs cruzado, **pero no** en `canAssign` (`≤ .65`/`.95`) ni en `assignedCosts` cuando el modo temporal gana al de etiqueta: costes neutrales subestimados .04. | `M/rig_tracking.mjs:705,708,757-760`; copia inline `H:2271-2276`. |
| H11 | B | `./scripts/univoz.sh test` no ejecuta Gradle: los 20 tests Kotlin no corren en la verificación habitual; `LandmarkEngine` no tiene tests. | `scripts/univoz.sh:377-416`. |
| H12 | B | BodyProfile y SignSpace existen en JS, Dart y Python sin script de sincronía; hoy las constantes coinciden. | `M/rig_body_profile.mjs`, `senas_core/lib/body_profile.dart`, `senas_core/tools/body_profile.py`. |

## Paridad de umbrales web ↔ Android

Coinciden: umbrales de MediaPipe (.4/.3), `HandCandidateGate` (MIN_VIS .5,
escala .12–.9, duplicado .2/.5, brazo 1.0, BirthGate 3 frames/.08), pesos
del coste de asignación (.45/.20/.20/.10/.05), `canAssign` .65/.95, margen
`max(.06, sw·.16)`, contacto .22/.25, LOST 500 ms, skew 50/120, constantes
de BodyProfile/SignSpace y calibración de pulgar/rig.

Difieren: ver H1 (aspecto), H4 (visibilidad brazo), H5 (sw fijo), H6
(funciones de un solo lado), H7 (delegate). Compuerta de seguridad,
suavizado y calibradores corren en JS en ambas plataformas (Android vía
WebView), así que sus umbrales son comunes.

## Calibración propuesta ("punto medio")

Regla: el umbral deja ≤ 1 % de falsos rechazos sobre movimiento válido y
sigue rechazando los artefactos medidos. Si web y Android difieren, el valor
es por plataforma o se normaliza la medida para que sea uno solo.

| Parámetro | Actual | Propuesto | Base |
|---|---|---|---|
| Medida de la compuerta de manos | x,y normalizados | x escalado por `ancho/alto` de imagen antes de medir (unidades físicas iguales en web y Android) | H1. Requiere pasar el aspecto a JS (Android ya lo registra como `aspect`). |
| `minHandScale` / `maxHandScale` | .12 / .9 | **.09 / 1.2** sobre la medida corregida | Web corregida (÷1.33 en vertical): aceptadas p50 ≈ .35. De 83 rechazos por escala en wddae4, 52 están en (.9, 1.2] — mano cerca de cámara junto al brazo, válida — y 30 por encima de 1.2 (artefacto). `hand_far_from_arm` sigue cubriendo el resto. |
| Velocidad angular de mano | 24 rad/s, solo por dt | **20 rad/s** + **tope por frame de 100°**; un salto > 120° en un frame se clasifica `palm_flip` y se resuelve con la superficie (palma/dorso, 2 frames) en vez de congelar | H2. Movimiento válido p95 ≈ 5 rad/s; giros reales rápidos 40–90°/frame a 15 FPS (10–23 rad/s). Volteos 140–180°. |
| Velocidad angular de dedos/brazo | 24 rad/s | sin cambio hasta tener sesión con buena luz | Pocos eventos (≤ 5 por articulación). |
| `maxSourceSkewMs` | 120 | sin cambio; caducar `webPoseCache` (o skew `null`) cuando falta pose, contar `stage_desync` **una vez por frame** y registrar `skew_ms` por frame en web | H9. |
| Visibilidad de cadena de brazo (Kotlin) | .35 en ambos brazos | **.35 por brazo**; el brazo visible decide su lado, el otro queda por continuidad (como web) | H4: recupera 3–12 % de frames con mano. |
| sw en `handSurfaceTransition` (Kotlin) | .4 fijo | ancho real de hombros del frame | H5. |
| `maxAgeMs` de la compuerta | 500 (inactivo) | pasar `nowMs = performance.now()` y fijar **200 ms** (default del módulo), por debajo de `kFrameStaleMs` 450 | H8. Con cámara a 15 FPS el frame dura 66 ms; 200 ms = 3 frames. |
| One Euro / deadbands | `M/rig_math.mjs:305-312` | sin cambio | Jitter de fase 3 en PASS en wddae4; revisar tras sesión Android. |

Todos los valores son **PROVISIONALES**: salen de webcam a 15 FPS con poca
luz. Se confirman con la sesión Android y una sesión web con buena luz,
re-ejecutando `analizar_sesion.py --gates` y comparando congelamientos.

## Sesión Android (pendiente, prioridad)

Teléfono por USB con depuración activada; `adb` está en
`~/Android/Sdk/platform-tools/adb` (no en `PATH`).

```bash
# Nunca `flutter install`: desinstala la app y borra sesiones y muestras.
cd univoz && flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
# Abrir Traducir señas (espejo), ~5 min: señas reales + maniobras 1–9 de manos
adb exec-out run-as com.example.univoz ls app_flutter/sesiones
adb exec-out run-as com.example.univoz cat app_flutter/sesiones/<id>.jsonl > senas_core/sesiones/<id>.jsonl
python3 senas_core/tools/analizar_sesion.py --gates senas_core/sesiones/<id>.jsonl
```

Sin `marker` en Android (H3, decidido no agregarlo por ahora), anotar a mano
el segundo de inicio de cada maniobra. Medir en Android: frames sin cadena de
brazo (`assignment_modes.fallback`), distribución de escala de mano con
`aspect` (H1) y `skew_ms`. Paridad de la captura sobre la sesión:
`node senas_core/tools/rig-tests/paridad/replay_sesion.mjs <sesión>`.

## Tests Kotlin

`cd senas_core/android && ./gradlew :app:testDebugUnitTest` (corre dentro de
`univoz.sh test` si hay SDK y JDK): 64 tests (`ParidadManosTest` 1 sobre 1270
frames, `HandTrackCoordinatorTest` 25, `CapturaManosTest` 11,
`DeviceTierTest` 19, `HandCandidateGateTest` 7, `MediaPipeProtobufTest` 1).

`./gradlew testDebugUnitTest` (todos los módulos) **falla** fuera de
nuestro código: `:path_provider_android:processDebugUnitTestManifest`,
"minSdkVersion 19 cannot be smaller than version 21 declared in library
[androidx.exifinterface:exifinterface:1.4.1]". Al sumar Gradle a
`univoz.sh test` (H11) usar `:app:testDebugUnitTest`.

## Cómo se midió (para repetir)

- **Velocidad angular de palma (H2):** por lado asignado
  (`hands.assignment.sides` + `hands.passed`), marco de palma con
  y = muñeca→MCP medio (0→9), x = MCP meñique→MCP índice (17→5),
  z = x × y; ángulo entre marcos consecutivos `acos((tr(AᵀB) − 1)/2)` ÷ dt,
  solo pares con dt ≤ 150 ms. Histograma de grados por frame para los
  eventos > 18 rad/s.
- **Escala de mano (H1):** `hypot(lm0 − lm9) / hypot(pose11 − pose12)` en
  x,y como la compuerta, solo frames con hombros visibles ≥ .5; separado
  por aceptadas y por código de rechazo (`hands.rejected`).
- **Visibilidad de brazo (H4):** frames con mano seguida donde algún punto
  11/13/15 o 12/14/16 tiene visibilidad < .35.
- **`stage_desync` (H9):** `t_ms − started_at_ms` de cada evento contra
  `t` de frames vecinos.

Los scripts de esta sesión vivían en el scratchpad y no se conservan; si se
repiten seguido, convertirlos en `analizar_sesion.py --calibrar`.

## Cambios 2026-10-19 (web/JS; Android los hereda vía WebView)

Hechos sobre la investigación "estilo VTuber" (mano válida, filtrada,
estable; avatar que no improvisa). Detalle en
[04](04-rig-ik-y-avatar.md#safety-gate) y
[03](03-estabilizacion-y-pulgar.md#perfil-de-confianza-de-mediapipe-web).

- **H2:** 20 rad/s, recorte a velocidad máxima (tope 100°/frame) en vez de
  congelar; `palm_flip` (> 120° en `*:hand`) separado de
  `angular_velocity_exceeded`. Diferencia con lo propuesto: el volteo se
  confirma dentro de la compuerta (misma pose nueva ±15° dos frames
  seguidos), no con `classifyHandSurface`.
- **H8:** `nowMs` real (edad desde la llegada al visor) y `maxAgeMs` 200.
- **H9:** `webPoseCache` caduca a 120 ms sin pose; `stage_desync` se cuenta
  una vez por frame; web registra `skew_ms` por frame.
- **H13 (nuevo):** el chequeo de longitud ósea del brazo nunca podía fallar
  (`referenceBoneLength` y `boneLength` eran la misma longitud del rig).
  Ahora mide hombro→codo y codo→muñeca contra la mediana de las últimas 30
  medidas; en modo `audit` (registra, no congela) hasta medirlo en sesión.
- **H14 (nuevo):** la reproducción de plantillas reinicia su reloj en 0 y
  las compuertas del torso, que ya habían visto timestamps/ids mayores, la
  rechazaban entera como `stale_frame`; y el vivo posterior también. Se
  reinician las compuertas al empezar y al terminar la plantilla.
- Reposo y entrada a pose viva con mezcla por tiempo (250/150 ms), estados de
  avatar en sesión (`avatar_state`), zona muerta angular suave 1.5°,
  recuperación por tiempo (100 ms), cara suavizada por tiempo, plantilla
  interpolada por render, perfil `?perfil=estable`.
- Smoke en navegador (Brave headless, puente `aplicarFrameVivo`, mismo
  guion): rechazos de compuerta 223 en `KARIM` previo → 33 ahora (61 con
  `?transiciones=0`). Solo orientativo: frames sintéticos, no una sesión.
- Sin tocar: factores fijos de `rig_tracking.mjs` (.65/.35, recuperación de
  3 frames) porque tienen espejo en Kotlin (H6); umbrales Kotlin.

### Validación con sesiones web 2026-10-19

Dos sesiones físicas, Holistic en worker, webcam ACER HD a 360×270, **sin
marcas de protocolo** (fases 2 y 4 `SIN_DATOS`, jitter de fase 3 sin
calcular). Gates en `docs/evidence/gates/`.

| | `20261020T031410Z-8ttkmb` (sensible) | `20261020T031538Z-gq000m` (estable) | `wddae4` (antes) |
|---|---|---|---|
| Duración / frames | 78 s / 1146 | 286 s / 4315 (manos en cuadro ~47 s) | 236 s / 3625 |
| Congelamiento de mano por giro/volteo | 2 `palm_flip` | 0 | 86 `angular_velocity_exceeded` |
| `angular_velocity_clamped` (no congela) | 94 | 70 | — |
| `stage_desync` | 0 | 0 | 48 |
| `stale_frame` | 8, segundo 2 | 26, segundo 1 | 0 |
| Mano seguida con muñeca de pose visible | 99.4 / 99.5 % | 99.2 / 97.8 % | — |
| Latencia p50 / p95 | 36 / 43 ms | 36 / 47 ms | 33 / 44 ms |
| Cámara / tracking | 15 / 16 FPS | 15 / 16 FPS | 15 / 15 FPS |

Conclusiones:

- **H2 resuelto en la práctica:** ningún congelamiento de mano por velocidad
  fuera de 2 volteos de un frame; los giros rápidos se recortan y siguen.
- **Reposo suave verificado:** HOLD 251–260 ms (gracia 250) y RETURNING
  mediana 253–282 ms (máx 445); 9 de 10 pérdidas siguieron
  HOLD → RETURNING → TRACKING y una volvió dentro de la gracia (62 ms).
  Huecos de mano seguidos: casi todos ≤ 250 ms; la gracia no se alarga.
- **`stale_frame` solo al arrancar:** el primer segundo el worker devuelve
  frames con 1.3–2.5 s de latencia; la compuerta no los anima (correcto). Se
  cuenta una vez por articulación (~26) en un solo instante.
- **H13 (longitud de brazo) se queda en `audit`:** con `vec` crudo, la
  desviación contra la mediana de 30 frames supera 15 % en 6–22 % de los
  frames según el segmento (p99 30–74 %). Con `freeze` y `.15` los brazos se
  congelarían seguido: el z monocular no sirve como compuerta de longitud.
- **Perfil `estable` sin ventaja medible:** detección con muñeca visible
  ≥ 97.8 % en ambos; la cobertura baja de `gq000m` es tiempo sin manos en
  cuadro. Default sigue `sensible`.
- **Fase 1 sigue limitada por la cámara:** el visor pide 30 FPS y la ACER
  entrega 15 (prioridad de exposición con poca luz). Falta `v4l-utils` para
  fijarla.
- **Medición pendiente:** el jitter de fase 3 se calcula sobre `vec` crudo
  (entrada de MediaPipe), no sobre la pose aplicada al avatar; el efecto de
  One Euro, zona muerta y recorte no se ve en las sesiones. En bloques de 1 s
  quietos, el antebrazo crudo da mediana 1.9–2.7° (wddae4 1.7°): es la
  entrada, no el avatar.

### Pulido tras las sesiones (2026-10-19)

- **H8 corregido:** la edad del frame en web se medía desde la captura; en un
  equipo con latencia constante > 200 ms la compuerta habría congelado todo
  el avatar. Ahora web y Android miden desde la llegada al visor. El arranque
  lento del worker (causa de los `stale_frame`) pasa a un calentamiento que
  no anima el avatar ([04](04-rig-ik-y-avatar.md#calentamiento-de-la-captura-web)).
- **Avatar medido:** la sesión web registra la pose aplicada (campo
  `avatar`) y los recortes por articulación (`safety_clamped_joints`);
  `analizar_sesion.py` reporta `jitter_avatar_deg`, `jitter_auto` y
  `articulaciones_recortes` ([10](10-metricas-y-criterios.md)). El refactor
  del jitter deja igual el valor histórico (wddae4 1.543/1.839°, 9qwtjc
  1.259/1.608°).
- **Cámara:** la sesión guarda qué deja controlar el navegador
  (`meta.camera`: rango de FPS, modos y tiempo de exposición) y el aviso de
  FPS bajos indica el control de `v4l2-ctl`.
- Smoke del puente: rechazos de compuerta 33 → 28 con el mismo guion.

### Fluidez (sesión `20261020T040119Z-dnrzh8`, con protocolo)

Fases 0, 2, 3 y 4 PASS (inversión 0.59 %, jitter de entrada 1.46/1.50°, 0
swaps); fase 1 FAIL por cámara a 15 FPS. Métrica nueva `fluidez`: 15 cambios
de pose por segundo con render a 144 Hz (0.94 por frame de cámara) y pasos de
hasta ~106° en un render (volteos confirmados recuperados en 1–2 frames). El
avatar tembló más que la entrada en muñeca (2.1–3.1°). Se añadió suavizado de
salida a ritmo de render, tope de velocidad y recuperación de volteo de
250 ms ([04](04-rig-ik-y-avatar.md#suavizado-de-salida-render)); reproduciendo
la misma sesión: 100 % de renders con movimiento, paso p95 15.7°, jitter de
mano 1.3–1.8°. Banco de prueba: reproducir un `.jsonl` por
`aplicarFrameVivo` con su ritmo original en Brave sin ventana con GPU
(`--use-angle=gl-egl`), leyendo `webCameraState.avatarPose` y
`renderMotion`.

## Primera prueba en teléfono (Galaxy S22+ SM-S906E, 2026-10-19)

- **H15 (crash):** al encender la cámara la app se cerraba. MediaPipe tasks
  1.0.0 declara `protobuf-javalite` pero llama `Any.Builder.build()` con la
  firma de `protobuf-java`: `NoSuchMethodError` al crear Holistic, y como es
  `Error` (no `Exception`) el respaldo GPU→CPU→separado no entraba. Venía
  desde `d6bae9f` (2026-10-02); nunca se había corrido en teléfono. Arreglo:
  excluir javalite y usar `protobuf-java:4.26.1` (trae también el runtime
  lite) en `senas_core` y `univoz`; `MediaPipeProtobufTest` lo reproduce.
- **H16:** `DeviceTier` bajó el S22+ (7.4 GB) de alto a bajo + separado en
  28 s y lo guardó para siempre. Holistic con GPU (GL; OpenCL no carga en
  este Exynos) tarda ~80 ms (~12 FPS), por encima de los presupuestos del
  plan (33/40/60 ms), y los primeros resultados de calentamiento contaban.
  Ahora: presupuestos 100/110/125 ms (Holistic sirve ≥ 10 FPS; separado solo
  < 8 FPS), 30 resultados de calentamiento ignorados tras crear o cambiar el
  motor, y cada sesión parte del techo del hardware (nada se guarda).
- **H17:** al salir de una pantalla con cámara, `ControladorCaptura.apagar()`
  escribía `frame` después de `dispose()` (`ValueNotifier ... used after
  being disposed`). Arreglado con test.
- **Traducir usaba el sistema viejo:** esqueleto crudo y detector con umbral
  fijo sobre la imagen. Ahora muestra el avatar (visor web, vista espejo,
  `AlimentadorAvatar` compartido con Espejo) y corta las señas con el
  quieto/movimiento adaptativo del visor: el visor manda `motion:` por frame
  (`intentionalMotion` del filtro o `fingerMotionScore` ≥ .8, con mano) y
  Dart lo pasa a `DetectorAutomatico.alimentarMovimiento` (misma máquina de
  estados por tiempo). Sin pose usable el preview cuenta como quieto. El
  reconocimiento DTW sigue sobre el 152D crudo (las plantillas son crudas).
  En navegador: 0 % movimiento con la mano quieta, 99 % en un tramo de seña
  real.
- `DetectorAutomatico` mide por tiempo (corte ~0.33 s y misma sensibilidad a
  15/24/30 FPS); antes contaba frames.

## Paridad Android (2026-10-20)

Android usaba un port parcial y viejo de la captura web. Ahora corre la misma
captura, verificada frame a frame contra la web.

- **Una sola fuente en JS.** La lógica inline de `index.html` pasó a módulos:
  `rig_motion_frame.mjs` (`handUsable`, `poseGeometry`,
  `normalizeMotionFrame` con `renderWrists`, `frameQuality`) y
  `rig_hand_capture.mjs` (`createHandCapture`: compuerta → nacimiento →
  cadena de brazo → mano utilizable → seguimiento → desacuerdo de muñeca;
  `countHandEvents`, `nativeTracking`). La página solo registra diagnóstico y
  sesión. Al extraerla, el banco regenerado salió **idéntico byte a byte**.
- **Banco de paridad.** `tools/rig-tests/gen_paridad_manos.mjs` toma
  ventanas de las sesiones `dnrzh8`, `wddae4` y `9qwtjc` (todas las
  maniobras y códigos) más 13 escenarios sintéticos (oclusión 200–700 ms,
  salto, volteo, cruce con etiquetas cambiadas, sin ancla, 3 candidatas,
  pose ausente…). Reproduce con la captura web actual y escribe
  `test/golden/paridad_manos.jsonl.gz`: 1270 frames, 26 códigos. El fixture lo
  leen cuatro implementaciones:
  - `paridad_manos.test.mjs`: candado de la web.
  - `ParidadManosTest.kt`: compuerta, lados, utilizables, estado, superficie,
    render, costos, contacto y errores.
  - `paridad_manos_test.dart`: 152D, vector de render, motivos y calidad.
  - `test_paridad_manos.py`: 152D, render y motivos.

  Los discretos se exigen exactos y los números a 1e-9. Mutaciones
  verificadas: H10 en Kotlin da 68 desajustes (34 frames × 2 lados), y el tope
  de muñecas de render a .05 en Python da 234.
- **Kotlin.** `HandTrackCoordinator.kt` reescrito como espejo de
  `rig_tracking.mjs`: superficie palma/dorso y `hand_surface_ambiguous`,
  `gateAssignmentMode`, retención de saltos, recuperación de 3 frames,
  render acotado y `track_ambiguous`. `CapturaManos.kt` replica
  `createHandCapture` y `handUsable`. `JsMath.hypot` copia el `Math.hypot`
  de V8 bit a bit; con `java.lang.Math.hypot` hoy también pasa.
  `LandmarkEngine` queda como adaptador:
  - caché de pose de 120 ms en ambos modos, y el frame lleva el instante de
    las manos;
  - separado emite solo por resultado de manos;
  - payload nuevo `hands_in`/`track`/`pose_ran`.
- **Resueltos:**

  | Hallazgo | Qué era y cómo quedó |
  |---|---|
  | H3 | Esquema de sesión web en Android, y perf con contadores reales. Sin `marker`, por decisión. |
  | H4 | Ya no hay umbral de 6 puntos de brazo. |
  | H5 | `handSurfaceTransition` usa el ancho de hombros real. |
  | H6 | Las funciones que solo existían en la web están portadas. |
  | H7 | El modo separado prueba GPU y luego CPU; `gpuOk` dice la verdad. |
  | H10 | Corregido en la web (`contactBefore.active`); cambia solo los costos de 34 frames. |
  | H11 | Gradle corre dentro de `univoz.sh test`. |
  | N1 | El 152D de reconocimiento usa la mano cruda aunque el seguimiento la retenga; antes se perdía. |
  | N5 | Se quitó `renderAt`, que marcaba OCCLUDED falsos con cada pose. |
  | N6 | `hand_identity_swap` se evalúa por frame. |
  | N7 | La pista de pose va solo con `pose_arm_chain`. |
  | N9 | El costo de posición es 3D. |
  | N10 | `wrist_disagreement` exige 3 frames en fusión directa (antes, cada frame). |
  | N11 | El contacto es un objeto. |
  | N12 | Holistic manda manos incompletas a la compuerta en vez de descartarlas en silencio. |

- **Validaciones en Dart y Python.** `manoUtilizable`/`hand_usable`,
  `poseGeometriaValida`/`pose_geometry`, `motivos` con los códigos web,
  muñecas de render (tope .75), mano ≠ 21 puntos ignorada y chequeo final de
  finitud. `calidadFrame` reemplaza la calidad del avatar, que antes era el
  hombro mínimo. `norm_version` no cambia: las validaciones solo descartan
  manos o frames, los valores aceptados son iguales. El golden se regeneró
  con anatomía plausible y suma un bloque `validaciones` (10 casos) que
  comprueban Python, Dart y JS.
- **Reconocimiento (Traducir).**
  - Un solo DTW por intento (`classifyRanking`).
  - Pre-roll de 200 ms desde un anillo de 400 ms.
  - Recorte de la cola quieta: el corte queda en
    `ultimoMovimientoMs + 100 ms`.
  - El modo manual también exige 8 frames válidos ("Seña muy corta").
  - Evento de sesión `reconocimiento`.
  - El espejo automático cubre también el paquete y el diccionario
    sincronizado. Leave-one-out del paquete (146 plantillas, 44 glosas):
    con la mano habitual, 66.4 → 65.8 % top-1; con la otra mano,
    11.0 → 65.8 %.

## Backlog (Android primero)

1. ~~Android emite `perf`, `tracked.*_surface` y unifica el esquema de
   `hands` con web (H3).~~ Hecho 2026-10-20 (sin `marker`, por decisión). Cruza con el plan
   `docs/superpowers/plans/2026-10-05-android-niveles-dispositivo.md`
   (Task 6 ya cubre `perf`).
2. Compuerta de manos con aspecto corregido + umbrales .09/1.2, en JS y
   Kotlin a la vez, con tests espejo (H1).
3. ~~`palm_flip` separado de `angular_velocity_exceeded` + 20 rad/s + tope por
   frame (H2).~~ Hecho 2026-10-19.
4. ~~Kotlin: visibilidad por brazo (H4), sw real (H5), respaldo CPU en
   `separado` (H7).~~ Hecho 2026-10-20.
5. ~~Compuerta de seguridad: `nowMs` real + `maxAgeMs` 200 (H8); caducar
   `webPoseCache` sin pose, contar `stage_desync` por frame y registrar
   `skew_ms` en web (H9).~~ Hecho 2026-10-19.
6. ~~`univoz.sh test` corre `./gradlew :app:testDebugUnitTest` (H11).~~
   Hecho 2026-10-20. `LandmarkEngine` sigue sin tests propios (lo cubre la
   paridad de `CapturaManos`).
7. ~~Portar a Kotlin `gateAssignmentMode`, `classifyHandSurface`, salto de
   posición y recuperación (H6).~~ Hecho 2026-10-20 con banco de paridad.
8. ~~`contactBefore.active` en la matriz neutral (H10).~~ Hecho 2026-10-20. Limpieza: script de sincronía o test de
   paridad de constantes para BodyProfile/SignSpace (H12).
