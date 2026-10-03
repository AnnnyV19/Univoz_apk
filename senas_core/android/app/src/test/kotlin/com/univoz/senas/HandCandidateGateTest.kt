package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Espejo de tools/rig-tests/rig_hand_gate.test.mjs. */
class HandCandidateGateTest {
    private fun pose(
        leftWrist: Pair<Double, Double> = .62 to .70,
        rightWrist: Pair<Double, Double> = .38 to .70,
        wristVis: Double = .9,
    ): DoubleArray = DoubleArray(33 * 4).also { p ->
        fun put(i: Int, x: Double, y: Double, v: Double) {
            p[i * 4] = x; p[i * 4 + 1] = y; p[i * 4 + 3] = v
        }
        for (i in 0 until 33) put(i, .5, .5, .9)
        put(11, .60, .40, .99)
        put(12, .40, .40, .99)
        put(13, .62, .55, .9)
        put(14, .38, .55, .9)
        put(15, leftWrist.first, leftWrist.second, wristVis)
        put(16, rightWrist.first, rightWrist.second, wristVis)
    }

    private fun hand(x: Double, y: Double, size: Double = .06, conf: Double = .9) =
        HandCandidateGate.Input(DoubleArray(63).also { h ->
            for (i in 0 until 21) {
                h[i * 3] = x + (i % 5) * size * .1
                h[i * 3 + 1] = y - size * (.3 + (i % 4) * .25)
            }
            h[0] = x; h[1] = y
            h[27] = x; h[28] = y - size
        }, conf)

    @Test
    fun acceptsHandsAtPoseWrists() {
        val r = HandCandidateGate.gate(listOf(hand(.62, .70), hand(.38, .70)), pose())
        assertEquals(listOf(0, 1), r.accepted)
        assertTrue(r.rejected.isEmpty())
    }

    @Test
    fun dropsDuplicateKeepingStronger() {
        val r = HandCandidateGate.gate(
            listOf(hand(.62, .70, conf = .6), hand(.625, .705, conf = .95)), pose())
        assertEquals(listOf(1), r.accepted)
        assertEquals(listOf(0 to "hand_duplicate"), r.rejected)
    }

    @Test
    fun rejectsHandFarFromBothArms() {
        val r = HandCandidateGate.gate(listOf(hand(.50, .20)), pose())
        assertTrue(r.accepted.isEmpty())
        assertEquals("hand_far_from_arm", r.rejected.single().second)
    }

    @Test
    fun rejectsImplausibleSizes() {
        assertEquals("hand_scale_implausible",
            HandCandidateGate.gate(listOf(hand(.62, .70, .005)), pose()).rejected.single().second)
        assertEquals("hand_scale_implausible",
            HandCandidateGate.gate(listOf(hand(.62, .70, .30)), pose()).rejected.single().second)
    }

    @Test
    fun unanchoredWhenNoPoseWristVisible() {
        val r = HandCandidateGate.gate(listOf(hand(.50, .20)), pose(wristVis = .1))
        assertEquals(listOf(0), r.accepted)
        assertEquals(listOf(0), r.unanchored)
    }

    @Test
    fun noShouldersDoesNotBlock() {
        val p = pose().also { it[11 * 4 + 3] = .1 }
        assertEquals(listOf(0), HandCandidateGate.gate(listOf(hand(.5, .2)), p).accepted)
    }

    @Test
    fun birthGateNeedsConsecutiveFramesOnlyForUnanchored() {
        val gate = HandCandidateGate.BirthGate(frames = 3)
        val c = listOf(hand(.5, .2))
        assertEquals(emptyList<Int>(), gate.filter(c, listOf(0), listOf(0)))
        assertEquals(emptyList<Int>(), gate.filter(c, listOf(0), listOf(0)))
        assertEquals(listOf(0), gate.filter(c, listOf(0), listOf(0)))
        assertEquals(listOf(0), gate.filter(listOf(hand(.62, .70)), listOf(0), emptyList()))
        val g2 = HandCandidateGate.BirthGate(frames = 2)
        g2.filter(listOf(hand(.5, .2)), listOf(0), listOf(0))
        assertEquals(emptyList<Int>(), g2.filter(listOf(hand(.8, .8)), listOf(0), listOf(0)))
    }
}
