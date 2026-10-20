package com.univoz.senas

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Espejo de tools/rig-tests/rig_hand_capture.test.mjs, de la cadena de brazo
 * de rig_tracking.test.mjs y de handUsable en rig_motion_frame.test.mjs.
 */
class CapturaManosTest {
    /** Pose 33 x (x, y, z, vis); [puntos]: indice -> (x, y, z, vis). */
    private fun pose(vararg puntos: Pair<Int, DoubleArray>): DoubleArray =
        DoubleArray(33 * 4).also { p ->
            for (i in 0 until 33) {
                p[i * 4] = .5; p[i * 4 + 1] = .5; p[i * 4 + 3] = 1.0
            }
            for ((i, v) in puntos) for (k in v.indices) p[i * 4 + k] = v[k]
        }

    private fun pt(x: Double, y: Double, z: Double = 0.0, vis: Double = 1.0) =
        doubleArrayOf(x, y, z, vis)

    /** Mano esquematica de rig_tracking.test.mjs. */
    private fun palma(x: Double, y: Double, direction: Double = 1.0): DoubleArray =
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

    private val brazos = arrayOf(
        11 to pt(.72, .35), 13 to pt(.70, .46), 15 to pt(.68, .55),
        12 to pt(.28, .35), 14 to pt(.30, .46), 16 to pt(.32, .55),
    )

    @Test
    fun armChainLocksPhysicalHandsDespiteContradictoryLabels() {
        val r = CapturaManos.assignHandsByArmChain(
            listOf(palma(.68, .55), palma(.32, .55)), pose(*brazos), .4)
        assertEquals(listOf("left", "right"), r.sideByIndex)
        assertEquals("pose_arm_chain", r.mode)
    }

    @Test
    fun armChainUsesImageXyOnlySoPoseDepthNeverDecides() {
        // Datos reales (sesion 20261004T081355Z): la z de la pose (~-1,
        // relativa a la cadera) no es comparable con la de la mano.
        val p = pose(
            11 to pt(.281, .626, -.09, .95), 13 to pt(.349, .85, -.39, .95),
            15 to pt(.350, .672, -.97, .96),
            12 to pt(.046, .635, -.09, .95), 14 to pt(-.016, .851, -.25, .95),
            16 to pt(-.016, .927, -.72, .10),
        )
        val r = CapturaManos.assignHandsByArmChain(listOf(palma(.38, .676)), p, .235)
        assertEquals(listOf("left"), r.sideByIndex)
        assertEquals("pose_arm_chain", r.mode)
        assertTrue("costo izquierdo ${r.costs[0].first}", r.costs[0].first < .5)
    }

    @Test
    fun ambiguousArmChainsDoNotLockEitherHand() {
        val p = pose(
            11 to pt(.40, .35), 13 to pt(.46, .45), 15 to pt(.50, .55),
            12 to pt(.60, .35), 14 to pt(.54, .45), 16 to pt(.50, .55),
        )
        val r = CapturaManos.assignHandsByArmChain(listOf(palma(.48, .55), palma(.52, .55)), p, .2)
        assertEquals(listOf(null, null), r.sideByIndex)
        assertEquals("ambiguous", r.mode)
    }

    @Test
    fun singleCompleteHandResolvesSideFromArmChain() {
        val r = CapturaManos.assignHandsByArmChain(listOf(palma(.68, .55)), pose(*brazos), .4)
        assertEquals(listOf("left"), r.sideByIndex)
        assertEquals("pose_arm_chain", r.mode)
    }

    @Test
    fun singleHandPrefersTheArmWhoseWristIsVisible() {
        // MediaPipe estima la muneca izquierda oculta encima de la mano real
        // (derecha, visible): sin visibilidad ganaria la izquierda.
        val mano = DoubleArray(63).also {
            for (i in 0 until 21) {
                it[i * 3] = .50 + i * .001
                it[i * 3 + 1] = .45 - i * .002
            }
        }
        val p = pose(
            11 to pt(.6, .4), 12 to pt(.4, .4), 13 to pt(.62, .55), 14 to pt(.38, .55),
            15 to pt(.50, .45, vis = .1), 16 to pt(.52, .47, vis = .95),
        )
        assertEquals("right", CapturaManos.assignHandsByArmChain(listOf(mano), p, .2).sideByIndex[0])
    }

    @Test
    fun handSideStaysPendingUntilArmChainIsReady() {
        val fallback = CapturaManos.resolveAnatomicalHandSide(
            CapturaManos.Asignacion("fallback", listOf("right"), emptyList()), 0)
        assertNull(fallback.side)
        assertFalse(fallback.sideLocked)
        assertTrue(fallback.sideAmbiguous)
        val chain = CapturaManos.resolveAnatomicalHandSide(
            CapturaManos.Asignacion("pose_arm_chain", listOf("left"), emptyList()), 0)
        assertEquals("left", chain.side)
        assertTrue(chain.sideLocked)
        assertFalse(chain.sideAmbiguous)
    }

    // ---- captura (rig_hand_capture.test.mjs) ----

    /** Mano plausible con la muneca en (x, y). */
    private fun mano(x: Double, y: Double): DoubleArray {
        val forma = arrayOf(
            0.0 to 0.0, -.06 to -.05, -.11 to -.10, -.14 to -.16, -.16 to -.22,
            -.04 to -.08, -.05 to -.16, -.06 to -.24, -.06 to -.32, 0.0 to -.10,
            0.0 to -.20, 0.0 to -.30, 0.0 to -.40, .04 to -.09, .06 to -.18, .07 to -.26,
            .08 to -.34, .08 to -.06, .11 to -.13, .13 to -.19, .14 to -.24,
        )
        return DoubleArray(63).also { h ->
            forma.forEachIndexed { i, (dx, dy) ->
                h[i * 3] = x + dx * .4
                h[i * 3 + 1] = y + dy * .4
                h[i * 3 + 2] = if (i == 0) 0.0 else -.02 - i * .001
            }
        }
    }

    /** Munecas de la pose en (.70, .70) y (.30, .70). */
    private fun poseCaptura() = pose(
        11 to pt(.62, .35), 12 to pt(.38, .35), 13 to pt(.68, .55), 14 to pt(.32, .55),
        15 to pt(.70, .70), 16 to pt(.30, .70),
    )

    private fun candidata(x: Double, y: Double, etiqueta: String, confianza: Double = 1.0) =
        CapturaManos.Candidata(mano(x, y), etiqueta, confianza)

    @Test
    fun twoHandsNearTheirWristsGetAnatomicalSidesAndRawLandmarks() {
        val captura = CapturaManos()
        var r: CapturaManos.Resultado? = null
        for (i in 0 until 4) {
            val t = 1000.0 + i * 33
            r = captura.process(listOf(candidata(.70, .70, "Left"), candidata(.30, .70, "Right")),
                poseCaptura(), t, t)
        }
        r!!
        assertEquals("pose_arm_chain", r.assignment.mode)
        assertEquals(listOf("left", "right"), r.assignment.sideByIndex)
        assertEquals("TRACKING", r.tracking.left.state)
        assertSame(r.tracking.left.raw, r.left)
        assertSame(r.tracking.left.render, r.renderLeft)
        assertEquals(listOf(true, true), r.usable)
    }

    @Test
    fun gateRejectionsAreAssociationErrorsWithoutSide() {
        val r = CapturaManos().process(
            listOf(candidata(.70, .70, "Left"), candidata(.701, .701, "Left", .5)),
            poseCaptura(), 1000.0, 1000.0)
        assertTrue(r.gate.rejected.any { it.second == "hand_duplicate" })
        assertTrue(r.errors.any {
            it["stage"] == "association" && it["code"] == "hand_duplicate" && it["side"] == null
        })
    }

    @Test
    fun unusableHandReachesTheTrackerWithoutLandmarks() {
        val captura = CapturaManos()
        val malo = mano(.70, .70).also { it[12 * 3] = .70; it[12 * 3 + 1] = 0.0; it[12 * 3 + 2] = 0.0 }
        for (i in 0 until 4) {
            val t = 1000.0 + i * 33
            val r = captura.process(listOf(CapturaManos.Candidata(malo, "Left", 1.0)),
                poseCaptura(), t, t)
            if (i == 3) {
                assertEquals(listOf(false), r.usable)
                assertNull(r.tracking.left.detected)
                assertTrue(r.errors.any {
                    it["stage"] == "capture" && it["code"] == "hand_segment_invalid" &&
                        it["side"] == "left" && it["landmark"] == "12"
                })
                assertTrue(r.errors.any { it["code"] == "hand_landmarks_invalid" })
            }
        }
    }

    @Test
    fun wristDisagreementNeedsThreeDirectFramesAndIsReportedOnce() {
        fun reportes(skew: Double): List<Int> {
            val captura = CapturaManos()
            return (0 until 8).map { i ->
                val t = 1000.0 + i * 33
                captura.process(listOf(candidata(.80, .70, "Left")), poseCaptura(), t, t - skew)
                    .errors.count { it["code"] == "wrist_disagreement" }
            }
        }
        val directa = reportes(0.0)
        assertEquals(1, directa.sum())
        assertTrue(directa.indexOf(1) >= 2)
        // Con pose 80 ms mas vieja (proyeccion) no se acusa desacuerdo.
        assertEquals(0, reportes(80.0).sum())
    }

    // ---- mano utilizable (rig_motion_frame.test.mjs) ----

    private fun manoValida(): DoubleArray {
        val p = arrayOf(
            .50 to .70, .44 to .65, .39 to .60, .36 to .54, .34 to .48,
            .46 to .62, .45 to .54, .44 to .46, .44 to .38,
            .50 to .60, .50 to .50, .50 to .40, .50 to .30,
            .54 to .61, .56 to .52, .57 to .44, .58 to .36,
            .58 to .64, .61 to .57, .63 to .51, .64 to .46,
        )
        return DoubleArray(63).also { h ->
            p.forEachIndexed { i, (x, y) -> h[i * 3] = x; h[i * 3 + 1] = y }
        }
    }

    private fun DoubleArray.con(i: Int, x: Double, y: Double) =
        copyOf().also { it[i * 3] = x; it[i * 3 + 1] = y; it[i * 3 + 2] = 0.0 }

    @Test
    fun handUsableAcceptsPlausibleHandAndNamesEachRejection() {
        assertEquals(CapturaManos.Utilizable(true, null, null), CapturaManos.handUsable(manoValida()))
        assertEquals("hand_landmarks_incomplete",
            CapturaManos.handUsable(manoValida().copyOf(60)).code)
        assertEquals(CapturaManos.Utilizable(false, "point_non_finite", 7),
            CapturaManos.handUsable(manoValida().con(7, Double.NaN, .5)))
        assertEquals("wrist_out_of_frame",
            CapturaManos.handUsable(manoValida().con(0, 1.02, .7)).code)
        val fuera = manoValida().also { for (i in 5 until 21) it[i * 3] += .9 }
        assertEquals("hand_out_of_frame", CapturaManos.handUsable(fuera).code)
        val chica = manoValida().also {
            for (i in 0 until 21) {
                it[i * 3] = .5 + (it[i * 3] - .5) * .05
                it[i * 3 + 1] = .7 + (it[i * 3 + 1] - .7) * .05
            }
        }
        assertEquals(CapturaManos.Utilizable(false, "hand_scale_invalid", 9),
            CapturaManos.handUsable(chica))
        assertFalse(CapturaManos.handUsable(manoValida().con(12, 1.4, .3)).ok)
        assertEquals(CapturaManos.Utilizable(false, "hand_segment_invalid", 12),
            CapturaManos.handUsable(manoValida().con(12, .5, .02)))
    }
}
