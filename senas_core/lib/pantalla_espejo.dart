/// Modo espejo: la camara te sigue y el avatar copia tus movimientos en
/// vivo, sin grabar ni reconocer nada.
///
/// Sirve para dos cosas. La primera es demostrativa: es la forma mas directa
/// de ver que el pipeline completo funciona de punta a punta. La segunda es
/// de desarrollo, y es la razon por la que existe: calibrar el visor contra
/// plantillas grabadas es lento y a ciegas, porque si la sena no se ve bien
/// no se sabe si la culpa es del dato o del render. Aca moves la mano y ves
/// el resultado al instante, con la referencia delante.
///
/// El camino del dato es el mismo de siempre, solo que sin buffer:
///   camara nativa -> LandmarkFrame fusionado -> sign_norm (152 dims) -> avatar
library pantalla_espejo;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import 'avatar_bridge.dart';
import 'avatar_vista.dart';
import 'avatar_vivo.dart';
import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'modo_desarrollador.dart';
import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'sesion_automatica.dart';
import 'skeleton_painter.dart' show SkeletonPainter;

class PantallaEspejo extends StatefulWidget {
  final bool iniciarCalibracion;

  /// App producto (univoz). Los contadores, datos técnicos y el modo
  /// diagnóstico solo salen con el modo desarrollador (ModoDesarrollador).
  final bool modoProducto;

  const PantallaEspejo(
      {super.key,
      this.iniciarCalibracion = false,
      this.modoProducto = false,
      this.visorParaPruebas});

  /// Solo pruebas: visor sin WebView (AvatarBridge.sinVisor).
  final AvatarBridge? visorParaPruebas;

  @override
  State<PantallaEspejo> createState() => _PantallaEspejoState();
}

class _PantallaEspejoState extends State<PantallaEspejo> {
  final _ctrl = ControladorCaptura();
  late final AvatarBridge _bridge = widget.visorParaPruebas ?? AvatarBridge();
  final _almacen = AlmacenMuestras.instancia;

  StreamSubscription<LandmarkFrame>? _sub;

  /// Envio al WebView: ultimo frame gana, sin cola (avatar_vivo.dart).
  late final _alimentador = AlimentadorAvatar(
    enviar: _bridge.mostrarFrame,
    perfilMedidas: () => _almacen.ajustes.perfilCorporal?.measures,
  );

  bool _espejando = false;
  bool _mostrarCamara = true;
  String? _aviso;
  bool _avisoAhorroMostrado = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_alCambiar);
    _bridge.onPoseCapturada = _copiarPose;
    _bridge.onDiagnosticReport = _compartirDiagnostico;
    _bridge.onCalibrationChanged = _guardarCalibracion;
    _bridge.onPerf = (perf) => _ctrl.sesion?.evento('perf', perf);
    _bridge.onErrorVisor = (detalle) {
      final sesion = _ctrl.sesion;
      if (sesion != null) {
        sesion.evento('error_visor', {'detalle': detalle});
      } else {
        debugPrint('visor avatar: $detalle');
      }
    };
    _arrancar();
  }

  Future<void> _compartirDiagnostico(String json) async {
    final directory = await getTemporaryDirectory();
    final path = '${directory.path}/rig_diagnostic_'
        '${DateTime.now().millisecondsSinceEpoch}.json';
    final file = File(path);
    await file.writeAsString(json, flush: true);
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json')],
      text: 'Diagnóstico RigBody (solo landmarks, sin video)',
    );
  }

  Future<void> _guardarCalibracion(RigCalibration calibration) async {
    final ajustes = _almacen.ajustes.copiar()..rigCalibration = calibration;
    await _almacen.guardarAjustes(ajustes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Calibración de pulgares guardada.'),
    ));
  }

  /// Llega desde el boton "Copiar pose" del editor del visor. Se copia al
  /// portapapeles para poder pegarlo donde sea -- transcribir angulos a mano
  /// desde la pantalla del telefono no es realista.
  Future<void> _copiarPose(String texto) async {
    await Clipboard.setData(ClipboardData(text: texto));
    if (!mounted) return;
    final lineas = texto.split('\n').length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Pose copiada al portapapeles ($lineas líneas)'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// Numeros y panel de diagnostico del visor: solo con el modo desarrollador.
  /// El espejo en si (avatar, estado de cuerpo y manos, pausar) es del producto.
  bool get _diagnostico => ModoDesarrollador.activo;

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  Future<void> _arrancar() async {
    if (!_bridge.disponible) {
      if (mounted) {
        setState(() => _aviso = 'El modo espejo está disponible en Android.');
      }
      return;
    }
    try {
      await AlmacenMuestras.instancia.cargar();
      final permiso = await Permission.camera.request();
      if (!permiso.isGranted) {
        if (mounted) {
          setState(
              () => _aviso = 'Sin permiso de cámara no puedo hacer espejo.');
        }
        return;
      }
      await _ctrl.iniciar(frontal: _almacen.ajustes.camaraFrontal);
      if (!_ctrl.lista) return;
      if (!mounted) return;
      final sesionActiva = await activarSesionConConsentimiento(
          context, _ctrl, _almacen,
          pantalla: 'espejo');
      await _bridge.configurarSesion(sesionActiva);
      await _bridge.configurarRig(_almacen.ajustes.rigCalibration);
      // Esta pantalla es para verte a ti mismo: el avatar actua como reflejo.
      // Las pantallas de traduccion dejan la vista de interlocutor.
      await _bridge.configurarVista(espejo: true);
      await _bridge.configurarDiagnostico(_diagnostico &&
          (_almacen.ajustes.rigDiagnosticMode || widget.iniciarCalibracion));
      if (widget.iniciarCalibracion) {
        await _bridge.iniciarCalibracionPulgares();
      }
    } catch (_) {
      if (mounted) {
        setState(() => _aviso = 'No se pudo iniciar el modo espejo.');
      }
      return;
    }
    if (!mounted) return;
    _empezarEspejo();
  }

  void _empezarEspejo() {
    _sub?.cancel();
    // El preview sigue alimentando SkeletonPainter; RigBody usa frames
    // fusionados para no animar con pose y manos de timestamps distintos.
    _sub = _ctrl.camara.frames.listen(_alFrame, onError: _errorStream);
    _alimentador.iniciar();
    setState(() => _espejando = true);
  }

  /// Error del stream nativo: el controlador lo clasifica, lo registra y, si
  /// es grave, deja el error visible; aqui solo se evita que llegue sin manejar.
  void _errorStream(Object error, StackTrace _) =>
      debugPrint('stream de landmarks: $error');

  void _pararEspejo() {
    _sub?.cancel();
    _sub = null;
    _alimentador.detener();
    setState(() => _espejando = false);
  }

  void _alFrame(LandmarkFrame f) {
    if (!_espejando) return;
    if (widget.modoProducto && !_avisoAhorroMostrado && f.tier == 'bajo') {
      _avisoAhorroMostrado = true;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Modo ahorro: el avatar se mueve más simple en este teléfono')));
    }
    _alimentador.alFrame(f);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _alimentador.detener();
    _ctrl.removeListener(_alCambiar);
    _ctrl.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Espejo'),
        actions: [
          IconButton(
            icon: Icon(_mostrarCamara
                ? Icons.videocam_outlined
                : Icons.videocam_off_outlined),
            tooltip: _mostrarCamara ? 'Ocultar cámara' : 'Mostrar cámara',
            onPressed: () => setState(() => _mostrarCamara = !_mostrarCamara),
          ),
        ],
      ),
      // El avatar y el preview van APILADOS EN COLUMNA, no superpuestos.
      // En Android el WebView es una platform view que dibuja el sistema, no
      // Flutter, y un Texture (el preview de la camara) puesto encima dentro
      // de un Stack queda tapado por la superficie del WebView. Separandolos
      // en filas el problema no existe.
      body: Column(
        children: [
          if (_aviso != null || _ctrl.error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.tertiary,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                  _aviso ??
                      (ModoDesarrollador.activo
                          ? 'La cámara no arrancó: ${_ctrl.error}'
                          : 'La cámara no arrancó. Cierra esta pantalla y '
                              'vuelve a intentarlo.'),
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onTertiary,
                      fontSize: 13)),
            ),
          Expanded(
            child: _bridge.disponible
                ? VistaAvatar(bridge: _bridge)
                : const _EspejoNoDisponible(),
          ),
          _barra(),
        ],
      ),
    );
  }

  Widget _preview() {
    final camara = _ctrl.iniciada;
    if (camara == null) {
      return AspectRatio(
        aspectRatio: 3 / 4,
        child: ColoredBox(
          color: Theme.of(context)
              .colorScheme
              .onInverseSurface
              .withValues(alpha: 0.2),
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: AspectRatio(
        aspectRatio: camara.relacionAspecto,
        child: Stack(
          children: [
            Positioned.fill(
              child: Texture(textureId: camara.textureId),
            ),
            ValueListenableBuilder<LandmarkFrame?>(
              valueListenable: _ctrl.frame,
              builder: (_, frame, __) => CustomPaint(
                painter: SkeletonPainter(frame: frame),
                size: Size.infinite,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _barra() {
    final colores = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        color: colores.inverseSurface,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_mostrarCamara) SizedBox(width: 96, child: _preview()),
            if (_mostrarCamara) const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<LandmarkFrame?>(
                    valueListenable: _ctrl.frame,
                    builder: (_, frame, __) => _estado(frame),
                  ),
                  const SizedBox(height: 6),
                  if (_diagnostico)
                    Text('${_alimentador.framesEnviados} frames enviados',
                        style: TextStyle(
                            color:
                                colores.onInverseSurface.withValues(alpha: 0.5),
                            fontSize: 11)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _ctrl.lista
                          ? (_espejando ? _pararEspejo : _empezarEspejo)
                          : null,
                      icon: Icon(_espejando ? Icons.pause : Icons.play_arrow),
                      label: Text(_espejando ? 'Pausar' : 'Reanudar'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mismo criterio que el chip de pantalla_captura: si el cuerpo no se ve,
  /// normalize() devuelve null y el avatar no se mueve por mas que las manos
  /// esten perfectas. Conviene que eso sea visible de un vistazo.
  Widget _estado(LandmarkFrame? frame) {
    final colores = Theme.of(context).colorScheme;
    Widget punto(String texto, bool ok) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Text(
            '${ok ? "✓" : "✗"} $texto',
            style: TextStyle(
              fontSize: 12,
              color: ok
                  ? colores.inversePrimary
                  : colores.onInverseSurface.withValues(alpha: 0.6),
            ),
          ),
        );
    final modo = frame?.association['hand_assignment_mode'] ?? 'pose_pending';
    return Wrap(spacing: 4, runSpacing: 2, children: [
      punto('Cuerpo', frame?.pose != null),
      punto('Izq', frame?.left != null),
      punto('Der', frame?.right != null),
      if (_diagnostico)
        Text(
          'Lados: $modo',
          style: TextStyle(
              color: colores.onInverseSurface.withValues(alpha: 0.6),
              fontSize: 11),
        ),
    ]);
  }
}

class _EspejoNoDisponible extends StatelessWidget {
  const _EspejoNoDisponible();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.inverseSurface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'El modo espejo está disponible en Android',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onInverseSurface,
                  fontSize: 18),
            ),
          ),
        ),
      );
}
