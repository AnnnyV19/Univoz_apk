package com.univoz.senas

import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.util.zip.GZIPInputStream
import kotlin.math.abs
import kotlin.math.max

/**
 * Lector del banco de paridad test/golden/paridad_manos.jsonl.gz (lo genera
 * tools/rig-tests/gen_paridad_manos.mjs con la captura web). Cada linea es un
 * frame: `in` (entrada del detector) y `esp` (salida esperada de la web).
 */
object FixtureParidad {
    class Frame(
        val i: Int,
        val t: Double,
        val skew: Double,
        val pose: DoubleArray?,
        val candidatas: List<CapturaManos.Candidata>,
        val esperado: JsonObject,
    )

    class Tramo(val nombre: String, val frames: List<Frame>)

    fun cargar(recurso: String = "/paridad_manos.jsonl.gz"): List<Tramo> {
        val flujo = FixtureParidad::class.java.getResourceAsStream(recurso)
            ?: error("falta $recurso en los recursos de test (test/golden)")
        val tramos = linkedMapOf<String, MutableList<Frame>>()
        GZIPInputStream(flujo).bufferedReader().useLines { lineas ->
            for (linea in lineas) {
                if (linea.isBlank()) continue
                val l = JsonParser.parseString(linea).asJsonObject
                val entrada = l.getAsJsonObject("in")
                val pose = entrada.get("pose").takeUnless { it.isJsonNull }?.asJsonArray
                tramos.getOrPut(l.get("tramo").asString) { mutableListOf() } += Frame(
                    i = l.get("i").asInt,
                    t = entrada.get("t").asDouble,
                    skew = entrada.get("skew")?.takeUnless { it.isJsonNull }?.asDouble ?: 0.0,
                    pose = pose?.let { puntos(it, 4) },
                    candidatas = entrada.getAsJsonArray("cand").map { c ->
                        val o = c.asJsonObject
                        CapturaManos.Candidata(
                            puntos(o.getAsJsonArray("lm"), 3),
                            o.get("label")?.takeUnless { it.isJsonNull }?.asString,
                            o.get("conf")?.takeUnless { it.isJsonNull }?.asDouble,
                        )
                    },
                    esperado = l.getAsJsonObject("esp"),
                )
            }
        }
        return tramos.map { (nombre, frames) -> Tramo(nombre, frames) }
    }

    /** Puntos [[x, y, z, vis?], ...] a un arreglo plano de [ancho] valores por punto. */
    private fun puntos(arr: JsonArray, ancho: Int): DoubleArray =
        DoubleArray(arr.size() * ancho).also { out ->
            arr.forEachIndexed { i, p ->
                val v = p.asJsonArray
                for (k in 0 until ancho) {
                    out[i * ancho + k] = if (k < v.size() && !v[k].isJsonNull) v[k].asDouble
                    else if (k == 3) 1.0 else 0.0
                }
            }
        }

    private fun cerca(esperado: Double, obtenido: Double) =
        abs(esperado - obtenido) <= 1e-9 * max(1.0, abs(esperado))

    private fun numeroONulo(e: JsonElement?): Double? =
        if (e == null || e.isJsonNull) null else e.asDouble

    private fun indice(candidatas: List<CapturaManos.Candidata>, puntos: DoubleArray?): Int? =
        puntos?.let { p -> candidatas.indexOfFirst { it.puntos.contentEquals(p) } }

    private fun error(stage: String?, code: String?, side: String?) =
        "[\"$stage\",\"$code\",${side?.let { "\"$it\"" } ?: "null"}]"

    /**
     * Compara lo que la web espera con lo que dio [r]; [desajuste] recibe
     * (campo, esperado, obtenido) por cada diferencia.
     */
    fun comparar(
        frame: Frame,
        r: CapturaManos.Resultado,
        desajuste: (String, Any?, Any?) -> Unit,
    ) {
        val esp = frame.esperado
        fun igual(campo: String, esperado: Any?, obtenido: Any?) {
            if (esperado != obtenido) desajuste(campo, esperado, obtenido)
        }
        fun numero(campo: String, esperado: Double?, obtenido: Double?) {
            val ok = if (esperado == null || obtenido == null) esperado == obtenido
            else cerca(esperado, obtenido)
            if (!ok) desajuste(campo, esperado, obtenido)
        }

        val gate = esp.getAsJsonObject("gate")
        fun enteros(a: JsonArray) = a.map { it.asInt }
        igual("gate.accepted", enteros(gate.getAsJsonArray("accepted")), r.gate.accepted)
        igual("gate.unanchored", enteros(gate.getAsJsonArray("unanchored")), r.gate.unanchored)
        igual("gate.rejected", gate.getAsJsonArray("rejected").map {
            it.asJsonArray[0].asInt to it.asJsonArray[1].asString
        }, r.gate.rejected)
        igual("gate.passed", enteros(gate.getAsJsonArray("passed")), r.passed)

        val assign = esp.getAsJsonObject("assign")
        igual("assign.mode", assign.get("mode").asString, r.assignment.mode)
        igual("assign.sides", assign.getAsJsonArray("sides").map {
            if (it.isJsonNull) null else it.asString
        }, r.assignment.sideByIndex)
        igual("usable", esp.getAsJsonArray("usable").map { it.asBoolean }, r.usable)

        for ((lado, vista) in listOf("left" to r.tracking.left, "right" to r.tracking.right)) {
            val e = esp.getAsJsonObject(lado)
            fun indiceEsperado(k: String) = e.get(k).takeUnless { it.isJsonNull }?.asInt
            igual("$lado.raw", indiceEsperado("raw"), indice(frame.candidatas, vista.raw))
            igual("$lado.detected", indiceEsperado("detected"),
                indice(frame.candidatas, vista.detected))
            igual("$lado.state", e.get("state").asString, vista.state)
            igual("$lado.surface", e.get("surface").takeUnless { it.isJsonNull }?.asString,
                vista.surface)
            igual("$lado.surfaceChanges", e.get("surfaceChanges").asInt, vista.surfaceChanges)
            igual("$lado.recoveryFrames", e.get("recoveryFrames").asInt, vista.recoveryFrames)
            numero("$lado.restBlend", e.get("restBlend").asDouble, vista.restBlend)
            numero("$lado.cost", numeroONulo(e.get("cost")), r.tracking.costs[lado])
            val render = e.get("render")
            when {
                render.isJsonNull -> igual("$lado.render", null,
                    vista.render?.let { "${it.size / 3} puntos" })
                render.isJsonPrimitive -> igual("$lado.render", "raw",
                    if (vista.render != null && vista.raw != null &&
                        vista.render.contentEquals(vista.raw)) "raw" else "otro")
                else -> {
                    val puntos = render.asJsonArray
                    val obtenido = vista.render
                    if (obtenido == null || obtenido.size != puntos.size() * 3) {
                        igual("$lado.render", "${puntos.size()} puntos",
                            obtenido?.let { "${it.size / 3} puntos" })
                    } else {
                        puntos.forEachIndexed { i, p ->
                            for (k in 0 until 3) numero("$lado.render[$i][$k]",
                                p.asJsonArray[k].asDouble, obtenido[i * 3 + k])
                        }
                    }
                }
            }
        }

        val contacto = esp.getAsJsonObject("contact")
        igual("contact.active", contacto.get("active").asBoolean, r.tracking.contact.active)
        numero("contact.wrist", numeroONulo(contacto.get("wrist")),
            r.tracking.contact.wristDistanceShoulders)
        numero("contact.overlap", contacto.get("overlap").asDouble, r.tracking.contact.boxOverlap)

        val esperados = esp.getAsJsonArray("err_captura").map {
            val a = it.asJsonArray
            error(a[0].asString, a[1].asString, a[2].takeUnless { s -> s.isJsonNull }?.asString)
        }.sorted()
        val obtenidos = r.errors.map { error(it["stage"], it["code"], it["side"]) }.sorted()
        igual("err_captura", esperados, obtenidos)
    }
}
