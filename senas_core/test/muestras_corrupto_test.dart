import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:senas_core/muestras_locales.dart';

class _Rutas extends PathProviderPlatform {
  _Rutas(this.ruta);
  final String ruta;
  @override
  Future<String?> getApplicationDocumentsPath() async => ruta;
}

void main() {
  test('un archivo de muestras ilegible se aparta, no se sobrescribe', () async {
    final tmp = Directory.systemTemp.createTempSync('almacen_corrupto_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _Rutas(tmp.path);
    final original = File('${tmp.path}/muestras_locales.json')
      ..writeAsStringSync('{ esto no es json');

    await AlmacenMuestras.instancia.cargar();

    expect(original.existsSync(), isFalse);
    final apartados = tmp
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('muestras_locales.json.corrupto-'))
        .toList();
    expect(apartados, hasLength(1));
    expect(apartados.single.readAsStringSync(), '{ esto no es json');
  });
}
