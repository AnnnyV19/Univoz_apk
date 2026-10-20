package com.univoz.senas

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Banco de paridad: CapturaManos (Kotlin) reproduce frame a frame la captura
 * web (rig_hand_capture.mjs + rig_tracking.mjs) sobre sesiones reales y
 * escenarios sinteticos. Discretos exactos; numeros a 1e-9.
 * Si la web cambia: `node tools/rig-tests/gen_paridad_manos.mjs` y portar aqui.
 */
class ParidadManosTest {
    @Test
    fun capturaKotlinReproduceLaWebFrameAFrame() {
        val tramos = FixtureParidad.cargar()
        var frames = 0
        val desajustes = mutableListOf<String>()
        for (tramo in tramos) {
            // Cada tramo arranca de estado limpio, como en el generador.
            val captura = CapturaManos()
            for (frame in tramo.frames) {
                frames++
                val r = captura.process(frame.candidatas, frame.pose, frame.t,
                    frame.t - frame.skew)
                FixtureParidad.comparar(frame, r) { campo, esperado, obtenido ->
                    desajustes += "${tramo.nombre}#${frame.i} $campo: " +
                        "web=$esperado kotlin=$obtenido"
                }
            }
        }
        assertTrue("fixture casi vacio: $frames frames", frames > 1000)
        assertTrue(
            "${desajustes.size} desajustes en $frames frames; primeros 20:\n" +
                desajustes.take(20).joinToString("\n"),
            desajustes.isEmpty(),
        )
    }
}
