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
    /** Resultados que no cuentan tras crear o cambiar el motor (GPU calentando). */
    private val calentamientoFrames: Int = CALENTAMIENTO_FRAMES,
) {
    companion object {
        const val VENTANA_FRAMES = 60
        /**
         * Los primeros resultados tras crear el motor o reenlazar la camara
         * tardan segundos (compilacion de shaders): con ellos el Galaxy S22+
         * bajo de alto a bajo en 28 s (2026-10-19).
         */
        const val CALENTAMIENTO_FRAMES = 30
        const val HISTERESIS_MS = 10_000L
        const val RECUPERACION_MS = 30_000L
        /** PowerManager.THERMAL_STATUS_NONE / THERMAL_STATUS_MODERATE. */
        const val TERMICO_NINGUNO = 0
        const val TERMICO_MODERADO = 2

        fun config(n: Nivel): TierConfig = when (n) {
            // Presupuestos medidos en telefono (Galaxy S22+, 2026-10-19):
            // Holistic con GPU GL tarda ~80 ms y sigue siendo usable; se
            // baja si no llega a 10 FPS (100 ms) y en bajo se pasa a Pose +
            // Hand si no llega a 8 FPS (125 ms).
            Nivel.BAJO -> TierConfig(240, 320, 15, false, 125.0)
            Nivel.MEDIO -> TierConfig(360, 480, 24, true, 110.0)
            Nivel.ALTO -> TierConfig(360, 480, 30, true, 100.0)
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
    private var porCalentar = calentamientoFrames.coerceAtLeast(0)

    /** Cada cambio re-crea el motor o reenlaza la camara: calentar de nuevo. */
    private fun cambio(ahoraMs: Long) {
        ultimoCambioMs = ahoraMs
        muestras.clear()
        porCalentar = calentamientoFrames.coerceAtLeast(0)
    }

    private var ultimoCambioMs = Long.MIN_VALUE / 2
    private var ningunoDesdeMs: Long? = null

    /** True si cambio el nivel o el modo separado. */
    fun registrarInferencia(ms: Double, ahoraMs: Long): Boolean {
        if (!ms.isFinite() || ms < 0) return false
        if (porCalentar > 0) {
            porCalentar--
            return false
        }
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
        cambio(ahoraMs)
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
            cambio(ahoraMs)
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
        cambio(ahoraMs)
        ningunoDesdeMs = ahoraMs
        return true
    }
}
