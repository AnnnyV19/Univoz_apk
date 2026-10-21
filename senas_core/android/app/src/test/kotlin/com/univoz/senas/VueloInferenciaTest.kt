package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VueloInferenciaTest {
    private val ms = 1_000_000L

    @Test fun unSoloFrameEnVuelo() {
        val v = VueloInferencia(2_000 * ms)
        assertTrue(v.intentarIniciar(0))
        assertFalse(v.intentarIniciar(10 * ms))
        assertTrue(v.ocupado(10 * ms))
    }

    @Test fun terminarLiberaYMideMs() {
        val v = VueloInferencia(2_000 * ms)
        v.intentarIniciar(5 * ms)
        assertEquals(80.0, v.terminar(85 * ms), 1e-9)
        assertFalse(v.ocupado(86 * ms))
        assertTrue(v.intentarIniciar(86 * ms))
    }

    // Camino de error del modelo: el listener libera sin esperar al timeout.
    @Test fun liberarTrasErrorNoEsperaElTimeout() {
        val v = VueloInferencia(2_000 * ms)
        v.intentarIniciar(0)
        v.liberar()
        assertFalse(v.ocupado(1 * ms))
        assertTrue(v.intentarIniciar(1 * ms))
    }

    // Sin modelo no hay envio: la compuerta no debe quedar tomada. El motor
    // revisa el modelo ANTES de intentarIniciar; si no lo hiciera, liberar()
    // tiene que dejarla libre al instante.
    @Test fun sinModeloNoQuedaTomada() {
        val v = VueloInferencia(2_000 * ms)
        assertTrue(v.intentarIniciar(0))
        v.liberar()
        assertTrue(v.intentarIniciar(1 * ms))
    }

    @Test fun elTimeoutDeSeguridadLiberaUnResultadoPerdido() {
        val v = VueloInferencia(2_000 * ms)
        assertTrue(v.intentarIniciar(0))
        assertFalse(v.intentarIniciar(1_999 * ms))
        assertFalse(v.ocupado(2_000 * ms))
        assertTrue(v.intentarIniciar(2_000 * ms))
    }

    @Test fun terminarSinFrameNoDejaOcupada() {
        val v = VueloInferencia()
        v.terminar(10 * ms)
        assertFalse(v.ocupado(11 * ms))
    }
}
