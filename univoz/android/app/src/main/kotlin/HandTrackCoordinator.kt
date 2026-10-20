package com.univoz.senas

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Seguimiento temporal de manos: espejo de assets/avatar_viewer/rig_tracking.mjs
 * (createHandTrackCoordinator y sus piezas). Debe dar la misma salida que la
 * web frame a frame; lo fija ParidadManosTest con test/golden/paridad_manos.
 * Un cambio de comportamiento va primero en el JS, se regenera el fixture
 * (tools/rig-tests/gen_paridad_manos.mjs) y luego se porta aqui.
 *
 * Deteccion cruda (raw), aceptada y render estabilizado van separados: el
 * reconocimiento usa raw; el avatar, render.
 */
class HandTrackCoordinator {
    /**
     * [points]: 21 x (x, y, z) de imagen; null = mano que no paso la
     * validacion (cuenta como `hand_landmarks_invalid`).
     */
    class Candidate(
        val points: DoubleArray?,
        val side: String?,
        val confidence: Double? = null,
        /** El lado lo fijo la cadena de brazo de la pose. */
        val sideLocked: Boolean = false,
        /** La pose no pudo distinguir el lado este frame. */
        val sideAmbiguous: Boolean = false,
    )

    /** Munecas de la pose en imagen; solo con cadena de brazo confiable. */
    data class PoseHint(
        val leftWristX: Double,
        val leftWristY: Double,
        val rightWristX: Double,
        val rightWristY: Double,
        val shoulderWidth: Double,
    )

    class Vec3(val x: Double, val y: Double, val z: Double) {
        val finite: Boolean get() = x.isFinite() && y.isFinite() && z.isFinite()
    }

    /** Marco de palma: el CMC fija el signo del eje radial (palmFrameV2). */
    class PalmFrame(
        val radial: Vec3,
        val forward: Vec3,
        val normal: Vec3,
        val cmcRadialDot: Double,
    )

    class Surface(val surface: String, val confidence: Double, val score: Double, val normal: Vec3)

    class Transition(
        val accepted: Boolean,
        val flipped: Boolean,
        val action: String,
        val orientationDistance: Double,
        val pendingCount: Int,
        val pendingFrame: PalmFrame?,
    )

    data class Contact(
        val active: Boolean,
        val wristDistanceShoulders: Double?,
        val boxOverlap: Double,
    )

    class TrackView(
        val side: String,
        val sideLocked: Boolean,
        val state: String,
        val landmarks: DoubleArray?,
        /** Deteccion cruda asignada a este lado este frame (aunque se retenga). */
        val raw: DoubleArray?,
        val accepted: DoubleArray?,
        /** Deteccion aceptada este frame; null si se retuvo o no hubo. */
        val detected: DoubleArray?,
        /** Mano estabilizada para el avatar. */
        val render: DoubleArray?,
        val velocity: Vec3,
        val surface: String?,
        val surfaceConfidence: Double,
        val surfaceChanges: Int,
        val recoveryFrames: Int,
        val confidence: Double,
        val restBlend: Double,
    )

    class Result(
        val left: TrackView,
        val right: TrackView,
        val contact: Contact,
        val costs: Map<String, Double?>,
        val candidateCosts: List<Pair<Double, Double>>,
        val errors: List<Map<String, String>>,
    )

    private class Track(val side: String) {
        var sideLocked = false
        var state = "LOST"
        var landmarks: DoubleArray? = null
        var rawLandmarks: DoubleArray? = null
        var acceptedLandmarks: DoubleArray? = null
        var renderLandmarks: DoubleArray? = null
        var detected: DoubleArray? = null
        var velocity = Vec3(0.0, 0.0, 0.0)
        var frame: PalmFrame? = null
        var surface: String? = null
        var surfaceConfidence = 0.0
        var surfaceChanges = 0
        var pendingSurface: String? = null
        var pendingSurfaceCount = 0
        var confidence = 0.0
        var lastSeenMs: Double? = null
        var hits = 0
        var pendingOrientationFrame: PalmFrame? = null
        var pendingOrientationCount = 0
        var pendingPosition: Vec3? = null
        var pendingPositionCount = 0
        var recoveryFrom: DoubleArray? = null
        var recoveryTarget: DoubleArray? = null
        var recoveryFrames = 0
        var lastRejectCode: String? = null
        var lastEventCode: String? = null
        var restBlend = 0.0
    }

    private class Gated(val mode: String?, val pendingMode: String?, val pendingCount: Int, val held: Boolean)

    private var left = Track("left")
    private var right = Track("right")
    private var assignmentMode: String? = null
    private var pendingAssignmentMode: String? = null
    private var pendingAssignmentCount = 0

    fun reset() {
        left = Track("left")
        right = Track("right")
        assignmentMode = null
        pendingAssignmentMode = null
        pendingAssignmentCount = 0
    }

    fun update(rawCandidates: List<Candidate?>, pose: PoseHint?, timestampMs: Long): Result =
        update(rawCandidates, pose, timestampMs.toDouble())

    fun update(rawCandidates: List<Candidate?>, pose: PoseHint?, timestampMs: Double): Result {
        val t = orDefault(timestampMs, 0.0)
        val tooMany = rawCandidates.size > 2
        val incomplete = rawCandidates.filter { it?.points != null && it.points.size != 63 }
        val invalid = rawCandidates.filter {
            it?.points != null && it.points.size == 63 && !validHandLandmarks(it.points)
        }
        val malformed = rawCandidates.filter { it != null && it.points == null }
        val candidates = rawCandidates.filterNotNull()
            .filter { validHandLandmarks(it.points) }
            .take(2)
        val shoulderWidth = max(.05, orDefault(pose?.shoulderWidth, .4))
        val contactBefore = detectHandContact(
            candidates.getOrNull(0)?.points, candidates.getOrNull(1)?.points, shoulderWidth)
        val costs = candidates.map {
            Pair(
                handCandidateCost(left, it, pose, t, contactBefore.active),
                handCandidateCost(right, it, pose, t, contactBefore.active),
            )
        }
        val assigned = mutableMapOf<String, Candidate?>("left" to null, "right" to null)
        val assignedCosts = mutableMapOf<String, Double?>("left" to null, "right" to null)
        var assignmentHysteresis = false
        left.lastRejectCode = null
        right.lastRejectCode = null
        left.lastEventCode = null
        right.lastEventCode = null

        fun canAssign(candidate: Candidate, cost: Double) =
            cost <= .65 || (candidate.sideLocked && cost <= .95)

        if (candidates.size == 2) {
            val normal = costs[0].first + costs[1].second
            val crossed = costs[0].second + costs[1].first
            val margin = max(.06, shoulderWidth * .16)
            val ambiguous = candidates.all { it.sideAmbiguous } &&
                normal.isFinite() && crossed.isFinite() &&
                abs(normal - crossed) < margin
            if (!ambiguous) {
                // La cadena de brazo manda solo si coincide con la continuidad
                // temporal: un frame malo durante un cruce rapido no debe
                // intercambiar las manos fisicas del avatar.
                val neutralCosts = candidates.map {
                    val neutral = Candidate(it.points, null, it.confidence,
                        sideLocked = false, sideAmbiguous = true)
                    Pair(
                        handCandidateCost(left, neutral, pose, t, contactBefore.active, true),
                        handCandidateCost(right, neutral, pose, t, contactBefore.active, true),
                    )
                }
                val temporalNormal = neutralCosts[0].first + neutralCosts[1].second
                val temporalCrossed = neutralCosts[0].second + neutralCosts[1].first
                val labelMode = when {
                    normal.isFinite() && (!crossed.isFinite() || normal <= crossed) -> "normal"
                    crossed.isFinite() -> "crossed"
                    else -> null
                }
                val temporalMode = if (temporalNormal.isFinite() &&
                    temporalCrossed.isFinite() &&
                    abs(temporalNormal - temporalCrossed) >= margin
                ) {
                    if (temporalNormal <= temporalCrossed) "normal" else "crossed"
                } else null
                var selectedMode = labelMode
                // Un frame emparejado ya establece la identidad posicional;
                // esperar a TRACKING deja expuesto el primer cruce rapido.
                val established = left.hits >= 1 && right.hits >= 1
                if (established && labelMode != null && temporalMode != null &&
                    labelMode != temporalMode
                ) {
                    selectedMode = temporalMode
                    assignmentHysteresis = true
                }
                val evidence = abs(temporalNormal - temporalCrossed)
                // Solo un cambio propuesto por ambas senales independientes
                // pasa por la compuerta de 3 frames.
                val gateCandidate = if (candidates.all { it.sideLocked } &&
                    labelMode != null && temporalMode != null && labelMode == temporalMode
                ) selectedMode else null
                val gated = gateAssignmentMode(assignmentMode, pendingAssignmentMode,
                    pendingAssignmentCount, gateCandidate, evidence)
                if (gateCandidate != null) {
                    selectedMode = gated.mode
                    pendingAssignmentMode = gated.pendingMode
                    pendingAssignmentCount = gated.pendingCount
                    assignmentHysteresis = assignmentHysteresis || gated.held
                } else if (selectedMode == assignmentMode) {
                    pendingAssignmentMode = null
                    pendingAssignmentCount = 0
                }
                if (gateCandidate != null || assignmentMode == null) {
                    if (selectedMode != null) assignmentMode = selectedMode
                }
                val pairs = when (selectedMode) {
                    "normal" -> listOf("left" to 0, "right" to 1)
                    "crossed" -> listOf("left" to 1, "right" to 0)
                    else -> emptyList()
                }
                for ((side, index) in pairs) {
                    val selected = if (selectedMode == labelMode) costs else neutralCosts
                    val value = if (side == "left") selected[index].first else selected[index].second
                    if (canAssign(candidates[index], value)) {
                        assigned[side] = candidates[index]
                        assignedCosts[side] = value
                    }
                }
            }
        } else if (candidates.size == 1) {
            val side = if (costs[0].first <= costs[0].second) "left" else "right"
            val value = if (side == "left") costs[0].first else costs[0].second
            val margin = max(.06, shoulderWidth * .16)
            val ambiguous = candidates[0].sideAmbiguous &&
                abs(costs[0].first - costs[0].second) < margin
            if (!ambiguous && canAssign(candidates[0], value)) {
                assigned[side] = candidates[0]
                assignedCosts[side] = value
            }
        }

        for (track in listOf(left, right)) {
            val candidate = assigned[track.side]
            track.rawLandmarks = candidate?.points
                ?.takeIf { validHandLandmarks(it) }?.copyOf()
            if (candidate != null) {
                if (!updateVisible(track, candidate, t, shoulderWidth)) updateHidden(track, t)
            } else updateHidden(track, t)
        }
        val contact = detectHandContact(left.renderLandmarks, right.renderLandmarks, shoulderWidth)
        val errors = mutableListOf<Map<String, String>>()
        fun error(stage: String, code: String, side: String? = null, action: String? = null) {
            errors += buildMap {
                put("stage", stage)
                put("code", code)
                side?.let { put("side", it) }
                action?.let { put("action", it) }
            }
        }
        incomplete.forEach { error("capture", "hand_landmarks_incomplete", it?.side) }
        invalid.forEach { error("capture", "hand_landmarks_invalid", it?.side) }
        malformed.forEach { error("capture", "hand_landmarks_invalid", it?.side) }
        if (tooMany) {
            error("capture", "too_many_hand_candidates", action = "reject_excess_candidates")
        }
        for (track in listOf(left, right)) {
            if (track.state == "OCCLUDED") error("association", "hand_occluded", track.side)
            track.lastRejectCode?.let {
                error("association", it, track.side, "hold_previous")
            }
            track.lastEventCode?.let {
                error("association", it, track.side,
                    if (it == "hand_recovered") "interpolate_recovery" else "hold_previous")
            }
        }
        if (candidates.isNotEmpty() && assigned["left"] == null && assigned["right"] == null) {
            error("association", "track_ambiguous")
        }
        if (rawCandidates.any { it?.sideAmbiguous == true }) {
            error("association", "hand_side_ambiguous")
        }
        if (assignmentHysteresis) {
            error("association", "hand_assignment_hysteresis", action = "hold_temporal_identity")
        }
        for (side in listOf("left", "right")) {
            val stated = (assigned[side]?.side ?: "").lowercase()
            // Una retencion temporal usa a proposito una candidata cuya etiqueta
            // transitoria contradice la pista fisica: se reporta la retencion,
            // no un segundo error de intercambio para el mismo frame.
            if (!assignmentHysteresis && stated.isNotEmpty() && stated != side) {
                error("association", "hand_identity_swap", side)
            }
        }
        return Result(snapshot(left), snapshot(right), contact, assignedCosts.toMap(), costs, errors)
    }

    private fun handCandidateCost(
        track: Track,
        candidate: Candidate,
        pose: PoseHint?,
        timestampMs: Double,
        contact: Boolean,
        ignoreSide: Boolean = false,
    ): Double {
        if (!ignoreSide && candidate.sideLocked && !candidate.side.isNullOrEmpty() &&
            candidate.side != track.side
        ) return Double.POSITIVE_INFINITY
        val points = candidate.points ?: return Double.POSITIVE_INFINITY
        val wrist = point(points, 0)
        if (!wrist.finite) return Double.POSITIVE_INFINITY
        val width = max(.05, orDefault(pose?.shoulderWidth, .4))
        // Sin historial: muneca de la pose solo en x/y (su z es relativa a la
        // cadera y la de la mano a su propia muneca; no se comparan).
        val expected = expectedWrist(track, timestampMs) ?: when (track.side) {
            "left" -> Vec3(pose?.leftWristX ?: Double.NaN, pose?.leftWristY ?: Double.NaN, 0.0)
            else -> Vec3(pose?.rightWristX ?: Double.NaN, pose?.rightWristY ?: Double.NaN, 0.0)
        }
        val position = if (expected.finite) clamp(distance(wrist, expected) / width) else .5
        var velocity = .5
        val lastSeen = track.lastSeenMs
        val landmarks = track.landmarks
        if (landmarks != null && lastSeen != null && timestampMs > lastSeen) {
            val previous = point(landmarks, 0)
            val dt = max(.001, (timestampMs - lastSeen) / 1000)
            val ox = (wrist.x - previous.x) / dt
            val oy = (wrist.y - previous.y) / dt
            val oz = (wrist.z - previous.z) / dt
            velocity = clamp(JsMath.hypot(
                ox - track.velocity.x,
                oy - track.velocity.y,
                oz - track.velocity.z,
            ) * .25)
        }
        val orientation = orientationDistance(track.frame, palmFrameV2(points))
        // Antes de pose_arm_chain la etiqueta de MediaPipe puede venir
        // invertida con camara frontal: no contradice la continuidad.
        val stated = if (ignoreSide || candidate.sideAmbiguous) "" else
            (candidate.side ?: "").lowercase()
        val side = if (stated.isNotEmpty() && stated != track.side) 1.0
        else if (stated.isNotEmpty()) 0.0 else .5
        val confidence = 1 - clamp(candidate.confidence ?: .5)
        val sideWeight = if (contact) .02 else .10
        return .45 * position + .20 * velocity + .20 * orientation +
            sideWeight * side + .05 * confidence
    }

    private fun expectedWrist(track: Track, timestampMs: Double): Vec3? {
        val landmarks = track.landmarks ?: return null
        val lastSeen = track.lastSeenMs ?: return null
        val wrist = point(landmarks, 0)
        if (!wrist.finite) return null
        val dt = clamp((timestampMs - lastSeen) / 1000, 0.0, .3)
        return Vec3(
            wrist.x + track.velocity.x * dt,
            wrist.y + track.velocity.y * dt,
            wrist.z + track.velocity.z * dt,
        )
    }

    private fun updateVisible(
        track: Track,
        candidate: Candidate,
        timestampMs: Double,
        shoulderWidth: Double,
    ): Boolean {
        val points = candidate.points!!
        track.rawLandmarks = if (validHandLandmarks(points)) points.copyOf() else null
        val lastSeen = track.lastSeenMs
        if (lastSeen != null && timestampMs <= lastSeen) {
            track.lastRejectCode = "stale_frame"
            return false
        }
        val landmarks = points.copyOf()
        val wrist = point(landmarks, 0)
        val previous = track.landmarks?.let { point(it, 0) }
        val previousFinite = previous?.finite == true
        val previousRender = track.renderLandmarks ?: track.landmarks
        val previousState = track.state
        val previousRestBlend = track.restBlend
        val hadHistory = lastSeen != null
        val frame = palmFrameV2(landmarks)
        if (frame == null) {
            track.lastRejectCode = "hand_geometry_degenerate"
            return false
        }
        val surface = classifyHandSurface(landmarks, track.side)
        if (surface.surface == "ambiguous") {
            track.lastRejectCode = "hand_surface_ambiguous"
            return false
        }
        val surfaceChanged = track.surface != null && surface.surface != track.surface
        val transition = handSurfaceTransition(
            track.frame,
            frame,
            shoulderWidth,
            if (previousFinite) distance(wrist, previous!!) else 0.0,
            track.pendingOrientationFrame,
            track.pendingOrientationCount,
        )
        track.pendingOrientationFrame = transition.pendingFrame
        track.pendingOrientationCount = transition.pendingCount
        if (!transition.accepted) {
            if (surfaceChanged) {
                // Igual que la web: la cuenta sube aunque se acabe de asignar.
                track.pendingSurface = surface.surface
                track.pendingSurfaceCount = track.pendingSurfaceCount + 1
            }
            track.lastRejectCode = "hand_surface_flip"
            return false
        }
        if (surfaceChanged) {
            val repeats = if (track.pendingSurface == surface.surface)
                track.pendingSurfaceCount + 1 else 1
            track.pendingSurface = surface.surface
            track.pendingSurfaceCount = repeats
            if (repeats < 2) {
                track.lastRejectCode = "hand_surface_flip"
                return false
            }
            track.pendingSurface = null
            track.pendingSurfaceCount = 0
            track.surfaceChanges++
        } else {
            track.pendingSurface = null
            track.pendingSurfaceCount = 0
        }
        val dt = if (lastSeen != null && timestampMs > lastSeen)
            max(.001, (timestampMs - lastSeen) / 1000) else 0.0
        val step = if (previousFinite) distance(wrist, previous!!) else 0.0
        val predicted = expectedWrist(track, timestampMs)
        val predictionError = if (predicted?.finite == true)
            distance(wrist, predicted) / shoulderWidth else 0.0
        // El movimiento normal sigue respondiendo. Un salto grande de la
        // muneca necesita repetirse en el mismo lugar; luego el render
        // avanza con paso acotado.
        val maxStep = max(shoulderWidth * .04,
            (shoulderWidth * 3.0 + .8) * min(.2, if (dt != 0.0) dt else 1.0 / 60))
        val positionJump = previousFinite && (step > maxStep || predictionError > .55)
        if (positionJump) {
            val pending = track.pendingPosition
            val repeats = if (pending != null &&
                distance(wrist, pending) <= shoulderWidth * .10
            ) track.pendingPositionCount + 1 else 1
            track.pendingPosition = wrist
            track.pendingPositionCount = repeats
            if (repeats < 2) {
                track.lastEventCode = "hand_position_jump"
                track.lastRejectCode = "hand_position_held"
                return false
            }
            track.pendingPosition = null
            track.pendingPositionCount = 0
        } else {
            track.pendingPosition = null
            track.pendingPositionCount = 0
        }
        if (previousFinite && lastSeen != null && timestampMs > lastSeen) {
            val mx = (wrist.x - previous!!.x) / dt
            val my = (wrist.y - previous.y) / dt
            val mz = (wrist.z - previous.z) / dt
            track.velocity = Vec3(
                mx * .65 + track.velocity.x * .35,
                my * .65 + track.velocity.y * .35,
                mz * .65 + track.velocity.z * .35,
            )
        }
        track.landmarks = landmarks
        track.acceptedLandmarks = landmarks
        track.frame = frame
        track.surface = surface.surface
        track.surfaceConfidence = surface.confidence
        track.confidence = clamp(candidate.confidence ?: .5)
        track.sideLocked = candidate.sideLocked || track.sideLocked
        track.lastSeenMs = timestampMs
        track.hits++
        track.state = if (track.hits >= 2) "TRACKING" else "TENTATIVE"
        track.detected = landmarks
        val wasRecovering = (previousState == "LOST" && hadHistory) ||
            previousRestBlend > 0 || track.recoveryFrames > 0
        if (wasRecovering) {
            if (track.recoveryFrames <= 0) {
                track.recoveryFrames = 3
                track.recoveryFrom = previousRender?.copyOf() ?: landmarks
            }
            track.recoveryTarget = landmarks.copyOf()
            val progress = (4 - track.recoveryFrames) / 3.0
            track.renderLandmarks = blendLandmarks(
                track.recoveryFrom, track.recoveryTarget!!, progress)
            track.recoveryFrames--
            if (track.recoveryFrames <= 0) {
                track.renderLandmarks = track.recoveryTarget!!.copyOf()
                track.recoveryFrom = null
                track.recoveryTarget = null
            }
            track.lastEventCode = "hand_recovered"
        } else {
            track.renderLandmarks = boundedRenderLandmarks(landmarks, previousRender, maxStep)
        }
        track.restBlend = 0.0
        track.lastRejectCode = null
        return true
    }

    private fun updateHidden(track: Track, timestampMs: Double) {
        track.detected = null
        val landmarks = track.landmarks
        val lastSeen = track.lastSeenMs
        if (landmarks == null || lastSeen == null) {
            track.state = "LOST"
            track.renderLandmarks = null
            track.restBlend = 1.0
            return
        }
        val elapsed = max(0.0, timestampMs - lastSeen)
        if (elapsed > 500) {
            track.state = "LOST"
            track.renderLandmarks = null
            track.restBlend = 1.0
            return
        }
        track.state = "OCCLUDED"
        val predictMs = min(300.0, elapsed)
        track.renderLandmarks = translated(
            landmarks,
            track.velocity.x * predictMs / 1000,
            track.velocity.y * predictMs / 1000,
            track.velocity.z * predictMs / 1000,
        )
        track.restBlend = if (elapsed <= 300) 0.0 else clamp((elapsed - 300) / 200)
    }

    private fun snapshot(track: Track) = TrackView(
        track.side,
        track.sideLocked,
        track.state,
        track.landmarks,
        track.rawLandmarks,
        track.acceptedLandmarks,
        track.detected,
        track.renderLandmarks,
        track.velocity,
        track.surface,
        track.surfaceConfidence,
        track.surfaceChanges,
        track.recoveryFrames,
        track.confidence,
        track.restBlend,
    )

    private fun gateAssignmentMode(
        currentMode: String?,
        pendingMode: String?,
        pendingCount: Int,
        proposedMode: String?,
        advantage: Double,
    ): Gated {
        if (proposedMode == null) return Gated(currentMode, null, 0, false)
        if (currentMode == null || proposedMode == currentMode) {
            return Gated(proposedMode, null, 0, false)
        }
        if (!advantage.isFinite() || advantage < ASSIGNMENT_ADVANTAGE) {
            return Gated(currentMode, null, 0, true)
        }
        val nextCount = if (pendingMode == proposedMode) pendingCount + 1 else 1
        if (nextCount < ASSIGNMENT_CONFIRM_FRAMES) {
            return Gated(currentMode, proposedMode, nextCount, true)
        }
        return Gated(proposedMode, null, 0, false)
    }

    companion object {
        private const val ASSIGNMENT_CONFIRM_FRAMES = 3
        private const val ASSIGNMENT_ADVANTAGE = .15

        private fun clamp(value: Double, min: Double = 0.0, max: Double = 1.0): Double =
            kotlin.math.max(min, kotlin.math.min(max, value))

        /** `value || fallback` de JS para numeros: null, NaN y 0 caen al defecto. */
        private fun orDefault(value: Double?, fallback: Double): Double =
            if (value == null || value.isNaN() || value == 0.0) fallback else value

        private fun point(points: DoubleArray, index: Int) =
            Vec3(points[index * 3], points[index * 3 + 1], points[index * 3 + 2])

        private fun distance(a: Vec3, b: Vec3) = JsMath.hypot(a.x - b.x, a.y - b.y, a.z - b.z)

        private fun normalize(x: Double, y: Double, z: Double): Vec3? {
            val n = JsMath.hypot(x, y, z)
            return if (n > 1e-8) Vec3(x / n, y / n, z / n) else null
        }

        /** Contrato de mano: 21 puntos con x, y, z finitos. */
        fun validHandLandmarks(points: DoubleArray?): Boolean =
            points != null && points.size == 63 && points.all { it.isFinite() }

        /**
         * Marco canonico de palma. El CMC fija el signo del eje radial para
         * que la misma mano fisica no se invierta si el detector espeja.
         */
        fun palmFrameV2(points: DoubleArray?): PalmFrame? {
            if (points == null || points.size < 18 * 3) return null
            val wrist = point(points, 0)
            val cmc = point(points, 1)
            val index = point(points, 5)
            val middle = point(points, 9)
            val little = point(points, 17)
            if (!listOf(wrist, cmc, index, middle, little).all { it.finite }) return null
            val forward = normalize(middle.x - wrist.x, middle.y - wrist.y, middle.z - wrist.z)
            val normalBase = normalize(
                (index.y - wrist.y) * (little.z - wrist.z) -
                    (index.z - wrist.z) * (little.y - wrist.y),
                (index.z - wrist.z) * (little.x - wrist.x) -
                    (index.x - wrist.x) * (little.z - wrist.z),
                (index.x - wrist.x) * (little.y - wrist.y) -
                    (index.y - wrist.y) * (little.x - wrist.x),
            )
            if (forward == null || normalBase == null) return null
            var normal: Vec3 = normalBase
            var radial = normalize(
                normal.y * forward.z - normal.z * forward.y,
                normal.z * forward.x - normal.x * forward.z,
                normal.x * forward.y - normal.y * forward.x,
            ) ?: return null
            val cx = cmc.x - wrist.x
            val cy = cmc.y - wrist.y
            val cz = cmc.z - wrist.z
            val radialDot = cx * radial.x + cy * radial.y + cz * radial.z
            if (!radialDot.isFinite() || abs(radialDot) <= 1e-8) return null
            if (radialDot < 0) {
                normal = Vec3(-normal.x, -normal.y, -normal.z)
                radial = Vec3(-radial.x, -radial.y, -radial.z)
            }
            val correctedDot = cx * radial.x + cy * radial.y + cz * radial.z
            return PalmFrame(radial, forward, normal, correctedDot)
        }

        fun orientationDistance(a: PalmFrame?, b: PalmFrame?): Double {
            if (a == null || b == null) return .5
            fun dot(u: Vec3, v: Vec3) = clamp((u.x * v.x + u.y * v.y + u.z * v.z + 1) / 2)
            return 1 - (0.0 + dot(a.radial, b.radial) + dot(a.forward, b.forward) +
                dot(a.normal, b.normal)) / 3
        }

        /**
         * Retiene un salto sospechoso palma/dorso y lo acepta solo si la
         * misma orientacion llega al frame siguiente.
         */
        fun handSurfaceTransition(
            previous: PalmFrame?,
            current: PalmFrame?,
            shoulderWidth: Double,
            wristDisplacement: Double,
            pendingFrame: PalmFrame?,
            pendingCount: Int,
        ): Transition {
            val orientation = orientationDistance(previous, current)
            val width = max(.05, orDefault(shoulderWidth, .4))
            val displacement = max(0.0, orDefault(wristDisplacement, 0.0)) / width
            val suspicious = previous != null && current != null && orientation >= .60 &&
                displacement <= .40
            if (!suspicious) return Transition(true, false, "accept", orientation, 0, null)
            val repeatsPending = pendingFrame != null &&
                orientationDistance(pendingFrame, current) < .25
            val nextCount = if (repeatsPending) max(0, pendingCount) + 1 else 1
            val accepted = nextCount >= 2
            return Transition(
                accepted,
                true,
                if (accepted) "accept_surface_change" else "hold_previous",
                orientation,
                if (accepted) 0 else nextCount,
                if (accepted) null else current,
            )
        }

        /**
         * Palma/dorso por geometria, nunca por la etiqueta del detector. El
         * signo de profundidad se normaliza por anatomia: izquierda +1,
         * derecha -1.
         */
        fun classifyHandSurface(points: DoubleArray?, side: String?, margin: Double = .20): Surface {
            val fallback = Surface("ambiguous", 0.0, 0.0, Vec3(0.0, 0.0, 0.0))
            if (!validHandLandmarks(points) || (side != "left" && side != "right")) return fallback
            val frame = palmFrameV2(points) ?: return fallback
            if (!frame.normal.finite) return fallback
            val sign = if (side == "left") 1.0 else -1.0
            val score = frame.normal.z * sign
            val m = max(.05, orDefault(margin, .20))
            val confidence = clamp((abs(score) - m) / max(.01, 1 - m))
            val surface = if (score > m) "palm" else if (score < -m) "dorsum" else "ambiguous"
            return Surface(surface, confidence, score, frame.normal)
        }

        private fun bounds(points: DoubleArray?): DoubleArray? {
            if (points == null) return null
            var minX = Double.POSITIVE_INFINITY
            var maxX = Double.NEGATIVE_INFINITY
            var minY = Double.POSITIVE_INFINITY
            var maxY = Double.NEGATIVE_INFINITY
            var any = false
            for (i in 0 until points.size / 3) {
                val p = point(points, i)
                if (!p.finite) continue
                any = true
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
                minY = min(minY, p.y)
                maxY = max(maxY, p.y)
            }
            return if (any) doubleArrayOf(minX, maxX, minY, maxY) else null
        }

        private fun overlapRatio(a: DoubleArray?, b: DoubleArray?): Double {
            val aa = bounds(a) ?: return 0.0
            val bb = bounds(b) ?: return 0.0
            val width = max(0.0, min(aa[1], bb[1]) - max(aa[0], bb[0]))
            val height = max(0.0, min(aa[3], bb[3]) - max(aa[2], bb[2]))
            val intersection = width * height
            val areaA = max(1e-8, (aa[1] - aa[0]) * (aa[3] - aa[2]))
            val areaB = max(1e-8, (bb[1] - bb[0]) * (bb[3] - bb[2]))
            return clamp(intersection / min(areaA, areaB))
        }

        /** Contacto: munecas a menos de .22 hombros o cajas solapadas > 25 %. */
        fun detectHandContact(left: DoubleArray?, right: DoubleArray?, shoulderWidth: Double): Contact {
            val lw = left?.takeIf { it.size >= 3 }?.let { point(it, 0) }
            val rw = right?.takeIf { it.size >= 3 }?.let { point(it, 0) }
            val width = max(.05, orDefault(shoulderWidth, .4))
            val wristRatio = if (lw?.finite == true && rw?.finite == true)
                distance(lw, rw) / width else Double.POSITIVE_INFINITY
            val overlap = overlapRatio(left, right)
            return Contact(
                wristRatio < .22 || overlap > .25,
                if (wristRatio.isFinite()) wristRatio else null,
                overlap,
            )
        }

        private fun translated(points: DoubleArray, dx: Double, dy: Double, dz: Double) =
            DoubleArray(points.size) { k ->
                points[k] + when (k % 3) { 0 -> dx; 1 -> dy; else -> dz }
            }

        private fun blendLandmarks(from: DoubleArray?, to: DoubleArray, amount: Double): DoubleArray {
            val alpha = clamp(amount)
            return DoubleArray(to.size) { k ->
                val start = if (from != null && k < from.size) from[k] else to[k]
                start + (to[k] - start) * alpha
            }
        }

        private fun boundedRenderLandmarks(
            points: DoubleArray,
            previous: DoubleArray?,
            maxStep: Double,
        ): DoubleArray {
            if (previous == null || previous.size < 3) return points.copyOf()
            val target = point(points, 0)
            val start = point(previous, 0)
            if (!target.finite || !start.finite) return points.copyOf()
            val dx = target.x - start.x
            val dy = target.y - start.y
            val dz = target.z - start.z
            val step = JsMath.hypot(dx, dy, dz)
            if (step <= maxStep || step <= 1e-8) return points.copyOf()
            val scale = maxStep / step
            return translated(points, dx * (scale - 1), dy * (scale - 1), dz * (scale - 1))
        }

        /** direct <= 50 ms, project <= 120 ms, reject (o no finito). */
        fun classifySourceSkew(skewMs: Double): String {
            val skew = abs(skewMs)
            return when {
                !skew.isFinite() -> "reject"
                skew <= 50 -> "direct"
                skew <= 120 -> "project"
                else -> "reject"
            }
        }

        fun sourceSkewMode(skewMs: Long): String = classifySourceSkew(skewMs.toDouble())
    }
}
