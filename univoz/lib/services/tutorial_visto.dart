import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Si ya se vio el tutorial de primer uso (TutorialScreen). Un archivo vacío
/// en los documentos de la app: existe = ya se vio. Se lee una vez al
/// arrancar (main.dart) para que la bienvenida sepa a dónde ir sin esperar.
class TutorialVisto {
  TutorialVisto._();

  static const String _kArchivo = 'tutorial_visto';

  static bool _visto = false;

  /// Solo para pruebas: carpeta en vez de la de documentos. Si lanza, se
  /// comporta como "sin disco" (el tutorial se ve, y no se recuerda).
  static Future<Directory> Function()? directorioParaPruebas;

  static bool get visto => _visto;

  static Future<File> _archivo() async {
    final dir = await (directorioParaPruebas ?? getApplicationDocumentsDirectory)();
    return File('${dir.path}/$_kArchivo');
  }

  static Future<void> cargar() async {
    try {
      _visto = await (await _archivo()).exists();
    } catch (_) {
      _visto = false;
    }
  }

  /// Lo marca como visto (en memoria al instante; el archivo, sin esperar).
  static Future<void> marcar() async {
    _visto = true;
    try {
      await (await _archivo()).writeAsString('1');
    } catch (_) {
      // Sin disco: se vuelve a mostrar la próxima vez, nada más.
    }
  }

  /// Solo para pruebas.
  static void restablecerParaPruebas({bool visto = false}) => _visto = visto;
}
