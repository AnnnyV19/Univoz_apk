/// Calibracion del reconocedor, sin recompilar.
///
/// Los umbrales por defecto (kMaxDistanceDefault / kMinMarginDefault, en
/// dtw.dart) se calibraron contra las plantillas reales del diccionario, pero
/// con pocas personas: conviene ajustarlos cuando grabe mas gente. Esta
/// pantalla es para hacerlo probando, que es la unica forma honesta de
/// calibrarlos.
library pantalla_ajustes;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'componentes_univoz.dart';
import 'diagnostico_latencia.dart';
import 'modo_desarrollador.dart';
import 'dtw.dart' show kMaxDistanceDefault, kMinMarginDefault;
import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'pantalla_espejo.dart';
import 'registro_errores.dart';
import 'rotacion_sesiones.dart';
import 'voz.dart';

class PantallaAjustes extends StatefulWidget {
  const PantallaAjustes({Key? key}) : super(key: key);

  @override
  State<PantallaAjustes> createState() => _PantallaAjustesState();
}

class _PantallaAjustesState extends State<PantallaAjustes> {
  final _almacen = AlmacenMuestras.instancia;
  late Ajustes _a;
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    await _almacen.cargar();
    if (!mounted) return;
    setState(() {
      _a = _almacen.ajustes.copiar();
      _listo = true;
    });
  }

  Future<void> _guardar() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text(
              'Ajustes guardados. Vuelve a entrar a Reconocer para aplicarlos.')),
    );
  }

  Future<Directory> _dirSesiones() async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/sesiones');

  Future<void> _compartirUltimaSesion() async {
    // Una sesion larga son varios archivos (`.part002`...): se comparten
    // todos juntos, no solo el ultimo (sin la cabecera de la sesion).
    final partes = await partesDeUltimaSesion(await _dirSesiones());
    if (partes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Todavía no hay sesiones.')));
      return;
    }
    await Share.shareXFiles(
      [for (final f in partes) XFile(f.path, mimeType: 'application/x-ndjson')],
      text: 'Sesión Univoz (solo puntos, sin video)',
    );
  }

  Future<void> _compartirErrores() async {
    final archivo = await RegistroErrores.instancia.archivoParaCompartir();
    if (archivo == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay errores registrados.')));
      return;
    }
    await Share.shareXFiles(
      [XFile(archivo.path, mimeType: 'application/x-ndjson')],
      text: 'Registro de errores de Univoz',
    );
  }

  /// Se guarda al momento (solo este ajuste): es una decision de privacidad,
  /// no un umbral que se prueba antes de confirmar.
  Future<void> _cambiarConsentimiento(bool v) async {
    await _almacen.guardarAjustes(_almacen.ajustes.copiar()
      ..consentimientoSesion = v
      ..consentimientoPreguntado = true);
    if (!mounted) return;
    setState(() {
      _a.consentimientoSesion = v;
      _a.consentimientoPreguntado = true;
    });
  }

  Future<void> _borrarMisDatos() async {
    final dir = await _dirSesiones();
    if (await dir.exists()) await dir.delete(recursive: true);
    _a = _almacen.ajustes.copiar()
      ..consentimientoSesion = false
      ..consentimientoPreguntado = false
      ..perfilCorporal = null;
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Datos de sesiones y perfil borrados.')));
  }

  Future<void> _calibrarPulgares() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const PantallaEspejo(iniciarCalibracion: true),
    ));
    if (!mounted) return;
    setState(() => _a = _almacen.ajustes.copiar());
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          TarjetaUnivoz(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EncabezadoSeccion(
                  icono: Icons.tune_rounded,
                  titulo: 'Umbrales de reconocimiento',
                  descripcion:
                      'Una seña se acepta solo si la distancia está POR DEBAJO del máximo '
                      'y el margen POR ENCIMA del mínimo. Si te reconoce cosas que no hiciste, '
                      'baja la distancia máxima o sube el margen. Si no te reconoce nada, al revés.',
                ),
                AjusteDeslizador(
                  etiqueta: 'Distancia máxima',
                  valor: _a.maxDistance,
                  min: 0.10,
                  max: 1.50,
                  divisiones: 28,
                  ayuda: 'más bajo = más estricto',
                  onChanged: (v) => setState(() => _a.maxDistance = v),
                ),
                AjusteDeslizador(
                  etiqueta: 'Margen mínimo',
                  valor: _a.minMargin,
                  min: 0.0,
                  max: 0.50,
                  divisiones: 25,
                  ayuda:
                      'cuánto tiene que ganarle a la segunda candidata; más alto = más estricto',
                  onChanged: (v) => setState(() => _a.minMargin = v),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: Text(
                      'Volver a los valores por defecto (${kMaxDistanceDefault.toStringAsFixed(2)} / ${kMinMarginDefault.toStringAsFixed(2)})',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () => setState(() {
                      _a.maxDistance = kMaxDistanceDefault;
                      _a.minMargin = kMinMarginDefault;
                    }),
                  ),
                ),
              ],
            ),
          ),
          TarjetaUnivoz(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EncabezadoSeccion(
                  icono: Icons.camera_alt_outlined,
                  titulo: 'Cámara',
                ),
                AjusteInterruptor(
                  titulo: 'Usar cámara frontal',
                  subtitulo:
                      'La trasera evita la ambigüedad del espejo, pero necesitas que alguien sostenga el teléfono.',
                  valor: _a.camaraFrontal,
                  onChanged: (v) => setState(() => _a.camaraFrontal = v),
                ),
              ],
            ),
          ),
          TarjetaUnivoz(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EncabezadoSeccion(
                  icono: Icons.volume_up_outlined,
                  titulo: 'Voz',
                ),
                AjusteInterruptor(
                  titulo: 'Decir el resultado en voz alta',
                  subtitulo:
                      'Apenas se reconoce una seña con confianza, el teléfono dice la palabra. '
                      'Apágalo para que quede solo en pantalla.',
                  valor: _a.hablarResultado,
                  onChanged: (v) => setState(() => _a.hablarResultado = v),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Probar voz ("Hola, gracias")'),
                  onPressed: () async {
                    final err =
                        await LectorVoz.instancia.decir('Hola, gracias');
                    if (!mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error de voz: $err')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          TarjetaUnivoz(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const EncabezadoSeccion(
                  icono: Icons.front_hand_outlined,
                  titulo: 'Diccionario',
                ),
                AjusteInterruptor(
                  titulo: 'Agregar versión espejada de cada plantilla',
                  subtitulo:
                      'Cubre a quien seña con la otra mano sin grabar de nuevo '
                      '(muestras, paquete y diccionario sincronizado). '
                      'Desactívalo solo si alguna seña usa izquierda/derecha como parte del significado.',
                  valor: _a.espejoAutomatico,
                  onChanged: (v) => setState(() => _a.espejoAutomatico = v),
                ),
              ],
            ),
          ),
          TarjetaUnivoz(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                EncabezadoSeccion(
                  icono: Icons.shield_outlined,
                  titulo: 'Sesiones y perfil corporal',
                  descripcion: _a.consentimientoSesion
                      ? 'Cada sesión de cámara se mide y se registra en este teléfono '
                          '(puntos, nunca video).'
                      : 'Sin consentimiento: no se registra ni se mide nada.',
                ),
                AjusteInterruptor(
                  titulo: 'Guardar sesiones para mejorar el reconocimiento',
                  valor: _a.consentimientoSesion,
                  onChanged: _cambiarConsentimiento,
                ),
                if (ModoDesarrollador.activo)
                  AccionFila(
                    icono: Icons.ios_share,
                    titulo: 'Compartir última sesión',
                    onTap: _compartirUltimaSesion,
                  ),
                if (ModoDesarrollador.activo)
                  AccionFila(
                    icono: Icons.bug_report_outlined,
                    titulo: 'Compartir registro de errores',
                    onTap: _compartirErrores,
                  ),
                AccionFila(
                  icono: Icons.delete_outline,
                  titulo: 'Borrar mis datos',
                  detalle: 'Consentimiento, perfil y sesiones guardadas',
                  peligro: true,
                  onTap: _borrarMisDatos,
                ),
              ],
            ),
          ),
          // Calibración del avatar: solo para quien desarrolla (modo
          // desarrollador, ver modo_desarrollador.dart).
          if (ModoDesarrollador.activo)
            TarjetaUnivoz(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const EncabezadoSeccion(
                    icono: Icons.accessibility_new_rounded,
                    titulo: 'RigBody / avatar 3D',
                    descripcion:
                        'Ajusta cómo el espacio 3D normalizado mueve el avatar. Estos '
                        'valores no cambian vectores ni entrenamiento; solo calibran el rig.',
                  ),
                  AjusteInterruptor(
                    titulo: 'Invertir profundidad Z',
                    subtitulo: 'Úsalo si el avatar mueve manos hacia atrás.',
                    valor: _a.rigCalibration.invertZ,
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(invertZ: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Escala del avatar',
                    valor: _a.rigCalibration.avatarScale,
                    min: 0.70,
                    max: 1.30,
                    divisiones: 60,
                    ayuda: 'ajusta tamaño visual, no datos IA',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(avatarScale: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Ganancia brazo izquierdo',
                    valor: _a.rigCalibration.leftArmGain,
                    min: 0.50,
                    max: 1.50,
                    divisiones: 50,
                    ayuda: 'respuesta del IK izquierdo',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(leftArmGain: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Ganancia brazo derecho',
                    valor: _a.rigCalibration.rightArmGain,
                    min: 0.50,
                    max: 1.50,
                    divisiones: 50,
                    ayuda: 'respuesta del IK derecho',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(rightArmGain: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Sensibilidad de dedos',
                    valor: _a.rigCalibration.fingerSensitivity,
                    min: 0.50,
                    max: 1.50,
                    divisiones: 50,
                    ayuda: 'amplitud de flexión de falanges',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(fingerSensitivity: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Límite mínimo de codo',
                    valor: _a.rigCalibration.ikMin,
                    min: 0.0,
                    max: 1.50,
                    divisiones: 30,
                    ayuda: 'evita soluciones IK demasiado cerradas',
                    onChanged: (v) => setState(() {
                      final max = _a.rigCalibration.ikMax < v
                          ? v
                          : _a.rigCalibration.ikMax;
                      _a.rigCalibration =
                          _a.rigCalibration.copyWith(ikMin: v, ikMax: max);
                    }),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Límite máximo de codo',
                    valor: _a.rigCalibration.ikMax,
                    min: _a.rigCalibration.ikMin,
                    max: 3.14,
                    divisiones: 62,
                    ayuda: 'evita soluciones IK imposibles',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(ikMax: v)),
                  ),
                  AjusteDeslizador(
                    etiqueta: 'Compensación de muñeca',
                    valor: _a.rigCalibration.wristCompensation,
                    min: -1.0,
                    max: 1.0,
                    divisiones: 40,
                    ayuda: 'corrección angular de palma',
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(wristCompensation: v)),
                  ),
                  AjusteInterruptor(
                    titulo: 'Restablecer mano si se pierde',
                    subtitulo:
                        'Tras un margen breve, devuelve dedos y muñeca a reposo; '
                        'evita dejar una mano congelada o deformada.',
                    valor: _a.rigCalibration.resetHandOnLoss,
                    onChanged: (v) => setState(() => _a.rigCalibration =
                        _a.rigCalibration.copyWith(resetHandOnLoss: v)),
                  ),
                  AjusteInterruptor(
                    titulo: 'Modo diagnóstico RigBody',
                    subtitulo:
                        'Muestra FPS, skew, tracks, contacto y errores. Apagado por defecto; '
                        'guarda hasta 300 frames sin video.',
                    valor: _a.rigDiagnosticMode,
                    onChanged: (v) => setState(() => _a.rigDiagnosticMode = v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.pan_tool_alt_outlined, size: 16),
                        label: const Text('Calibrar pulgares con cámara'),
                        onPressed: _calibrarPulgares,
                      ),
                      TextButton(
                        onPressed: () => setState(
                            () => _a.rigCalibration = const RigCalibration()),
                        child: const Text('Restablecer calibración RigBody'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (ModoDesarrollador.activo)
            TarjetaUnivoz(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const EncabezadoSeccion(
                    icono: Icons.speed_rounded,
                    titulo: 'Latencia del avatar (pruebas)',
                    descripcion:
                        'Solo en memoria: se pierde al cerrar la app. Con el modo '
                        'desarrollador activo, la app escribe un resumen por segundo en '
                        'logcat con la etiqueta UnivozLat.',
                  ),
                  _selector<SuavizadoAvatar>(
                    etiqueta: 'Suavizado del avatar',
                    ayuda:
                        'Normal es el de siempre. Apagado: sin suavizado, para ver '
                        'el retraso crudo.',
                    valores: SuavizadoAvatar.values,
                    notificador: DiagnosticoLatencia.suavizado,
                    texto: (v) => v.etiqueta,
                  ),
                  _selector<DelegadoMediaPipe>(
                    etiqueta: 'Delegado MediaPipe',
                    ayuda:
                        'GPU es el de siempre. Aplica la próxima vez que se abra '
                        'la cámara.',
                    valores: DelegadoMediaPipe.values,
                    notificador: DiagnosticoLatencia.delegado,
                    texto: (v) => v.etiqueta,
                  ),
                  _selector<ModeloMediaPipe>(
                    etiqueta: 'Modelo',
                    ayuda:
                        'Holistic es el del producto. Separado usa Pose lite + '
                        'Hand (sin cara): para comparar inferencia y FPS. Aplica '
                        'la próxima vez que se abra la cámara.',
                    valores: ModeloMediaPipe.values,
                    notificador: DiagnosticoLatencia.modelo,
                    texto: (v) => v.etiqueta,
                  ),
                  _selector<FpsCamara>(
                    etiqueta: 'FPS de la cámara',
                    ayuda:
                        'Máx fijo: el rango fijo más alto (hasta 60) para acortar '
                        'exposición y cola de la cámara. Auto: lo que decida '
                        'Android. Aplica al abrir la cámara.',
                    valores: FpsCamara.values,
                    notificador: DiagnosticoLatencia.fps,
                    texto: (v) => v.etiqueta,
                  ),
                  _selector<VistaPreviaCamara>(
                    etiqueta: 'Vista previa de la cámara',
                    ayuda:
                        'Chica limita la imagen de la cámara a 640×480 (menos '
                        'carga); Auto deja la que elija CameraX. Aplica al abrir '
                        'la cámara.',
                    valores: VistaPreviaCamara.values,
                    notificador: DiagnosticoLatencia.vistaPrevia,
                    texto: (v) => v.etiqueta,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _guardar,
              icon: const Icon(Icons.check_rounded, size: 20),
              label: const Text('Guardar ajustes'),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _selector<T>({
    required String etiqueta,
    required String ayuda,
    required List<T> valores,
    required ValueNotifier<T> notificador,
    required String Function(T) texto,
  }) {
    final colores = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(etiqueta),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(ayuda,
                style: TextStyle(fontSize: 13, color: colores.onSurfaceVariant)),
          ),
          ValueListenableBuilder<T>(
            valueListenable: notificador,
            builder: (_, actual, __) => SegmentedButton<T>(
              segments: [
                for (final v in valores)
                  ButtonSegment<T>(value: v, label: Text(texto(v))),
              ],
              selected: {actual},
              onSelectionChanged: (s) => notificador.value = s.first,
            ),
          ),
        ],
      ),
    );
  }
}
