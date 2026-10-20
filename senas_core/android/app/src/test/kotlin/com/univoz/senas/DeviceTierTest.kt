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
        assertTrue(ventana(c, 150.0, 20_000))
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
        assertTrue(ventana(t, 115.0, 20_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        assertEquals(Nivel.MEDIO, t.techoInferencia)
        // 5 s despues: dentro de la histeresis, no baja otra vez.
        assertFalse(ventana(t, 115.0, 25_000))
        assertEquals(Nivel.MEDIO, t.nivel)
        // 11 s despues: 115 ms > 110 ms de medio, baja a bajo.
        assertTrue(ventana(t, 115.0, 31_000))
        assertEquals(Nivel.BAJO, t.nivel)
    }

    @Test fun enBajoHolisticLentoPasaASeparado() {
        val t = DeviceTier(Nivel.BAJO, calentamientoFrames = 0)
        // 115 ms en bajo (~9 FPS) todavia es Holistic.
        assertFalse(ventana(t, 115.0, 20_000))
        assertFalse(t.separado)
        // Menos de 8 FPS: Pose lite + Hand.
        assertTrue(ventana(t, 140.0, 31_000))
        assertEquals(Nivel.BAJO, t.nivel)
        assertTrue(t.separado)
        assertFalse(ventana(t, 140.0, 60_000))
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
        assertTrue(ventana(t, 115.0, 20_000))
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
