# Android: niveles por dispositivo y paridad con el laboratorio — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Que la app `univoz` se adapte sola al teléfono (nivel bajo/medio/alto), emita el evento `perf` de sesión desde Android, no muestre controles técnicos, y termine en un APK de depuración para probar.

**Architecture:** La captura nativa (Kotlin, CameraX + MediaPipe) decide el nivel con una clase pura (`DeviceTier`) alimentada por una sonda delgada (`DeviceProbe`) y aplica resolución, modelo, tope de FPS y cara. El nivel viaja por el canal de landmarks → Dart (`LandmarkFrame`) → `sourceMeta` → visor WebView, que ajusta FPS de render y `pixelRatio` y arma el evento `perf`, que vuelve a Dart por `SenasChannel` y se escribe en la sesión.

**Tech Stack:** Kotlin (JUnit 4), Flutter/Dart (`flutter test`), JavaScript ES modules (`node --test`), Python (`pytest`), Gradle.

**Spec:** `docs/superpowers/specs/2026-10-05-android-niveles-dispositivo-design.md`

## Global Constraints

- Niveles y valores exactos: `bajo` 240×320, 15 FPS, sin cara, render 30 FPS / `pixelRatio` 0.75, presupuesto 60 ms; `medio` 360×480, 24 FPS, cara, 30 FPS / 1.0, 40 ms; `alto` 360×480, 30 FPS, cara, 60 FPS / 1.25, 33 ms.
- Nivel inicial: sonda falla (RAM ≤ 0) → `medio`; RAM < 3 GB o sin GPU → `bajo`; RAM < 6 GB → `medio`; resto → `alto`.
- Ventana de medición: 60 frames. Histéresis: 10 s. Recuperación térmica: `THERMAL_STATUS_NONE` (0) sostenido 30 s. Baja con `THERMAL_STATUS_MODERATE` (2) o mayor.
- En `bajo`, si Holistic no cumple 60 ms p95 → Pose lite + Hand (`separado`).
- Valores de cable del nivel: `"bajo" | "medio" | "alto"`. Campos nuevos en `sourceMeta`: `tier`, `infer_ms`, `thermal` (0–6 o `null`).
- El laboratorio web no cambia salvo `?tier=`.
- Toda copia a `univoz/` se hace con `python3 senas_core/tools/sincronizar_kotlin.py` y `python3 senas_core/tools/inline_viewer_modules.py`; nunca a mano.
- Aviso de nivel bajo (texto exacto): `Modo ahorro: el avatar se mueve más simple en este teléfono`.
- Comentarios en español, como el código existente. Commits en inglés con prefijo convencional y la línea `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Nivel desconocido o basura en `sourceMeta.tier` (versión vieja del plugin, `null`, número) → el visor usa `alto`, nunca lanza. Test en Task 4.
2. Teléfono con API < 29 (sin estado térmico) → `thermal` = `null`, el nivel no cambia por calor y nada falla. Test en Task 1.
3. Nivel guardado mayor que el techo del hardware (respaldo restaurado en otro teléfono) → se recorta al techo. Test en Task 1.
4. Mensaje `perf:` corrupto o que no es objeto JSON → se ignora, sin excepción. Test en Task 6.
5. Teléfono que bajó por inferencia y luego se enfría → no vuelve a subir por encima de lo que la inferencia permitió (evita vaivén). Test en Task 1.

## Notas de alcance respecto al spec

- El único lugar donde la cámara en vivo mueve al avatar es `PantallaEspejo` (`senas_core/lib/pantalla_espejo.dart`), que `univoz` abre desde `traducir_senas_screen.dart`. `comunicarse` y `aprender` solo reproducen señas grabadas, así que no emiten `perf`. El nivel igual aplica a toda captura porque vive en Kotlin.
- El estado térmico se consulta una vez por segundo con `PowerManager.currentThermalStatus` en vez de usar un listener: `NONE` sostenido necesita reloj de todos modos.

## Estructura de archivos

| Archivo | Acción | Responsabilidad |
|---|---|---|
| `senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceTier.kt` | Crear | Lógica pura de niveles y tope de FPS |
| `senas_core/android/app/src/test/kotlin/com/univoz/senas/DeviceTierTest.kt` | Crear | Pruebas JUnit |
| `senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceProbe.kt` | Crear | RAM, estado térmico, persistencia |
| `senas_core/android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt` | Modificar | `forzadoSeparado`, `gpuOk`, `conCara`, medir inferencia |
| `senas_core/android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt` | Modificar | Aplicar nivel, re-enlazar, tope de FPS, payload |
| `senas_core/tools/sincronizar_kotlin.py` | Modificar | Copiar los dos archivos nuevos |
| `senas_core/lib/camera_bridge.dart` | Modificar | `LandmarkFrame.tier/inferMs/thermal` |
| `senas_core/test/landmark_frame_contract_test.dart` | Modificar | Prueba de los campos |
| `senas_core/assets/avatar_viewer/rig_device_tier.mjs` | Crear | Presupuesto de render por nivel |
| `senas_core/assets/avatar_viewer/rig_embedded_perf.mjs` | Crear | Evento `perf` del visor embebido |
| `senas_core/tools/rig-tests/rig_device_tier.test.mjs` | Crear | Pruebas |
| `senas_core/tools/rig-tests/rig_embedded_perf.test.mjs` | Crear | Pruebas |
| `senas_core/tools/inline_viewer_modules.py` | Modificar | Registrar módulos nuevos |
| `senas_core/assets/avatar_viewer/index.html` | Modificar | Integrar render, `perf`, `configurarSesion`, `avisar` técnico |
| `senas_core/lib/avatar_bridge.dart` | Modificar | `onPerf`, `configurarSesion`, `decodificarPerf` |
| `senas_core/test/avatar_perf_test.dart` | Crear | Prueba de `decodificarPerf` |
| `senas_core/lib/pantalla_espejo.dart` | Modificar | `modoProducto`, `perf` → sesión, `sourceMeta` |
| `univoz/lib/screens/traducir_senas_screen.dart` | Modificar | Abrir espejo en `modoProducto` |
| `senas_core/tools/analizar_sesion.py` | Modificar | Reportar niveles vistos en fase 1 |
| `senas_core/tools/test_analizar_sesion.py` | Modificar | Sesión Android con `perf` |
| `senas_core/tools/test_paridad_cara.py` | Crear | Índices de cara iguales en las 3 capas |
| `docs/02-contratos-y-datos.md` | Modificar | Documentar campos nuevos |

---

### Task 1: `DeviceTier` (lógica pura de niveles)

**Files:**
- Create: `senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceTier.kt`
- Create: `senas_core/android/app/src/test/kotlin/com/univoz/senas/DeviceTierTest.kt`
- Modify: `senas_core/tools/sincronizar_kotlin.py` (lista `ARCHIVOS`)

**Interfaces:**
- Produces:
  - `enum class Nivel(val wire: String) { BAJO, MEDIO, ALTO }` con `bajar()`, `subir()`, `Nivel.desdeWire(String?): Nivel?`.
  - `data class TierConfig(analisisAncho: Int, analisisAlto: Int, fpsMax: Int, cara: Boolean, presupuestoMs: Double)`.
  - `class DeviceTier(techo: Nivel, inicio: Nivel = techo, separado: Boolean = false)` con `nivel: Nivel`, `separado: Boolean`, `techoInferencia: Nivel`, `termicoActual: Int?`, `config: TierConfig`, `registrarInferencia(ms: Double, ahoraMs: Long): Boolean`, `registrarTermico(estado: Int?, ahoraMs: Long): Boolean`.
  - `DeviceTier.config(Nivel)`, `DeviceTier.nivelInicial(ramMb: Long, gpuOk: Boolean): Nivel`, `DeviceTier.admitirFrame(siguienteMs: Double, tMs: Long, fpsMax: Int): Double?`.

- [ ] **Step 1: Escribir la prueba que falla**

`senas_core/android/app/src/test/kotlin/com/univoz/senas/DeviceTierTest.kt`:

```kotlin
package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceTierTest {
    private fun ventana(t: DeviceTier, ms: Double, ahoraMs: Long): Boolean {
        var cambio = false
        repeat(DeviceTier.VENTANA_FRAMES) { cambio = t.registrarInferencia(ms, ahoraMs) || cambio }
        return cambio
    }

    @Test fun nivelInicialPorHardware() {
        assertEquals(Nivel.BAJO, DeviceTier.nivelInicial(2048, true))
        assertEquals(Nivel.BAJO, DeviceTier.nivelInicial(4096, false))
        assertEquals(Nivel.MEDIO, DeviceTier.nivelInicial(4096, true))
        assertEquals(Nivel.ALTO, DeviceTier.nivelInicial(8192, true))
        // Sonda fallida: medio, aunque la GPU no se sepa.
        assertEquals(Nivel.MEDIO, DeviceTier.nivelInicial(-1, false))
    }

    @Test fun configuracionPorNivel() {
        assertEquals(TierConfig(240, 320, 15, false, 60.0), DeviceTier.config(Nivel.BAJO))
        assertEquals(TierConfig(360, 480, 24, true, 40.0), DeviceTier.config(Nivel.MEDIO))
        assertEquals(TierConfig(360, 480, 30, true, 33.0), DeviceTier.config(Nivel.ALTO))
    }

    @Test fun wire() {
        assertEquals("bajo", Nivel.BAJO.wire)
        assertEquals(Nivel.MEDIO, Nivel.desdeWire("medio"))
        assertNull(Nivel.desdeWire("ultra"))
        assertNull(Nivel.desdeWire(null))
    }

    @Test fun inicioGuardadoSeRecortaAlTecho() {
        val t = DeviceTier(techo = Nivel.MEDIO, inicio = Nivel.ALTO)
        assertEquals(Nivel.MEDIO, t.nivel)
        assertEquals(Nivel.MEDIO, t.techoInferencia)
    }

    @Test fun separadoGuardadoSoloAplicaEnBajo() {
        assertFalse(DeviceTier(Nivel.MEDIO, separado = true).separado)
        assertTrue(DeviceTier(Nivel.BAJO, separado = true).separado)
    }

    @Test fun ventanaIncompletaNoDecide() {
        val t = DeviceTier(Nivel.ALTO)
        repeat(DeviceTier.VENTANA_FRAMES - 1) { assertFalse(t.registrarInferencia(90.0, 20_000)) }
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun dentroDelPresupuestoNoCambia() {
        val t = DeviceTier(Nivel.ALTO)
        assertFalse(ventana(t, 30.0, 20_000))
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun inferenciaLentaBajaUnNivelConHisteresis() {
        val t = DeviceTier(Nivel.ALTO)
        assertTrue(ventana(t, 50.0, 20_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        assertEquals(Nivel.MEDIO, t.techoInferencia)
        // 5 s despues: dentro de la histeresis, no baja otra vez.
        assertFalse(ventana(t, 50.0, 25_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        // 11 s despues: 50 ms > 40 ms de medio, baja a bajo.
        assertTrue(ventana(t, 50.0, 31_000))
        assertEquals(Nivel.BAJO, t.nivel)
    }

    @Test fun enBajoHolisticLentoPasaASeparado() {
        val t = DeviceTier(Nivel.BAJO)
        assertTrue(ventana(t, 80.0, 20_000))
        assertEquals(Nivel.BAJO, t.nivel)
        assertTrue(t.separado)
        assertFalse(ventana(t, 80.0, 40_000))
    }

    @Test fun inferenciaInvalidaSeIgnora() {
        val t = DeviceTier(Nivel.ALTO)
        repeat(100) { assertFalse(t.registrarInferencia(Double.NaN, 20_000)) }
        repeat(100) { assertFalse(t.registrarInferencia(-5.0, 20_000)) }
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun calorBajaYEnfriarSostenidoSube() {
        val t = DeviceTier(Nivel.ALTO)
        assertTrue(t.registrarTermico(2, 20_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        assertFalse(t.registrarTermico(0, 21_000))
        assertFalse(t.registrarTermico(0, 40_000))
        assertTrue(t.registrarTermico(0, 51_001))
        assertEquals(Nivel.ALTO, t.nivel)
        // Ya en el techo: no sube mas.
        assertFalse(t.registrarTermico(0, 200_000))
    }

    @Test fun calorLigeroNiBajaNiSube() {
        val t = DeviceTier(Nivel.ALTO)
        assertTrue(t.registrarTermico(2, 20_000))
        assertFalse(t.registrarTermico(0, 21_000))
        // LIGHT (1) corta la racha de NONE.
        assertFalse(t.registrarTermico(1, 40_000))
        assertFalse(t.registrarTermico(0, 52_000))
        assertEquals(Nivel.MEDIO, t.nivel)
    }

    @Test fun enfriarNoSubePorEncimaDeLoQuePermitioLaInferencia() {
        val t = DeviceTier(Nivel.ALTO)
        assertTrue(ventana(t, 50.0, 20_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        assertFalse(t.registrarTermico(0, 31_000))
        assertFalse(t.registrarTermico(0, 70_000))
        assertEquals(Nivel.MEDIO, t.nivel)
    }

    @Test fun sinApiTermicaNoHaceNada() {
        val t = DeviceTier(Nivel.ALTO)
        assertFalse(t.registrarTermico(null, 20_000))
        assertNull(t.termicoActual)
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun calorEnBajoNoBajaMas() {
        val t = DeviceTier(Nivel.BAJO)
        assertFalse(t.registrarTermico(4, 20_000))
        assertEquals(Nivel.BAJO, t.nivel)
        assertEquals(4, t.termicoActual)
    }

    private fun admitidos(fpsMax: Int, fuenteFps: Int = 30, segundos: Int = 3): Int {
        var siguiente = 0.0
        var n = 0
        for (i in 0 until fuenteFps * segundos) {
            val t = Math.round(i * 1000.0 / fuenteFps)
            val nuevo = DeviceTier.admitirFrame(siguiente, t, fpsMax) ?: continue
            siguiente = nuevo
            n++
        }
        return n
    }

    @Test fun topeDeFpsPromedia() {
        assertEquals(45, admitidos(15))
        assertEquals(72, admitidos(24))
        assertEquals(90, admitidos(30))
        assertEquals(45, admitidos(15, fuenteFps = 60))
    }
}
```

- [ ] **Step 2: Correr la prueba y ver que falla**

Run: `cd senas_core/android && ./gradlew :app:testDebugUnitTest --tests com.univoz.senas.DeviceTierTest`
Expected: FAIL de compilación, `Unresolved reference: DeviceTier`.

- [ ] **Step 3: Implementar**

`senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceTier.kt`:

```kotlin
package com.univoz.senas

import kotlin.math.ceil

/**
 * Nivel de calidad por dispositivo
 * (docs/superpowers/specs/2026-10-05-android-niveles-dispositivo-design.md).
 * Logica pura, sin APIs de Android: DeviceProbe le da los datos del
 * telefono y LandmarkPlugin aplica la configuracion. Orden BAJO < MEDIO < ALTO.
 */
enum class Nivel(val wire: String) {
    BAJO("bajo"), MEDIO("medio"), ALTO("alto");

    fun bajar(): Nivel = if (this == ALTO) MEDIO else BAJO
    fun subir(): Nivel = if (this == BAJO) MEDIO else ALTO

    companion object {
        fun desdeWire(s: String?): Nivel? = values().firstOrNull { it.wire == s }
    }
}

data class TierConfig(
    val analisisAncho: Int,
    val analisisAlto: Int,
    val fpsMax: Int,
    val cara: Boolean,
    /** p95 de inferencia por encima del cual se baja de nivel. */
    val presupuestoMs: Double,
)

class DeviceTier(
    /** Maximo que permite el hardware (nivelInicial). */
    val techo: Nivel,
    inicio: Nivel = techo,
    separado: Boolean = false,
) {
    companion object {
        const val VENTANA_FRAMES = 60
        const val HISTERESIS_MS = 10_000L
        const val RECUPERACION_MS = 30_000L
        /** PowerManager.THERMAL_STATUS_NONE / THERMAL_STATUS_MODERATE. */
        const val TERMICO_NINGUNO = 0
        const val TERMICO_MODERADO = 2

        fun config(n: Nivel): TierConfig = when (n) {
            Nivel.BAJO -> TierConfig(240, 320, 15, false, 60.0)
            Nivel.MEDIO -> TierConfig(360, 480, 24, true, 40.0)
            Nivel.ALTO -> TierConfig(360, 480, 30, true, 33.0)
        }

        fun nivelInicial(ramMb: Long, gpuOk: Boolean): Nivel = when {
            ramMb <= 0 -> Nivel.MEDIO // la sonda fallo
            ramMb < 3 * 1024 || !gpuOk -> Nivel.BAJO
            ramMb < 6 * 1024 -> Nivel.MEDIO
            else -> Nivel.ALTO
        }

        /**
         * Tope de FPS sobre los timestamps de la camara. null = descartar el
         * frame; si no, el proximo instante permitido. La tolerancia de un
         * cuarto de intervalo absorbe el jitter de la camara sin pasarse
         * del promedio (DeviceTierTest.topeDeFpsPromedia).
         */
        fun admitirFrame(siguienteMs: Double, tMs: Long, fpsMax: Int): Double? {
            val intervalo = 1000.0 / fpsMax.coerceAtLeast(1)
            if (tMs + intervalo * .25 < siguienteMs) return null
            return if (tMs - siguienteMs > intervalo) tMs + intervalo else siguienteMs + intervalo
        }

        private fun p95(v: List<Double>): Double {
            val orden = v.sorted()
            return orden[(ceil(orden.size * .95).toInt() - 1).coerceIn(0, orden.size - 1)]
        }
    }

    var nivel: Nivel = minOf(inicio, techo)
        private set

    /** En BAJO, Holistic no cumple su presupuesto: usar Pose lite + Hand. */
    var separado: Boolean = separado && nivel == Nivel.BAJO
        private set

    /**
     * Lo maximo que la inferencia medida permite. El calor puede bajar y
     * volver a subir, pero nunca por encima de esto (evita vaiven).
     */
    var techoInferencia: Nivel = nivel
        private set

    var termicoActual: Int? = null
        private set

    val config: TierConfig get() = config(nivel)

    private val muestras = ArrayList<Double>(VENTANA_FRAMES)
    private var ultimoCambioMs = Long.MIN_VALUE / 2
    private var ningunoDesdeMs: Long? = null

    /** True si cambio el nivel o el modo separado. */
    fun registrarInferencia(ms: Double, ahoraMs: Long): Boolean {
        if (!ms.isFinite() || ms < 0) return false
        muestras += ms
        if (muestras.size < VENTANA_FRAMES) return false
        val medido = p95(muestras)
        muestras.clear()
        if (ahoraMs - ultimoCambioMs < HISTERESIS_MS) return false
        if (medido <= config.presupuestoMs) return false
        if (nivel == Nivel.BAJO) {
            if (separado) return false
            separado = true
        } else {
            nivel = nivel.bajar()
            techoInferencia = nivel
        }
        ultimoCambioMs = ahoraMs
        return true
    }

    /** [estado]: PowerManager.THERMAL_STATUS_* o null sin API (< 29). */
    fun registrarTermico(estado: Int?, ahoraMs: Long): Boolean {
        termicoActual = estado
        if (estado == null) return false
        if (estado >= TERMICO_MODERADO) {
            ningunoDesdeMs = null
            if (nivel == Nivel.BAJO || ahoraMs - ultimoCambioMs < HISTERESIS_MS) return false
            nivel = nivel.bajar()
            ultimoCambioMs = ahoraMs
            return true
        }
        if (estado != TERMICO_NINGUNO) {
            ningunoDesdeMs = null
            return false
        }
        val desde = ningunoDesdeMs ?: ahoraMs.also { ningunoDesdeMs = it }
        if (ahoraMs - desde < RECUPERACION_MS) return false
        if (nivel >= minOf(techo, techoInferencia)) return false
        if (ahoraMs - ultimoCambioMs < HISTERESIS_MS) return false
        nivel = nivel.subir()
        ultimoCambioMs = ahoraMs
        ningunoDesdeMs = ahoraMs
        return true
    }
}
```

En `senas_core/tools/sincronizar_kotlin.py`, cambiar la lista:

```python
ARCHIVOS = ["LandmarkPlugin.kt", "LandmarkEngine.kt", "HandTrackCoordinator.kt",
            "HandCandidateGate.kt", "DeviceTier.kt", "DeviceProbe.kt"]
```

(`DeviceProbe.kt` se crea en Task 2; si el script falla porque no existe, correrlo hasta después de Task 2.)

- [ ] **Step 4: Correr la prueba y ver que pasa**

Run: `cd senas_core/android && ./gradlew :app:testDebugUnitTest --tests com.univoz.senas.DeviceTierTest`
Expected: PASS, 16 pruebas.

- [ ] **Step 5: Commit**

```bash
git add senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceTier.kt \
        senas_core/android/app/src/test/kotlin/com/univoz/senas/DeviceTierTest.kt \
        senas_core/tools/sincronizar_kotlin.py
git commit -m "feat(android): device tier rules for capture quality"
```

---

### Task 2: Motor y cámara por nivel (`DeviceProbe`, `LandmarkEngine`, `LandmarkPlugin`)

**Files:**
- Create: `senas_core/android/app/src/main/kotlin/com/univoz/senas/DeviceProbe.kt`
- Modify: `senas_core/android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt`
- Modify: `senas_core/android/app/src/main/kotlin/com/univoz/senas/LandmarkPlugin.kt`
- Copias: `univoz/android/app/src/main/kotlin/*.kt` (vía script)

**Interfaces:**
- Consumes: todo lo de Task 1.
- Produces:
  - `DeviceProbe(context)`: `ramMb(): Long`, `termico(): Int?`, `nivelGuardado(): Nivel?`, `separadoGuardado(): Boolean`, `guardar(techo: Nivel, separado: Boolean)`.
  - `LandmarkEngine(..., onInferencia: (Double) -> Unit = {}, forzadoSeparado: Boolean = false)` con `val gpuOk: Boolean`, `@Volatile var conCara: Boolean`, `FrameResult.inferMs: Double?`.
  - Payload del canal `univoz/landmarks(_preview)` gana `tier: String`, `infer_ms: Double?`, `thermal: Int?` (los consume Task 3).

Sin pruebas unitarias nuevas: la lógica decisoria ya está probada en Task 1; aquí solo se cablea. La verificación es compilación + suite JUnit existente + prueba en teléfono (Task 8).

- [ ] **Step 1: Crear `DeviceProbe.kt`**

```kotlin
package com.univoz.senas

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.os.PowerManager

/**
 * Lo que DeviceTier necesita saber del telefono. Cualquier fallo devuelve un
 * valor neutro: RAM -1 (DeviceTier.nivelInicial -> medio), termico null.
 */
class DeviceProbe(private val context: Context) {
    private val prefs = context.getSharedPreferences("univoz_device_tier", Context.MODE_PRIVATE)

    fun ramMb(): Long = try {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        info.totalMem / (1024 * 1024)
    } catch (e: Exception) {
        -1
    }

    fun termico(): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return try {
            (context.getSystemService(Context.POWER_SERVICE) as PowerManager).currentThermalStatus
        } catch (e: Exception) {
            null
        }
    }

    /** Ultimo techo aprendido por inferencia en este telefono. */
    fun nivelGuardado(): Nivel? = Nivel.desdeWire(prefs.getString("techo", null))

    fun separadoGuardado(): Boolean = prefs.getBoolean("separado", false)

    fun guardar(techo: Nivel, separado: Boolean) {
        prefs.edit().putString("techo", techo.wire).putBoolean("separado", separado).apply()
    }
}
```

- [ ] **Step 2: `LandmarkEngine.kt` — constructor, GPU, cara e inferencia**

Constructor (reemplazar la firma actual):

```kotlin
class LandmarkEngine(
    context: Context,
    private val onFrame: (FrameResult) -> Unit,
    private val onPreview: (FrameResult) -> Unit,
    private val onError: (String) -> Unit,
    /** ms de inferencia de cada resultado (Holistic, o manos en separado). */
    private val onInferencia: (Double) -> Unit = {},
    /** true: no intentar Holistic (nivel bajo con Holistic lento). */
    val forzadoSeparado: Boolean = false,
) {
```

En `FrameResult`, agregar al final de los parámetros:

```kotlin
        val captureMode: String = "separado",
        /** Inferencia del ultimo resultado, ms (nivel por dispositivo). */
        val inferMs: Double? = null,
    )
```

Junto a `val holisticActivo`, agregar los campos y cambiar `init`:

```kotlin
    /** El modelo cargo con delegado GPU (entra a DeviceTier.nivelInicial). */
    var gpuOk = false
        private set

    /** false en nivel bajo: no se mandan puntos de cara. */
    @Volatile var conCara = true

    @Volatile private var ultimaInferenciaMs: Double? = null

    val holisticActivo: Boolean get() = holisticLandmarker != null

    init {
        holisticLandmarker = if (forzadoSeparado) null else crearHolistic(context)
        if (holisticLandmarker == null) crearSeparados(context)
    }
```

En `crearHolistic`, justo antes de `return HolisticLandmarker.createFromOptions(context, options)`, reemplazar esa línea por:

```kotlin
                val creado = HolisticLandmarker.createFromOptions(context, options)
                gpuOk = delegate == Delegate.GPU
                return creado
```

Al final de `crearSeparados`, después de crear ambos landmarkers:

```kotlin
        gpuOk = true
```

Al inicio de `onHolistic`, reemplazar `synchronized(holisticLock) { holisticEnVuelo = false }` por:

```kotlin
        val inferMs = synchronized(holisticLock) {
            holisticEnVuelo = false
            (System.nanoTime() - holisticDesdeNs) / 1e6
        }
        ultimaInferenciaMs = inferMs
        onInferencia(inferMs)
```

y la condición de cara (`val cara = if (caraLm.size > 400) ...`) pasa a:

```kotlin
        val cara = if (conCara && caraLm.size > 400) DoubleArray(FACE_KEYPOINTS.size * 3).also {
```

En `onManos` (línea con `synchronized(manosLock) { manosEnVuelo = false }`), reemplazar por:

```kotlin
        val inferMs = synchronized(manosLock) {
            manosEnVuelo = false
            (System.nanoTime() - manosDesdeNs) / 1e6
        }
        ultimaInferenciaMs = inferMs
        onInferencia(inferMs)
```

En `crearFrame`, en la construcción final de `FrameResult`, agregar después de `captureMode = ...`:

```kotlin
            inferMs = ultimaInferenciaMs,
```

- [ ] **Step 3: `LandmarkPlugin.kt` — nivel, re-enlace y tope de FPS**

Imports nuevos:

```kotlin
import android.os.SystemClock
```

En el `companion object`, borrar `RESOLUCION_ANALISIS` y su comentario (la resolución ahora sale del nivel).

Campos nuevos y cambios (junto a los existentes):

```kotlin
    @Volatile private var engine: LandmarkEngine? = null
    @Volatile private var sessionToken = 0L
    private val probe = DeviceProbe(context)
    // Solo se toca en el hilo principal.
    private var tier: DeviceTier? = null
    private var selectorActual: CameraSelector? = null
    private var analysisActual: ImageAnalysis? = null
    private var resolucionActual: Size? = null
    private var ultimoChequeoTermicoMs = 0L
    // Tope de FPS (hilo del ejecutor).
    @Volatile private var fpsMax = 30
    private var siguienteFrameMs = 0.0
```

(`engine` y `sessionToken` ya existen: solo se les agrega `@Volatile`.)

En `iniciar`, reemplazar desde `val analysis = ImageAnalysis.Builder()` hasta `analysis.setAnalyzer(ejecutor) { proxy -> procesar(proxy) }` (inclusive) por:

```kotlin
                var motor = crearMotor(probe.separadoGuardado())
                val techo = DeviceTier.nivelInicial(probe.ramMb(), motor.gpuOk)
                val nivelTier = DeviceTier(techo, probe.nivelGuardado() ?: techo,
                    probe.separadoGuardado())
                if (motor.forzadoSeparado != nivelTier.separado) {
                    motor.cerrar()
                    motor = crearMotor(nivelTier.separado)
                }
                val cfg = nivelTier.config
                motor.conCara = cfg.cara
                fpsMax = cfg.fpsMax
                siguienteFrameMs = 0.0
                engine = motor
                tier = nivelTier
                val resolucion = Size(cfg.analisisAncho, cfg.analisisAlto)
                val analysis = construirAnalisis(resolucion)
                analysisActual = analysis
                resolucionActual = resolucion
```

y justo después de calcular `selector`, agregar:

```kotlin
                selectorActual = selector
```

Funciones nuevas (debajo de `iniciar`):

```kotlin
    private fun crearMotor(forzarSeparado: Boolean) = LandmarkEngine(
        context,
        onFrame = { emitir(it) },
        onPreview = { emitirPreview(it) },
        onError = { msg -> principal.post { sink?.error("mediapipe", msg, null) } },
        onInferencia = { ms -> principal.post { alInferir(ms) } },
        forzadoSeparado = forzarSeparado,
    )

    private fun construirAnalisis(resolucion: Size): ImageAnalysis =
        ImageAnalysis.Builder()
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(
                ResolutionSelector.Builder()
                    .setResolutionStrategy(
                        ResolutionStrategy(
                            resolucion,
                            ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER,
                        )
                    )
                    .build()
            )
            .build()
            .also { it.setAnalyzer(ejecutor) { proxy -> procesar(proxy) } }

    // Hilo principal: DeviceTier no es thread-safe.
    private fun alInferir(ms: Double) {
        val t = tier ?: return
        val ahora = SystemClock.elapsedRealtime()
        var cambio = t.registrarInferencia(ms, ahora)
        if (ahora - ultimoChequeoTermicoMs >= 1000) {
            ultimoChequeoTermicoMs = ahora
            cambio = t.registrarTermico(probe.termico(), ahora) || cambio
        }
        if (cambio) aplicarNivel(t)
    }

    private fun aplicarNivel(t: DeviceTier) {
        probe.guardar(t.techoInferencia, t.separado)
        val cfg = t.config
        val sesion = sessionToken
        val separado = t.separado
        fpsMax = cfg.fpsMax
        engine?.conCara = cfg.cara
        // Cambiar de modelo en el hilo del ejecutor: procesar() corre ahi,
        // asi nunca usa un motor cerrado.
        ejecutor.execute {
            val motor = engine
            if (sesion != sessionToken || motor == null ||
                motor.forzadoSeparado == separado) return@execute
            motor.cerrar()
            engine = crearMotor(separado).also { it.conCara = cfg.cara }
        }
        val resolucion = Size(cfg.analisisAncho, cfg.analisisAlto)
        if (resolucion != resolucionActual) reenlazarAnalisis(resolucion)
    }

    private fun reenlazarAnalisis(resolucion: Size) {
        val provider = cameraProvider ?: return
        val selector = selectorActual ?: return
        val anterior = analysisActual ?: return
        val nueva = construirAnalisis(resolucion)
        try {
            provider.unbind(anterior)
            provider.bindToLifecycle(lifecycleOwner, selector, nueva)
            analysisActual = nueva
            resolucionActual = resolucion
        } catch (e: Exception) {
            // Si el tamano nuevo no enlaza, seguir con el anterior.
            try {
                provider.bindToLifecycle(lifecycleOwner, selector, anterior)
            } catch (_: Exception) {
            }
            sink?.error("analisis", "tier_rebind_failed", null)
        }
    }
```

En `procesar`, rama Holistic: después de `if (motor.holisticOcupado()) return`, agregar:

```kotlin
                val siguiente = DeviceTier.admitirFrame(
                    siguienteFrameMs, proxy.imageInfo.timestamp / 1_000_000, fpsMax) ?: return
                siguienteFrameMs = siguiente
```

Rama separada: después de `if (!manosLibres && !tocaPose) return`, agregar el mismo bloque:

```kotlin
            val siguiente = DeviceTier.admitirFrame(
                siguienteFrameMs, proxy.imageInfo.timestamp / 1_000_000, fpsMax) ?: return
            siguienteFrameMs = siguiente
```

(`return` dentro de `try` igual pasa por `finally { proxy.close() }`.)

En `aMapa`, cambiar la capacidad a `HashMap<String, Any?>(20)` y agregar antes de `return payload`:

```kotlin
        // Nivel por dispositivo: el visor ajusta su render y lo registra en perf.
        payload["tier"] = tier?.nivel?.wire
        payload["infer_ms"] = f.inferMs
        payload["thermal"] = tier?.termicoActual
```

En `limpiarRecursos`, agregar al final:

```kotlin
        tier = null
        analysisActual = null
        selectorActual = null
        resolucionActual = null
        siguienteFrameMs = 0.0
```

- [ ] **Step 4: Sincronizar y compilar**

Run:
```bash
python3 senas_core/tools/sincronizar_kotlin.py
python3 senas_core/tools/sincronizar_kotlin.py --check
cd senas_core/android && ./gradlew :app:compileDebugKotlin :app:testDebugUnitTest
cd ../../univoz/android && ./gradlew :app:compileDebugKotlin
```
Expected: `--check` sin diferencias; ambas compilaciones `BUILD SUCCESSFUL`; JUnit verde (DeviceTierTest, HandCandidateGateTest, HandTrackCoordinatorTest).

- [ ] **Step 5: Commit**

```bash
git add senas_core/android/app/src/main/kotlin/com/univoz/senas/ univoz/android/app/src/main/kotlin/
git commit -m "feat(android): apply device tier to capture resolution, model, fps and face"
```

---

### Task 3: `LandmarkFrame` lleva el nivel

**Files:**
- Modify: `senas_core/lib/camera_bridge.dart` (clase `LandmarkFrame`)
- Test: `senas_core/test/landmark_frame_contract_test.dart`

**Interfaces:**
- Consumes: claves `tier`, `infer_ms`, `thermal` del mapa nativo (Task 2).
- Produces: `LandmarkFrame.tier: String?`, `LandmarkFrame.inferMs: double?`, `LandmarkFrame.thermal: int?` (los consume Task 6).

- [ ] **Step 1: Escribir la prueba que falla**

Agregar al final de `main()` en `senas_core/test/landmark_frame_contract_test.dart`:

```dart
  test('fromMap lee nivel, inferencia y estado térmico del nativo', () {
    final f = LandmarkFrame.fromMap(
        {'t': 1, 'tier': 'bajo', 'infer_ms': 41.5, 'thermal': 2});
    expect(f.tier, 'bajo');
    expect(f.inferMs, 41.5);
    expect(f.thermal, 2);
    final json = f.toJson();
    expect(json['tier'], 'bajo');
    expect(json['infer_ms'], 41.5);
    expect(json['thermal'], 2);

    // Plugin viejo o API < 29: campos ausentes o de tipo equivocado.
    final viejo = LandmarkFrame.fromMap({'t': 1, 'tier': 3, 'thermal': null});
    expect(viejo.tier, isNull);
    expect(viejo.inferMs, isNull);
    expect(viejo.thermal, isNull);
    expect(viejo.toJson().containsKey('tier'), isFalse);
  });
```

- [ ] **Step 2: Correr y ver que falla**

Run: `cd senas_core && flutter test test/landmark_frame_contract_test.dart`
Expected: FAIL, `The getter 'tier' isn't defined for the type 'LandmarkFrame'`.

- [ ] **Step 3: Implementar**

En `LandmarkFrame`, después de `final double? imageAspect;`:

```dart
  /// Nivel por dispositivo ('bajo' | 'medio' | 'alto'), DeviceTier.kt.
  final String? tier;

  /// Inferencia del ultimo resultado nativo, ms.
  final double? inferMs;

  /// PowerManager.THERMAL_STATUS_* (0-6); null sin API (Android < 10).
  final int? thermal;
```

En el constructor, después de `this.imageAspect,`:

```dart
    this.tier,
    this.inferMs,
    this.thermal,
```

En `fromMap`, después de `imageAspect: _aspecto(map['image_w'], map['image_h']),`:

```dart
      tier: map['tier'] is String ? map['tier'] as String : null,
      inferMs: (map['infer_ms'] as num?)?.toDouble(),
      thermal: (map['thermal'] as num?)?.toInt(),
```

En `toJson`, después de la línea de `image_aspect`:

```dart
        if (tier != null) 'tier': tier,
        if (inferMs != null) 'infer_ms': inferMs,
        if (thermal != null) 'thermal': thermal,
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `cd senas_core && flutter test test/landmark_frame_contract_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add senas_core/lib/camera_bridge.dart senas_core/test/landmark_frame_contract_test.dart
git commit -m "feat(capture): carry device tier, inference time and thermal state"
```

---

### Task 4: Módulos del visor (`rig_device_tier`, `rig_embedded_perf`)

**Files:**
- Create: `senas_core/assets/avatar_viewer/rig_device_tier.mjs`
- Create: `senas_core/assets/avatar_viewer/rig_embedded_perf.mjs`
- Create: `senas_core/tools/rig-tests/rig_device_tier.test.mjs`
- Create: `senas_core/tools/rig-tests/rig_embedded_perf.test.mjs`
- Modify: `senas_core/tools/inline_viewer_modules.py` (`MODULES`, `EXPORT_ALL`)

**Interfaces:**
- Produces (nombres en el ámbito de `index.html` tras el inline):
  - `TIER_RENDER`, `renderBudgetForTier(tier) -> {frameIntervalMs, pixelRatio}` (siempre el mismo objeto por nivel; desconocido → `TIER_RENDER.alto`), `shouldRenderFrame(lastRenderAt, now, budget) -> boolean`.
  - `createEmbeddedPerf() -> {frameReceived({frameId, receivedAtMs, inferMs, hasHand, tier, thermal}), frameRendered({frameId, renderedAtMs}), renderTick(), drain(extra = {}) -> object | null, reset()}`.

- [ ] **Step 1: Escribir las pruebas que fallan**

`senas_core/tools/rig-tests/rig_device_tier.test.mjs`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  TIER_RENDER,
  renderBudgetForTier,
  shouldRenderFrame,
} from '../../assets/avatar_viewer/rig_device_tier.mjs';

test('render budget per tier matches the spec', () => {
  assert.deepEqual(renderBudgetForTier('bajo'), {frameIntervalMs: 1000 / 30, pixelRatio: .75});
  assert.deepEqual(renderBudgetForTier('medio'), {frameIntervalMs: 1000 / 30, pixelRatio: 1});
  assert.deepEqual(renderBudgetForTier('alto'), {frameIntervalMs: 1000 / 60, pixelRatio: 1.25});
});

test('unknown tier falls back to alto (same object)', () => {
  for (const tier of [null, undefined, '', 'ULTRA', 3, {}]) {
    assert.equal(renderBudgetForTier(tier), TIER_RENDER.alto);
  }
  assert.equal(renderBudgetForTier('bajo'), TIER_RENDER.bajo);
});

function renders(tier, hz, seconds = 1) {
  const budget = renderBudgetForTier(tier);
  let last = 0;
  let n = 0;
  for (let i = 1; i <= hz * seconds; i++) {
    const t = i * 1000 / hz;
    if (shouldRenderFrame(last, t, budget)) {
      last = t;
      n++;
    }
  }
  return n;
}

test('frame skipping hits the tier fps on 60 and 120 Hz displays', () => {
  assert.equal(renders('medio', 60), 30);
  assert.equal(renders('bajo', 120), 30);
  assert.equal(renders('alto', 60), 60);
  assert.equal(renders('alto', 120), 60);
});
```

`senas_core/tools/rig-tests/rig_embedded_perf.test.mjs`:

```js
import test from 'node:test';
import assert from 'node:assert/strict';

import {createEmbeddedPerf} from '../../assets/avatar_viewer/rig_embedded_perf.mjs';

test('drain is null until a frame arrives', () => {
  const perf = createEmbeddedPerf();
  perf.renderTick();
  assert.equal(perf.drain(), null);
});

test('one second of frames becomes a perf event and resets', () => {
  const perf = createEmbeddedPerf();
  for (let i = 1; i <= 30; i++) {
    perf.frameReceived({frameId: i, receivedAtMs: i * 33, inferMs: 20,
      hasHand: i % 2 === 0, tier: 'medio', thermal: 1});
    perf.frameRendered({frameId: i, renderedAtMs: i * 33 + 10});
  }
  for (let i = 0; i < 30; i++) perf.renderTick();
  const out = perf.drain({safety_codes: {angular_velocity_exceeded: 2}});
  assert.deepEqual(out.fps, {input: 30, inference: 30, tracking: 15, pose: 30, render: 30});
  assert.equal(out.latency_ms.length, 30);
  assert.equal(out.latency_ms[0], 30);
  assert.equal(out.tier, 'medio');
  assert.equal(out.thermal, 1);
  assert.equal(out.infer_ms_p95, 20);
  assert.deepEqual(out.safety_codes, {angular_velocity_exceeded: 2});
  assert.equal(perf.drain(), null);
});

test('a frame rendered twice counts latency once', () => {
  const perf = createEmbeddedPerf();
  perf.frameReceived({frameId: 1, receivedAtMs: 100, inferMs: 5});
  perf.frameRendered({frameId: 1, renderedAtMs: 110});
  perf.frameRendered({frameId: 1, renderedAtMs: 126});
  assert.deepEqual(perf.drain().latency_ms, [15]);
});

test('garbage inference and thermal values are ignored', () => {
  const perf = createEmbeddedPerf();
  perf.frameReceived({frameId: 1, receivedAtMs: 0, inferMs: 'x', thermal: 'hot', tier: 7});
  perf.frameRendered({frameId: 1, renderedAtMs: 5});
  const out = perf.drain();
  assert.deepEqual(out.latency_ms, [5]);
  assert.equal(out.infer_ms_p95, null);
  assert.equal(out.thermal, null);
  assert.equal(out.tier, null);
});

test('pending frames are bounded', () => {
  const perf = createEmbeddedPerf();
  for (let i = 1; i <= 100; i++) perf.frameReceived({frameId: i, receivedAtMs: i});
  perf.frameRendered({frameId: 1, renderedAtMs: 200});
  perf.frameRendered({frameId: 100, renderedAtMs: 200});
  assert.deepEqual(perf.drain().latency_ms, [100]);
});
```

- [ ] **Step 2: Correr y ver que fallan**

Run: `cd senas_core/tools/rig-tests && node --test rig_device_tier.test.mjs rig_embedded_perf.test.mjs`
Expected: FAIL, `Cannot find module .../rig_device_tier.mjs`.

- [ ] **Step 3: Implementar**

`senas_core/assets/avatar_viewer/rig_device_tier.mjs`:

```js
// Presupuesto de render por nivel de dispositivo (DeviceTier.kt manda el
// nivel en sourceMeta.tier). Spec:
// docs/superpowers/specs/2026-10-05-android-niveles-dispositivo-design.md

export const TIER_RENDER = Object.freeze({
  bajo: Object.freeze({frameIntervalMs: 1000 / 30, pixelRatio: .75}),
  medio: Object.freeze({frameIntervalMs: 1000 / 30, pixelRatio: 1}),
  alto: Object.freeze({frameIntervalMs: 1000 / 60, pixelRatio: 1.25}),
});

// Nivel desconocido (plugin viejo, null, basura): alto, el comportamiento
// de antes. Devuelve siempre el mismo objeto para comparar por identidad.
export function renderBudgetForTier(tier) {
  // hasOwnProperty y no Object.hasOwn: WebViews viejos (Chrome < 93) de
  // telefonos de gama baja no lo tienen.
  return typeof tier === 'string' &&
    Object.prototype.hasOwnProperty.call(TIER_RENDER, tier)
    ? TIER_RENDER[tier] : TIER_RENDER.alto;
}

// rAF corre a la tasa de la pantalla (60/90/120 Hz); se salta frames hasta
// cumplir el intervalo. 2 ms de margen absorben el jitter de rAF.
export function shouldRenderFrame(lastRenderAt, now, budget) {
  return !lastRenderAt || now - lastRenderAt >= budget.frameIntervalMs - 2;
}
```

`senas_core/assets/avatar_viewer/rig_embedded_perf.mjs`:

```js
// Evento perf del visor embebido (Android): mismo contenido que el de la
// camara web (eventoPerfSesion en index.html), medido sobre los frames que
// llegan por aplicarFrameVivo. Latencia = inferencia nativa + espera hasta
// el render; no incluye el cruce Kotlin -> Dart -> WebView porque los
// relojes no son comparables.

const kMaxPendientes = 8;

const p95 = (values) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * .95) - 1)];
};

export function createEmbeddedPerf() {
  let received = 0;
  let withHand = 0;
  let rendered = 0;
  let latency = [];
  let infer = [];
  let tier = null;
  let thermal = null;
  const pending = new Map();

  const reset = () => {
    received = 0;
    withHand = 0;
    rendered = 0;
    latency = [];
    infer = [];
    pending.clear();
  };

  const frameReceived = ({frameId, receivedAtMs, inferMs, hasHand,
    tier: nivel, thermal: termico} = {}) => {
    received++;
    if (hasHand === true) withHand++;
    const ms = typeof inferMs === 'number' && Number.isFinite(inferMs) && inferMs >= 0
      ? inferMs : null;
    if (ms !== null) infer.push(ms);
    tier = typeof nivel === 'string' ? nivel : null;
    thermal = Number.isInteger(termico) ? termico : null;
    pending.set(frameId, {receivedAtMs: Number(receivedAtMs) || 0, inferMs: ms ?? 0});
    if (pending.size > kMaxPendientes) pending.delete(pending.keys().next().value);
  };

  const frameRendered = ({frameId, renderedAtMs}) => {
    const p = pending.get(frameId);
    if (!p) return;
    pending.delete(frameId);
    latency.push(Math.round((renderedAtMs - p.receivedAtMs + p.inferMs) * 10) / 10);
  };

  const renderTick = () => { rendered++; };

  const drain = (extra = {}) => {
    if (received === 0) {
      reset();
      return null;
    }
    const out = {
      latency_ms: latency,
      fps: {input: received, inference: received, tracking: withHand,
        pose: received, render: rendered},
      tier,
      thermal,
      infer_ms_p95: p95(infer),
      ...extra,
    };
    reset();
    return out;
  };

  return {frameReceived, frameRendered, renderTick, drain, reset};
}
```

En `senas_core/tools/inline_viewer_modules.py`:

```python
MODULES = ["rig_math", "rig_metrics", "rig_diagnostics", "rig_safety",
           "rig_tracking", "rig_sign_space", "rig_mirror", "rig_body_profile",
           "rig_retarget", "rig_holistic", "rig_holistic_worker", "rig_face",
           "rig_hand_gate", "rig_session", "rig_device_tier",
           "rig_embedded_perf"]
# Modulos nuevos: exponen todos sus exports. Los historicos conservan la
# lista de nombres de su bloque (algunos exports no se usan en la pagina).
EXPORT_ALL = {"rig_sign_space", "rig_mirror", "rig_body_profile",
              "rig_retarget", "rig_holistic", "rig_holistic_worker", "rig_face",
              "rig_hand_gate", "rig_session", "rig_device_tier",
              "rig_embedded_perf"}
```

- [ ] **Step 4: Correr las pruebas, inlinear y verificar**

Run:
```bash
cd senas_core/tools/rig-tests && node --test rig_device_tier.test.mjs rig_embedded_perf.test.mjs && cd ../../..
python3 senas_core/tools/inline_viewer_modules.py
python3 senas_core/tools/inline_viewer_modules.py --check
grep -n "inicio rig_device_tier.mjs\|inicio rig_embedded_perf.mjs" senas_core/assets/avatar_viewer/index.html
```
Expected: 8 pruebas PASS; `--check` sin deriva; dos líneas de `grep` (bloques insertados antes de `// ---- fin modulos inline ----`).

- [ ] **Step 5: Commit**

```bash
git add senas_core/assets/avatar_viewer/ senas_core/tools/rig-tests/rig_device_tier.test.mjs \
        senas_core/tools/rig-tests/rig_embedded_perf.test.mjs senas_core/tools/inline_viewer_modules.py \
        univoz/assets/avatar_viewer/
git commit -m "feat(viewer): render budget per tier and embedded perf counters"
```

---

### Task 5: Integrar en `index.html` (render, `perf` embebido, sesión, mensajes técnicos)

**Files:**
- Modify: `senas_core/assets/avatar_viewer/index.html` (fuera de los bloques inline)
- Copia: `univoz/assets/avatar_viewer/index.html` (vía script)

**Interfaces:**
- Consumes: `renderBudgetForTier`, `shouldRenderFrame`, `createEmbeddedPerf` (Task 4); `sourceMeta.tier/infer_ms/thermal/has_hand` (Task 6 los manda).
- Produces: `window.configurarSesion(activa: boolean)`; mensaje `perf:<json>` por `SenasChannel` cada segundo con sesión activa.

- [ ] **Step 1: Presupuesto de render**

Reemplazar las líneas (sección "Escena"):

```js
    const renderPixelRatio = Math.min(window.devicePixelRatio || 1, 1.25);
```

por:

```js
    // Nivel por dispositivo: Android lo manda en sourceMeta.tier; en web se
    // fuerza con ?tier=bajo|medio|alto para simularlo. Sin nivel: alto.
    let presupuestoRender = renderBudgetForTier(standaloneWeb
      ? new URLSearchParams(window.location.search).get('tier') : null);
    const renderPixelRatio = Math.min(window.devicePixelRatio || 1,
      presupuestoRender.pixelRatio);
```

Inmediatamente después de `renderer.setSize(window.innerWidth, window.innerHeight);` (la primera vez, junto a la creación del renderer), agregar:

```js
    function aplicarNivelRender(tier) {
      const presupuesto = renderBudgetForTier(tier);
      if (presupuesto === presupuestoRender) return;
      presupuestoRender = presupuesto;
      renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, presupuesto.pixelRatio));
      renderer.setSize(window.innerWidth, window.innerHeight);
    }
```

- [ ] **Step 2: Saltar frames en `animar`**

Reemplazar:

```js
    let ultimoT = 0;
    let acumMs = 0;
    function animar(t) {
      requestAnimationFrame(animar);
      const dt = ultimoT ? t - ultimoT : 16;
```

por:

```js
    let ultimoT = 0;
    let acumMs = 0;
    let ultimoRenderAt = 0;
    function animar(t) {
      requestAnimationFrame(animar);
      if (!shouldRenderFrame(ultimoRenderAt, t, presupuestoRender)) return;
      ultimoRenderAt = t;
      const dt = ultimoT ? t - ultimoT : 16;
```

En la misma función, dentro de la rama `else` que llama `RigBodyEngine.aplicarFrame(espejo ? mirrorMotionFrame(frameVivo) : frameVivo, ...)`, justo después de `aplicarCara(...)`, agregar:

```js
          if (streamExternoEnVivo) {
            perfEmbebido.frameRendered({frameId: frameVivoFrameId, renderedAtMs: t});
          }
```

Y después de `renderer.render(scene, camera);`, agregar:

```js
      if (!standaloneWeb) perfEmbebido.renderTick();
```

- [ ] **Step 3: Recibir el nivel y contar frames en `aplicarFrameVivo`**

Dentro de `window.aplicarFrameVivo`, justo después de `frameVivoRecibidoAt = performance.now();`, agregar:

```js
      if (!standaloneWeb) {
        aplicarNivelRender(sourceMeta?.tier);
        perfEmbebido.frameReceived({
          frameId: frameVivoFrameId,
          receivedAtMs: frameVivoRecibidoAt,
          inferMs: sourceMeta?.infer_ms,
          hasHand: sourceMeta?.has_hand === true,
          tier: sourceMeta?.tier,
          thermal: sourceMeta?.thermal,
        });
      }
```

- [ ] **Step 4: `configurarSesion` y envío cada segundo**

Justo después de la función `eventoPerfSesion()` (termina con `safetyArticulaciones = {};` y `}`), agregar:

```js
    // Android: el visor no tiene la sesion (vive en Dart); Dart avisa si hay
    // sesion con consentimiento y el visor le manda un perf por segundo, con
    // el mismo formato que eventoPerfSesion (analizar_sesion.py --gates).
    const perfEmbebido = createEmbeddedPerf();
    let perfEmbebidoTimer = null;
    window.configurarSesion = function (activa) {
      if (perfEmbebidoTimer) clearInterval(perfEmbebidoTimer);
      perfEmbebidoTimer = null;
      perfEmbebido.reset();
      if (!activa || standaloneWeb || !window.SenasChannel) return;
      perfEmbebidoTimer = setInterval(() => {
        const s = webCameraState;
        const perf = perfEmbebido.drain({
          counters: {swaps: s.handSwaps, surface_flips: s.surfaceFlips,
            holds: s.handHolds, recoveries: s.handRecoveries,
            safety_rejections: s.invalidTransforms, teleports: s.teleports},
          safety_codes: safetyCodigos,
          safety_joints: safetyArticulaciones,
        });
        safetyCodigos = {};
        safetyArticulaciones = {};
        if (perf) window.SenasChannel.postMessage('perf:' + JSON.stringify(perf));
      }, 1000);
    };
```

`perfEmbebido` se declara con `const` aquí y se usa en `animar` y `aplicarFrameVivo`, que solo corren después de que el script terminó de evaluarse; no hay TDZ.

- [ ] **Step 5: Mensajes técnicos fuera de la pantalla del teléfono**

Reemplazar la firma y el inicio de `avisar`:

```js
    function avisar(msg) {
```

por:

```js
    // tecnico: en el telefono no se pinta (queda en consola y en el audit);
    // en el laboratorio web se ve todo.
    function avisar(msg, {tecnico = false} = {}) {
      if (tecnico && !standaloneWeb) {
        console.error(msg);
        return;
      }
```

y marcar como técnicos los tres avisos de `window.reproducirSecuencia`:

```js
        avisar('norm_version incompatible: ' + normVersion, {tecnico: true});
```
```js
        avisar('secuencia invalida: ' + e, {tecnico: true});
```
```js
        avisar('secuencia incompatible: se requieren 32 frames de 152 valores',
          {tecnico: true});
```

(Los demás `avisar` técnicos —Holistic, MediaPipe, worker, marcas— solo corren en el camino web y se quedan visibles en el laboratorio.)

- [ ] **Step 6: Verificar sintaxis, deriva y la simulación web**

Run:
```bash
python3 senas_core/tools/inline_viewer_modules.py
python3 senas_core/tools/inline_viewer_modules.py --check
awk '/<script[^>]*type="module"/ {inside=1; next} inside && /<\/script>/ {exit} inside {print}' \
  senas_core/assets/avatar_viewer/index.html | node --check --input-type=module
cd senas_core/tools/rig-tests && npm test
```
Expected: sin deriva; `node --check` sin salida; `npm test` verde.

Prueba manual en web (el servidor ya existe: `./scripts/univoz.sh web --no-open`): abrir `http://127.0.0.1:8080/assets/avatar_viewer/index.html?standalone=1&tier=bajo`, iniciar cámara y confirmar en el panel que `render` ronda 30 FPS; sin `&tier=` debe rondar la tasa anterior (hasta 60).

- [ ] **Step 7: Commit**

```bash
git add senas_core/assets/avatar_viewer/index.html univoz/assets/avatar_viewer/index.html
git commit -m "feat(viewer): tier-driven render, embedded perf events, quiet technical notices"
```

---

### Task 6: Dart — `AvatarBridge`, espejo en modo producto y `univoz`

**Files:**
- Modify: `senas_core/lib/avatar_bridge.dart`
- Create: `senas_core/test/avatar_perf_test.dart`
- Modify: `senas_core/lib/pantalla_espejo.dart`
- Modify: `univoz/lib/screens/traducir_senas_screen.dart:106`

**Interfaces:**
- Consumes: `LandmarkFrame.tier/inferMs/thermal` (Task 3); `window.configurarSesion` y `perf:` (Task 5); `ControladorCaptura.sesion` (`SesionCaptura?`, existente); `activarSesionConConsentimiento(...)` devuelve `Future<bool>` (existente).
- Produces: `decodificarPerf(String) -> Map<String, dynamic>?` (top-level), `AvatarBridge.onPerf`, `AvatarBridge.configurarSesion(bool)`, `PantallaEspejo(modoProducto: bool)`.

- [ ] **Step 1: Escribir la prueba que falla**

`senas_core/test/avatar_perf_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/avatar_bridge.dart';

void main() {
  test('decodificarPerf devuelve el objeto del visor', () {
    final perf = decodificarPerf(
        'perf:{"latency_ms":[30.5],"fps":{"render":30},"tier":"bajo"}');
    expect(perf, isNotNull);
    expect(perf!['tier'], 'bajo');
    expect((perf['fps'] as Map)['render'], 30);
  });

  test('decodificarPerf ignora mensajes corruptos o que no son objeto', () {
    expect(decodificarPerf('perf:{roto'), isNull);
    expect(decodificarPerf('perf:[1,2]'), isNull);
    expect(decodificarPerf('perf:'), isNull);
    expect(decodificarPerf('fin'), isNull);
  });
}
```

- [ ] **Step 2: Correr y ver que falla**

Run: `cd senas_core && flutter test test/avatar_perf_test.dart`
Expected: FAIL, `Method not found: 'decodificarPerf'`.

- [ ] **Step 3: Implementar en `avatar_bridge.dart`**

Antes de `class AvatarBridge {`:

```dart
/// Evento `perf` del visor embebido ('perf:<json>', ver rig_embedded_perf).
/// null si el mensaje no es un objeto JSON: un perf roto no debe tirar nada.
Map<String, dynamic>? decodificarPerf(String mensaje) {
  if (!mensaje.startsWith('perf:')) return null;
  try {
    final valor = jsonDecode(mensaje.substring(5));
    return valor is Map<String, dynamic> ? valor : null;
  } catch (_) {
    return null;
  }
}
```

En la clase, junto a los otros callbacks:

```dart
  /// Un evento perf por segundo mientras haya sesion (configurarSesion).
  void Function(Map<String, dynamic>)? onPerf;
  bool _sesion = false;
```

En el `onMessageReceived`, antes de `} else if (msg.message == 'js_listo') {`:

```dart
          } else if (msg.message.startsWith('perf:')) {
            final perf = decodificarPerf(msg.message);
            if (perf != null) onPerf?.call(perf);
```

En `_cargarAvatar`, después de `await webView.runJavaScript('window.configurarDiagnostico($_diagnostico)');`:

```dart
    await webView.runJavaScript('window.configurarSesion($_sesion)');
```

Método nuevo (después de `configurarRig`):

```dart
  /// Con sesion activa el visor manda perf cada segundo (onPerf).
  Future<void> configurarSesion(bool activa) async {
    _sesion = activa;
    if (kIsWeb || !_jsListo) return;
    await controller?.runJavaScript('window.configurarSesion($activa)');
  }
```

En `dispose`, agregar `onPerf = null;`.

- [ ] **Step 4: Correr y ver que pasa**

Run: `cd senas_core && flutter test test/avatar_perf_test.dart`
Expected: PASS.

- [ ] **Step 5: `PantallaEspejo` en modo producto**

Parámetro nuevo:

```dart
  final bool iniciarCalibracion;

  /// App producto (univoz): sin contadores ni datos técnicos en pantalla y
  /// sin modo diagnóstico.
  final bool modoProducto;

  const PantallaEspejo(
      {super.key, this.iniciarCalibracion = false, this.modoProducto = false});
```

Estado: agregar junto a `int _framesEnviados = 0;`:

```dart
  bool _avisoAhorroMostrado = false;
```

En `initState`, después de `_bridge.onCalibrationChanged = _guardarCalibracion;`:

```dart
    _bridge.onPerf = (perf) => _ctrl.sesion?.evento('perf', perf);
```

En `_arrancar`, reemplazar:

```dart
      await activarSesionConConsentimiento(context, _ctrl, _almacen,
          pantalla: 'espejo');
```

por:

```dart
      final sesionActiva = await activarSesionConConsentimiento(
          context, _ctrl, _almacen,
          pantalla: 'espejo');
      await _bridge.configurarSesion(sesionActiva);
```

y la llamada de diagnóstico por:

```dart
      await _bridge.configurarDiagnostico(!widget.modoProducto &&
          (_almacen.ajustes.rigDiagnosticMode || widget.iniciarCalibracion));
```

En `_alFrame`, después de `if (!_espejando) return;`:

```dart
    if (widget.modoProducto && !_avisoAhorroMostrado && f.tier == 'bajo') {
      _avisoAhorroMostrado = true;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Modo ahorro: el avatar se mueve más simple en este teléfono')));
    }
```

En el `sourceMeta` de `_enviarPendiente`, después de la línea de `image_aspect`:

```dart
          if (f.tier != null) 'tier': f.tier,
          if (f.inferMs != null) 'infer_ms': f.inferMs,
          if (f.thermal != null) 'thermal': f.thermal,
          'has_hand': f.tieneAlgunaMano,
```

En `_barra`, envolver el contador:

```dart
                  if (!widget.modoProducto)
                    Text('$_framesEnviados frames enviados',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
```

En `_estado`, envolver el texto de lados:

```dart
      if (!widget.modoProducto)
        Text(
          'Lados: $modo',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
```

En `dispose` de la pantalla no hace falta nada: `_bridge.dispose()` ya limpia `onPerf`.

- [ ] **Step 6: `univoz` abre el espejo en modo producto**

`univoz/lib/screens/traducir_senas_screen.dart`, línea 106:

```dart
                      onTap: () => _abrirConCamara(
                          const PantallaEspejo(modoProducto: true)),
```

- [ ] **Step 7: Analizar y probar**

Run:
```bash
cd senas_core && flutter analyze && flutter test && cd ../univoz && flutter analyze && flutter test
```
Expected: sin issues nuevos; todas las pruebas PASS.

- [ ] **Step 8: Commit**

```bash
git add senas_core/lib/avatar_bridge.dart senas_core/test/avatar_perf_test.dart \
        senas_core/lib/pantalla_espejo.dart univoz/lib/screens/traducir_senas_screen.dart
git commit -m "feat(app): perf events from Android sessions, product mirror without lab info"
```

---

### Task 7: Contrato, gates de Android y paridad de cara

**Files:**
- Modify: `docs/02-contratos-y-datos.md`
- Modify: `senas_core/tools/analizar_sesion.py` (función de gates, bloque `f1`)
- Modify: `senas_core/tools/test_analizar_sesion.py`
- Create: `senas_core/tools/test_paridad_cara.py`

**Interfaces:**
- Consumes: forma del evento `perf` (Task 4/5): `latency_ms`, `fps`, `tier`, `thermal`, `infer_ms_p95`.
- Produces: `gates()["fase_1_rendimiento"]["tiers"]: list[str]`.

- [ ] **Step 1: Escribir las pruebas que fallan**

Al final de `senas_core/tools/test_analizar_sesion.py`:

```python
def test_gates_sesion_android_con_perf_y_nivel():
    regs = _sesion_gates(pasos=range(1, 10))
    regs[0]["meta"]["platform"] = "android"
    for r in regs:
        if r.get("type") == "perf":
            r["tier"] = "medio"
            r["thermal"] = 0
            r["infer_ms_p95"] = 28.0
    g = an.gates(an.leer_registros(regs))
    f1 = g["fase_1_rendimiento"]
    assert f1["veredicto"] != "SIN_DATOS"
    assert f1["tiers"] == ["medio"]
    assert g["contexto"]["platform"] == "android"


def test_gates_sin_nivel_reporta_lista_vacia():
    g = an.gates(an.leer_registros(_sesion_gates(pasos=range(1, 10))))
    assert g["fase_1_rendimiento"]["tiers"] == []
```

`senas_core/tools/test_paridad_cara.py`:

```python
"""Los 17 puntos de cara que manda Android deben ser los mismos en Kotlin,
Dart y el visor; si derivan, la cabeza y las expresiones se calculan con
puntos equivocados sin ningun error visible."""

import os
import re

RAIZ = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


def _leer(ruta):
    with open(os.path.join(RAIZ, ruta), encoding="utf-8") as f:
        return f.read()


def _enteros(patron, texto):
    m = re.search(patron, texto, flags=re.S)
    assert m, patron
    return [int(x) for x in re.findall(r"\d+", m.group(1))]


def test_puntos_de_cara_iguales_en_kotlin_dart_y_visor():
    kt = _enteros(r"FACE_KEYPOINTS = intArrayOf\(([^)]*)\)", _leer(
        "android/app/src/main/kotlin/com/univoz/senas/LandmarkEngine.kt"))
    js = _enteros(r"FACE_KEYPOINTS = Object\.freeze\(\[([^\]]*)\]", _leer(
        "assets/avatar_viewer/rig_face.mjs"))
    dart = _enteros(r"kFaceKeypoints = \[([^\]]*)\]", _leer("lib/camera_bridge.dart"))
    assert len(kt) == 17
    assert kt == js == dart
```

- [ ] **Step 2: Correr y ver que fallan**

Run: `cd senas_core && python3 -m pytest -q tools/test_analizar_sesion.py tools/test_paridad_cara.py`
Expected: las dos de gates FALLAN con `KeyError: 'tiers'`; la de paridad PASA ya (es un candado, documenta el estado actual).

- [ ] **Step 3: Implementar**

En `senas_core/tools/analizar_sesion.py`, reemplazar:

```python
    f1 = {"perf_events": len(perfs)}
```

por:

```python
    # Niveles por dispositivo vistos (Android, DeviceTier.kt); web no manda.
    f1 = {"perf_events": len(perfs),
          "tiers": sorted({p["tier"] for p in perfs if isinstance(p.get("tier"), str)})}
```

En `docs/02-contratos-y-datos.md`, agregar una sección nueva justo antes de `## Cara (\`face_pts\`)`:

```markdown
## Nivel por dispositivo (`sourceMeta`, Android)

```

y debajo de ese título:

```markdown
- `tier` (opcional, Android): nivel por dispositivo, `"bajo" | "medio" | "alto"`
  (`DeviceTier.kt`). El visor ajusta FPS de render y `pixelRatio`
  (`rig_device_tier.mjs`); desconocido = `alto`.
- `infer_ms` (opcional, Android): inferencia MediaPipe del último resultado, ms.
- `thermal` (opcional, Android): `PowerManager.THERMAL_STATUS_*` (0–6) o
  `null` en Android < 10.
- `has_hand` (opcional, Android): el frame trae al menos una mano.
```

y al final de la sección `## SessionLogV1 (registro de sesión)` (después del párrafo que menciona `safety_joints`), un párrafo nuevo:

```markdown
- En Android el evento lo arma el visor embebido (`rig_embedded_perf.mjs`) y
  Dart lo escribe en la sesión. Agrega `tier`, `thermal` e `infer_ms_p95`.
  Su `latency_ms` = inferencia nativa + espera hasta el render (sin el cruce
  Kotlin → Dart → WebView). `--gates` lista los niveles en
  `fase_1_rendimiento.tiers`.
```

- [ ] **Step 4: Correr y ver que pasan**

Run: `cd senas_core && python3 -m pytest -q tools/`
Expected: PASS todo.

- [ ] **Step 5: Commit**

```bash
git add docs/02-contratos-y-datos.md senas_core/tools/analizar_sesion.py \
        senas_core/tools/test_analizar_sesion.py senas_core/tools/test_paridad_cara.py
git commit -m "feat(tools): report device tiers in gates; pin face keypoint parity"
```

---

### Task 8: Suite completa y APK de depuración

**Files:** ninguno nuevo (solo verificación y build).

- [ ] **Step 1: Suite completa**

Run: `./scripts/univoz.sh test`
Expected: termina con `[INFO] Todas las verificaciones pasaron.`

Si falla, arreglar en la Task dueña del archivo y volver a correr. No seguir con un fallo.

- [ ] **Step 2: Compilar el APK**

Run: `cd univoz && flutter build apk --debug`
Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 3: Registrar el estado en el roadmap**

En `docs/12-plan-sistema-unico.md`, en la lista de checks, después del ítem del worker de captura, agregar:

```markdown
- [x] Niveles por dispositivo en Android (`DeviceTier.kt`: resolución,
  modelo, FPS, cara y render según RAM, GPU, inferencia y calor) y evento
  `perf` desde Android (`rig_embedded_perf.mjs` → Dart). Falta validarlo en
  teléfonos de gama baja y media.
```

y en "Próxima sesión" reemplazar el punto `5. Android: emitir evento perf ...` por:

```markdown
5. Android: instalar el APK de depuración en un teléfono de gama baja y uno
   de gama media, correr el protocolo de `docs/09` y
   `analizar_sesion.py --gates`; ajustar umbrales de `DeviceTier.kt` con lo
   medido.
```

- [ ] **Step 4: Commit**

```bash
git add docs/12-plan-sistema-unico.md
git commit -m "docs: device tiers done; next is the physical phone run"
```

- [ ] **Step 5: Entregar**

Reportar la ruta `univoz/build/app/outputs/flutter-apk/app-debug.apk` y cómo instalarla:

```bash
cd univoz && flutter install --debug
```

(Siempre `--debug`: sin él `flutter install` busca el APK de release y desinstala el que había.)

Prueba física a cargo del usuario: abrir *Traducir señas → Espejo*, confirmar que no aparecen "frames enviados" ni "Lados", aceptar el consentimiento, usarlo un par de minutos y luego en Ajustes compartir la sesión para correr `python3 senas_core/tools/analizar_sesion.py --gates <sesion>.jsonl` y ver `fase_1_rendimiento` con `tiers`.
