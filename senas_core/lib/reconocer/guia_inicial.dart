/// Guia de la primera vez en "Reconocer seña": tres pasos cortos encima de
/// la pantalla, con Siguiente / Omitir. Se recuerda que ya se vio (mismo
/// almacen que el modo desarrollador: un JSON en la carpeta de documentos de
/// la app) y se vuelve a abrir con el boton de informacion.
library guia_inicial;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

const List<String> kPasosGuiaReconocer = [
  'Colócate para que se vean tus hombros y manos',
  'En Automático reconozco cuando terminas la seña',
  'Toca una alternativa si me equivoqué',
];

/// Estado de la guia: que paso se ve (null = cerrada) y si ya se vio.
class ControladorGuiaInicial extends ChangeNotifier {
  ControladorGuiaInicial({this.pasos = kPasosGuiaReconocer});

  static const String _kArchivo = 'guia_reconocer.json';

  /// Solo para pruebas: carpeta del archivo (path_provider no existe en
  /// `flutter test`). Mismo patron que ModoDesarrollador.
  static Future<Directory> Function()? directorioParaPruebas;

  final List<String> pasos;
  int? _paso;
  bool _liberado = false;
  int? get paso => _paso;
  bool get abierta => _paso != null;

  static Future<File> _ruta() async {
    final dir = directorioParaPruebas != null
        ? await directorioParaPruebas!()
        : await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_kArchivo');
  }

  /// True si ya se vio (terminada u omitida). Cualquier problema al leer
  /// cuenta como no vista: mostrarla de mas es mejor que nunca.
  static Future<bool> yaVista() async {
    try {
      final f = await _ruta();
      if (!await f.exists()) return false;
      final j = jsonDecode(await f.readAsString());
      return j is Map && j['vista'] == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _guardarVista() async {
    try {
      final f = await _ruta();
      await f.writeAsString(jsonEncode({'v': 1, 'vista': true}));
    } catch (_) {}
  }

  /// Abre la guia si nunca se vio. Reintentar la camara la vuelve a pedir:
  /// si ya esta abierta, sigue en su paso.
  Future<void> mostrarSiPrimeraVez() async {
    if (abierta || await yaVista()) return;
    abrir();
  }

  /// Abre desde el primer paso (boton de informacion). Sin efecto si la
  /// pantalla ya se cerro mientras se leia el archivo.
  void abrir() {
    if (_liberado) return;
    _paso = 0;
    notifyListeners();
  }

  /// Avanza; en el ultimo paso la termina.
  Future<void> siguiente() async {
    final p = _paso;
    if (p == null) return;
    if (p + 1 < pasos.length) {
      _paso = p + 1;
      notifyListeners();
      return;
    }
    await cerrar();
  }

  /// Cierra (Omitir o fin) y la recuerda como vista. La UI se cierra al
  /// instante; el guardado va despues.
  Future<void> cerrar() async {
    if (_liberado) return;
    _paso = null;
    notifyListeners();
    await _guardarVista();
  }

  @override
  void dispose() {
    _liberado = true;
    super.dispose();
  }
}

/// Pone la guia encima de [child] mientras este abierta.
class CapaGuiaInicial extends StatelessWidget {
  const CapaGuiaInicial({
    super.key,
    required this.controlador,
    required this.child,
  });

  final ControladorGuiaInicial controlador;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        ListenableBuilder(
          listenable: controlador,
          builder: (context, _) {
            final paso = controlador.paso;
            if (paso == null) return const SizedBox.shrink();
            return Positioned.fill(
              child: _Paso(
                indice: paso,
                total: controlador.pasos.length,
                texto: controlador.pasos[paso],
                onSiguiente: controlador.siguiente,
                onOmitir: controlador.cerrar,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Paso extends StatelessWidget {
  const _Paso({
    required this.indice,
    required this.total,
    required this.texto,
    required this.onSiguiente,
    required this.onOmitir,
  });

  final int indice;
  final int total;
  final String texto;
  final VoidCallback onSiguiente;
  final VoidCallback onOmitir;

  static const _iconos = [
    Icons.accessibility_new,
    Icons.auto_awesome,
    Icons.touch_app_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final colores = tema.colorScheme;
    final ultimo = indice == total - 1;
    return ColoredBox(
      color: colores.scrim.withValues(alpha: 0.55),
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(_iconos[indice % _iconos.length],
                              color: colores.primary, size: 28),
                          const SizedBox(width: 12),
                          Text('${indice + 1} de $total',
                              style: tema.textTheme.labelLarge
                                  ?.copyWith(color: colores.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Semantics(
                        liveRegion: true,
                        child: Text(texto, style: tema.textTheme.titleLarge),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (!ultimo)
                            TextButton(
                                onPressed: onOmitir,
                                child: const Text('Omitir')),
                          const Spacer(),
                          FilledButton(
                            onPressed: onSiguiente,
                            child: Text(ultimo ? 'Entendido' : 'Siguiente'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
