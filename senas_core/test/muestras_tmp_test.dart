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
  test('AlmacenMuestras.cargar barre los .tmp huerfanos viejos', () async {
    final tmp = Directory.systemTemp.createTempSync('almacen_tmp_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _Rutas(tmp.path);
    final raw = Directory('${tmp.path}/$kDirectorioRaw')..createSync();

    File crear(String ruta, Duration edad) => File(ruta)
      ..writeAsStringSync('x')
      ..setLastModifiedSync(DateTime.now().subtract(edad));
    final viejoDatos = crear('${tmp.path}/muestras_locales.json.9.1.tmp',
        const Duration(minutes: 10));
    final viejoRaw =
        crear('${raw.path}/123_0.json.gz.9.2.tmp', const Duration(minutes: 10));
    final reciente = crear('${tmp.path}/plantillas_sync.json.9.3.tmp',
        const Duration(seconds: 3));

    await AlmacenMuestras.instancia.cargar();

    expect(viejoDatos.existsSync(), isFalse);
    expect(viejoRaw.existsSync(), isFalse);
    expect(reciente.existsSync(), isTrue);
  });
}
