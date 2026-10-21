package com.univoz.senas

/**
 * Compuerta de backpresion de UN modelo: a lo mucho un frame en vuelo. Se
 * libera con el resultado, con el error del modelo o por [timeoutNs] por si
 * nada de eso llega. Hilo-seguro (el frame entra por el hilo de camara y el
 * resultado/error llega por el del modelo). Sin dependencias de Android para
 * poder probarla en JVM.
 */
class VueloInferencia(private val timeoutNs: Long = 2_000_000_000L) {
    private val lock = Any()
    private var enVuelo = false
    private var desdeNs = 0L

    /** true si arranca un frame; false si ya hay uno en vuelo y no vencio. */
    fun intentarIniciar(ahoraNs: Long): Boolean = synchronized(lock) {
        if (enVuelo && ahoraNs - desdeNs < timeoutNs) return false
        enVuelo = true
        desdeNs = ahoraNs
        true
    }

    /** Hay un frame en vuelo que aun no vence. */
    fun ocupado(ahoraNs: Long): Boolean = synchronized(lock) {
        enVuelo && ahoraNs - desdeNs < timeoutNs
    }

    /** Libera la compuerta; devuelve los ms desde que arranco el frame. */
    fun terminar(ahoraNs: Long): Double = synchronized(lock) {
        enVuelo = false
        (ahoraNs - desdeNs) / 1e6
    }

    /** Libera sin medir (error, cierre o frame que no llego a enviarse). */
    fun liberar() = synchronized(lock) { enVuelo = false }
}
