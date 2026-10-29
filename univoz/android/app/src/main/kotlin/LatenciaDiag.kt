package com.univoz.senas

import kotlin.math.ceil

/**
 * Medicion de latencia nativa para el modo desarrollador (etiqueta de logcat
 * `UnivozLat`). Solo se crea con el diagnostico encendido, asi que apagado no
 * cuesta nada. Sin dependencias de Android para probarla en JVM; el plugin
 * hace el Log.i con la linea que arma [cerrarSiToca].
 */
class VentanaMs(private val capacidad: Int = 256) {
    private val v = DoubleArray(capacidad)
    private var n = 0
    private var sig = 0

    @Synchronized fun agregar(ms: Double) {
        if (!ms.isFinite()) return
        v[sig] = ms
        sig = (sig + 1) % capacidad
        if (n < capacidad) n++
    }

    @Synchronized fun limpiar() {
        n = 0
        sig = 0
    }

    /** `p50/p95/max` con un decimal, o `-` sin muestras (percentil por rango superior). */
    @Synchronized fun resumen(): String {
        if (n == 0) return "-"
        val orden = v.copyOfRange(0, n).also { it.sort() }
        fun p(q: Double) = orden[(ceil(n * q).toInt() - 1).coerceIn(0, n - 1)]
        return "%.1f/%.1f/%.1f".format(java.util.Locale.US, p(.5), p(.95), orden[n - 1])
    }
}

class MedidorNativo(
    /** SENSOR_INFO_TIMESTAMP_SOURCE: REALTIME hace validas las edades de captura. */
    val fuenteReloj: String = "?",
    private val ventanaMs: Long = 1000,
) {
    private var inicioMs = -1L
    private var entrada = 0
    private var salida = 0
    private var descartesOcupado = 0
    private var descartesFps = 0
    private var descartesSinPeticion = 0

    /** Edad de captura al entrar al analizador de CameraX. */
    val edadEntrada = VentanaMs()

    /** Edad de captura al enviar el bitmap al modelo (inicio de inferencia). */
    val edadInferencia = VentanaMs()
    val preparar = VentanaMs()
    val inferencia = VentanaMs()

    /** Edad de captura justo antes de entregar el frame al canal (latencia nativa total). */
    val edadEmision = VentanaMs()

    @Synchronized fun frameEntrada() { entrada++ }
    @Synchronized fun descarteOcupado() { descartesOcupado++ }
    @Synchronized fun descarteFps() { descartesFps++ }
    @Synchronized fun descarteSinPeticion() { descartesSinPeticion++ }
    @Synchronized fun frameSalida() { salida++ }

    /**
     * Si paso la ventana devuelve la linea (sin la etiqueta) y reinicia los
     * contadores; si no, null. [ahoraMs] es un reloj monotono cualquiera.
     */
    @Synchronized fun cerrarSiToca(
        ahoraMs: Long, nivel: String?, delegado: String, modo: String,
    ): String? {
        if (inicioMs < 0) {
            inicioMs = ahoraMs
            return null
        }
        if (ahoraMs - inicioMs < ventanaMs) return null
        val seg = (ahoraMs - inicioMs) / 1000.0
        fun tasa(n: Int) = "%.1f".format(java.util.Locale.US, n / seg)
        val linea = "win=${ahoraMs - inicioMs}ms in=${tasa(entrada)}/s out=${tasa(salida)}/s " +
            "drop_busy=$descartesOcupado drop_fps=$descartesFps drop_idle=$descartesSinPeticion " +
            "tier=${nivel ?: "-"} delegate=$delegado mode=$modo ts_src=$fuenteReloj " +
            "cap_cb=${edadEntrada.resumen()} cap_infer=${edadInferencia.resumen()} " +
            "prep=${preparar.resumen()} infer=${inferencia.resumen()} " +
            "cap_emit=${edadEmision.resumen()}"
        entrada = 0; salida = 0
        descartesOcupado = 0; descartesFps = 0; descartesSinPeticion = 0
        edadEntrada.limpiar(); edadInferencia.limpiar(); preparar.limpiar()
        inferencia.limpiar(); edadEmision.limpiar()
        inicioMs = ahoraMs
        return linea
    }
}
