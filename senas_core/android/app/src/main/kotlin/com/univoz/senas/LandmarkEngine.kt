package com.univoz.senas

import android.content.Context
import android.graphics.Bitmap
import kotlin.math.abs
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
 * asincronos que llegan en orden impredecible. Cada resultado sale UNA vez
 * por [onResultado], con una marca de "fusionado":
 *
 * - Siempre: se dispara cada vez que CUALQUIERA de los dos modelos termina,
 *   combinando con el ultimo dato conocido del otro. Es para pintar el
 *   esqueleto en pantalla en vivo.
 *
 * - Fusionado = true: pose y manos disponibles pertenecen a instantes
 *   compatibles (ventana maxima de 120 ms). Las tareas pueden terminar con
 *   latencias distintas; exigir timestamp exacto dejaria el canal de
 *   grabacion vacio en dispositivos lentos. Usar para guardar muestras o
 *   alimentar el clasificador (DtwClassifier).
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
    /**
     * Un solo aviso por resultado (antes dos: preview y fusionado, y el
     * plugin armaba el mismo mapa dos veces). El Boolean es "fusionado": pose
     * y manos compatibles; Dart reparte a sus dos streams.
     */
    private val onResultado: (FrameResult, Boolean) -> Unit,
    private val onError: (String) -> Unit,
    /** ms de inferencia de cada resultado (Holistic, o manos en separado). */
    private val onInferencia: (Double) -> Unit = {},
    /** true: no intentar Holistic (nivel bajo con Holistic lento). */
    val forzadoSeparado: Boolean = false,
    /**
     * true: solo delegado CPU (toggle de desarrollador "Delegado MediaPipe").
     * false (default): GPU primero y CPU si no carga, como siempre.
     */
    val forzarCpu: Boolean = false,
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
        /** Inferencia del ultimo resultado, ms (nivel por dispositivo). */
        val inferMs: Double? = null,
        /**
         * Entrada de manos con el esquema de sesion web (`hands`): candidatas,
         * compuerta, nacimiento y lados. Permite reproducir la captura.
         */
        val handsIn: Map<String, Any?>? = null,
        /** Estado del seguimiento por lado (estado, superficie, recuperacion). */
        val track: Map<String, Any?>? = null,
        /** La pose de este frame salio del mismo instante (no del cache). */
        val poseRan: Boolean? = null,
    )

    // Cache de pose (kPoseCacheMaxMs de la web): cada resultado de manos se
    // arma con la ultima pose si tiene <= 120 ms. Con lock propio porque pose
    // y manos llegan de hilos distintos (cada modelo tiene su callback).
    private val ultimoLock = Any()
    private var ultimaPose: DoubleArray? = null
    private var ultimaPoseMundo: DoubleArray? = null
    private var ultimoTimestampPose = Long.MIN_VALUE
    /** Captura de manos de la web portada (CapturaManos); bajo [ultimoLock]. */
    private val captura = CapturaManos()

    // A 30 FPS permite un desfase de hasta 3-4 capturas entre tasks, pero no
    // mezcla posturas separadas por una pausa real del tracking.
    private val ventanaFusionMs = 120L
    companion object {
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
    // Cada compuerta se libera con el resultado, con el error del modelo o,
    // por seguridad, a los 2 s si ninguno de los dos llega.
    private val manosVuelo = VueloInferencia()
    private val poseVuelo = VueloInferencia()

    private var handLandmarker: HandLandmarker? = null
    private var poseLandmarker: PoseLandmarker? = null
    private var holisticLandmarker: HolisticLandmarker? = null
    private val holisticVuelo = VueloInferencia()

    /** Errores al crear Holistic (se reportan en el primer frame). */
    private val erroresCreacion = mutableListOf<Map<String, String>>()

    /** El modelo cargo con delegado GPU (entra a DeviceTier.nivelInicial). */
    var gpuOk = false
        private set

    /** false en nivel bajo: no se mandan puntos de cara. */
    @Volatile var conCara = true

    @Volatile private var ultimaInferenciaMs: Double? = null

    val holisticActivo: Boolean get() = holisticLandmarker != null

    /** Delegado con el que quedo cargado (para el diagnostico de latencia). */
    val delegadoNombre: String get() = if (gpuOk) "GPU" else "CPU"

    /** Delegados a intentar, en orden. */
    private val delegados: List<Delegate> =
        if (forzarCpu) listOf(Delegate.CPU) else listOf(Delegate.GPU, Delegate.CPU)

    init {
        holisticLandmarker = if (forzadoSeparado) null else crearHolistic(context)
        if (holisticLandmarker == null) crearSeparados(context)
    }

    private fun crearHolistic(context: Context): HolisticLandmarker? {
        for (delegate in delegados) {
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
                    .setErrorListener { e ->
                        holisticVuelo.liberar()
                        onError("holistic: ${e.message}")
                    }
                    .build()
                val creado = HolisticLandmarker.createFromOptions(context, options)
                gpuOk = delegate == Delegate.GPU
                return creado
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
        // GPU primero; si el delegado no carga (docs/14 H7), CPU. gpuOk
        // queda en true solo si los dos modelos corren en GPU.
        var enGpu = true
        fun <T> crear(nombre: String, construir: (Delegate) -> T): T? {
            for (delegate in delegados) {
                try {
                    return construir(delegate).also { if (delegate == Delegate.CPU) enGpu = false }
                } catch (e: Exception) {
                    erroresCreacion += mapOf(
                        "stage" to "capture",
                        "code" to "${nombre}_create_failed",
                        "delegate" to delegate.name,
                    )
                }
            }
            return null
        }
        fun base(modelo: String, delegate: Delegate) = BaseOptions.builder()
            .setModelAssetPath(modelo)
            .setDelegate(delegate)
            .build()

        handLandmarker = crear("hand") { delegate ->
            HandLandmarker.createFromOptions(context,
                HandLandmarker.HandLandmarkerOptions.builder()
                    .setBaseOptions(base("hand_landmarker.task", delegate))
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setNumHands(2)
                    .setMinHandDetectionConfidence(0.3f)
                    .setMinTrackingConfidence(0.3f)
                    .setMinHandPresenceConfidence(0.3f)
                    .setResultListener { result, _ -> onManos(result) }
                    .setErrorListener { e ->
                        manosVuelo.liberar()
                        onError("manos: ${e.message}")
                    }
                    .build())
        }
        poseLandmarker = crear("pose") { delegate ->
            PoseLandmarker.createFromOptions(context,
                PoseLandmarker.PoseLandmarkerOptions.builder()
                    .setBaseOptions(base("pose_landmarker_lite.task", delegate))
                    .setRunningMode(RunningMode.LIVE_STREAM)
                    .setNumPoses(1)
                    .setMinPoseDetectionConfidence(0.3f)
                    .setMinTrackingConfidence(0.3f)
                    .setMinPosePresenceConfidence(0.3f)
                    .setResultListener { result, _ -> onPose(result) }
                    .setErrorListener { e ->
                        poseVuelo.liberar()
                        onError("pose: ${e.message}")
                    }
                    .build())
        }
        gpuOk = enGpu && handLandmarker != null && poseLandmarker != null
    }

    fun holisticOcupado(): Boolean = holisticVuelo.ocupado(System.nanoTime())

    /** [timestampMs] estrictamente creciente. False si ya hay un frame en vuelo. */
    fun analizarHolistic(bitmap: Bitmap, timestampMs: Long): Boolean {
        val tarea = holisticLandmarker ?: return false
        return detectar(holisticVuelo) {
            val imagen = BitmapImageBuilder(bitmap).build()
            tarea.detectAsync(imagen, timestampMs)
        }
    }

    fun manosOcupadas(): Boolean = manosVuelo.ocupado(System.nanoTime())

    fun poseOcupada(): Boolean = poseVuelo.ocupado(System.nanoTime())

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay manos en vuelo. */
    fun analizarManos(bitmap: Bitmap, timestampMs: Long): Boolean {
        // El modelo se revisa ANTES de tomar la compuerta: sin modelo no hay
        // resultado que la libere y quedaria tomada hasta el timeout.
        val tarea = handLandmarker ?: return false
        return detectar(manosVuelo) {
            val imagen = BitmapImageBuilder(bitmap).build()
            tarea.detectAsync(imagen, timestampMs)
        }
    }

    /** [timestampMs] estrictamente creciente. Devuelve false si ya hay pose en vuelo. */
    fun analizarPose(bitmap: Bitmap, timestampMs: Long): Boolean {
        val tarea = poseLandmarker ?: return false
        return detectar(poseVuelo) {
            val imagen = BitmapImageBuilder(bitmap).build()
            tarea.detectAsync(imagen, timestampMs)
        }
    }

    /**
     * Toma la compuerta y envia. Si detectAsync lanza (modelo ya cerrado,
     * timestamp no creciente) la libera y relanza: no habra resultado que lo
     * haga, y el plugin ya reporta la excepcion.
     */
    private fun detectar(vuelo: VueloInferencia, enviar: () -> Unit): Boolean {
        if (!vuelo.intentarIniciar(System.nanoTime())) return false
        try {
            enviar()
        } catch (e: Exception) {
            vuelo.liberar()
            throw e
        }
        return true
    }

    private fun crearFrame(
        timestampMs: Long,
        pose: DoubleArray?,
        poseMundo: DoubleArray?,
        poseTimestampMs: Long?,
        candidatas: List<CapturaManos.Candidata>,
        r: CapturaManos.Resultado,
        extraErrors: List<Map<String, String>>,
        extras: Extras?,
    ): FrameResult {
        val skew = poseTimestampMs?.let { abs(it - timestampMs) }
        val errors = mutableListOf<Map<String, String>>()
        errors.addAll(extraErrors)
        // Incluye wrist_disagreement solo si persiste 3 frames en fusion
        // directa (antes se acusaba en cada frame: docs/14 N10).
        errors.addAll(r.errors)
        if (skew != null && skew > 50) {
            errors += mapOf("stage" to "fusion", "code" to "source_skew")
        }
        val tracking = r.tracking
        val association = mapOf(
            "left_state" to tracking.left.state,
            "right_state" to tracking.right.state,
            "left_cost" to tracking.costs["left"],
            "right_cost" to tracking.costs["right"],
            "left_surface" to tracking.left.surface,
            "right_surface" to tracking.right.surface,
            // Como webCameraState.handAssignmentMode: sin pose, pose_pending.
            "hand_assignment_mode" to when (r.assignment.mode) {
                "pose_arm_chain", "ambiguous" -> r.assignment.mode
                else -> "pose_pending"
            },
            "contact" to tracking.contact.active,
            "contact_wrist_distance" to tracking.contact.wristDistanceShoulders,
        )
        val handsIn = mapOf(
            "candidates" to candidatas.map {
                mapOf("lm" to it.puntos, "label" to it.etiqueta, "conf" to it.confianza)
            },
            "accepted" to r.gate.accepted,
            "unanchored" to r.gate.unanchored,
            "rejected" to r.gate.rejected.map { (index, code) -> listOf(index, code) },
            "passed" to r.passed,
            "assignment" to mapOf("mode" to r.assignment.mode, "sides" to r.assignment.sideByIndex),
            "usable" to r.usable,
        )
        fun vista(v: HandTrackCoordinator.TrackView) = mapOf(
            "state" to v.state,
            "surface" to v.surface,
            "surface_changes" to v.surfaceChanges,
            "recovery_frames" to v.recoveryFrames,
            "rest_blend" to v.restBlend,
        )
        return FrameResult(
            timestampMs,
            pose,
            poseMundo,
            // Evidencia cruda para reconocimiento aunque el seguimiento la
            // retenga (docs/14 N1); el avatar usa render.
            r.left,
            r.right,
            r.renderLeft,
            r.renderRight,
            poseTimestampMs,
            timestampMs,
            skew,
            association,
            errors,
            face = extras?.face,
            leftWorld = extras?.leftWorld,
            rightWorld = extras?.rightWorld,
            captureMode = if (holisticActivo) "holistic" else "separado",
            inferMs = ultimaInferenciaMs,
            handsIn = handsIn,
            track = mapOf("left" to vista(tracking.left), "right" to vista(tracking.right)),
            poseRan = poseTimestampMs == timestampMs,
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
        val inferMs = holisticVuelo.terminar(System.nanoTime())
        ultimaInferenciaMs = inferMs
        onInferencia(inferMs)
        val t = result.timestampMs()
        val poseLm = result.poseLandmarks()
        val pose = if (poseLm.size >= 33) normalizados(poseLm, true) else null
        val mundoLm = result.poseWorldLandmarks()
        val mundo = if (mundoLm.size >= 33) metricos(mundoLm) else null
        val caraLm = result.faceLandmarks()
        val cara = if (conCara && caraLm.size > 400) DoubleArray(FACE_KEYPOINTS.size * 3).also {
            FACE_KEYPOINTS.forEachIndexed { k, i ->
                it[k * 3] = caraLm[i].x().toDouble()
                it[k * 3 + 1] = caraLm[i].y().toDouble()
                it[k * 3 + 2] = caraLm[i].z().toDouble()
            }
        } else null

        val candidatas = mutableListOf<CapturaManos.Candidata>()
        val mundos = mutableListOf<DoubleArray?>()
        val errores = mutableListOf<Map<String, String>>()
        synchronized(erroresCreacion) {
            errores += erroresCreacion
            erroresCreacion.clear()
        }
        for ((etiqueta, imagen, metrico) in listOf(
            Triple("Left", result.leftHandLandmarks(), result.leftHandWorldLandmarks()),
            Triple("Right", result.rightHandLandmarks(), result.rightHandWorldLandmarks()),
        )) {
            if (imagen.isEmpty()) continue
            // La etiqueta de Holistic es solo pista: el lado lo decide la
            // cadena del brazo. Manos incompletas o no finitas van igual a la
            // compuerta, que las rechaza con motivo (docs/14 N12). Holistic no
            // da score por mano: confianza 1.
            candidatas += CapturaManos.Candidata(normalizados(imagen, false), etiqueta, 1.0)
            mundos += if (metrico.size == 21) metricos(metrico) else null
        }

        synchronized(ultimoLock) {
            ultimaPose = pose
            ultimaPoseMundo = mundo
            ultimoTimestampPose = t
        }
        procesarManos(t, candidatas, errores) { r ->
            // Mundo de cada mano segun el lado que le dio la captura.
            fun mundoDe(mano: DoubleArray?): DoubleArray? {
                if (mano == null) return null
                return mundos.getOrNull(candidatas.indexOfFirst { it.puntos.contentEquals(mano) })
            }
            Extras(cara, mundoDe(r.left), mundoDe(r.right))
        }
    }

    private fun onPose(result: PoseLandmarkerResult) {
        poseVuelo.liberar()

        val t = result.timestampMs()
        val lm = result.landmarks().firstOrNull()
        val arr = if (lm == null || lm.size < 33) null else normalizados(lm.take(33), true)

        // Esqueleto metrico. Sin visibility: worldLandmarks no la trae, y de
        // todos modos el filtro por visibilidad se hace con `pose`.
        val wlm = result.worldLandmarks().firstOrNull()
        val arrMundo = if (wlm == null || wlm.size < 33) null else metricos(wlm.take(33))

        // Solo actualiza el cache: el frame sale con cada resultado de manos,
        // como en la web (antes un preview por pose marcaba OCCLUDED falsos:
        // docs/14 N5).
        synchronized(ultimoLock) {
            ultimaPose = arr
            ultimaPoseMundo = arrMundo
            ultimoTimestampPose = t
        }
    }

    private fun onManos(result: HandLandmarkerResult) {
        val inferMs = manosVuelo.terminar(System.nanoTime())
        ultimaInferenciaMs = inferMs
        onInferencia(inferMs)

        val t = result.timestampMs()
        val categorias = result.handednesses()
        // Todas las manos van a la compuerta (incompletas o no finitas se
        // rechazan alli con motivo). El score ordena duplicados y pesa la
        // asociacion; categoryName nunca decide el lado fisico.
        val candidatas = result.landmarks().mapIndexed { i, lm ->
            val categoria = categorias.getOrNull(i)?.firstOrNull()
            CapturaManos.Candidata(
                normalizados(lm, false),
                categoria?.categoryName(),
                categoria?.score()?.toDouble(),
            )
        }
        procesarManos(t, candidatas, emptyList())
    }

    /**
     * Captura de manos (CapturaManos, espejo de la web) -> frames. Comun a
     * Holistic y al camino separado. El frame lleva el instante de las manos
     * y la pose del cache si tiene <= 120 ms; sin pose vigente solo sale el
     * preview.
     */
    private fun procesarManos(
        t: Long,
        candidatas: List<CapturaManos.Candidata>,
        erroresEntrada: List<Map<String, String>>,
        extras: ((CapturaManos.Resultado) -> Extras)? = null,
    ) {
        var vigente = false
        val frame = synchronized(ultimoLock) {
            vigente = ultimoTimestampPose != Long.MIN_VALUE &&
                abs(t - ultimoTimestampPose) <= ventanaFusionMs
            val pose = if (vigente) ultimaPose else null
            val poseMundo = if (vigente) ultimaPoseMundo else null
            val poseT = if (vigente) ultimoTimestampPose else null
            val r = captura.process(candidatas, pose, t.toDouble(), (poseT ?: t).toDouble())
            crearFrame(t, pose, poseMundo, poseT, candidatas, r, erroresEntrada,
                extras?.invoke(r))
        }
        onResultado(frame, vigente)
    }

    fun cerrar() {
        handLandmarker?.close()
        poseLandmarker?.close()
        holisticLandmarker?.close()
        holisticVuelo.liberar()
        synchronized(ultimoLock) {
            ultimaPose = null
            ultimaPoseMundo = null
            ultimoTimestampPose = Long.MIN_VALUE
            captura.reset()
        }
        manosVuelo.liberar()
        poseVuelo.liberar()
    }
}
