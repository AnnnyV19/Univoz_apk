package com.univoz.senas

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * Math.hypot tal como lo calcula V8 (Chrome/WebView/node): normaliza por el
 * maximo y suma con Kahan. java.lang.Math.hypot puede diferir en el ultimo
 * bit, y la captura de manos debe dar exactamente lo mismo que la web
 * (ParidadManosTest). Cada llamada usa la misma aridad que en el JS: un
 * tercer argumento 0 cambia la compensacion de Kahan.
 */
internal object JsMath {
    fun hypot(a: Double, b: Double): Double = hypotDe(doubleArrayOf(a, b))

    fun hypot(a: Double, b: Double, c: Double): Double = hypotDe(doubleArrayOf(a, b, c))

    private fun hypotDe(values: DoubleArray): Double {
        var max = 0.0
        var nan = false
        for (i in values.indices) {
            val v = values[i]
            if (v.isNaN()) {
                nan = true
                values[i] = 0.0
            } else {
                values[i] = abs(v)
                if (values[i] > max) max = values[i]
            }
        }
        if (max == Double.POSITIVE_INFINITY) return Double.POSITIVE_INFINITY
        if (nan) return Double.NaN
        if (max == 0.0) return 0.0
        var sum = 0.0
        var compensation = 0.0
        for (v in values) {
            val n = v / max
            val summand = n * n - compensation
            val preliminary = sum + summand
            compensation = (preliminary - sum) - summand
            sum = preliminary
        }
        return sqrt(sum) * max
    }
}
