# Estudio — cómo mueve Kalidoface 3D a un avatar VRM (y qué nos sirve)

## Objetivo

Entender cómo una app web de VTuber que ya corre en teléfonos (Kalidoface 3D:
MediaPipe + Kalidokit + three-vrm) calcula y suaviza el movimiento de un
modelo VRM, y sacar una lista corta de mejoras **medibles** para el avatar de
Univoz en teléfonos de gama baja y media (Android hoy, iPhone después).

Es un estudio de solo lectura: no se cambió código del producto. Fecha:
2026-10-20, rama `KARIM`.

Preguntas del encargo: (a) solver de brazo/mano/dedos y límites; (b) suavizado;
(c) si el tracking está desacoplado del render; (d) configuración de MediaPipe
en móvil; (e) degradación en móvil; (f) mano perdida u ocluida; (g) patrones de
asignación de memoria por frame.

## Método

Abreviaturas: `KF` = bundle `https://3d.kalidoface.com/assets/index.e2bec78d.js`
(197 858 bytes, sha256 `33a8f605…ad24`, versión de la app `0.0.11`, minificado,
sin source maps); `KK` = Kalidokit `6437947` (MIT, clonado a un directorio
nuevo, solo leído); `U` = `senas_core/assets/avatar_viewer/`.

Herramientas REA usadas y resultado:

| Herramienta | Resultado | Evidencia |
| --- | --- | --- |
| Brave headless con CDP (puerto 9222) | Cargó el sitio sin problema | — |
| `analyze_web_bundle` (source maps + consola) | Funcionó: 4 scripts, `vendor.832d142e.js` (2.5 MB) e `index.e2bec78d.js`; grafo de chunks. Source maps: **no disponibles**. No devuelve el texto de las funciones | `ev_05dc3e9965937f5eb9a590676b55465162bdf37dcc94db76f6db603f66c0acef` |
| `capture_browser_scenario` (conectado, viewport 412×915 @2.6x, 12 s) | Funcionó: red, consola, árbol de accesibilidad. Resultado enorme: se leyó con `jq` | `ev_e7b03bc1a808eb21d476df32960e217fe2d5fa052da93a338ebc2ec75e4e2a7f` |
| `capture_browser_scenario` (mismo viewport, clic en "Start Face Tracking", 20 s) | Funcionó: se ve qué modelos MediaPipe se piden | `ev_548e261b30b9ed312a8f060dce757a75aec3693ad08a6ec2a629131fc48c3f46` |
| Lectura del bundle KF | `curl` de solo lectura al mismo archivo (su sha256 coincide con el de la evidencia REA), luego búsqueda con Python `-I`. No es una herramienta REA | sha256 arriba |
| Lectura de KK (`src/PoseSolver`, `HandSolver`, `FaceSolver`, `utils`) | Completa | commit `6437947` |
| `observe_web_execution`, `trace_javascript_semantics` | No se usaron: la cámara es falsa (patrón de prueba, sin persona), así que no hay landmarks reales y la cobertura de ejecución no habría dicho nada útil | — |

Lo que **no** se pudo hacer: ver el sitio rastreando a una persona (no hay
cámara real ni teléfono), así que no hay FPS ni latencias de Kalidoface. Todo
lo de abajo es lectura de código más la carga observada.

## Hallazgos Kalidoface

Cada fila: **O** = observado (código leído o red capturada), **I** = inferido,
**D** = desconocido. Las posiciones son offsets de carácter en `KF`.

### Qué corre en un teléfono

| # | Hallazgo | Tipo | Fuente |
| --- | --- | --- | --- |
| 1 | `face.enable = !(window.innerWidth > 600)` y `holistic.enable = window.innerWidth > 600`. En pantalla angosta el modo por defecto es **solo cara** (FaceMesh); cuerpo+manos (Holistic) es el modo de pantalla ancha. El usuario puede alternar en Ajustes (los dos son excluyentes) | O | `KF@42443`, `KF@124387` |
| 2 | En 412 px de ancho el botón dice "Start Face Tracking" | O | `ev_e7b03bc1…` (accesibilidad) |
| 3 | En ese mismo viewport, tras el clic, se descargan `holistic_solution_simd_wasm_bin.wasm`, `holistic_solution_packed_assets.data`, `holistic.binarypb` y la consola dice que espera `pose_detection`, `palm_detection_{lite,full}`, `hand_landmark_full`, `hand_recrop`, `face_landmark(_with_attention)`. O sea que el grafo Holistic **se inicializa aunque en móvil solo se envíe cara** (`new Holistic` + `setOptions` corren siempre fuera de iOS). No se vieron pedidos de `face_mesh_solution*` en 20 s | O (red); causa: I | `ev_548e261b…`, `KF@43122` |
| 4 | iPhone/Safari (`navigator.vendor` Apple, sin CriOS/FxiOS) usa otra ruta: TF.js BlazePose `modelType: "lite"`, `enableSmoothing: true`, runtime `tfjs`; la cara con `mediapipeFacemesh` de TF.js si WebGL está deshabilitado | O | `KF@3430`, `KF@43122` |
| 5 | Versiones fijas por CDN: `@mediapipe/holistic@0.5.1635989137`, `face_mesh@0.4.1633559619` (API legada de 2021, no Tasks) | O | `ev_548e261b…` |

### (d) Configuración de MediaPipe

| Parámetro | Valor | Tipo | Fuente |
| --- | --- | --- | --- |
| Holistic | `modelComplexity: 1`, `smoothLandmarks: true`, `minDetectionConfidence: .7`, `minTrackingConfidence: .7`, `refineFaceLandmarks: true` | O | `KF@42443` |
| FaceMesh (ruta `mediapipe`) | `maxNumFaces: 1`, `refineLandmarks: true`, `minDetection/Tracking: .5` | O | `KF@43122` |
| Cámara | `facingMode: "user"`, ancho `min 480 / ideal 640 / max 640`, alto `min 480 / ideal 480 / max 480`. Sin `frameRate` | O | `KF@23467` |
| Bucle de inferencia | `async function C(){ await f.send({image}) ; await c.send({image}); requestAnimationFrame(C) }`: **un envío tras otro, en el hilo principal, y el siguiente frame no se pide hasta que termina el anterior** (contrapresión natural, sin cola) | O | `KF@43122` |
| Calentamiento | Los primeros 20 resultados se descartan (`sn<20`) | O | `KF@36048` |
| Dibujo de depuración | Cada resultado dibuja conexiones y puntos en un canvas (`Xn`), sin condicionarlo a "debug" | O | `KF@31118` |

### (c) Desacople tracking / render

- El render tiene su propio `requestAnimationFrame` con `THREE.Clock.getDelta()`
  (`Ke`) sin tope (`KF@55418`). El tracking tiene otro rAF encadenado a la
  promesa de inferencia (arriba). Los resultados de tracking **solo escriben
  un estado** (`tracking.Pose`, `tracking.RightHand`…); el render lee ese
  estado en cada tick y lo acerca a los huesos. **Observado.**
- Los solvers (`Pose.solve`, `Hand.solve`, `Face.solve`) corren **una vez por
  resultado de tracking**, no por tick de render (`KF@32491` `Sn`, `KF@36048`
  `lr`, `nr`). **Observado.**
- Todo ocurre en el hilo principal (no se vieron workers en la captura; la
  captura incluía el evento `workers` y no registró ninguno). El render y la
  inferencia compiten por el mismo hilo. **Observado / inferido.**

### (a) Solvers y límites (Kalidokit, leído completo)

Brazos, desde `poseWorldLandmarks` (`KK/PoseSolver/calcArms.ts`):

- Rotación por `findRotation` entre hombro→codo y codo→muñeca, más ángulos
  entre tres puntos 3D para el eje Y.
- Escalas: `UpperArm.z *= -2.3`, `UpperArm.y *= π`, `LowerArm.{x,y,z} *= 2.14`.
- Límites: `LowerArm.z ∈ [-2.14, 0]`, `UpperArm.x ∈ [-0.5, π]`,
  `LowerArm.x ∈ [-0.3, 0.3]`, `Hand.y ∈ [-0.6, 0.6]`.
- Ángulos tipo Euler directos por hueso, **sin IK**, sin longitudes de hueso.

Brazo fuera de cuadro (`KK/PoseSolver/index.ts`): si `y > 0.1` o
`visibility < 0.23` o `y2d > 0.995`, el brazo se multiplica por 0 y la z del
brazo superior se fija en el reposo (`±1.25`). Es decir, **visibilidad de
landmark como criterio de "fuera de cuadro"**.

Manos (`KK/HandSolver/index.ts`), desde landmarks de mano:

- Muñeca: `rollPitchYaw` de (0, 5, 17); `x ∈ [-0.3, 0.3]`,
  `y ∈ [-1.2, 0.6]` (derecha) / `[-0.6, 1.6]` (izquierda), `z *= -2.3`.
- Dedos (no pulgar): un ángulo por articulación = `angleBetween3DCoords` de
  tres landmarks, `z = clamp(-π·ángulo, -π..0)` (derecha) o `0..π`
  (izquierda). Solo flexión; sin abducción.
- Pulgar: tabla de amortiguadores (`dampener`) y posición inicial por
  segmento; clamps por segmento ([-0.6, 0.3], [-1, 0.3], [-2, 2]).
- En `lr` (`KF@36048`) la mano de Kalidoface toma `x,y` de la muñeca de
  `Hand.solve` y `z` del brazo de `Pose.solve`.

Aplicación en el avatar (`KF@55418`, funciones `zt`, `Kn`, `Ms`, `un`, `cn`):
cada hueso se fija como cuaternión desde un Euler.

### (b) Suavizado

| Capa | Qué hace | Tipo |
| --- | --- | --- |
| Entrada | Solo lo que ya trae MediaPipe (`smoothLandmarks: true`; en iOS `enableSmoothing`). **No hay One Euro ni filtro propio sobre landmarks** | O |
| Render, todos los huesos (`zt`) | `quaternion.slerp(objetivo, clamp(t·a, 0, 1))` con `t = 0.04 + dt·k` y `a = 0.6 + clamp(\|qx+qy+qz\|·40, 0, 1)·0.4`, donde `q = objetivo⁻¹·actual`. Es decir: factor lineal en dt, con un impulso de 0.6 a 1.0 según cuánto falta | O |
| `k` por grupo | cuello/brazos/cadera/antebrazo: 4; mano: 6; dedos: 8; torso: 2; piernas: 4–8 (piso 0.08) | O |
| Cara | resorte de Svelte `stiffness .15, damping .7` (solo para el parpadeo), boca `lerp .7`, pupilas `lerp .1` y `.7`; parpadeo con `stabilizeBlink` (compensa giro de cabeza, `maxRot .5`) | O |
| Hips / posición | `lerp` fijo (`.5+dt·4`, `.05+…`, `.02+…`, `.7`) | O |

No hay tope de velocidad angular, no hay zona muerta, no hay filtro de
valores atípicos.

### (f) Mano perdida u ocluida

- Mano: `i[o] !== null && (tracking[o+"Hand"] = Hand.solve(...))`. Si la mano
  no llega, **no se actualiza y los dedos se quedan como estaban, sin límite
  de tiempo** (`KF@36048`). **Observado.**
- Brazo: criterio de visibilidad de Kalidokit (arriba): vuelve a reposo con
  el mismo slerp de siempre, sin cruce explícito.

### (g) Asignaciones por frame

- `zt` crea por hueso y por tick: `new Quaternion()`, `new Euler()`,
  `n.clone().invert()`; `Vn` crea `new Vector3`. Con ~45 huesos son unos
  150–200 objetos por tick de render (**inferido por conteo del código**, sin
  medir).
- Kalidokit crea un `Vector` nuevo en cada operación (`add`, `multiply`,
  `lerp`…). Sin pooling.
- El estado de seguimiento se copia con `JSON.parse(JSON.stringify(...))` en
  reinicios (`KF@44804`), fuera del camino caliente.
- Conclusión: Kalidoface **no** es un modelo de bajas asignaciones; en móvil
  se mantiene barato porque no corre cuerpo ni manos por defecto (hallazgo 1).

### (e) Degradación en móvil

- Observado: no hay niveles de dispositivo, ni tope de FPS de render, ni
  stride de pose. La "degradación" es el **modo por pantalla** (hallazgo 1) y
  la ruta distinta para iPhone (hallazgo 4).
- El render es pesado: `setPixelRatio(Math.max(2, devicePixelRatio))` (nunca
  baja de 2), `antialias: true`, sombras con mapa de 2048, y postproceso con
  SMAA/outline en `EffectComposer` (`KF@75275`; nombres `smaa-search`,
  `smaa-area` en `analyze_web_bundle`). **Observado.**

### Desconocido

- FPS reales de tracking y de render en teléfonos concretos.
- Si la ruta FaceMesh de 412 px baja o no el costo del grafo Holistic ya
  inicializado (hallazgo 3).
- Latencia entrada→avatar.

## Comparación con Univoz

| Tema | Kalidoface | Univoz (`U`) | Veredicto |
| --- | --- | --- | --- |
| Solver brazo | Euler directo desde pose, sin IK, clamps fijos | IK de dos huesos + anclaje a cara/pecho (`rig_retarget.mjs`, `index.html ~6506`), límites en `rig_safety` | Univoz mejor |
| Dedos | 1 ángulo por articulación + tabla de pulgar | 15 ángulos con filtro One Euro (`createHandAngleFilter`), calibración de pulgar | Univoz mejor |
| Suavizado de landmarks | Solo MediaPipe | One Euro + MAD + salto + zona muerta (`createResponsiveRigFilter`, `rig_math.mjs`) | Univoz mejor |
| Suavizado de salida | slerp lineal en dt con impulso por distancia | `alpha = 1-exp(-dt/tau)` con tau adaptativo y tope de velocidad (`createOutputSmoother`) | Equivalente en idea; Univoz es independiente de la tasa de FPS |
| Desacople | Rutas separadas, pero en el hilo principal | Worker de MediaPipe + frame vivo "último gana" + render con presupuesto | Univoz mejor |
| Config MediaPipe | Holistic `modelComplexity 1`, confianza .7, cámara 640×480 | Holistic Task GPU, confianza .4/.4/.3 (perfil "sensible") o .65/.55/.55 ("estable"), cámara 360×270 / 240×320 | Distinto; Univoz prioriza latencia |
| Degradación | Modo por ancho de pantalla | `DeviceTier` (bajo/medio/alto: resolución, FPS, cara, presupuesto ms), stride de pose, `pixelRatio` .75–1.25, 15 FPS en reposo | Univoz mejor |
| Mano perdida | Se queda congelada | Gracia 250 ms, reposo, crossfade al volver | Univoz mejor |
| Brazo fuera de cuadro | Visibilidad < 0.23 | `brazoTieneDatos` (norma del codo > 0.05) | Distinto: Univoz no usa visibilidad aquí |
| Parpadeo | `stabilizeBlink`, compensa giro de cabeza; 3 puntos de párpado | 1 par de puntos arriba/abajo, sin compensación (`rig_face.mjs`) | Kalidoface mejor |
| Calentamiento | Descarta 20 resultados | `calentamientoWeb` y `CALENTAMIENTO_FRAMES = 30` en Kotlin | Equivalente |
| Asignaciones | Muchas, sin pooling | `suavizarSalida` crea varios arreglos por hueso y tick | Ambos mejorables |
| Render | `pixelRatio ≥ 2`, sombras 2048, SMAA | `antialias: false`, sin sombras, `pixelRatio` por nivel | Univoz mejor |

Conclusión honesta: Univoz ya está por delante de Kalidoface en casi todo lo
que importa para señas en un teléfono. Lo que sí deja el estudio es corto.

## Mejoras candidatas priorizadas

Ninguna se implementó. Todas son opcionales y se deben medir antes de
quedarse.

### 1. Suavizado de salida sin asignaciones y sin trabajo en huesos quietos

- **Qué**: en `suavizarSalida` (`index.html ~6033`) y `createOutputSmoother`
  (`rig_avatar_state.mjs:210`) reutilizar buffers (`Float64Array` por hueso),
  no hacer `q.set(...mostrado)` con spread, y saltar el hueso cuando el
  objetivo coincide con lo mostrado y el hueco angular < ~0.05°.
- **Por qué**: hoy cada hueso, en cada tick, crea el arreglo escrito, el
  normalizado, el resultado del slerp y una copia (4–5 arreglos pequeños;
  ~40 huesos entre cuerpo, brazos y dedos ⇒ del orden de 200 por tick, por
  lectura del código, sin medir). En gama baja eso es presión de GC en el
  mismo hilo que dibuja.
- **Ganancia esperada**: menos GC y menos ms de CPU por tick; no cambia lo que
  se ve. Cifra a confirmar con la medición de abajo.
- **Riesgo**: bajo. Debe dar los mismos cuaterniones (tolerancia 1e-9) que
  la versión actual.
- **Dónde**: `rig_avatar_state.mjs` (+ regenerar con
  `python3 senas_core/tools/inline_viewer_modules.py`), `index.html`
  `suavizarSalida`. Es solo del visor: no entra al fixture de paridad de
  manos ni a Kotlin.
- **Cómo medir**: prueba de nodo nueva junto a `rig_avatar_state.test.mjs`:
  42 huesos × 3000 ticks con `performance.now()` y `process.memoryUsage()`
  (con `--expose-gc` y `gc()` antes/después) antes y después; más igualdad
  de salida contra la versión vieja. En el replay de sesión
  (`replay_sesion.test.mjs`) comparar `webCameraState.renderMotion` (el
  resumen por segundo de `medirFluidezRender`) para confirmar que la fluidez no empeora.

### 2. Compensar giro de cabeza en el parpadeo (de Kalidokit `stabilizeBlink`)

- **Qué**: en `expressionsFromFaceLandmarks` (`rig_face.mjs:116`), cuando el
  giro de cabeza (ya calculado por `headRotationFromFace`) pasa de ~0.5 rad,
  igualar el ojo ocluido al visible; y exigir que ambos ojos bajen juntos
  para marcar parpadeo salvo guiño claro.
- **Por qué**: en LSM el giro de cabeza es gramática. Con la cara de perfil
  parcial, el ojo lejano se cierra "solo" en la malla y el avatar guiña. Solo
  se usan 2 puntos por párpado, sin promedio.
- **Ganancia**: menos guiños falsos al girar; no afecta latencia.
- **Riesgo**: bajo-medio. Un guiño real al girar se pierde. El promedio de
  3 puntos del párpado de Kalidokit **no** se propone aquí: pediría índices
  nuevos en `FACE_KEYPOINTS` (Kotlin y Dart), un cambio de contrato.
- **Dónde**: `rig_face.mjs` (y su prueba `rig_face.test.mjs`); si la lógica
  también existe en Kotlin/Dart hay que portarla después de regenerar el
  fixture (regla de captura: JS primero).
- **Cómo medir**: en sesiones grabadas con cara, contar eventos de guiño por
  minuto cuando `|yaw| > 0.5` antes y después; debe bajar sin tocar los
  parpadeos con cabeza de frente.

### 3. Cara a una fracción de la tasa en modo "separado" (solo gama media)

- **Qué**: en la captura separada (Pose + Hand + Face) correr la cara cada
  2.º–3.er frame y mantener la última expresión entre medias (la cara cambia
  más despacio que las manos).
- **Por qué**: medición propia del repo (2026-10-04, Chromium GPU): Pose 7 ms
  + Hand 6 ms + Face 9 ms ≈ 22 ms; la cara es ~40 % del total. Kalidoface
  resuelve el mismo problema quitando cuerpo/manos (inaceptable para señas);
  la adaptación sensata para nosotros es bajar solo la cara. `TierConfig.cara`
  hoy es todo o nada (bajo: apagada).
- **Ganancia esperada**: hasta ~9 ms por frame de inferencia en el camino
  separado a la mitad o un tercio de la tasa. Solo aplica cuando Holistic no
  carga o el nivel obliga a separado; en Holistic la cara va dentro del
  modelo y no se puede espaciar.
- **Riesgo**: medio. Toca `LandmarkEngine.kt` / `TierConfig` y
  `rig_holistic_worker.mjs`; hay que sincronizar Kotlin con
  `python3 senas_core/tools/sincronizar_kotlin.py`.
- **Cómo medir**: `rig_holistic_worker.test.mjs` para la lógica; en
  teléfono, p95 de `ms` por resultado (`stages`) con la cara en stride 1/2/3
  y la tasa efectiva de hand_detected.

### 4. Visibilidad del landmark como segunda señal de "brazo fuera de cuadro"

- **Qué**: además de `brazoTieneDatos` (norma del codo > 0.05, en
  `index.html:9173`), considerar la visibilidad de muñeca/codo (< ~0.23, valor
  de Kalidokit) cuando el frame la traiga.
- **Por qué**: hoy un brazo en el borde del cuadro con puntos "inventados" por
  el modelo puede dar un codo con norma suficiente y mover el brazo a una pose
  falsa en vez de a reposo.
- **Ganancia**: menos brazos que se disparan al entrar o salir del cuadro. No
  medido en Univoz todavía.
- **Riesgo**: medio: la visibilidad puede no viajar en el frame de 152D y
  agregarla es un cambio de contrato. Solo vale la pena si el análisis de
  sesiones muestra el problema.
- **Dónde**: primero revisar `rig_motion_frame.mjs` y las sesiones
  (`analizar_sesion.py`); cambiar solo si aparece.
- **Cómo medir**: en el replay, contar frames con `presI/presD = 1` y
  muñeca a menos de 3 % del borde, y ver cuántos terminan con salto de
  hueso > 30° en un frame (`rig_diagnostics.mjs`).

### 5. Quitar dibujo/diagnóstico del camino caliente en producción móvil

- **Qué**: confirmar que ni el resumen por segundo (`medirFluidezRender`,
  `index.html ~9543`) ni otros contadores de diagnóstico corren cuando no hay
  sesión de diagnóstico activa; Kalidoface dibuja siempre y es un mal
  ejemplo, no un modelo.
- **Por qué**: cada tick compara cuaterniones de `kHuesosMedidos` y
  actualiza contadores. Es poco, pero es trabajo en cada render en gama baja.
- **Ganancia**: pequeña; solo si la medición del punto 1 muestra que importa.
- **Riesgo**: bajo, pero puede esconder métricas que usa la sesión
  automática (`rig_session`).
- **Cómo medir**: perfil de `animar()` con y sin `medirFluidezRender`
  (Brave con `?tier=bajo` y estrangulamiento de CPU 4x).

### Lo que **no** conviene copiar

- Modo "solo cara" en pantalla angosta: para señas necesitas manos.
- `pixelRatio ≥ 2`, sombras de 2048 y SMAA: ya vimos que cuestan en móvil.
- Mano congelada sin límite: Univoz ya hace mejor (reposo con gracia).
- Slerp lineal en dt: el exponencial de Univoz es más correcto y ya tiene
  tope de velocidad.

## Limitaciones

- No hay medición de Kalidoface en acción: la cámara es falsa y no hay
  teléfono. Los hallazgos son lectura de código y carga de red.
- El código del bundle es minificado y sin source maps; los nombres (`zt`,
  `Kn`, `Ms`, `un`, `cn`, `lr`, `Sn`) son los del archivo. La asociación con
  Kalidokit se apoya en que el código de `lr`/`Sn` llama a los mismos solvers
  y en las mismas constantes (2.3, 2.14, 0.23); es una inferencia fuerte, no
  una prueba formal.
- `analyze_web_bundle` no devuelve el texto de las funciones; el texto se
  leyó con `curl` de solo lectura sobre el mismo archivo (el sha256 coincide
  con el de la evidencia). No se ejecutó ningún script del sitio ni de
  Kalidokit.
- El hallazgo 3 (Holistic se inicializa en móvil) es observado en red; la
  causa es inferida y no se sabe cuánto cuesta en un teléfono real.
- Las cuentas de asignaciones por tick (Kalidoface y Univoz) salen de leer el
  código, no de un perfil de memoria.
- La versión legada de MediaPipe (2021) de Kalidoface no es comparable en
  rendimiento con Holistic Task GPU de Univoz.
- Brave headless no es un teléfono: cualquier cifra de rendimiento de este
  estudio debe volver a tomarse en el Galaxy S22+ (docs/12).

## Rendimiento visor (T3)

Se aplicaron las mejoras 1 y 5 de arriba, más resolver solo frames nuevos.
Medido con un replay de la sesión `20261020T031538Z-gq000m` (primeros 90 s:
1345 frames a ~15 FPS, manos las dos, una y ninguna) por
`aplicarFrameVivo`, en Brave headless GPU (`--use-angle=gl-egl`), visor no
standalone, nivel alto (render 60 Hz), reloj virtual (5429 ticks, mismos
ticks antes y después) y CPU estrangulada 4x. Media de 2 corridas.

| Por tick (CPU 4x) | Antes | Después |
| --- | --- | --- |
| JS (sin dibujo), media | 4.69 ms | 3.66 ms (−22 %) |
| JS, tick sin frame nuevo | 4.57 ms | 3.41 ms (−25 %) |
| JS, tick con frame nuevo | 5.07 ms | 4.42 ms (−13 %) |
| `aplicarFrame` (perfil) | 0.68 ms | 0.27 ms |
| `suavizarSalida` (perfil) | 0.38 ms | 0.08 ms |
| Memoria nueva por tick | ~629 KB | ~526 KB |
| Jitter de la pose (13 huesos) | igual | igual (Δq máx 1.1e-10) |

- **Qué cambió**: `RigBodyEngine.aplicarFrame` corre solo cuando cambia la
  clave del frame (`shouldSolveFrame` en `rig_avatar_state.mjs`: frame,
  id, tiempo, vista, retarget, avatar) o mientras una mano está en su gracia
  de pérdida (el paso a reposo depende del reloj). El suavizado de salida,
  las transiciones, la cara y `vrm.update` siguen en cada tick. La muestra de
  retraso de dedos (`measureFingerLag`) es una por frame. El suavizado de
  salida lee y escribe el cuaternion del hueso en su lugar y deja quieto el
  hueso que ya llegó a su objetivo (< 1e-10). IK de brazo y marco de palma
  reusan vectores y cuaterniones de trabajo.
- **No cambió lo que se ve**: la traza de cuaterniones por tick coincide con
  la de antes a 1.1e-10 (vista interlocutor) y a 2e-6 (espejo: tolerancia
  1e-6 propia del suavizado); la reproducción de plantillas da la misma
  traza (diferencia 0).
- **`medirFluidezRender` no se movió**: cuesta ~0.016 ms por tick (0.3 %),
  no se nota en la medición.
- **Lo que sigue pesando**: las funciones `update` del perfil
  (`vrm.update` con huesos de resorte y matrices, más los `update` internos
  de three) suman ~3.2-3.5 ms por tick, la mayor parte del tick. No es parte
  de este cambio; es el siguiente candidato.
- Con reloj real (8x) el tick baja de ~12.7 a ~11.4 ms y el FPS se queda en
  ~59-60 en las dos (Brave headless topa en 60). Como dice "Limitaciones",
  estas cifras hay que repetirlas en el Galaxy S22+.
