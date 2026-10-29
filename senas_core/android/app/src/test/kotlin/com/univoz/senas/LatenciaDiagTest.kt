package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LatenciaDiagTest {
    @Test fun ventanaSinMuestrasEsGuion() {
        assertEquals("-", VentanaMs().resumen())
    }

    @Test fun ventanaDaP50P95Max() {
        val v = VentanaMs()
        for (i in 1..100) v.agregar(i.toDouble())
        assertEquals("50.0/95.0/100.0", v.resumen())
    }

    @Test fun ventanaEsUnAnillo() {
        val v = VentanaMs(4)
        for (i in 1..10) v.agregar(i.toDouble())
        assertEquals("8.0/10.0/10.0", v.resumen())
    }

    @Test fun ventanaIgnoraNoFinitos() {
        val v = VentanaMs()
        v.agregar(Double.NaN)
        v.agregar(Double.POSITIVE_INFINITY)
        assertEquals("-", v.resumen())
    }

    @Test fun cerrarSiTocaEsperaLaVentanaYReinicia() {
        val m = MedidorNativo("REALTIME", ventanaMs = 1000)
        // El primer llamado solo marca el inicio de la ventana.
        assertNull(m.cerrarSiToca(0, "alto", "GPU", "holistic"))
        repeat(30) { m.frameEntrada() }
        repeat(15) { m.frameSalida() }
        repeat(2) { m.descarteOcupado() }
        m.descarteFps()
        m.edadEmision.agregar(120.0)
        m.inferencia.agregar(80.0)
        assertNull(m.cerrarSiToca(500, "alto", "GPU", "holistic"))
        val linea = m.cerrarSiToca(1000, "alto", "GPU", "holistic")
        assertNotNull(linea)
        assertTrue(linea!!, linea.contains("win=1000ms"))
        assertTrue(linea, linea.contains("in=30.0/s out=15.0/s"))
        assertTrue(linea, linea.contains("drop_busy=2 drop_fps=1 drop_idle=0"))
        assertTrue(linea, linea.contains("tier=alto delegate=GPU mode=holistic ts_src=REALTIME"))
        assertTrue(linea, linea.contains("infer=80.0/80.0/80.0"))
        assertTrue(linea, linea.contains("cap_emit=120.0/120.0/120.0"))
        assertTrue(linea, linea.contains("prep=-"))
        // Ventana nueva: sin datos y sin cerrar hasta otro segundo.
        assertNull(m.cerrarSiToca(1500, "alto", "GPU", "holistic"))
        val vacia = m.cerrarSiToca(2000, null, "CPU", "separado")!!
        assertTrue(vacia, vacia.contains("in=0.0/s out=0.0/s"))
        assertTrue(vacia, vacia.contains("tier=- delegate=CPU mode=separado"))
        assertTrue(vacia, vacia.contains("infer=-"))
    }
}
