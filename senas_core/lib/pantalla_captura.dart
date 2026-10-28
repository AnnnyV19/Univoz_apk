/// Grabar muestras nuevas desde el telefono, etiquetadas con la palabra.
///
/// Esta pensada para grabar MUCHAS repeticiones seguidas: la palabra queda
/// fija arriba y el boton vuelve a estar listo apenas se guarda una, sin
/// tener que reescribir nada. Es lo que hace la diferencia entre juntar 5
/// muestras y juntar 50.
library pantalla_captura;

import 'package:flutter/material.dart';
import 'immersive_navigation.dart';

import 'camera_bridge.dart';
import 'controlador_captura.dart';
import 'muestras_locales.dart';
import 'skeleton_painter.dart' show SkeletonPainter;

/// Debajo de esto la grabacion casi seguro salio mal (mano fuera de cuadro,
/// boton apretado dos veces sin querer).
const int kMinFramesUtiles = 8;

/// Categorias que ya usa el equipo (las mismas de videos/palabras_sm.xlsx,
/// cargadas a la base con sql/003_categorizar_senas.sql). Se ofrecen como
/// punto de partida al elegir la categoria, ademas de las que ya se hayan
/// usado en este telefono -- no es una lista cerrada: se puede escribir
/// cualquier otra y queda guardada tal cual.
const List<String> kCategoriasBase = [
  'Acciones / Verbos',
  'Entorno y Educación',
  'Entorno y Familia',
  'Familia',
  'Familia y Relaciones',
  'Identidad / Personal',
  'LSM / Comunicación',
  'Necesidades y Entorno',
  'Preguntas',
  'Preguntas e Interacción',
  'Respuestas BÁSICAS',
  'Saludos y Cortesía',
  'Sentimientos y Expresiones',
];

class PantallaCaptura extends StatefulWidget {
  const PantallaCaptura({Key? key}) : super(key: key);

  @override
  State<PantallaCaptura> createState() => _PantallaCapturaState();
}

class _PantallaCapturaState extends State<PantallaCaptura> {
  final _ctrl = ControladorCaptura();
  final _almacen = AlmacenMuestras.instancia;
  final _palabraCtrl = TextEditingController();
  final _signerCtrl = TextEditingController();

  /// Controller real del campo de categoria -- lo crea y lo destruye el
  /// propio widget Autocomplete (ver fieldViewBuilder en _campoCategoria);
  /// aca solo guardamos la referencia para poder leerlo al guardar y
  /// completarlo automaticamente si se reconoce la palabra.
  TextEditingController? _categoriaCtrl;

  String _glosa = '';
  int _guardadasEstaSesion = 0;
  String? _aviso;
  bool _avisoEsError = false;
  bool _volteando = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_alCambiar);
    _palabraCtrl.addListener(() {
      final g = aGlosa(_palabraCtrl.text);
      if (g == _glosa) return;
      setState(() => _glosa = g);
      // Si ya se grabo esta palabra antes y todavia no se toco el campo de
      // categoria a mano, se sugiere la misma de la ultima vez -- asi no
      // hay que volver a escribirla en cada repeticion de la misma sena.
      final categoriaCtrl = _categoriaCtrl;
      if (categoriaCtrl != null && categoriaCtrl.text.trim().isEmpty) {
        final sugerida = _almacen.categoriaDe(g);
        if (sugerida != null) categoriaCtrl.text = sugerida;
      }
    });
    // "Tu nombre" y "Categoría" tambien son obligatorios para poder grabar
    // (ver _puedeGrabar): sin este listener, el boton "Grabar muestra" solo
    // reflejaria estos dos campos cuando algo mas (como un frame de camara)
    // dispare un rebuild por su cuenta.
    _signerCtrl.addListener(_alCambiar);
    _arrancar();
  }

  Future<void> _arrancar() async {
    await _almacen.cargar();
    if (!mounted) return;
    await _ctrl.iniciar(
      frontal: _almacen.ajustes.camaraFrontal,
      cruzarManos: _almacen.ajustes.cruzarManos,
    );
  }

  /// Cambia entre camara frontal y trasera sin salir de la pantalla, y deja
  /// el nuevo lado guardado en Ajustes para la proxima vez. No se permite
  /// mientras se esta grabando: cortaria la muestra a mitad de camino.
  Future<void> _voltearCamara() async {
    if (_volteando || _ctrl.grabando || !_ctrl.lista) return;
    setState(() => _volteando = true);
    final nuevos = _almacen.ajustes.copiar()
      ..camaraFrontal = !_almacen.ajustes.camaraFrontal;
    try {
      await _ctrl.reiniciar(
        frontal: nuevos.camaraFrontal,
        cruzarManos: nuevos.cruzarManos,
      );
      await _almacen.guardarAjustes(nuevos);
    } finally {
      if (mounted) setState(() => _volteando = false);
    }
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_alCambiar);
    _ctrl.dispose();
    _palabraCtrl.dispose();
    _signerCtrl.removeListener(_alCambiar);
    _signerCtrl.dispose();
    // _categoriaCtrl NO se destruye aca (ni se le saca el listener con
    // removeListener): es del propio Autocomplete (ver _campoCategoria),
    // que lo crea y lo libera solo.
    super.dispose();
  }

  /// Palabra, nombre de quien seña y categoría son obligatorios: sin los
  /// tres completos no se puede grabar ni guardar una muestra.
  bool get _camposCompletos =>
      _glosa.isNotEmpty &&
      _signerCtrl.text.trim().isNotEmpty &&
      (_categoriaCtrl?.text.trim().isNotEmpty ?? false);

  bool get _puedeGrabar => _camposCompletos && _ctrl.lista;

  Future<void> _alternarGrabacion() async {
    if (_ctrl.grabando) {
      final framesLeidos = _ctrl.framesGrabados;
      final captura = await _ctrl.terminarCaptura();
      if (!mounted) return;

      if (captura == null) {
        _mostrar(
          'No se capturó nada. Asegurate de que se vean los hombros y las manos en cámara.',
          error: true,
        );
        return;
      }
      if (framesLeidos < kMinFramesUtiles) {
        _mostrar(
          'Grabación demasiado corta ($framesLeidos frames). No se guardó — haz la seña completa antes de detener.',
          error: true,
        );
        return;
      }

      await _almacen.agregar(
        gloss: _glosa,
        espanol: _palabraCtrl.text.trim(),
        seq: captura.secuencia.frames,
        nFramesOrig: captura.framesCrudos.length,
        categoria: (_categoriaCtrl?.text.trim().isEmpty ?? true)
            ? null
            : _categoriaCtrl!.text.trim(),
        signer:
            _signerCtrl.text.trim().isEmpty ? null : _signerCtrl.text.trim(),
        captura: captura,
      );
      if (!mounted) return;
      setState(() => _guardadasEstaSesion++);
      _mostrar(
          'Guardada. $_glosa tiene ${_almacen.cuantasDe(_glosa)} muestra(s).');
    } else {
      setState(() => _aviso = null);
      _ctrl.empezar();
    }
  }

  void _mostrar(String texto, {bool error = false}) {
    setState(() {
      _aviso = texto;
      _avisoEsError = error;
    });
  }

  InputDecoration _fluentInputDecoration({
    required String labelText,
    String? hintText,
    IconData? prefixIcon,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixIcon: prefixIcon != null
          ? Icon(prefixIcon, size: 18, color: const Color(0xFF791FC1))
          : null,
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      labelStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF6B6375)),
      hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFFA8A1B2)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE2DEEC), width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFE2DEEC), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF791FC1), width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ImmersiveNavigation(
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF29232F),
          elevation: 0,
          scrolledUnderElevation: 0,
          title: const Text(
            'Agregar muestras',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Color(0xFF29232F),
            ),
          ),
          centerTitle: false,
          actions: [
            IconButton(
              icon: _volteando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.cameraswitch_outlined, size: 22),
              tooltip: _almacen.ajustes.camaraFrontal
                  ? 'Cambiar a cámara trasera'
                  : 'Cambiar a cámara frontal',
              onPressed:
                  (_ctrl.grabando || !_ctrl.lista) ? null : _voltearCamara,
            ),
            if (_guardadasEstaSesion > 0)
              Padding(
                padding: const EdgeInsets.only(right: 14),
                child: Center(
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3E8FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '+$_guardadasEstaSesion',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF791FC1),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        body: Column(
          children: [
            _formulario(),
            Expanded(child: _preview()),
            _barraInferior(),
          ],
        ),
      ),
    );
  }

  Widget _formulario() {
    final yaTiene = _glosa.isEmpty ? 0 : _almacen.cuantasDe(_glosa);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDE9F4), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.025),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _palabraCtrl,
            enabled: !_ctrl.grabando,
            textCapitalization: TextCapitalization.none,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
            decoration: _fluentInputDecoration(
              labelText: 'Palabra o frase *',
              hintText: 'Ej. gracias, cómo estás...',
              prefixIcon: Icons.translate_rounded,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _signerCtrl,
                  enabled: !_ctrl.grabando,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: _fluentInputDecoration(
                    labelText: 'Tu nombre *',
                    hintText: 'Ej. Ana',
                    prefixIcon: Icons.person_outline_rounded,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _campoCategoria(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _camposCompletos
                  ? const Color(0xFFF0FDF4)
                  : const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _camposCompletos
                    ? const Color(0xFFBBF7D0)
                    : const Color(0xFFFDE68A),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _camposCompletos
                      ? Icons.check_circle_outline_rounded
                      : Icons.info_outline_rounded,
                  size: 14,
                  color: _camposCompletos
                      ? const Color(0xFF16A34A)
                      : const Color(0xFFD97706),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _camposCompletos
                        ? 'Glosa: $_glosa  ·  $yaTiene muestra(s) previa(s)'
                        : 'Escribe la palabra, tu nombre y categoría para grabar',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight:
                          _camposCompletos ? FontWeight.w600 : FontWeight.w500,
                      color: _camposCompletos
                          ? const Color(0xFF15803D)
                          : const Color(0xFFB45309),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Campo de categoria con autocompletado y estilo Fluent.
  Widget _campoCategoria() {
    final sugerencias =
        {...kCategoriasBase, ..._almacen.categoriasUsadas}.toList()..sort();
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue valor) {
        if (valor.text.isEmpty) return sugerencias;
        final buscado = valor.text.toLowerCase();
        return sugerencias.where((c) => c.toLowerCase().contains(buscado));
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        if (_categoriaCtrl != controller) controller.addListener(_alCambiar);
        _categoriaCtrl = controller;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !_ctrl.grabando,
          style: const TextStyle(fontSize: 13.5),
          decoration: _fluentInputDecoration(
            labelText: 'Categoría *',
            hintText: 'Seleccionar...',
            prefixIcon: Icons.folder_outlined,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, opciones) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 6,
          shadowColor: Colors.black.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFEBE6F3)),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (final o in opciones)
                    InkWell(
                      onTap: () => onSelected(o),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        child: Text(
                          o,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF29232F),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _preview() {
    if (_ctrl.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_ctrl.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                  onPressed: _arrancar, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }

    final camara = _ctrl.iniciada;
    if (camara == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEDE9F4), width: 1),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(
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
              ),
              Positioned(
                top: 10,
                left: 10,
                child: ValueListenableBuilder<LandmarkFrame?>(
                  valueListenable: _ctrl.frame,
                  builder: (_, frame, __) => _chipEstado(frame),
                ),
              ),
              if (_ctrl.grabando)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFDC2626).withOpacity(0.35),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.fiber_manual_record,
                            color: Colors.white, size: 10),
                        const SizedBox(width: 4),
                        Text(
                          '${_ctrl.framesGrabados} frames',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chipEstado(LandmarkFrame? frame) {
    final cuerpo = frame?.pose != null;
    final izq = frame?.left != null;
    final der = frame?.right != null;

    Widget punto(String label, bool ok) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? const Color(0xFF4ADE80) : Colors.white38,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: ok ? FontWeight.w600 : FontWeight.w400,
                color: ok ? Colors.white : Colors.white60,
              ),
            ),
            const SizedBox(width: 8),
          ],
        );

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 2, 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.48),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.18), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          punto('Cuerpo', cuerpo),
          punto('Mano I', izq),
          punto('Mano D', der),
        ],
      ),
    );
  }

  Widget _barraInferior() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(color: Color(0xFFF0EDF5), width: 1),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_aviso != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: BoxDecoration(
                  color: _avisoEsError
                      ? const Color(0xFFFEF2F2)
                      : const Color(0xFFF0FDF4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _avisoEsError
                        ? const Color(0xFFFECACA)
                        : const Color(0xFFBBF7D0),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _avisoEsError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 16,
                      color: _avisoEsError
                          ? const Color(0xFFDC2626)
                          : const Color(0xFF16A34A),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _aviso!,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: _avisoEsError
                              ? const Color(0xFF991B1B)
                              : const Color(0xFF166534),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _puedeGrabar ? _alternarGrabacion : null,
                icon: Icon(
                  _ctrl.grabando
                      ? Icons.stop_rounded
                      : Icons.fiber_manual_record_rounded,
                  size: 20,
                ),
                label: Text(
                  _ctrl.grabando
                      ? 'Detener y guardar'
                      : (_puedeGrabar
                          ? 'Grabar muestra'
                          : 'Completa los campos para grabar'),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _ctrl.grabando
                      ? const Color(0xFFDC2626)
                      : const Color(0xFF791FC1),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFFEDEBF0),
                  disabledForegroundColor: const Color(0xFFA69EB0),
                  elevation: _puedeGrabar ? 2 : 0,
                  shadowColor: const Color(0xFF791FC1).withOpacity(0.3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
