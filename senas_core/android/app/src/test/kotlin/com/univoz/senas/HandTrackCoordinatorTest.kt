package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/** Espejo de tools/rig-tests/rig_tracking.test.mjs (parte de seguimiento). */
class HandTrackCoordinatorTest {
    private fun hand(x: Double, y: Double = .55, direction: Double = 1.0): DoubleArray =
        DoubleArray(63).also { points ->
            fun point(index: Int, px: Double, py: Double) {
                points[index * 3] = px
                points[index * 3 + 1] = py
            }
            for (index in 0 until 21) point(index, x, y)
            point(1, x + .06 * direction, y + .01)
            point(5, x + .04 * direction, y - .02)
            point(9, x, y - .08)
            point(17, x - .04 * direction, y - .02)
        }

    private val pose = HandTrackCoordinator.PoseHint(.68, .55, .32, .55, .4)

    private fun candidate(
        points: DoubleArray?,
        side: String?,
        confidence: Double = .9,
        sideLocked: Boolean = false,
        sideAmbiguous: Boolean = false,
    ) = HandTrackCoordinator.Candidate(points, side, confidence, sideLocked, sideAmbiguous)

    private fun HandTrackCoordinator.Result.has(
        code: String,
        action: String? = null,
        side: String? = null,
    ) = errors.any {
        it["code"] == code && (action == null || it["action"] == action) &&
            (side == null || it["side"] == side)
    }

    @Test
    fun palmFrameRadialAxisPointsTowardCmcForBothSides() {
        for (side in listOf("left", "right")) {
            val direction = if (side == "left") 1.0 else -1.0
            val frame = HandTrackCoordinator.palmFrameV2(hand(.5, .5, direction))
            assertNotNull(frame)
            assertTrue(frame!!.normal.x.isFinite())
            assertTrue(frame.cmcRadialDot > 0)
            assertTrue(frame.radial.x * direction > 0)
        }
    }

    @Test
    fun surfaceClassifierReturnsPalmAndDorsumForBothSides() {
        for (side in listOf("left", "right")) {
            val palm = HandTrackCoordinator.classifyHandSurface(
                hand(.5, .5, if (side == "left") 1.0 else -1.0), side)
            val dorsum = HandTrackCoordinator.classifyHandSurface(
                hand(.5, .5, if (side == "left") -1.0 else 1.0), side)
            for (result in listOf(palm, dorsum)) {
                assertTrue(result.confidence in 0.0..1.0)
                assertTrue(result.score.isFinite())
                assertTrue(result.normal.finite)
            }
            assertEquals("palm", palm.surface)
            assertEquals("dorsum", dorsum.surface)
        }
    }

    @Test
    fun surfaceClassifierMarksLowNormalMarginAmbiguous() {
        val edgeOn = hand(.5, .5).also { p ->
            for (i in 0 until 21) {
                p[i * 3 + 2] = abs(p[i * 3] - .5)
                p[i * 3 + 1] = .5
            }
        }
        val result = HandTrackCoordinator.classifyHandSurface(edgeOn, "left", .2)
        assertEquals("ambiguous", result.surface)
        assertTrue(result.confidence < 1)
    }

    @Test
    fun handContractRequiresExactly21FiniteLandmarks() {
        assertTrue(HandTrackCoordinator.validHandLandmarks(hand(.5, .5)))
        assertFalse(HandTrackCoordinator.validHandLandmarks(hand(.5, .5).copyOf(60)))
        assertFalse(HandTrackCoordinator.validHandLandmarks(hand(.5, .5).also { it[24] = Double.NaN }))
        assertFalse(HandTrackCoordinator.validHandLandmarks(
            hand(.5, .5).also { it[27] = Double.POSITIVE_INFINITY }))
    }

    @Test
    fun pendingAssociationToleratesAbsentPoseHint() {
        val result = HandTrackCoordinator().update(
            listOf(candidate(hand(.68), "right", sideAmbiguous = true)), null, 0)
        assertEquals("LOST", result.left.state)
        assertEquals("LOST", result.right.state)
        assertTrue(result.has("hand_side_ambiguous"))
    }

    @Test
    fun contactKeepsAnatomicalIdentityWhenDetectionOrderReverses() {
        val tracker = HandTrackCoordinator()
        var result = tracker.update(listOf(
            candidate(hand(.68), "left", .95),
            candidate(hand(.32), "right", .95),
        ), pose, 0)
        assertEquals(.68, result.left.landmarks!![0], 0.0)
        assertEquals(.32, result.right.landmarks!![0], 0.0)
        var sawContact = false
        for (n in 1..6) {
            val leftX = .68 - n * .045
            val rightX = .32 + n * .045
            result = tracker.update(listOf(
                candidate(hand(rightX), "left", .55),
                candidate(hand(leftX), "right", .55),
            ), pose, n * 33L)
            sawContact = sawContact || result.contact.active
        }
        assertTrue(sawContact)
        assertTrue(result.left.velocity.x < 0)
        assertTrue(result.right.velocity.x > 0)
    }

    @Test
    fun sharedContactFixtureKeepsIdentityAcrossDetectionOrderChanges() {
        val tracker = HandTrackCoordinator()
        val rows = javaClass.classLoader!!.getResourceAsStream("hand_tracking.tsv")!!
            .bufferedReader().readLines()
            .filterNot { it.startsWith("#") || it.isBlank() }
        var contactSeen = false
        rows.forEach { row ->
            val columns = row.split(Regex("\\s+"))
            val t = columns[0].toLong()
            val leftX = columns[1].toDouble()
            val rightX = columns[2].toDouble()
            val flipped = columns[4] == "flipped"
            val left = candidate(hand(leftX), if (flipped) "right" else "left")
            val right = candidate(hand(rightX), if (flipped) "left" else "right")
            val detections = if (columns[3] == "LR") listOf(left, right) else listOf(right, left)
            val result = tracker.update(detections, pose, t)
            assertEquals(leftX, result.left.detected!![0], 1e-9)
            assertEquals(rightX, result.right.detected!![0], 1e-9)
            contactSeen = contactSeen || result.contact.active
        }
        assertTrue(contactSeen)
    }

    @Test
    fun rapidCrossingHoldsIdentityThroughTransientLockedSideInversion() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(
            candidate(hand(.68), "left", .95),
            candidate(hand(.32), "right", .95),
        ), pose, 0)
        // Un frame malo de la cadena de brazo mientras las munecas siguen su
        // trayectoria: la continuidad gana.
        val result = tracker.update(listOf(
            candidate(hand(.64), "right", .95, sideLocked = true),
            candidate(hand(.36), "left", .95, sideLocked = true),
        ), pose, 33)
        assertEquals(.64, result.left.landmarks!![0], 0.0)
        assertEquals(.36, result.right.landmarks!![0], 0.0)
        assertTrue(result.has("hand_assignment_hysteresis"))
    }

    @Test
    fun identityReassignmentRequiresThreeConsecutiveStrongFrames() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(
            candidate(hand(.68), "left", .95),
            candidate(hand(.32), "right", .95),
        ), pose, 0)
        val first = tracker.update(listOf(
            candidate(hand(.32), "right", .95, sideLocked = true),
            candidate(hand(.68), "left", .95, sideLocked = true),
        ), pose, 33)
        val second = tracker.update(listOf(
            candidate(hand(.31), "right", .95, sideLocked = true),
            candidate(hand(.69), "left", .95, sideLocked = true),
        ), pose, 66)
        assertTrue(first.has("hand_assignment_hysteresis"))
        assertTrue(second.has("hand_assignment_hysteresis"))
        val third = tracker.update(listOf(
            candidate(hand(.30), "right", .95, sideLocked = true),
            candidate(hand(.70), "left", .95, sideLocked = true),
        ), pose, 99)
        assertEquals(.30, third.left.detected!![0], 0.0)
        assertEquals(.70, third.right.detected!![0], 0.0)
    }

    @Test
    fun surfaceFlipIsHeldOnceAndAcceptedAfterConfirmation() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68, direction = 1.0), "left", 1.0)), pose, 0)
        val flipped = tracker.update(
            listOf(candidate(hand(.68, direction = -1.0), "left", 1.0)), pose, 33)
        assertNull(flipped.left.detected)
        assertEquals(.72, flipped.left.render!![5 * 3], 1e-9)
        assertTrue(flipped.has("hand_surface_flip", "hold_previous"))

        val confirmed = tracker.update(
            listOf(candidate(hand(.68, direction = -1.0), "left", 1.0)), pose, 66)
        assertEquals(.64, confirmed.left.detected!![5 * 3], 1e-9)
        assertEquals("dorsum", confirmed.left.surface)
        assertEquals(1, confirmed.left.surfaceChanges)
        assertFalse(confirmed.has("hand_surface_flip"))
    }

    @Test
    fun isolatedWristJumpIsHeldAndRepeatedMovementIsBounded() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left", 1.0)), pose, 0)
        val isolated = tracker.update(listOf(candidate(hand(.92), "left", 1.0)), pose, 33)
        assertNull(isolated.left.detected)
        assertEquals(.68, isolated.left.render!![0], 0.0)
        assertTrue(isolated.has("hand_position_jump", "hold_previous"))

        val repeated = tracker.update(listOf(candidate(hand(.92), "left", 1.0)), pose, 66)
        assertNotNull(repeated.left.detected)
        assertTrue(repeated.left.render!![0] < .92)
        assertTrue(repeated.left.render!![0] > .68)
        assertNotNull(repeated.left.raw)
        assertNotNull(repeated.left.accepted)
    }

    @Test
    fun reappearanceAfterLongOcclusionInterpolatesRender() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left", 1.0)), pose, 0)
        tracker.update(emptyList(), pose, 600)
        val first = tracker.update(listOf(candidate(hand(.68, .45), "left", 1.0)), pose, 633).left
        assertNotNull(first.detected)
        assertTrue(first.render!![1] > .45)
        assertTrue(first.render[1] < .55)
        assertEquals(2, first.recoveryFrames)
        val second = tracker.update(listOf(candidate(hand(.68, .45), "left", 1.0)), pose, 666).left
        val third = tracker.update(listOf(candidate(hand(.68, .45), "left", 1.0)), pose, 699).left
        assertTrue(second.render!![1] < first.render[1])
        assertEquals(0, third.recoveryFrames)
        assertEquals(.45, third.render!![1], 0.0)
    }

    @Test
    fun surfaceTransitionReportsFiniteOrientationDistance() {
        val before = HandTrackCoordinator.palmFrameV2(hand(.68, direction = 1.0))
        val after = HandTrackCoordinator.palmFrameV2(hand(.68, direction = -1.0))
        val result = HandTrackCoordinator.handSurfaceTransition(before, after, .4, 0.0, null, 0)
        assertFalse(result.accepted)
        assertEquals(1, result.pendingCount)
        assertTrue(result.orientationDistance.isFinite())
    }

    @Test
    fun staleTimestampHoldsPreviousLandmarksAndReportsError() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left", sideLocked = true)), pose, 100)
        val result = tracker.update(
            listOf(candidate(hand(.30), "left", sideLocked = true)), pose, 100)
        assertNull(result.left.detected)
        assertEquals(.68, result.left.render!![0], 0.0)
        assertTrue(result.has("stale_frame", "hold_previous"))
    }

    @Test
    fun degeneratePalmFrameHoldsPreviousOrientation() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left", sideLocked = true)), pose, 100)
        val degenerate = hand(.68).also {
            it[17 * 3] = it[5 * 3]
            it[17 * 3 + 1] = it[5 * 3 + 1]
        }
        val result = tracker.update(
            listOf(candidate(degenerate, "left", sideLocked = true)), pose, 133)
        assertNull(result.left.detected)
        assertEquals(.68, result.left.render!![0], 0.0)
        assertTrue(result.has("hand_geometry_degenerate", "hold_previous"))
    }

    @Test
    fun moreThanTwoCandidatesAreReportedExplicitly() {
        val result = HandTrackCoordinator().update(listOf(
            candidate(hand(.68), "left"),
            candidate(hand(.32), "right"),
            candidate(hand(.50), null, .4),
        ), pose, 100)
        assertTrue(result.has("too_many_hand_candidates"))
    }

    @Test
    fun singleDetectionUpdatesOneTrackAndNeverDuplicatesLandmarks() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left"), candidate(hand(.32), "right")), pose, 0)
        val result = tracker.update(listOf(candidate(hand(.66), "left")), pose, 200)
        assertEquals("TRACKING", result.left.state)
        assertEquals("OCCLUDED", result.right.state)
        assertNotNull(result.left.detected)
        assertNull(result.right.detected)
        assertNotNull(result.right.render)
        assertNotSame(result.left.landmarks, result.right.render)
    }

    @Test
    fun incompleteHandIsRejectedInsteadOfTrackingOnlyPalm() {
        val result = HandTrackCoordinator().update(
            listOf(candidate(hand(.68).copyOf(60), "left")), pose, 0)
        assertEquals("LOST", result.left.state)
        assertNull(result.left.detected)
        assertTrue(result.has("hand_landmarks_incomplete"))
    }

    @Test
    fun exactSizeNonFiniteInputIsRejected() {
        val invalid = hand(.68).also { it[4 * 3] = Double.POSITIVE_INFINITY }
        val result = HandTrackCoordinator().update(listOf(candidate(invalid, "left")), pose, 0)
        assertEquals("LOST", result.left.state)
        assertTrue(result.has("hand_landmarks_invalid"))
    }

    @Test
    fun absentAndDegenerateInputsDoNotThrow() {
        val result = HandTrackCoordinator().update(
            listOf(null, candidate(null, null), candidate(hand(.68), null)), pose, 0)
        assertTrue(result.has("hand_landmarks_invalid"))
        assertTrue(result.has("too_many_hand_candidates"))
    }

    @Test
    fun explicitIdentityContradictionIsReported() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.68), "left")), pose, 0)
        val result = tracker.update(listOf(candidate(hand(.67), "right")), pose, 33)
        assertTrue(result.has("hand_identity_swap", side = "left"))
    }

    @Test
    fun occludedRenderPredicts300msThenRestsAndIsLostAfter500ms() {
        val tracker = HandTrackCoordinator()
        tracker.update(listOf(candidate(hand(.6, .5), "left", 1.0)), pose, 0)
        tracker.update(listOf(candidate(hand(.58, .5), "left", 1.0)), pose, 50)
        val predicted = tracker.update(emptyList(), pose, 250).left
        val resting = tracker.update(emptyList(), pose, 370).left
        val lost = tracker.update(emptyList(), pose, 551).left
        assertEquals("OCCLUDED", predicted.state)
        assertTrue(predicted.render!![0] < .58)
        assertEquals(0.0, predicted.restBlend, 0.0)
        assertTrue(resting.restBlend > 0 && resting.restBlend < 1)
        assertEquals("LOST", lost.state)
        assertNull(lost.render)
    }

    @Test
    fun contactUsesWristDistanceOrHandBoxOverlap() {
        assertTrue(HandTrackCoordinator.detectHandContact(hand(.49, .5), hand(.51, .5), .4).active)
        assertFalse(HandTrackCoordinator.detectHandContact(hand(.2, .5), hand(.8, .5), .4).active)
    }

    @Test
    fun sourceSkewBoundariesSelectDirectProjectedAndRejected() {
        assertEquals("direct", HandTrackCoordinator.classifySourceSkew(0.0))
        assertEquals("direct", HandTrackCoordinator.sourceSkewMode(50))
        assertEquals("project", HandTrackCoordinator.sourceSkewMode(80))
        assertEquals("project", HandTrackCoordinator.sourceSkewMode(120))
        assertEquals("reject", HandTrackCoordinator.sourceSkewMode(121))
        assertEquals("reject", HandTrackCoordinator.classifySourceSkew(Double.NaN))
    }

    @Test
    fun trackWithoutHistoryComparesCandidatesToPoseWristInXy() {
        // Mano que reaparece: sin historial la posicion esperada sale de la
        // muneca de la pose (solo x/y), y gana el lado cercano.
        val near = HandTrackCoordinator().update(
            listOf(candidate(hand(.70, .56), null)),
            HandTrackCoordinator.PoseHint(.70, .55, .30, .55, .4), 0)
        assertNotNull(near.left.detected)
        assertNull(near.right.detected)
        assertTrue(near.costs["left"]!! + .1 < near.candidateCosts[0].second)
    }
}
