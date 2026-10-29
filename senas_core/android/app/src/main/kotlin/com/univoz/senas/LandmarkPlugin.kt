package com.univoz.senas
import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExtendableBuilder
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.Executors
/**
 * Puente entre CameraX + MediaPipe y Flutter.
 *
 * Por el canal viajan SOLO landmarks, nunca frames. Un frame de 720p son
 * megabytes por segundo cruzando el puente; los landmarks son ~2 KB. El
 * preview se muestra con una textura nativa, que Flutter pinta sin copiar
 * nada.
 */
class LandmarkPlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry,
    private val lifecycleOwner: LifecycleOwner,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    companion object {
        const val CANAL_METODOS = "univoz/camara"

        // Un solo evento por resultado. Lleva `fusionado` (pose y manos
        // dentro de una ventana compatible de 120 ms): Dart reparte a su
        // stream de UI (todos) y al de guardado/clasificador (fusionados).
        const val CANAL_EVENTOS = "univoz/landmarks"

        // Manos intentan cada captura; Pose corre cada ~66 ms. El reparto
        // conserva cadena anatomica fresca y deja CPU para dedos a 30 FPS.
        // Render/preview continua independiente a 60 FPS.
        private const val INTERVALO_MIN_POSE_NS = 66_000_000L

        /** Etiqueta de logcat del diagnostico de latencia (igual que en Dart). */
        private const val ETIQUETA_LATENCIA = "UnivozLat"

        /** Tope de la vista previa chica (A/B de desarrollador). 4:3 como el analisis. */
        private val PREVIEW_CHICA = Size(640, 480)
    }
    private val principal = Handler(Looper.getMainLooper())
    private val ejecutor = Executors.newSingleThreadExecutor()
    private var sink: EventChannel.EventSink? = null
    @Volatile private var engine: LandmarkEngine? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var cameraProvider: ProcessCameraProvider? = null
    @Volatile private var sessionToken = 0L
    private val probe = DeviceProbe(context)
    // Solo se toca en el hilo principal.
    @Volatile private var tier: DeviceTier? = null
    private var selectorActual: CameraSelector? = null
    private var analysisActual: ImageAnalysis? = null
    private var resolucionActual: Size? = null
    private var ultimoChequeoTermicoMs = 0L
    // Tope de FPS (hilo del ejecutor).
    @Volatile private var fpsMax = 30
    private var siguienteFrameMs = 0.0
    private var ultimoTimestamp = 0L
    private var ultimoPoseEnviadoNs = 0L

    // Diagnostico de latencia (modo desarrollador). null = apagado y entonces
    // procesar/emitir no miden nada. Lo crea enlazar() si Dart lo pidio.
    @Volatile private var medidor: MedidorNativo? = null
    private var diagnosticoPedido = false

    // Toggle de desarrollador: true = MediaPipe solo con CPU. Aplica a los
    // motores que se creen desde el proximo inicio de camara.
    @Volatile private var forzarCpu = false

    // Toggles de desarrollador (diagnostico_latencia.dart), se leen al
    // iniciar la camara. Por defecto: lo que se cree mejor para latencia.
    // fps: "auto" (CameraX/HAL), "30" (fijo) o "max" (fijo mas alto <= 60).
    private var fpsModo = "max"
    private var previewChica = true
    @Volatile private var forzarSeparado = false
    private var rangoFpsActual: Pair<Int, Int>? = null

    private val reportero = object : Runnable {
        override fun run() {
            val m = medidor ?: return
            val linea = m.cerrarSiToca(
                SystemClock.elapsedRealtime(),
                tier?.nivel?.wire,
                engine?.delegadoNombre ?: "-",
                if (engine?.holisticActivo == true) "holistic" else "separado",
            )
            if (linea != null) Log.i(ETIQUETA_LATENCIA, "nat $linea")
            principal.postDelayed(this, 1000)
        }
    }

    // Cache de la matriz de rotacion: los grados no cambian frame a frame.
    private var gradosCacheados: Int? = null
    private var matrizCacheada: Matrix? = null

    fun registrar() {
        MethodChannel(messenger, CANAL_METODOS).setMethodCallHandler(this)
        EventChannel(messenger, CANAL_EVENTOS).setStreamHandler(this)
    }
    override fun onMethodCall(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "iniciar" -> {
                val frontal = call.argument<Boolean>("frontal") ?: true
                val session = call.argument<Number>("session")?.toLong()
                    ?: ++sessionToken
                // Solo modo desarrollador (diagnostico_latencia.dart); sin
                // estos argumentos todo queda como siempre.
                diagnosticoPedido = call.argument<Boolean>("diagnostico") ?: false
                forzarCpu = call.argument<String>("delegado") == "cpu"
                fpsModo = call.argument<String>("fps") ?: "max"
                previewChica = (call.argument<String>("preview") ?: "chica") == "chica"
                forzarSeparado = call.argument<String>("modelo") == "separado"
                iniciar(frontal, session, result)
            }
            "detener" -> {
                val session = call.argument<Number>("session")?.toLong()
                detener(session)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }
    override fun onCancel(arguments: Any?) {
        sink = null
    }
    @SuppressLint("UnsafeOptInUsageError")
    private fun iniciar(
        frontal: Boolean,
        requestedSession: Long,
        result: MethodChannel.Result,
    ) {
        sessionToken = maxOf(sessionToken, requestedSession)
        limpiarRecursos()
        val futuro = ProcessCameraProvider.getInstance(context)
        futuro.addListener({
            val provider = try {
                futuro.get()
            } catch (e: Exception) {
                result.error("camera_start_failed", null, null)
                return@addListener
            }
            if (requestedSession != sessionToken) {
                result.error("camera_start_cancelled", null, null)
                return@addListener
            }
            // El motor (modelos + delegado GPU, ~1 s) se crea en el ejecutor:
            // en el hilo principal congelaba la UI al abrir la camara.
            // aplicarNivel ya crea motores en este mismo hilo.
            try {
                ejecutor.execute {
                    // Una sesion cancelada mientras esperaba en la cola no
                    // construye motor: ~1 s de modelos y GPU para tirarlo, y
                    // dos motores a la vez en la GPU de un equipo bajo.
                    if (requestedSession != sessionToken) {
                        principal.post {
                            result.error("camera_start_cancelled", null, null)
                        }
                        return@execute
                    }
                    val motor = try {
                        crearMotor(forzarSeparado)
                    } catch (e: Throwable) {
                        // ExceptionInInitializerError/UnsatisfiedLinkError de
                        // MediaPipe no son Exception: sin esto cerraban la app
                        // (release con R8 sin las clases de Flogger, 2026-10-21).
                        principal.post {
                            result.error("mediapipe_init", e.toString(), null)
                        }
                        return@execute
                    }
                    principal.post {
                        enlazar(provider, motor, frontal, requestedSession, result)
                    }
                }
            } catch (e: Exception) {
                // Ejecutor ya cerrado (plugin destruido).
                result.error("camera_start_cancelled", null, null)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Segunda mitad de [iniciar], en el hilo principal con el motor listo. */
    @SuppressLint("UnsafeOptInUsageError")
    private fun enlazar(
        provider: ProcessCameraProvider,
        motor: LandmarkEngine,
        frontal: Boolean,
        requestedSession: Long,
        result: MethodChannel.Result,
    ) {
        if (requestedSession != sessionToken) {
            motor.cerrar()
            result.error("camera_start_cancelled", null, null)
            return
        }
        // Dos inicios con el mismo token: el segundo no pisa sin cerrar el
        // motor y la textura del primero.
        if (engine != null || entry != null) limpiarRecursos()
        // Desde aqui limpiarRecursos() cierra el motor si algo falla.
        engine = motor
        try {
            cameraProvider = provider
            provider.unbindAll()
            val texEntry = textureRegistry.createSurfaceTexture()
            entry = texEntry
            val surfaceTexture = texEntry.surfaceTexture()
            val rango = DeviceTier.rangoFps(fpsModo, rangosFpsDisponibles(frontal))
            rangoFpsActual = rango
            val previewBuilder = Preview.Builder()
            if (previewChica) previewBuilder.setResolutionSelector(seleccionTamano(PREVIEW_CHICA))
            fijarFps(previewBuilder, rango)
            val preview = previewBuilder.build()
            preview.setSurfaceProvider { request ->
                surfaceTexture.setDefaultBufferSize(
                    request.resolution.width, request.resolution.height
                )
                val surface = Surface(surfaceTexture)
                request.provideSurface(surface, ejecutor) { surface.release() }
            }
            // Cada sesion parte del techo del hardware: una bajada por
            // inferencia o calor no se guarda (el S22+ quedo atascado en
            // bajo + separado por el calentamiento de la GPU, 2026-10-19).
            // Con CPU forzada el techo sigue siendo el del hardware (gpuOk seria
            // falso a proposito y bajaria a "bajo", cambiando el tier a probar).
            val techo = DeviceTier.nivelInicial(probe.ramMb(), motor.gpuOk || motor.forzarCpu)
            val nivelTier = DeviceTier(techo)
            val cfg = nivelTier.config
            motor.conCara = cfg.cara
            fpsMax = cfg.fpsMax
            siguienteFrameMs = 0.0
            tier = nivelTier
            val resolucion = Size(cfg.analisisAncho, cfg.analisisAlto)
            val analysis = construirAnalisis(resolucion)
            analysisActual = analysis
            resolucionActual = resolucion
            val selector = if (frontal) CameraSelector.DEFAULT_FRONT_CAMERA
            else CameraSelector.DEFAULT_BACK_CAMERA
            selectorActual = selector
            if (requestedSession != sessionToken) {
                limpiarRecursos()
                result.error("camera_start_cancelled", null, null)
                return
            }
            provider.bindToLifecycle(lifecycleOwner, selector, preview, analysis)
            if (requestedSession != sessionToken) {
                limpiarRecursos()
                result.error("camera_start_cancelled", null, null)
                return
            }
            registrarCamara(frontal, rango, preview, analysis)
            if (diagnosticoPedido) iniciarMedicion(frontal)

            val info = preview.resolutionInfo
            val res = info?.resolution
            val giro = info?.rotationDegrees ?: 0
            val volteado = giro == 90 || giro == 270
            val ancho = if (res == null) 0 else if (volteado) res.height else res.width
            val alto = if (res == null) 0 else if (volteado) res.width else res.height

            result.success(
                mapOf(
                    "textureId" to texEntry.id(),
                    // Preview sin espejo: el eje horizontal debe coincidir
                    // con landmarks y asociación anatómica.
                    "espejo" to false,
                    "ancho" to ancho,
                    "alto" to alto,
                )
            )
        } catch (e: SecurityException) {
            limpiarRecursos()
            result.error("camera_permission", null, null)
        } catch (e: IllegalArgumentException) {
            limpiarRecursos()
            result.error("camera_unavailable", null, null)
        } catch (e: IllegalStateException) {
            limpiarRecursos()
            result.error("camera_busy", null, null)
        } catch (e: Exception) {
            limpiarRecursos()
            result.error("camera_start_failed", null, null)
        }
    }

    private fun crearMotor(forzarSeparado: Boolean) = LandmarkEngine(
        context,
        onResultado = { f, fusionado -> emitir(f, fusionado) },
        onError = { msg -> principal.post { sink?.error("mediapipe", msg, null) } },
        onInferencia = { ms ->
            medidor?.inferencia?.agregar(ms)
            principal.post { alInferir(ms) }
        },
        forzadoSeparado = forzarSeparado,
        forzarCpu = forzarCpu,
    )

    /**
     * Enciende el diagnostico de latencia: lee la fuente de reloj de la camara
     * (la edad de captura solo es valida si es REALTIME, igual que
     * elapsedRealtimeNanos), la deja en logcat una vez y arranca el resumen
     * por segundo. Hilo principal.
     */
    private fun iniciarMedicion(frontal: Boolean) {
        val origen = caracteristicas(frontal)
            ?.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
        val fuente = when (origen) {
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME -> "REALTIME"
            CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN -> "UNKNOWN"
            else -> "?"
        }
        val nota = if (fuente == "REALTIME") "(edades de captura validas)"
        else "(las edades de captura NO son fiables)"
        Log.i(ETIQUETA_LATENCIA, "nat camera_ts_source=$fuente $nota")
        medidor = MedidorNativo(fuente)
        principal.removeCallbacks(reportero)
        principal.postDelayed(reportero, 1000)
    }

    /** Caracteristicas Camera2 de la camara del lado pedido; null si no se pueden leer. */
    private fun caracteristicas(frontal: Boolean): CameraCharacteristics? = try {
        val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val lente = if (frontal) CameraCharacteristics.LENS_FACING_FRONT
        else CameraCharacteristics.LENS_FACING_BACK
        cm.cameraIdList.map { cm.getCameraCharacteristics(it) }
            .firstOrNull { it.get(CameraCharacteristics.LENS_FACING) == lente }
    } catch (e: Exception) {
        null // sin esto solo se pierde la optimizacion/advertencia
    }

    private fun rangosFpsDisponibles(frontal: Boolean): List<Pair<Int, Int>> =
        caracteristicas(frontal)
            ?.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?.map { it.lower to it.upper } ?: emptyList()

    private fun seleccionTamano(tam: Size) = ResolutionSelector.Builder()
        .setResolutionStrategy(
            ResolutionStrategy(tam, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER)
        )
        .build()

    /**
     * Rango AE fijo para el caso de uso (null = lo que decida CameraX). Con
     * rango variable AE puede alargar la exposicion; fijo y alto acorta
     * exposicion, lectura y cola del HAL (DeviceTier.rangoFps).
     */
    @SuppressLint("UnsafeOptInUsageError")
    private fun fijarFps(b: ExtendableBuilder<*>, rango: Pair<Int, Int>?) {
        if (rango == null) return
        Camera2Interop.Extender(b).setCaptureRequestOption(
            CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, Range(rango.first, rango.second)
        )
    }

    /** Una vez por inicio de camara: lo que de verdad se pidio y lo que CameraX concedio. */
    private fun registrarCamara(
        frontal: Boolean,
        rango: Pair<Int, Int>?,
        preview: Preview,
        analysis: ImageAnalysis,
    ) {
        fun tam(r: Size?) = r?.let { "${it.width}x${it.height}" } ?: "?"
        Log.i(
            ETIQUETA_LATENCIA,
            "nat camera fps_modo=$fpsModo rango=${rango ?: "auto"} " +
                "disponibles=${rangosFpsDisponibles(frontal)} " +
                "preview=${tam(preview.resolutionInfo?.resolution)} " +
                "(pedido=${if (previewChica) tam(PREVIEW_CHICA) else "auto"}) " +
                "analisis=${tam(analysis.resolutionInfo?.resolution)} " +
                "modelo=${if (forzarSeparado) "separado(forzado)" else "holistic"}"
        )
    }

    private fun construirAnalisis(resolucion: Size): ImageAnalysis {
        val b = ImageAnalysis.Builder()
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setResolutionSelector(seleccionTamano(resolucion))
        fijarFps(b, rangoFpsActual)
        return b.build().also { it.setAnalyzer(ejecutor) { proxy -> procesar(proxy) } }
    }

    // Hilo principal: DeviceTier no es thread-safe.
    private fun alInferir(ms: Double) {
        val t = tier ?: return
        val ahora = SystemClock.elapsedRealtime()
        val antes = t.nivel
        var cambio = t.registrarInferencia(ms, ahora)
        if (ahora - ultimoChequeoTermicoMs >= 1000) {
            ultimoChequeoTermicoMs = ahora
            cambio = t.registrarTermico(probe.termico(), ahora) || cambio
        }
        if (!cambio) return
        Log.i(
            ETIQUETA_LATENCIA,
            "nat tier $antes->${t.nivel} separado=${t.separado} causa=${t.causaCambio}"
        )
        aplicarNivel(t)
    }

    private fun aplicarNivel(t: DeviceTier) {
        val cfg = t.config
        val sesion = sessionToken
        val separado = t.separado || forzarSeparado
        fpsMax = cfg.fpsMax
        engine?.conCara = cfg.cara
        // Cambiar de modelo en el hilo del ejecutor: procesar() corre ahi,
        // asi nunca usa un motor cerrado.
        ejecutor.execute {
            val motor = engine
            if (sesion != sessionToken || motor == null ||
                motor.forzadoSeparado == separado) return@execute
            motor.cerrar()
            engine = null
            val nuevo = try {
                crearMotor(separado).also { it.conCara = cfg.cara }
            } catch (e: Throwable) {
                // Sin motor no hay frames: el vigilante de Dart muestra el error.
                principal.post { sink?.error("mediapipe", e.toString(), null) }
                return@execute
            }
            // Se asigna en el hilo principal, donde detener/enlazar cambian la
            // sesion: si se detuvo mientras se creaba (~1 s) o ya hay otro
            // motor, este se cierra en vez de quedar huerfano.
            principal.post {
                if (sesion == sessionToken && engine == null) engine = nuevo
                else nuevo.cerrar()
            }
        }
        val resolucion = Size(cfg.analisisAncho, cfg.analisisAlto)
        if (resolucion != resolucionActual) reenlazarAnalisis(resolucion)
    }

    private fun reenlazarAnalisis(resolucion: Size) {
        val provider = cameraProvider ?: return
        val selector = selectorActual ?: return
        val anterior = analysisActual ?: return
        val nueva = construirAnalisis(resolucion)
        try {
            provider.unbind(anterior)
            provider.bindToLifecycle(lifecycleOwner, selector, nueva)
            analysisActual = nueva
            resolucionActual = resolucion
        } catch (e: Exception) {
            // Si el tamano nuevo no enlaza, seguir con el anterior.
            try {
                provider.bindToLifecycle(lifecycleOwner, selector, anterior)
            } catch (_: Exception) {
            }
            sink?.error("analisis", "tier_rebind_failed", null)
        }
    }
    private fun procesar(proxy: ImageProxy) {
        try {
            val motor = engine
            val med = medidor
            if (med != null) {
                med.frameEntrada()
                med.edadEntrada.agregar(edadCapturaMs(proxy))
            }
            if (motor?.holisticActivo == true) {
                // Holistic: un solo modelo para cuerpo, manos y cara; pose y
                // manos salen del mismo frame (sin desfase entre fuentes).
                if (motor.holisticOcupado()) {
                    med?.descarteOcupado()
                    return
                }
                val siguiente = DeviceTier.admitirFrame(
                    siguienteFrameMs, proxy.imageInfo.timestamp / 1_000_000, fpsMax)
                if (siguiente == null) {
                    med?.descarteFps()
                    return
                }
                siguienteFrameMs = siguiente
                val bitmap = prepararBitmapMedido(proxy, med)
                var t = proxy.imageInfo.timestamp / 1_000_000
                if (t <= ultimoTimestamp) t = ultimoTimestamp + 1
                ultimoTimestamp = t
                med?.edadInferencia?.agregar(edadCapturaMs(proxy))
                if (!motor.analizarHolistic(bitmap, t)) med?.descarteOcupado()
                return
            }
            val ahoraNs = proxy.imageInfo.timestamp
            val manosLibres = engine?.manosOcupadas() == false
            val tocaPose = engine?.poseOcupada() == false &&
                (ahoraNs - ultimoPoseEnviadoNs >= INTERVALO_MIN_POSE_NS)

            // Ninguno de los dos modelos quiere este frame: no gastes CPU
            // convirtiendolo a bitmap.
            if (!manosLibres && !tocaPose) {
                med?.descarteSinPeticion()
                return
            }
            val siguiente = DeviceTier.admitirFrame(
                siguienteFrameMs, proxy.imageInfo.timestamp / 1_000_000, fpsMax)
            if (siguiente == null) {
                med?.descarteFps()
                return
            }
            siguienteFrameMs = siguiente

            val bitmap = prepararBitmapMedido(proxy, med)
            var t = proxy.imageInfo.timestamp / 1_000_000
            if (t <= ultimoTimestamp) t = ultimoTimestamp + 1
            ultimoTimestamp = t
            med?.edadInferencia?.agregar(edadCapturaMs(proxy))

            if (manosLibres) engine?.analizarManos(bitmap, t)
            if (tocaPose) {
                engine?.analizarPose(bitmap, t)
                ultimoPoseEnviadoNs = ahoraNs
            }
        } catch (e: Exception) {
            principal.post { sink?.error("analisis", e.message, null) }
        } finally {
            proxy.close()
        }
    }
    /**
     * Edad del frame desde que la camara lo capturo, ms. Valida solo si el
     * reloj de la camara es REALTIME (se avisa al encender el diagnostico).
     */
    private fun edadCapturaMs(proxy: ImageProxy): Double =
        (SystemClock.elapsedRealtimeNanos() - proxy.imageInfo.timestamp) / 1e6

    /** prepararBitmap, midiendo su duracion si el diagnostico esta encendido. */
    private fun prepararBitmapMedido(proxy: ImageProxy, med: MedidorNativo?): Bitmap {
        if (med == null) return prepararBitmap(proxy)
        val t0 = System.nanoTime()
        val r = prepararBitmap(proxy)
        med.preparar.agregar((System.nanoTime() - t0) / 1e6)
        return r
    }

    @Volatile private var imagenAncho = 0
    @Volatile private var imagenAlto = 0

    /**
     * Bitmap ya rotado para el modelo. Deja en imagenAncho/imagenAlto su
     * tamano, que es el de las coordenadas de los landmarks.
     */
    private fun prepararBitmap(proxy: ImageProxy): Bitmap {
        val crudo = proxy.toBitmap()
        val bitmap = rotar(crudo, proxy.imageInfo.rotationDegrees)
        // ponytail: el crudo (~0.7 MB a 360x480) era basura por frame a 30/s;
        // se recicla. Si la rotacion pasa a ser de CameraX
        // (setOutputImageRotationEnabled) desaparece tambien esta copia.
        if (bitmap !== crudo) crudo.recycle()
        imagenAncho = bitmap.width
        imagenAlto = bitmap.height
        return bitmap
    }

    private fun rotar(bitmap: Bitmap, grados: Int): Bitmap {
        if (grados == 0) return bitmap
        val m = if (gradosCacheados == grados) {
            matrizCacheada!!
        } else {
            Matrix().apply { postRotate(grados.toFloat()) }.also {
                matrizCacheada = it
                gradosCacheados = grados
            }
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, m, false)
    }
    /**
     * El mapa se arma en el hilo del modelo y al hilo principal (el unico
     * donde se puede llamar al sink) solo va la entrega.
     */
    private fun emitir(f: LandmarkEngine.FrameResult, fusionado: Boolean) {
        val payload = aMapa(f, fusionado)
        principal.post {
            // Diagnostico de latencia: edad de captura al entregar el frame
            // al canal (Dart la suma a su propia espera). Ausente con el
            // diagnostico apagado.
            medidor?.let { med ->
                val edad = SystemClock.elapsedRealtimeNanos() / 1e6 - f.timestampMs
                payload["cap_age_ms"] = edad
                med.edadEmision.agregar(edad)
                med.frameSalida()
            }
            sink?.success(payload)
        }
    }

    private fun aMapa(f: LandmarkEngine.FrameResult, fusionado: Boolean): HashMap<String, Any?> {
        val payload = HashMap<String, Any?>(24)
        payload["t"] = f.timestampMs
        payload["fusionado"] = fusionado
        payload["pose"] = f.pose
        // Esqueleto metrico en 3D: es el unico con el que se puede
        // reconstruir una postura (ver LandmarkEngine.FrameResult).
        payload["poseMundo"] = f.poseMundo
        payload["left"] = f.left
        payload["right"] = f.right
        payload["renderLeft"] = f.renderLeft
        payload["renderRight"] = f.renderRight
        payload["pose_t"] = f.poseTimestampMs
        payload["hands_t"] = f.handsTimestampMs
        payload["source_skew_ms"] = f.sourceSkewMs
        payload["association"] = f.association
        payload["errors"] = f.errors
        payload["capture_mode"] = f.captureMode
        // Esquema de sesion web: entrada de manos, seguimiento por lado y si
        // la pose corrio en este frame (sesion_captura.dart los registra).
        payload["hands_in"] = f.handsIn
        payload["track"] = f.track
        payload["pose_ran"] = f.poseRan
        // Tamano del bitmap ya rotado: los landmarks vienen normalizados por
        // ancho y alto, y el visor necesita la proporcion para la cabeza.
        if (imagenAncho > 0 && imagenAlto > 0) {
            payload["image_w"] = imagenAncho
            payload["image_h"] = imagenAlto
        }
        // Solo Holistic: puntos clave de cara (orden FACE_KEYPOINTS) y manos
        // en metros.
        payload["face"] = f.face
        payload["leftWorld"] = f.leftWorld
        payload["rightWorld"] = f.rightWorld
        // Nivel por dispositivo: el visor ajusta su render y lo registra en perf.
        payload["tier"] = tier?.nivel?.wire
        payload["infer_ms"] = f.inferMs
        payload["thermal"] = tier?.termicoActual
        return payload
    }
    private fun detener(requestedSession: Long? = null) {
        sessionToken = requestedSession?.let { maxOf(sessionToken, it) }
            ?: (sessionToken + 1)
        limpiarRecursos()
    }
    private fun limpiarRecursos() {
        principal.removeCallbacks(reportero)
        medidor = null
        cameraProvider?.unbindAll()
        cameraProvider = null
        engine?.cerrar()
        engine = null
        entry?.release()
        entry = null
        ultimoTimestamp = 0L
        ultimoPoseEnviadoNs = 0L
        tier = null
        analysisActual = null
        selectorActual = null
        resolucionActual = null
        siguienteFrameMs = 0.0
    }
    fun destruir() {
        detener()
        ejecutor.shutdown()
    }
}
