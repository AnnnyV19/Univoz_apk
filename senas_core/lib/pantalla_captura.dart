/// Grabar muestras nuevas desde el telefono, etiquetadas con la palabra.
///
/// Esta pensada para grabar MUCHAS repeticiones seguidas: la palabra queda
/// fija arriba y el boton vuelve a estar listo apenas se guarda una, sin
/// tener que reescribir nada. Es lo que hace la diferencia entre juntar 5
/// muestras y juntar 50.
library pantalla_captura;

import 'package:flutter/material.dart';

import 'camera_bridge.dart';
import 'componentes_univoz.dart';
import 'controlador_captura.dart';
import 'muestras_locales.dart';
import 'skeleton_painter.dart' show SkeletonPainter;
import 'sesion_automatica.dart';
import 'tema_univoz.dart';

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
    if (!mounted || !_ctrl.lista) return;
    await activarSesionConConsentimiento(context, _ctrl, _almacen,
        pantalla: 'captura');
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
          'No se capturó nada. Asegúrate de que se vean los hombros y las manos en cámara.',
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
      _ctrl.sesion?.evento('sample_saved', {
        'gloss': _glosa,
        'frames': captura.framesCrudos.length,
      });
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

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agregar muestras'),
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
            onPressed: (_ctrl.grabando || !_ctrl.lista) ? null : _voltearCamara,
          ),
          if (_guardadasEstaSesion > 0)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: colores.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '+$_guardadasEstaSesion',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colores.primary,
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
    );
  }

  Widget _formulario() {
    final yaTiene = _glosa.isEmpty ? 0 : _almacen.cuantasDe(_glosa);
    return TarjetaUnivoz(
      margen: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      relleno: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _palabraCtrl,
            enabled: !_ctrl.grabando,
            textCapitalization: TextCapitalization.none,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
            decoration: const InputDecoration(
              labelText: '¿Qué palabra es? *',
              hintText: 'gracias, cómo estás...',
              prefixIcon: Icon(Icons.translate_rounded, size: 18),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _signerCtrl,
                  enabled: !_ctrl.grabando,
                  style: const TextStyle(fontSize: 13.5),
                  decoration: const InputDecoration(
                    labelText: 'Tu nombre *',
                    prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _campoCategoria()),
            ],
          ),
          const SizedBox(height: 8),
          AvisoUnivoz(
            _camposCompletos
                ? 'Se guardará como $_glosa  ·  ya tienes $yaTiene muestra(s)'
                : 'Completa palabra, tu nombre y categoría (los tres son '
                    'obligatorios) para poder grabar.',
            tipo: _camposCompletos ? TipoAviso.exito : TipoAviso.info,
            compacto: true,
            margen: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  /// Campo de categoria: se puede escribir cualquier cosa, pero a medida
  /// que se tipea aparecen como sugerencia las de kCategoriasBase y las que
  /// ya se usaron en este telefono -- asi el mismo nombre de categoria no
  /// termina escrito de dos formas distintas por error de tipeo.
  Widget _campoCategoria() {
    final colores = Theme.of(context).colorScheme;
    final sugerencias =
        {...kCategoriasBase, ..._almacen.categoriasUsadas}.toList()..sort();
    return Autocomplete<String>(
      optionsBuilder: (TextEditingValue valor) {
        if (valor.text.isEmpty) return sugerencias;
        final buscado = valor.text.toLowerCase();
        return sugerencias.where((c) => c.toLowerCase().contains(buscado));
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        // El controller de este campo lo crea y destruye el propio
        // Autocomplete -- solo guardamos la referencia (una vez; este
        // builder se re-invoca en cada rebuild del formulario, pero el
        // controller que nos pasa es siempre la misma instancia) para
        // poder leerlo al guardar y completarlo automaticamente desde el
        // listener de la palabra. Tambien es obligatoria (ver
        // _puedeGrabar), asi que necesita el mismo listener que dispara un
        // rebuild al tipear -- se agrega una sola vez, la primera vez que
        // llega esta instancia del controller.
        if (_categoriaCtrl != controller) controller.addListener(_alCambiar);
        _categoriaCtrl = controller;
        return TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: !_ctrl.grabando,
          style: const TextStyle(fontSize: 13.5),
          decoration: const InputDecoration(
            labelText: 'Categoría *',
            hintText: 'Saludos y Cortesía...',
            prefixIcon: Icon(Icons.folder_outlined, size: 18),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, opciones) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 6,
          shadowColor: Colors.black.withValues(alpha: 0.12),
          color: colores.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colores.outlineVariant),
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                children: [
                  for (final o in opciones)
                    ListTile(
                      dense: true,
                      title: Text(o,
                          style: TextStyle(
                              fontSize: 13, color: colores.onSurface)),
                      onTap: () => onSelected(o),
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
    final colores = Theme.of(context).colorScheme;
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
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colores.outlineVariant),
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
                        // Camara frontal = vista de espejo: se voltea la
                        // imagen y, con ella, los puntos del esqueleto.
                        child: Transform.flip(
                          flipX: camara.frontal,
                          child: Texture(textureId: camara.textureId),
                        ),
                      ),
                      ValueListenableBuilder<LandmarkFrame?>(
                        valueListenable: _ctrl.frame,
                        builder: (_, frame, __) => CustomPaint(
                          painter: SkeletonPainter(
                              frame: frame, espejo: camara.frontal),
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
                      color: EstadosUnivoz.claro.error.icono,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: EstadosUnivoz.claro.error.icono
                              .withValues(alpha: 0.35),
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

  /// Sobre el video (siempre oscuro): colores fijos claros a propósito.
  Widget _chipEstado(LandmarkFrame? frame) {
    final cuerpo = frame?.pose != null;
    final izq = frame?.left != null;
    final der = frame?.right != null;
    Widget punto(String texto, bool ok) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ok ? EstadosUnivoz.oscuro.exito.icono : Colors.white38,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              texto,
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
        color: Colors.black.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        punto('Cuerpo', cuerpo),
        punto('Izq', izq),
        punto('Der', der),
      ]),
    );
  }

  Widget _barraInferior() {
    final colores = Theme.of(context).colorScheme;
    final rojo = EstadosUnivoz.de(context).error.icono;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        decoration: BoxDecoration(
          color: colores.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerTheme.color ??
                colores.outlineVariant),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_aviso != null)
              AvisoUnivoz(
                _aviso!,
                tipo: _avisoEsError ? TipoAviso.error : TipoAviso.exito,
                margen: const EdgeInsets.only(bottom: 10),
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
                    _ctrl.grabando ? 'Detener y guardar' : 'Grabar muestra'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _ctrl.grabando ? rojo : null,
                  foregroundColor: _ctrl.grabando ? Colors.white : null,
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
