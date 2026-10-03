package com.univoz.senas

import android.content.Context
import android.graphics.Bitmap
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.core.Delegate
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.components.containers.Landmark
import com.google.mediapipe.tasks.components.containers.NormalizedLandmark
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarker
import com.google.mediapipe.tasks.vision.handlandmarker.HandLandmarkerResult
import com.google.mediapipe.tasks.vision.holisticlandmarker.HolisticLandmarker
import com.google.mediapipe.tasks.vision.holisticlandmarker.HolisticLandmarkerResult
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarker
import com.google.mediapipe.tasks.vision.poselandmarker.PoseLandmarkerResult

/**
 * Captura del producto: HolisticLandmarker (cuerpo, manos y cara en una sola
 * pasada, docs/13). Si Holistic no carga, cae a HandLandmarker +
 * PoseLandmarker corriendo en LIVE_STREAM, descritos abajo.
 *
 * Los dos tasks son independientes y devuelven resultados por callbacks
 * asincronos que llegan en orden impredecible. Hay DOS salidas distintas
 * a proposito:
 *
 * - [onFrame]: solo dispara cuando pose y manos disponibles pertenecen a
 *   instantes compatibles (ventana maxima de 120 ms). Las tareas pueden
 *   terminar con latencias distintas; exigir timestamp exacto dejaria el
 *   canal de grabacion vacio en dispositivos lentos. Usar para guardar
 *   muestras o alimentar el clasificador (DtwClassifier).
 *
 * - [onPreview]: dispara cada vez que CUALQUIERA de los dos modelos
 *   termina, combinando con el ultimo dato conocido del otro. Es para
 *   pintar el esqueleto en pantalla en vivo.
 *
 * [analizarManos] y [analizarPose] son independientes: cada una tiene su
 * propia compuerta de backpresion (no aceptan un frame nuevo mientras el
 * anterior sigue en vuelo) y quien llama (LandmarkPlugin) decide con que
 * frecuencia llama a cada una. La idea: las manos cambian de forma rapido
 * al senar y necesitan actualizarse seguido; el torso/hombros se mueven
 * mucho mas despacio, asi que correr pose con menos frecuencia libera
 * computo real para el modelo de manos sin perder nada perceptible.
 */
class LandmarkEngine(
    context: Context,
    private val onFrame: (FrameResult) -> Unit,
    private val onPreview: (FrameResult) -> Unit,
    private val onError: (String) -> Unit,
) {

    /**
     * pose: 33 x (x, y, z, visibility) en coordenadas de imagen [0,1].
     * poseMundo: 33 x (x, y, z) en METROS, con origen en el punto medio de
     *   las caderas. Es el esqueleto 3D real, no la profundidad aproximada
     *   que trae `pose`.
     * manos: 21 x (x, y, z) o null.
     *
     * Las dos versiones de pose viajan juntas porque sirven para cosas
     * distintas: las de imagen son las que se pintan sobre el preview de la
     * camara, y las metricas son las unicas con las que se puede reconstruir
     * una postura. La Z de `pose` se midio incoherente entre puntos vecinos
     * (recorridos de 3.5 anchos de hombro en un antebrazo de 0.8), asi que
     * no sirve para orientar huesos.
     */
    class FrameResult(
        val timestampMs: Long,
        val pose: DoubleArray?,
        val poseMundo: DoubleArray?,
        val left: DoubleArray?,
        val right: DoubleArray?,
        val renderLeft: DoubleArray?,
        val renderRight: DoubleArray?,
        val poseTimestampMs: Long?,
        val handsTimestampMs: Long?,
        val sourceSkewMs: Long?,
        val association: Map<String, Any?>,
        val errors: List<Map<String, String>>,
        /** 17 puntos clave de cara x (x, y, z) en el orden de [FACE_KEYPOINTS]. */
        val face: DoubleArray? = null,
        /** 21 x (x, y, z) en metros (solo Holistic). */
        val leftWorld: DoubleArray? = null,
        val rightWorld: DoubleArray? = null,
        val captureMode: String = "separado",
    )

    // Ultimo dato conocido de cada mitad, para armar el preview sin esperar
    // a que coincidan. Con lock propio porque pose y manos llegan de hilos
    // distintos (cada modelo tiene su propio callback interno).
    private val ultimoLock = Any()
    private var ultimaPose: DoubleArray? = null
    private var ultimaPoseMundo: DoubleArray? = null
    private var ultimoTimestampPose = Long.MIN_VALUE
    private var ultimaIzq: DoubleArray? = null
    private var ultimaDer: DoubleArray? = null
    private var ultimoTimestampManos = Long.MIN_VALUE
    private var manosConocidas = false
    private val handTracker = HandTrackCoordinator()
    private var ultimoTracking: HandTrackCoordinator.Result? = null
    private var ultimoAssignmentMode = "pose_pending"

    private data class ManoCandidata(
        val puntos: DoubleArray,
        val confianza: Double,
        val muñecaX: Double,
        val muñecaY: Double,
    )

    // A 30 FPS permite un desfase de hasta 3-4 capturas entre tasks, pero no
    // mezcla posturas separadas por una pausa real del tracking.
    private val ventanaFusionMs = 120L
    companion object {
        private const val MIN_POSE_WRIST_VISIBILITY = 0.35
        /**
         * Puntos de la malla facial que viajan al visor; mismos indices que
         * kCaraClave en index.html y FACE_IDX/EYE de rig_face.mjs.
         */
        val FACE_KEYPOINTS = intArrayOf(1, 10, 152, 33, 133, 159, 145, 263,
            362, 386, 374, 13, 14, 61, 291, 105, 334)
    }

    // Compuertas de backpresion INDEPENDIENTES: cada modelo se libera con
    // su propio resultado, no con el del otro. Asi las manos no esperan al
    // torso ni viceversa.
    private val manosLock = Any()
    private var manosEnVuelo = false
    private var manosDesdeNs = 0L

    private val poseLock = Any()
    private var poseEnVuelo = false
    private var poseDesdeNs = 0L

    private val timeoutNs = 2_000_000_000L // 2s de seguridad por si un resultado nunca llega

    private var handLandmarker: HandLandmarker? = null
    private var poseLandmarker: PoseLandmarker? = null
    private var holisticLandmarker: HolisticLandmarker? = null
    private val holisticLock = Any()
    private var holisticEnVuelo = false
    private var holisticDesdeNs = 0L
    private val birthGate = HandCandidateGate.BirthGate(frames = 3)

    /** Errores al crear Holistic (se reportan en el primer frame). */
    private val erroresCreacion = mutableListOf<Map<String, String>>()

    val holisticActivo: Boolean get() = holisticLandmarker != null

    init {
        holisticLandmarker = crearHolistic(context)
        if (holisticLandmarker == null) crearSeparados(context)
    }

    private fun crearHolistic(context: Context): HolisticLandmarker? {
        for (delegate in listOf(Delegate.GPU, Delegate.CPU)) {
            try {
                val options = HolisticLandmarker.HolisticLandmarkerOptions.builder()
                    .setBaseOptions(
                        BaseOptions.builder()
                            .setModelAssetPath("holistic_landmarker.task")
                            .setDelegate(delegate)
                            .build()
                    )
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setMinPoseDetectionConfidence(0.4f)
                    .setMinPosePresenceConfidence(0.4f)
                    .setMinHandLandmarksConfidence(0.4f)
                    .setMinFaceDetectionConfidence(0.4f)
                    .setMinFacePresenceConfidence(0.4f)
                    // Expresiones salen de la geometria de la malla (rig_face):
                    // el subgrafo de blendshapes no es necesario.
                    .setOutputFaceBlendshapes(false)
                    .setResultListener { result, _ -> onHolistic(result) }
                    .setErrorListener { e -> onError("holistic: ${e.message}") }
                    .build()
                return HolisticLandmarker.createFromOptions(context, options)
            } catch (e: Exception) {
                erroresCreacion += mapOf(
                    "stage" to "capture",
                    "code" to "holistic_create_failed",
                    "delegate" to delegate.name,
                )
            }
        }
        erroresCreacion += mapOf("stage" to "capture", "code" to "capture_fallback")
        return null
    }

    private fun crearSeparados(context: Context) {
        val handOptions = HandLandmarker.HandLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setModelAssetPath("hand_landmarker.task")
                    .setDelegate(Delegate.GPU)
                    .build()
            )
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumHands(2)
            .setMinHandDetectionConfidence(0.4f)
            .setMinTrackingConfidence(0.3f)
            .setMinHandPresenceConfidence(0.4f)
            .setResultListener { result, _ -> onManos(result) }
            .setErrorListener { e -> onError("manos: ${e.message}") }
            .build()

        val poseOptions = PoseLandmarker.PoseLandmarkerOptions.builder()
            .setBaseOptions(
                BaseOptions.builder()
                    .setModelAssetPath("pose_landmarker_lite.task")
                    .setDelegate(Delegate.GPU)
                    .build()
            )
            .setRunningMode(RunningMode.LIVE_STREAM)
            .setNumPoses(1)
            .setMinPoseDetectionConfidence(0.4f)
            .setMinTrackingConfidence(0.3f)
            .setMinPosePresenceConfidence(0.4f)
            .setResultListener { result, _ -> onPose(result) }
            .setErrorListener { e -> onError("pose: ${e.message}") }
            .build()

        handLandmarker = HandLandmarker.createFromOptions(context, handOptions)
        poseLandmarker = PoseLandmarker.createFromOptions(context, poseOptions)
    }

    fun holisticOcupado(): Boolean = synchronized(holisticLock) {
        holisticEnVuelo && (System.nanoTime() - holisticDesdeNs < timeoutNs)
    }

    /** [timestampMs] estrictamente creciente. False si ya hay un frame en vuelo. */
    fun analizarHolistic(bitmap: Bitmap, timestampMs: Long): Boolean {
        val tarea = holisticLandmarker ?: return false
        synchronized(holisticLock) {
            val ahora = System.nanoTime()
            if (holisticEnVuelo && ahora - holisticDesdeNs < timeoutNs) return false
            holisticEnVuelo = true
            holisticDesdeNs = ahora
        }
        tarea.detectAsync(BitmapImageBuilder(bitmap).build(), timestampMs)
        return true
    }

    fun manosOcupadas(): Boolean = synchronized(manosLock) {
        manosEnVuelo && (System.nanoTime() - manosDesdeNs < timeoutNs)
    }

    fun poseOcupada(): Boolean = synchronized(poseLock) {
        poseEnVuelo && (System.nanoTime() - poseDesdeNs < timeoutNs)
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay manos en vuelo. */
    fun analizarManos(bitmap: Bitmap, timestampMs: Long): Boolean {
        synchronized(manosLock) {
            val ahora = System.nanoTime()
            if (manosEnVuelo && ahora - manosDesdeNs < timeoutNs) return false
            manosEnVuelo = true
            manosDesdeNs = ahora
        }
        val tarea = handLandmarker ?: return false
        tarea.detectAsync(BitmapImageBuilder(bitmap).build(), timestampMs)
        return true
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay pose en vuelo. */
    fun analizarPose(bitmap: Bitmap, timestampMs: Long): Boolean {
        synchronized(poseLock) {
            val ahora = System.nanoTime()
            if (poseEnVuelo && ahora - poseDesdeNs < timeoutNs) return false
            poseEnVuelo = true
            poseDesdeNs = ahora
        }
        val tarea = poseLandmarker ?: return false
        tarea.detectAsync(BitmapImageBuilder(bitmap).build(), timestampMs)
        return true
    }

    private fun crearFrame(
        timestampMs: Long,
        pose: DoubleArray?,
        poseMundo: DoubleArray?,
        left: DoubleArray?,
        right: DoubleArray?,
        renderLeft: DoubleArray?,
        renderRight: DoubleArray?,
        poseTimestampMs: Long?,
        handsTimestampMs: Long?,
        tracking: HandTrackCoordinator.Result?,
        extraErrors: List<Map<String, String>> = emptyList(),
        extras: Extras? = null,
    ): FrameResult {
        val skew = if (poseTimestampMs != null && handsTimestampMs != null)
            abs(poseTimestampMs - handsTimestampMs) else null
        val errors = mutableListOf<Map<String, String>>()
        tracking?.errors?.let(errors::addAll)
        errors.addAll(extraErrors)
        if (skew != null && skew > 50) {
            errors += mapOf("stage" to "fusion", "code" to "source_skew")
        }
        if (pose != null && pose.size >= 33 * 4) {
            val shoulderWidth = max(.05, distanciaPose(pose, 11, 12))
            listOf("left" to (left to 15), "right" to (right to 16)).forEach {
                (side, handAndIndex) ->
                val hand = handAndIndex.first
                val poseIndex = handAndIndex.second
                if (hand != null && hand.size >= 3) {
                    val residual = hypot(
                        hand[0] - pose[poseIndex * 4],
                        hand[1] - pose[poseIndex * 4 + 1],
                    ) / shoulderWidth
                    if (residual > .25) errors += mapOf(
                        "stage" to "fusion",
                        "code" to "wrist_disagreement",
                        "side" to side,
                    )
                }
            }
        }
        val association = if (tracking == null) emptyMap() else mapOf(
            "left_state" to tracking.left.state,
            "right_state" to tracking.right.state,
            "left_cost" to tracking.costs["left"],
            "right_cost" to tracking.costs["right"],
            "hand_assignment_mode" to ultimoAssignmentMode,
            "contact" to tracking.contact,
            "contact_wrist_distance" to tracking.contactWristDistance,
        )
        return FrameResult(
            timestampMs,
            pose,
            poseMundo,
            left,
            right,
            renderLeft,
            renderRight,
            poseTimestampMs,
            handsTimestampMs,
            skew,
            association,
            errors,
            face = extras?.face,
            leftWorld = extras?.leftWorld,
            rightWorld = extras?.rightWorld,
            captureMode = if (holisticActivo) "holistic" else "separado",
        )
    }

    /** Datos que solo trae Holistic. */
    private class Extras(
        val face: DoubleArray?,
        val leftWorld: DoubleArray?,
        val rightWorld: DoubleArray?,
    )

    private fun normalizados(lm: List<NormalizedLandmark>, conVisibilidad: Boolean): DoubleArray {
        val ancho = if (conVisibilidad) 4 else 3
        return DoubleArray(lm.size * ancho).also {
            for (i in lm.indices) {
                val p = lm[i]
                it[i * ancho] = p.x().toDouble()
                it[i * ancho + 1] = p.y().toDouble()
                it[i * ancho + 2] = p.z().toDouble()
                if (conVisibilidad) {
                    it[i * ancho + 3] = p.visibility().orElse(0f).toDouble()
                }
            }
        }
    }

    private fun metricos(lm: List<Landmark>): DoubleArray =
        DoubleArray(lm.size * 3).also {
            for (i in lm.indices) {
                it[i * 3] = lm[i].x().toDouble()
                it[i * 3 + 1] = lm[i].y().toDouble()
                it[i * 3 + 2] = lm[i].z().toDouble()
            }
        }

    private fun onHolistic(result: HolisticLandmarkerResult) {
        synchronized(holisticLock) { holisticEnVuelo = false }
        val t = result.timestampMs()
        val poseLm = result.poseLandmarks()
        val pose = if (poseLm.size >= 33) normalizados(poseLm, true) else null
        val mundoLm = result.poseWorldLandmarks()
        val mundo = if (mundoLm.size >= 33) metricos(mundoLm) else null
        val caraLm = result.faceLandmarks()
        val cara = if (caraLm.size > 400) DoubleArray(FACE_KEYPOINTS.size * 3).also {
            FACE_KEYPOINTS.forEachIndexed { k, i ->
                it[k * 3] = caraLm[i].x().toDouble()
                it[k * 3 + 1] = caraLm[i].y().toDouble()
                it[k * 3 + 2] = caraLm[i].z().toDouble()
            }
        } else null

        val candidatas = mutableListOf<ManoCandidata>()
        val mundos = mutableListOf<DoubleArray?>()
        val errores = mutableListOf<Map<String, String>>()
        synchronized(erroresCreacion) {
            errores += erroresCreacion
            erroresCreacion.clear()
        }
        for ((imagen, metrico) in listOf(
            result.leftHandLandmarks() to result.leftHandWorldLandmarks(),
            result.rightHandLandmarks() to result.rightHandWorldLandmarks(),
        )) {
            if (imagen.size != 21) continue
            val arr = normalizados(imagen, false)
            if (arr.any { !it.isFinite() }) {
                errores += mapOf("stage" to "capture", "code" to "point_non_finite")
                continue
            }
            // La etiqueta de Holistic es solo pista: el lado lo decide la
            // cadena del brazo, igual que en el camino separado.
            candidatas += ManoCandidata(arr, 1.0, arr[0], arr[1])
            mundos += if (metrico.size == 21) metricos(metrico) else null
        }

        synchronized(ultimoLock) {
            ultimaPose = pose
            ultimaPoseMundo = mundo
            ultimoTimestampPose = t
        }
        procesarCandidatas(t, candidatas, pose, errores) { tracked ->
            // Mundo de cada mano segun el lado que le asigno el tracker.
            fun mundoDe(detected: DoubleArray?): DoubleArray? {
                if (detected == null) return null
                val i = candidatas.indexOfFirst { it.puntos.contentEquals(detected) }
                return mundos.getOrNull(i)
            }
            Extras(cara, mundoDe(tracked.left.detected), mundoDe(tracked.right.detected))
        }
    }

    private fun onPose(result: PoseLandmarkerResult) {
        synchronized(poseLock) { poseEnVuelo = false }

        val t = result.timestampMs()
        val lm = result.landmarks().firstOrNull()
        val arr = if (lm == null || lm.size < 33) null else DoubleArray(33 * 4).also {
            for (i in 0 until 33) {
                val p = lm[i]
                it[i * 4] = p.x().toDouble()
                it[i * 4 + 1] = p.y().toDouble()
                it[i * 4 + 2] = p.z().toDouble()
                it[i * 4 + 3] = (p.visibility().orElse(0f)).toDouble()
            }
        }

        // Esqueleto metrico. Sin visibility: worldLandmarks no la trae, y de
        // todos modos el filtro por visibilidad se hace con `pose`.
        val wlm = result.worldLandmarks().firstOrNull()
        val arrMundo = if (wlm == null || wlm.size < 33) null else DoubleArray(33 * 3).also {
            for (i in 0 until 33) {
                val p = wlm[i]
                it[i * 3] = p.x().toDouble()
                it[i * 3 + 1] = p.y().toDouble()
                it[i * 3 + 2] = p.z().toDouble()
            }
        }

        var fusionado: FrameResult? = null
        val preview = synchronized(ultimoLock) {
            ultimaPose = arr
            ultimaPoseMundo = arrMundo
            ultimoTimestampPose = t
            val shoulderWidth = if (arr != null && arr.size >= 33 * 4)
                max(.05, distanciaPose(arr, 11, 12)) else .4
            val render = if (manosConocidas) {
                handTracker.renderAt(t, shoulderWidth)
            } else null
            if (manosConocidas && abs(t - ultimoTimestampManos) <= ventanaFusionMs) {
                fusionado = crearFrame(
                    maxOf(t, ultimoTimestampManos),
                    arr,
                    arrMundo,
                    ultimaIzq,
                    ultimaDer,
                    render?.left?.render,
                    render?.right?.render,
                    t,
                    ultimoTimestampManos,
                    render ?: ultimoTracking,
                )
            }
            crearFrame(
                t,
                arr,
                arrMundo,
                ultimaIzq,
                ultimaDer,
                render?.left?.render,
                render?.right?.render,
                t,
                ultimoTimestampManos.takeIf { manosConocidas },
                render ?: ultimoTracking,
            )
        }
        onPreview(preview)
        fusionado?.let(onFrame)
    }

    private fun onManos(result: HandLandmarkerResult) {
        synchronized(manosLock) { manosEnVuelo = false }

        val t = result.timestampMs()
        val poseParaLados = synchronized(ultimoLock) {
            if (ultimoTimestampPose != Long.MIN_VALUE &&
                abs(t - ultimoTimestampPose) <= ventanaFusionMs
            ) {
                ultimaPose
            } else {
                null
            }
        }

        val manos = result.landmarks()
        val categorias = result.handednesses()
        val candidatas = mutableListOf<ManoCandidata>()
        val erroresEntrada = mutableListOf<Map<String, String>>()
        for (i in manos.indices) {
            val lm = manos[i]
            if (lm.size != 21) {
                erroresEntrada += mapOf(
                    "stage" to "capture",
                    "code" to "hand_landmarks_incomplete",
                    "index" to i.toString(),
                )
                continue
            }
            val arr = DoubleArray(21 * 3)
            for (j in 0 until 21) {
                val p = lm[j]
                arr[j * 3] = p.x().toDouble()
                arr[j * 3 + 1] = p.y().toDouble()
                arr[j * 3 + 2] = p.z().toDouble()
            }
            if (arr.any { !it.isFinite() }) {
                erroresEntrada += mapOf(
                    "stage" to "capture",
                    "code" to "point_non_finite",
                    "index" to i.toString(),
                )
                continue
            }
            candidatas += ManoCandidata(
                puntos = arr,
                // Conservar score para calidad; nunca usar categoryName para
                // decidir lado físico.
                confianza = categorias.getOrNull(i)?.firstOrNull()?.score()
                    ?.toDouble() ?: .5,
                muñecaX = lm[0].x().toDouble(),
                muñecaY = lm[0].y().toDouble(),
            )
        }
        procesarCandidatas(t, candidatas, poseParaLados, erroresEntrada)
    }

    /**
     * Compuerta anti-alucinacion -> lado por cadena del brazo -> tracker ->
     * frames. Comun a Holistic y al camino separado.
     */
    private fun procesarCandidatas(
        t: Long,
        todas: List<ManoCandidata>,
        poseParaLados: DoubleArray?,
        erroresEntrada: MutableList<Map<String, String>>,
        extras: ((HandTrackCoordinator.Result) -> Extras)? = null,
    ) {
        val entradas = todas.map { HandCandidateGate.Input(it.puntos, it.confianza) }
        val puerta = HandCandidateGate.gate(entradas, poseParaLados)
        puerta.rejected.forEach { (_, code) ->
            erroresEntrada += mapOf("stage" to "association", "code" to code)
        }
        val pasan = synchronized(birthGate) {
            birthGate.filter(entradas, puerta.accepted, puerta.unanchored)
        }
        val candidatas = pasan.map { todas[it] }
        val poseCadenaDisponible = poseParaLados != null &&
            poseParaLados.size >= 33 * 4 && poseTieneCadenaBrazo(poseParaLados)
        val ladosCadena = if (poseCadenaDisponible) {
            asignarLadosCadena(candidatas, poseParaLados!!)
        } else emptyList()
        ultimoAssignmentMode = when {
            !poseCadenaDisponible -> "pose_pending"
            ladosCadena.any { it != null } -> "pose_arm_chain"
            else -> "ambiguous"
        }
        val trackCandidates = candidatas.mapIndexed { index, candidata ->
            val ladoCadena = ladosCadena.getOrNull(index)
            HandTrackCoordinator.Candidate(
                candidata.puntos,
                ladoCadena,
                candidata.confianza,
                sideLocked = ladoCadena != null,
                // No usar etiqueta HandLandmarker antes de autoridad Pose.
                sideAmbiguous = !poseCadenaDisponible || ladoCadena == null,
            )
        }

        var fusionado: FrameResult? = null
        val preview = synchronized(ultimoLock) {
            val poseHint = poseParaLados?.takeIf {
                poseCadenaDisponible && it.size >= 33 * 4
            }?.let {
                HandTrackCoordinator.PoseHint(
                    it[15 * 4], it[15 * 4 + 1],
                    it[16 * 4], it[16 * 4 + 1],
                    max(.05, distanciaPose(it, 11, 12)),
                )
            }
            val tracked = handTracker.update(trackCandidates, poseHint, t)
            val extra = extras?.invoke(tracked)
            val izq = tracked.left.detected
            val der = tracked.right.detected
            ultimoTracking = tracked
            ultimaIzq = izq
            ultimaDer = der
            ultimoTimestampManos = t
            manosConocidas = true
            if (ultimoTimestampPose != Long.MIN_VALUE &&
                abs(t - ultimoTimestampPose) <= ventanaFusionMs
            ) {
                fusionado = crearFrame(
                    maxOf(t, ultimoTimestampPose),
                    ultimaPose,
                    ultimaPoseMundo,
                    izq,
                    der,
                    tracked.left.render,
                    tracked.right.render,
                    ultimoTimestampPose,
                    t,
                    tracked,
                    erroresEntrada,
                    extra,
                )
            }
            crearFrame(
                t,
                ultimaPose,
                ultimaPoseMundo,
                izq,
                der,
                tracked.left.render,
                tracked.right.render,
                ultimoTimestampPose.takeIf { it != Long.MIN_VALUE },
                t,
                tracked,
                erroresEntrada,
                extra,
            )
        }
        onPreview(preview)
        fusionado?.let(onFrame)
    }

    private fun poseTieneCadenaBrazo(pose: DoubleArray): Boolean {
        return listOf(11, 13, 15, 12, 14, 16).all { i ->
            pose[i * 4].isFinite() && pose[i * 4 + 1].isFinite() &&
                pose[i * 4 + 3].isFinite() &&
                pose[i * 4 + 3] >= MIN_POSE_WRIST_VISIBILITY
        }
    }

    /** Coste anatomico: hombro -> codo -> muñeca, no imagen izquierda/derecha. */
    private fun asignarLadosCadena(
        candidatas: List<ManoCandidata>,
        pose: DoubleArray,
    ): List<String?> {
        if (candidatas.isEmpty()) return emptyList()
        val ancho = max(.05, distanciaPose(pose, 11, 12))
        val margen = max(.06, ancho * .16)
        val costos = candidatas.map { mano ->
            costoCadenaBrazo(mano, pose, 11, 13, 15) to
                costoCadenaBrazo(mano, pose, 12, 14, 16)
        }
        if (candidatas.size >= 2) {
            val normal = costos[0].first + costos[1].second
            val cruzada = costos[0].second + costos[1].first
            if (normal.isFinite() && cruzada.isFinite() &&
                abs(normal - cruzada) >= margen
            ) {
                return if (normal < cruzada) listOf("left", "right")
                else listOf("right", "left")
            }
            // Ambiguous pair: do not guess side. Temporal tracker preserves
            // existing identity; new detections remain unassigned.
            return List(candidatas.size) { null }
        }
        return costos.map { (left, right) ->
            if (left.isFinite() && right.isFinite() &&
                abs(left - right) >= margen
            ) if (left < right) "left" else "right" else null
        }
    }

    private fun costoCadenaBrazo(
        mano: ManoCandidata,
        pose: DoubleArray,
        hombro: Int,
        codo: Int,
        muneca: Int,
    ): Double {
        val sx = pose[hombro * 4]
        val sy = pose[hombro * 4 + 1]
        val ex = pose[codo * 4]
        val ey = pose[codo * 4 + 1]
        val wx = pose[muneca * 4]
        val wy = pose[muneca * 4 + 1]
        if (!listOf(sx, sy, ex, ey, wx, wy, mano.muñecaX, mano.muñecaY)
                .all { it.isFinite() }
        ) return Double.POSITIVE_INFINITY

        val ancho = max(.05, distanciaPose(pose, 11, 12))
        val endpoint = hypot(mano.muñecaX - wx, mano.muñecaY - wy) / ancho
        val expectedX = wx - sx
        val expectedY = wy - sy
        val observedX = mano.muñecaX - sx
        val observedY = mano.muñecaY - sy
        val expectedLength = hypot(expectedX, expectedY)
        val observedLength = hypot(observedX, observedY)
        val direction = if (expectedLength <= 1e-8 || observedLength <= 1e-8) {
            .5
        } else {
            val aligned = (expectedX * observedX + expectedY * observedY) /
                (expectedLength * observedLength)
            1.0 - ((aligned + 1.0) / 2.0).coerceIn(0.0, 1.0)
        }
        val expectedLower = hypot(wx - ex, wy - ey)
        val observedLower = hypot(mano.muñecaX - ex, mano.muñecaY - ey)
        val chain = abs(observedLower - expectedLower) / ancho
        // Muneca que la pose no ve = estimacion (a veces encima de la otra
        // mano): pesa menos. Igual que armChainCost en rig_tracking.mjs.
        val visibilidad = pose[muneca * 4 + 3]
        val noVista = if (visibilidad.isFinite())
            (1.0 - visibilidad.coerceIn(0.0, 1.0)) * .6 else 0.0
        return endpoint + direction * .35 + chain * .20 + noVista
    }

    private fun distanciaPose(pose: DoubleArray, a: Int, b: Int): Double {
        val dx = pose[a * 4] - pose[b * 4]
        val dy = pose[a * 4 + 1] - pose[b * 4 + 1]
        return hypot(dx, dy)
    }

    fun cerrar() {
        handLandmarker?.close()
        poseLandmarker?.close()
        holisticLandmarker?.close()
        synchronized(holisticLock) { holisticEnVuelo = false }
        synchronized(birthGate) { birthGate.reset() }
        synchronized(ultimoLock) {
            ultimaPose = null
            ultimaPoseMundo = null
            ultimoTimestampPose = Long.MIN_VALUE
            ultimaIzq = null
            ultimaDer = null
            ultimoTimestampManos = Long.MIN_VALUE
            manosConocidas = false
            ultimoTracking = null
            ultimoAssignmentMode = "pose_pending"
            handTracker.reset()
        }
        synchronized(manosLock) { manosEnVuelo = false }
        synchronized(poseLock) { poseEnVuelo = false }
    }
}
