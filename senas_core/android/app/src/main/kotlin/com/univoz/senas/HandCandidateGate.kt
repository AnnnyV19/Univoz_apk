package com.univoz.senas

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Compuerta de manos ANTES de asignar lados, guiada por hombros y munecas de
 * la pose. Espejo de assets/avatar_viewer/rig_hand_gate.mjs (mismos casos en
 * HandCandidateGateTest).
 *
 * Rechaza: hand_duplicate (misma mano detectada dos veces: una copia por lado
 * hacia mover ambas manos del avatar iguales), hand_far_from_arm (lejos de las
 * dos munecas visibles: cara, fondo) y hand_scale_implausible (tamano
 * imposible respecto a los hombros). Sin muneca visible la mano pasa como
 * `unanchored` y [BirthGate] le exige varios frames seguidos.
 */
object HandCandidateGate {
    private const val MIN_VIS = .5

    /** [points]: 21 x (x, y, z) en coordenadas de imagen. */
    class Input(val points: DoubleArray, val confidence: Double)

    data class Result(
        val accepted: List<Int>,
        val rejected: List<Pair<Int, String>>,
        val unanchored: List<Int>,
    )

    private class Box(val x0: Double, val y0: Double, val x1: Double, val y1: Double)

    private fun box(p: DoubleArray): Box {
        var x0 = Double.POSITIVE_INFINITY; var y0 = Double.POSITIVE_INFINITY
        var x1 = Double.NEGATIVE_INFINITY; var y1 = Double.NEGATIVE_INFINITY
        for (i in 0 until 21) {
            x0 = min(x0, p[i * 3]); y0 = min(y0, p[i * 3 + 1])
            x1 = max(x1, p[i * 3]); y1 = max(y1, p[i * 3 + 1])
        }
        return Box(x0, y0, x1, y1)
    }

    private fun overlap(a: Box, b: Box): Double {
        val w = max(0.0, min(a.x1, b.x1) - max(a.x0, b.x0))
        val h = max(0.0, min(a.y1, b.y1) - max(a.y0, b.y0))
        fun area(r: Box) = max(1e-9, (r.x1 - r.x0) * (r.y1 - r.y0))
        return w * h / min(area(a), area(b))
    }

    fun gate(
        candidates: List<Input>,
        pose: DoubleArray?,
        maxWristDistance: Double = 1.0,
        minHandScale: Double = .12,
        maxHandScale: Double = .9,
        duplicateDistance: Double = .2,
        duplicateOverlap: Double = .5,
    ): Result {
        val rejected = mutableListOf<Pair<Int, String>>()
        val valid = candidates.withIndex().filter { (index, c) ->
            val ok = c.points.size >= 63 && c.points.all { it.isFinite() }
            if (!ok) rejected += index to "hand_landmarks_invalid"
            ok
        }
        fun vis(i: Int) = pose!![i * 4 + 3]
        val shouldersOk = pose != null && pose.size >= 33 * 4 &&
            vis(11) >= MIN_VIS && vis(12) >= MIN_VIS &&
            hypot(pose[44] - pose[48], pose[45] - pose[49]) > 1e-3
        if (!shouldersOk) {
            return Result(valid.map { it.index }, rejected.sortedBy { it.first }, emptyList())
        }
        val p = pose!!
        val sw = hypot(p[44] - p[48], p[45] - p[49])
        val wrists = listOf(15, 16).filter { vis(it) >= MIN_VIS }
            .map { p[it * 4] to p[it * 4 + 1] }

        val accepted = mutableListOf<Int>()
        val unanchored = mutableListOf<Int>()
        val kept = mutableListOf<Triple<Double, Double, Box>>()
        for ((index, c) in valid.sortedByDescending { it.value.confidence }) {
            val pts = c.points
            val wx = pts[0]; val wy = pts[1]
            val scale = hypot(wx - pts[27], wy - pts[28]) / sw
            if (scale !in minHandScale..maxHandScale) {
                rejected += index to "hand_scale_implausible"
                continue
            }
            val b = box(pts)
            if (kept.any { (kx, ky, kb) ->
                    hypot(kx - wx, ky - wy) / sw < duplicateDistance &&
                        overlap(kb, b) > duplicateOverlap
                }) {
                rejected += index to "hand_duplicate"
                continue
            }
            if (wrists.isNotEmpty()) {
                val near = wrists.minOf { (x, y) -> hypot(x - wx, y - wy) } / sw
                if (near > maxWristDistance) {
                    rejected += index to "hand_far_from_arm"
                    continue
                }
            } else {
                unanchored += index
            }
            kept += Triple(wx, wy, b)
            accepted += index
        }
        return Result(accepted.sorted(), rejected.sortedBy { it.first }, unanchored.sorted())
    }

    /** Exige [frames] detecciones seguidas en el mismo lugar a manos sin ancla. */
    class BirthGate(private val frames: Int = 3, private val maxJump: Double = .08) {
        private var pending = listOf<Pair<Pair<Double, Double>, Int>>()

        fun filter(candidates: List<Input>, accepted: List<Int>, unanchored: List<Int>): List<Int> {
            val out = mutableListOf<Int>()
            val next = mutableListOf<Pair<Pair<Double, Double>, Int>>()
            for (index in accepted) {
                if (index !in unanchored) {
                    out += index
                    continue
                }
                val w = candidates[index].points[0] to candidates[index].points[1]
                val prev = pending.firstOrNull { (pw, _) ->
                    hypot(pw.first - w.first, pw.second - w.second) <= maxJump
                }
                val count = (prev?.second ?: 0) + 1
                next += w to count
                if (count >= frames) out += index
            }
            pending = next
            return out
        }

        fun reset() { pending = emptyList() }
    }
}
