# Android: paridad con el laboratorio web y niveles por dispositivo

Fecha: 2026-10-05 · Rama: `KARIM` · Estado: aprobado para plan

## Objetivo

Que la app producto `univoz` (`com.example.univoz`) dé en el teléfono lo que
hoy funciona en el laboratorio web, sin controles técnicos a la vista y
adaptándose al hardware para que **cualquier teléfono Android, incluida la
gama media-baja (3–4 GB RAM, GPU débil)**, pueda usarla. Entregable final:
un APK de depuración para probar en dispositivos reales.

El laboratorio web (`?standalone=1`) se mantiene como está; solo gana
`?tier=` para simular niveles.

## Punto de partida (verificado en el código)

- Android ya captura con CameraX + Holistic nativo (GPU→CPU, respaldo
  Pose + Hand), con `HandTrackCoordinator` / `HandCandidateGate` en Kotlin y
  el mismo visor `index.html` en WebView (`aplicarFrameVivo`).
- El panel del laboratorio solo aparece con `standaloneWeb`; en WebView no.
- Copias de `univoz` (visor y Kotlin) sin deriva respecto a `senas_core`.
- Pista de muñeca en x/y (`bfb6186`) ya existía en Kotlin
  (`HandTrackCoordinator.kt:364`).
- Cara: Android manda 17 puntos (`FACE_KEYPOINTS`), los mismos índices que
  `kCaraClave` y `rig_face`; se asume paridad y se fija con una prueba.
- Estado actual sin adaptación: `minSdk` 21, análisis 360×480 fijo, render
  60 FPS con `pixelRatio` ≤ 1.25.

Huecos a cerrar:

1. Android no emite el evento `perf`: la fase 1 de `--gates` sale
   `SIN_DATOS`.
2. Ninguna adaptación al dispositivo (resolución, modelo, FPS, render, calor).
3. Mensajes técnicos del visor (`norm_version`, `secuencia invalida`, …)
   pueden verse en la app.

## Niveles

| | `bajo` | `medio` | `alto` |
|---|---|---|---|
| Resolución de análisis | 240×320 | 360×480 | 360×480 |
| Modelo | Holistic si inferencia p95 < 60 ms; si no Pose lite + Hand | Holistic | Holistic |
| Cara (`face_pts`) | apagada | encendida | encendida |
| FPS máx. de captura | 15 | 24 | 30 |
| Render avatar | 30 FPS, `pixelRatio` 0.75 | 30 FPS, 1.0 | 60 FPS, 1.25 |
| Presupuesto inferencia p95 | 60 ms | 40 ms | 33 ms |

### Decisión

1. **Nivel inicial** (al abrir la cámara): RAM total < 3 GB o GPU no
   disponible → `bajo`; RAM < 6 GB → `medio`; resto → `alto`.
2. **Medición**: tras los primeros 60 frames, si la p95 de inferencia supera
   el presupuesto del nivel, baja uno. Se reevalúa por ventanas de 60 frames.
3. **Térmico** (API 29+): `THERMAL_STATUS_MODERATE` o superior baja un
   nivel; `THERMAL_STATUS_NONE` sostenido 30 s permite subir uno (sin pasar
   del nivel inicial).
4. **Histéresis**: tras cualquier cambio, 10 s sin otro cambio.
5. **Persistencia**: el último nivel estable se guarda en
   `SharedPreferences` y es el punto de partida la siguiente vez (acotado por
   el nivel inicial por hardware).
6. **Fallo**: si la sonda falla o falta la API → `medio`. Si Holistic no
   carga ni en CPU → Pose + Hand (comportamiento actual).

## Componentes

### Kotlin (`senas_core/android/.../com/univoz/senas/`, copia a `univoz` con `tools/sincronizar_kotlin.py`)

- **`DeviceTier.kt`** (nuevo, puro, sin APIs Android): entrada
  `{ramMb, cores, gpuOk, inferP95Ms, thermal, ahoraMs}`; salida nivel +
  `TierConfig {analisisW, analisisH, modelo, fpsMax, cara, renderFps,
  pixelRatio}`. Implementa las reglas 1–4.
- **`DeviceProbe.kt`** (nuevo, delgado): lee `ActivityManager.MemoryInfo`,
  `Runtime.availableProcessors()`, `PowerManager` (listener térmico, API
  29+) y alimenta a `DeviceTier`.
- **`LandmarkPlugin.kt`**: `RESOLUCION_ANALISIS` pasa a venir del nivel;
  cambio de nivel re-enlaza `ImageAnalysis`. Tope de FPS descartando frames
  por tiempo antes de la inferencia.
- **`LandmarkEngine.kt`**: elige Holistic o Pose + Hand por nivel; sin cara
  no emite `face_pts`; mide `inferMs` por frame para `DeviceTier`.

### Contrato `sourceMeta` (documentar en `docs/02-contratos-y-datos.md`)

Campos nuevos, opcionales:

- `tier`: `"bajo" | "medio" | "alto"`.
- `infer_ms`: número, inferencia del frame.
- `thermal`: entero 0–6 (`PowerManager.THERMAL_STATUS_*`) o `null`.

### Visor (`senas_core/assets/avatar_viewer/`, copia con `tools/inline_viewer_modules.py`)

- **`rig_device_tier.mjs`** (nuevo): `renderBudgetForTier(tier)` →
  `{frameIntervalMs, pixelRatio}`; nivel desconocido → `alto`.
- **`animar()`**: sigue con `requestAnimationFrame` pero salta frames hasta
  cumplir `frameIntervalMs`; `renderer.setPixelRatio()` se aplica al cambiar
  `sourceMeta.tier`. En web, `?tier=` fuerza el nivel.
- **`perf` embebido**: mismo contenido que `eventoPerfSesion()` usando las
  métricas del camino `aplicarFrameVivo`, más `tier`, `infer_ms`, `thermal`.
  Se envía cada segundo como `perf:<json>` por `SenasChannel` solo si Dart
  activó la sesión con `window.configurarSesion(true|false)`.
- **`avisar(msg, {tecnico})`**: en modo embebido los mensajes técnicos no se
  pintan; quedan en sesión/audit. Los de usuario (fallo al cargar avatar +
  Reintentar) sí se ven. En web se ven todos.

### Dart

- **`AvatarBridge`** (`senas_core/lib/avatar_bridge.dart`): maneja
  `perf:` → callback `onPerf`; método `configurarSesion(bool)`.
- Pantallas con cámara/avatar (`comunicarse`, `aprender`,
  `traducir_senas`): conectan `onPerf` a `SesionCaptura.evento('perf', …)`,
  llaman `configurarSesion` según el consentimiento; se revisa que no quede
  ningún control técnico expuesto.
- En `bajo`, aviso único: "Modo ahorro: el avatar se mueve más simple en
  este teléfono".

## Pruebas

1. JUnit `DeviceTierTest`: nivel inicial, degradación por inferencia,
   térmico, histéresis, recuperación, tope por nivel inicial.
2. `rig-tests`: `renderBudgetForTier` y nivel desconocido.
3. Dart: `AvatarBridge` enruta `perf:` a `onPerf`.
4. `test_analizar_sesion.py`: sesión Android de ejemplo con `perf` + `tier`
   → `--gates` fase 1 deja de ser `SIN_DATOS`.
5. Paridad de cara: `FACE_KEYPOINTS` (Kotlin) = `kCaraClave` = índices de
   `rig_face`.
6. `./scripts/univoz.sh test` en verde.
7. Compilar APK: `cd univoz && flutter build apk --debug`.
8. Físico (usuario): teléfono gama baja y media, protocolo `docs/09`,
   `analizar_sesion.py --gates`.

## Fuera de alcance

- Render nativo (Filament/SceneView).
- Captura web dentro del WebView.
- Cambios al laboratorio web salvo `?tier=`.
- Ajuste fino de umbrales (sale de la prueba física).
