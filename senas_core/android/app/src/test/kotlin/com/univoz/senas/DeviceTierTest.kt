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

    /** Ventanas lentas SEGUIDAS que hacen falta para bajar (la primera no cambia). */
    private fun ventanasLentas(t: DeviceTier, ms: Double, ahoraMs: Long): Boolean {
        repeat(DeviceTier.VENTANAS_SOSTENIDAS - 1) { assertFalse(ventana(t, ms, ahoraMs)) }
        return ventana(t, ms, ahoraMs)
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
        // Presupuestos medidos en telefono (Galaxy S22+, 2026-10-19):
        // Holistic con GPU GL va a ~80 ms; sirve mientras rinda >= 10 FPS.
        assertEquals(TierConfig(240, 320, 15, false, 125.0), DeviceTier.config(Nivel.BAJO))
        assertEquals(TierConfig(360, 480, 24, true, 110.0), DeviceTier.config(Nivel.MEDIO))
        assertEquals(TierConfig(360, 480, 30, true, 100.0), DeviceTier.config(Nivel.ALTO))
    }

    @Test fun holisticComoEnElS22QuedaEnAlto() {
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        repeat(5) { assertFalse(ventana(t, 80.0, 20_000L + it * 11_000L)) }
        assertEquals(Nivel.ALTO, t.nivel)
        assertFalse(t.separado)
    }

    @Test fun calentamientoDeLaGpuNoCuenta() {
        val t = DeviceTier(Nivel.ALTO)
        // Primeros resultados: compilacion de shaders, segundos por frame.
        repeat(DeviceTier.CALENTAMIENTO_FRAMES) {
            assertFalse(t.registrarInferencia(2_000.0, 20_000))
        }
        assertFalse(ventana(t, 80.0, 20_000))
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun trasUnCambioVuelveACalentar() {
        val c = DeviceTier(Nivel.ALTO)
        repeat(DeviceTier.CALENTAMIENTO_FRAMES) { c.registrarInferencia(50.0, 20_000) }
        assertTrue(ventanasLentas(c, 150.0, 20_000))
        assertEquals(Nivel.MEDIO, c.nivel)
        // Motor nuevo o reenlace: sus primeros resultados son lentos y no
        // cuentan; si contaran, esta ventana bajaria otra vez a bajo.
        repeat(DeviceTier.CALENTAMIENTO_FRAMES) {
            assertFalse(c.registrarInferencia(2_000.0, 40_000))
        }
        assertFalse(ventana(c, 80.0, 40_000))
        assertEquals(Nivel.MEDIO, c.nivel)
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
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        repeat(DeviceTier.VENTANA_FRAMES - 1) { assertFalse(t.registrarInferencia(150.0, 20_000)) }
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun dentroDelPresupuestoNoCambia() {
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        assertFalse(ventana(t, 95.0, 20_000))
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun inferenciaLentaBajaUnNivelConHisteresis() {
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        assertTrue(ventanasLentas(t, 115.0, 20_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        assertEquals(Nivel.MEDIO, t.techoInferencia)
        // 5 s despues: dentro de la histeresis, no baja otra vez.
        assertFalse(ventana(t, 115.0, 25_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        // 11 s despues: 115 ms > 110 ms de medio, baja a bajo.
        assertTrue(ventanasLentas(t, 115.0, 31_000))
        assertEquals(Nivel.BAJO, t.nivel)
    }

    @Test fun enBajoHolisticLentoPasaASeparado() {
        val t = DeviceTier(Nivel.BAJO, calentamientoFrames = 0)
        // 115 ms en bajo (~9 FPS) todavia es Holistic.
        assertFalse(ventana(t, 115.0, 20_000))
        assertFalse(t.separado)
        // Menos de 8 FPS: Pose lite + Hand.
        assertTrue(ventanasLentas(t, 140.0, 31_000))
        assertEquals(Nivel.BAJO, t.nivel)
        assertTrue(t.separado)
        assertFalse(ventanasLentas(t, 140.0, 60_000))
    }

    @Test fun unaVentanaMalaAisladaNoBaja() {
        // Regresion S22+ 2026-10-21: p50 65-80 ms, una ventana con picos de
        // GPU compartida (p95 > 100) bajaba de alto a medio para siempre.
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        repeat(4) {
            assertFalse(ventana(t, 80.0, 20_000L + it * 15_000L))
            assertFalse(ventana(t, 130.0, 25_000L + it * 15_000L)) // mala aislada
        }
        assertEquals(Nivel.ALTO, t.nivel)
        assertNull(t.causaCambio)
    }

    @Test fun picosDeUnaVentanaSinSostenerNoCuentan() {
        // 3 picos de 205 ms entre 57 muestras de 80: p95 = 205 > 100.
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        repeat(3) { assertFalse(t.registrarInferencia(205.0, 20_000)) }
        repeat(DeviceTier.VENTANA_FRAMES - 3) { assertFalse(t.registrarInferencia(80.0, 20_000)) }
        assertEquals(Nivel.ALTO, t.nivel)
    }

    @Test fun causaDelCambioSeRegistra() {
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        assertTrue(ventanasLentas(t, 115.0, 20_000))
        assertTrue(t.causaCambio!!.startsWith("inferencia p95=115ms > 100ms"))
        val c = DeviceTier(Nivel.ALTO)
        assertTrue(c.registrarTermico(2, 20_000))
        assertEquals("termico=2", c.causaCambio)
    }

    @Test fun rangoFpsPorModo() {
        val s22 = listOf(15 to 15, 20 to 20, 24 to 24, 30 to 30, 7 to 30, 15 to 30, 60 to 60, 120 to 120)
        assertNull(DeviceTier.rangoFps("auto", s22))
        assertNull(DeviceTier.rangoFps(null, s22))
        assertEquals(30 to 30, DeviceTier.rangoFps("30", s22))
        // 120 es alta velocidad (otra resolucion): el tope es 60.
        assertEquals(60 to 60, DeviceTier.rangoFps("max", s22))
        // Solo rangos variables salvo 30: max cae al fijo mas alto.
        assertEquals(30 to 30, DeviceTier.rangoFps("max", listOf(15 to 30, 30 to 30)))
        // Sin ningun fijo no se toca nada.
        assertNull(DeviceTier.rangoFps("max", listOf(15 to 30)))
        assertNull(DeviceTier.rangoFps("30", emptyList()))
    }

    @Test fun inferenciaInvalidaSeIgnora() {
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
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
        val t = DeviceTier(Nivel.ALTO, calentamientoFrames = 0)
        assertTrue(ventanasLentas(t, 115.0, 20_000))
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
