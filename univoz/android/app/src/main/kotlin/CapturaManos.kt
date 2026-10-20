package com.univoz.senas

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Captura de manos: espejo de assets/avatar_viewer/rig_hand_capture.mjs
 * (createHandCapture) y de handUsable (rig_motion_frame.mjs).
 *
 * Candidatas del detector -> compuerta anti-alucinacion -> compuerta de
 * nacimiento -> lado por cadena de brazo -> mano utilizable -> seguimiento ->
 * desacuerdo muneca mano/pose. ParidadManosTest exige la misma salida que la
 * web frame a frame; un cambio va primero en el JS.
 */
class CapturaManos(private val birthFrames: Int = 3) {
    /**
     * [puntos]: 21 x (x, y, z) de imagen. [etiqueta]: handedness del detector;
     * solo pista, el lado lo decide la cadena de brazo.
     */
    class Candidata(val puntos: DoubleArray, val etiqueta: String?, val confianza: Double?)

    data class Utilizable(val ok: Boolean, val code: String?, val landmark: Int?)

    /** `fallback` (sin pose), `pose_arm_chain` o `ambiguous`. */
    class Asignacion(
        val mode: String,
        val sideByIndex: List<String?>,
        val costs: List<Pair<Double, Double>>,
    )

    class Anatomia(val side: String?, val sideLocked: Boolean, val sideAmbiguous: Boolean)

    class Resultado(
        val gate: HandCandidateGate.Result,
        val passed: List<Int>,
        val assignment: Asignacion,
        val usable: List<Boolean>,
        val sideAmbiguous: Boolean,
        val shoulderWidth: Double,
        val tracking: HandTrackCoordinator.Result,
        val errors: List<Map<String, String>>,
        /** Evidencia cruda para reconocimiento (raw aunque se retenga). */
        val left: DoubleArray?,
        val right: DoubleArray?,
        /** Manos estabilizadas para el avatar. */
        val renderLeft: DoubleArray?,
        val renderRight: DoubleArray?,
    )

    private val tracker = HandTrackCoordinator()
    private var birthGate = HandCandidateGate.BirthGate(frames = birthFrames)
    private val wristFrames = IntArray(2)
    private val wristReported = BooleanArray(2)

    fun reset() {
        tracker.reset()
        birthGate = HandCandidateGate.BirthGate(frames = birthFrames)
        wristFrames.fill(0)
        wristReported.fill(false)
    }

    /**
     * [pose]: 33 x (x, y, z, visibility) de imagen usada en este frame (o
     * null). [poseTimestampMs]: instante de esa pose; el desfase decide si el
     * desacuerdo de muneca cuenta (solo fusion directa, <= 50 ms).
     */
    fun process(
        candidatas: List<Candidata>,
        pose: DoubleArray?,
        timestampMs: Double,
        poseTimestampMs: Double? = null,
    ): Resultado {
        val t = timestampMs
        val errors = mutableListOf<Map<String, String>>()
        val entradas = candidatas.map { HandCandidateGate.Input(it.puntos, it.confianza ?: .5) }
        val gate = HandCandidateGate.gate(entradas, pose)
        val passed = birthGate.filter(entradas, gate.accepted, gate.unanchored)
        gate.rejected.forEach { (_, code) -> errors += error("association", code) }

        val kept = passed.map { candidatas[it] }
        val ls = posePoint(pose, 11)
        val rs = posePoint(pose, 12)
        val shoulderWidth = if (finite(ls) && finite(rs))
            max(.05, JsMath.hypot(ls[0] - rs[0], ls[1] - rs[1])) else .4
        val assignment = assignHandsByArmChain(kept.map { it.puntos }, pose, shoulderWidth)
        val sideAmbiguous = assignment.mode == "ambiguous"
        if (sideAmbiguous) errors += error("association", "hand_side_ambiguous")

        val usable = mutableListOf<Boolean>()
        val trackCandidates = kept.mapIndexed { index, candidata ->
            val anatomy = resolveAnatomicalHandSide(assignment, index)
            val check = handUsable(candidata.puntos)
            usable += check.ok
            if (!check.ok) {
                errors += error("capture", check.code!!, anatomy.side,
                    landmark = check.landmark)
            }
            HandTrackCoordinator.Candidate(
                if (check.ok) candidata.puntos else null,
                if (check.ok) anatomy.side else null,
                candidata.confianza ?: .5,
                sideLocked = check.ok && anatomy.sideLocked,
                sideAmbiguous = check.ok && anatomy.sideAmbiguous,
            )
        }
        // Sin cadena de brazo confiable el seguimiento no recibe pista de
        // pose (usa ancho de hombros .4 y su propia continuidad).
        val poseHint = if (assignment.mode == "pose_arm_chain") {
            val lw = posePoint(pose, 15)
            val rw = posePoint(pose, 16)
            HandTrackCoordinator.PoseHint(lw[0], lw[1], rw[0], rw[1], shoulderWidth)
        } else null
        val tracking = tracker.update(trackCandidates, poseHint, t)
        errors += tracking.errors

        val continuityHeld = tracking.errors.any { it["code"] == "hand_assignment_hysteresis" }
        val skewMode = HandTrackCoordinator.classifySourceSkew(abs(t - (poseTimestampMs ?: t)))
        listOf(Triple(0, "left", 15), Triple(1, "right", 16)).forEach { (k, side, poseIndex) ->
            val detected = (if (k == 0) tracking.left else tracking.right).detected
            val handWrist = detected?.let { doubleArrayOf(it[0], it[1], it[2]) }
            val poseWrist = posePoint(pose, poseIndex)
            if (handWrist == null || !finite(handWrist) || !finite(poseWrist)) return@forEach
            val residual = JsMath.hypot(handWrist[0] - poseWrist[0],
                handWrist[1] - poseWrist[1]) / shoulderWidth
            // Una pose hasta 120 ms mas vieja que las manos no es una union
            // rota: solo la fusion directa acusa desacuerdo, y solo si
            // persiste 3 frames (una vez por episodio).
            val disagreement = residual > .25 && !continuityHeld && skewMode == "direct"
            if (disagreement) {
                wristFrames[k]++
                if (wristFrames[k] >= 3 && !wristReported[k]) {
                    wristReported[k] = true
                    errors += error("fusion", "wrist_disagreement", side, landmark = 0,
                        status = "yellow")
                }
            } else {
                wristFrames[k] = 0
                wristReported[k] = false
            }
        }
        return Resultado(
            gate,
            passed,
            assignment,
            usable,
            sideAmbiguous,
            shoulderWidth,
            tracking,
            errors,
            tracking.left.raw ?: tracking.left.detected,
            tracking.right.raw ?: tracking.right.detected,
            tracking.left.render,
            tracking.right.render,
        )
    }

    companion object {
        const val HAND_MARGIN = .15

        /** Conexiones de la mano (mismas que HAND_CONNECTIONS de rig_motion_frame.mjs). */
        private val HAND_CONNECTIONS = arrayOf(
            0 to 1, 1 to 2, 2 to 3, 3 to 4,
            0 to 5, 5 to 6, 6 to 7, 7 to 8,
            0 to 9, 9 to 10, 10 to 11, 11 to 12,
            0 to 13, 13 to 14, 14 to 15, 15 to 16,
            0 to 17, 17 to 18, 18 to 19, 19 to 20,
            5 to 9, 9 to 13, 13 to 17,
        )

        private fun error(
            stage: String,
            code: String,
            side: String? = null,
            landmark: Int? = null,
            status: String? = null,
        ): Map<String, String> = buildMap {
            put("stage", stage)
            put("code", code)
            side?.let { put("side", it) }
            landmark?.let { put("landmark", it.toString()) }
            status?.let { put("status", it) }
        }

        private fun clamp(value: Double) = max(0.0, min(1.0, value))

        private fun finite(p: DoubleArray) = p[0].isFinite() && p[1].isFinite() && p[2].isFinite()

        /** (x, y, z, visibility) del punto [i] de la pose; NaN si no hay pose. */
        private fun posePoint(pose: DoubleArray?, i: Int): DoubleArray =
            if (pose == null || pose.size < (i + 1) * 4) DoubleArray(4) { Double.NaN }
            else doubleArrayOf(pose[i * 4], pose[i * 4 + 1], pose[i * 4 + 2], pose[i * 4 + 3])

        /**
         * No alimentar el normalizador con manos parcialmente corruptas: en
         * una oclusion MediaPipe puede devolver un punto aislado fuera de
         * cuadro que deforma angulo y orientacion de toda la mano.
         */
        fun handUsable(points: DoubleArray?): Utilizable {
            if (points == null || points.size != 63) {
                return Utilizable(false, "hand_landmarks_incomplete", null)
            }
            val nonFinite = (0 until 21).firstOrNull { i ->
                !(points[i * 3].isFinite() && points[i * 3 + 1].isFinite() &&
                    points[i * 3 + 2].isFinite())
            }
            if (nonFinite != null) return Utilizable(false, "point_non_finite", nonFinite)
            fun x(i: Int) = points[i * 3]
            fun y(i: Int) = points[i * 3 + 1]
            fun z(i: Int) = points[i * 3 + 2]
            // La muneca debe verse; las puntas pueden salirse un margen chico.
            if (!(x(0) >= 0 && x(0) <= 1 && y(0) >= 0 && y(0) <= 1)) {
                return Utilizable(false, "wrist_out_of_frame", 0)
            }
            val inside = (0 until 21).count { i ->
                x(i) >= -HAND_MARGIN && x(i) <= 1 + HAND_MARGIN &&
                    y(i) >= -HAND_MARGIN && y(i) <= 1 + HAND_MARGIN
            }
            if (inside < 15) {
                val outside = (0 until 21).firstOrNull { i ->
                    x(i) < -HAND_MARGIN || x(i) > 1 + HAND_MARGIN ||
                        y(i) < -HAND_MARGIN || y(i) > 1 + HAND_MARGIN
                }
                return Utilizable(false, "hand_out_of_frame", outside)
            }
            val scale = JsMath.hypot(x(9) - x(0), y(9) - y(0))
            if (!scale.isFinite() || scale < .015 || scale > .65) {
                return Utilizable(false, "hand_scale_invalid", 9)
            }
            // Cada conexion plausible respecto de la escala del MCP medio:
            // atrapa puntos intercambiados o picos sin rechazar manos
            // abiertas o cerradas.
            for ((a, b) in HAND_CONNECTIONS) {
                val d = JsMath.hypot(x(a) - x(b), y(a) - y(b), z(a) - z(b))
                if (!d.isFinite() || d < scale * .018 || d > scale * 2.2) {
                    return Utilizable(false, "hand_segment_invalid", b)
                }
            }
            return Utilizable(true, null, null)
        }

        private fun normalizedVector(fx: Double, fy: Double, tx: Double, ty: Double): DoubleArray? {
            val x = tx - fx
            val y = ty - fy
            val z = 0.0 - 0.0
            val length = JsMath.hypot(x, y, z)
            return if (length > 1e-8) doubleArrayOf(x / length, y / length, z / length) else null
        }

        /**
         * Costo hombro -> codo -> muneca en x/y de imagen (la z de la pose es
         * relativa a la cadera y la de la mano a su muneca: no se mezclan).
         */
        private fun armChainCost(
            hand: DoubleArray,
            side: String,
            pose: DoubleArray?,
            shoulderWidth: Double,
        ): Double {
            val (si, ei, wi) = if (side == "left") Triple(11, 13, 15) else Triple(12, 14, 16)
            val shoulder = posePoint(pose, si)
            val elbow = posePoint(pose, ei)
            val expected = posePoint(pose, wi)
            val wx = hand[0]
            val wy = hand[1]
            if (!listOf(shoulder[0], shoulder[1], elbow[0], elbow[1], expected[0], expected[1],
                    wx, wy).all { it.isFinite() }
            ) return Double.POSITIVE_INFINITY
            fun distance(ax: Double, ay: Double, bx: Double, by: Double) =
                JsMath.hypot(ax - bx, ay - by, 0.0 - 0.0)
            val endpoint = distance(wx, wy, expected[0], expected[1]) / shoulderWidth
            val expectedDirection = normalizedVector(shoulder[0], shoulder[1], expected[0], expected[1])
            val observedDirection = normalizedVector(shoulder[0], shoulder[1], wx, wy)
            val direction = if (expectedDirection != null && observedDirection != null) {
                1 - clamp((expectedDirection[0] * observedDirection[0] +
                    expectedDirection[1] * observedDirection[1] +
                    expectedDirection[2] * observedDirection[2] + 1) / 2)
            } else .5
            val expectedLower = distance(elbow[0], elbow[1], expected[0], expected[1])
            val observedLower = distance(elbow[0], elbow[1], wx, wy)
            val chain = abs(observedLower - expectedLower) / shoulderWidth
            // Una muneca que la pose no ve es una estimacion (a veces encima
            // de la otra mano): pesa menos que una visible.
            val visibility = if (pose == null) 1.0 else expected[3]
            val unseen = if (visibility.isFinite()) (1 - clamp(visibility)) * .6 else 0.0
            return endpoint + direction * .35 + chain * .20 + unseen
        }

        /** Lado fisico de cada mano completa por la cadena de brazo de la pose. */
        fun assignHandsByArmChain(
            hands: List<DoubleArray>,
            pose: DoubleArray?,
            shoulderWidth: Double,
        ): Asignacion {
            val valid = hands.withIndex().filter {
                HandTrackCoordinator.validHandLandmarks(it.value)
            }
            val sideByIndex = MutableList<String?>(hands.size) { null }
            val ls = posePoint(pose, 11)
            val rs = posePoint(pose, 12)
            val width = max(.05, shoulderWidth)
            if (valid.isEmpty() || !finite(ls) || !finite(rs)) {
                return Asignacion("fallback", sideByIndex, emptyList())
            }
            val costs = valid.map {
                Pair(armChainCost(it.value, "left", pose, width),
                    armChainCost(it.value, "right", pose, width))
            }
            val margin = max(.06, width * .16)
            if (valid.size >= 2) {
                val normal = costs[0].first + costs[1].second
                val crossed = costs[0].second + costs[1].first
                if (normal.isFinite() && crossed.isFinite() && abs(normal - crossed) >= margin) {
                    val leftIndex = if (normal < crossed) 0 else 1
                    val rightIndex = if (leftIndex == 0) 1 else 0
                    sideByIndex[valid[leftIndex].index] = "left"
                    sideByIndex[valid[rightIndex].index] = "right"
                    return Asignacion("pose_arm_chain", sideByIndex, costs)
                }
            } else {
                val only = costs[0]
                if (only.first.isFinite() && only.second.isFinite() &&
                    abs(only.first - only.second) >= margin
                ) {
                    sideByIndex[valid[0].index] = if (only.first < only.second) "left" else "right"
                    return Asignacion("pose_arm_chain", sideByIndex, costs)
                }
            }
            return Asignacion("ambiguous", sideByIndex, costs)
        }

        /**
         * Lado solo desde la cadena de brazo: la etiqueta del detector no es
         * segura antes (la camara frontal puede invertir la convencion).
         */
        fun resolveAnatomicalHandSide(assignment: Asignacion, index: Int): Anatomia {
            val side = if (assignment.mode == "pose_arm_chain")
                assignment.sideByIndex.getOrNull(index) else null
            return Anatomia(side, side != null, side == null)
        }
    }
}
