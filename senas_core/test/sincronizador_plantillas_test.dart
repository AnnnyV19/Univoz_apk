import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:senas_core/muestras_locales.dart' show kNombreArchivoSync;
import 'package:senas_core/paquete_sync.dart';
import 'package:senas_core/sign_norm.dart';
import 'package:senas_core/sincronizador_plantillas.dart';
import 'package:senas_core/supabase_api.dart';

List<List<double>> _seq() {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final v = (((data['cases'] as List).first as Map)['expected_frames'] as List)
      .first as List;
  final frame = v.map((x) => (x as num).toDouble()).toList();
  return List.generate(kTFrames, (_) => List<double>.from(frame));
}

String _hex(List<List<double>> seq) {
  final sb = StringBuffer(r'\x');
  for (final b in packF16(seq)) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Map<String, dynamic> _fila(String id, String gloss,
        {String norm = kNormVersion}) =>
    {
      'sign_id': id,
      'gloss': gloss,
      'espanol': gloss.toLowerCase(),
      'norm_version': norm,
      't_frames': kTFrames,
      'frame_dim': kFrameDim,
      'data': _hex(_seq()),
    };

void main() {
  late Directory dir;
  late File archivo;
  var pedidos = 0;
  var recargas = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_');
    archivo = File('${dir.path}/$kNombreArchivoSync');
    pedidos = 0;
    recargas = 0;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SupabaseApi api(Future<http.Response> Function() respuesta) => SupabaseApi(
        url: 'https://example.test',
        clave: 'k',
        cliente: MockClient((_) {
          pedidos++;
          return respuesta();
        }),
      );

  Future<ResultadoSync> correr(SupabaseApi a, {DateTime? ahora}) =>
      SincronizadorPlantillas.siCorresponde(
        api: a,
        directorio: () async => dir,
        ahora: ahora,
        alActualizar: () async => recargas++,
      );

  PlantillaRemota plantilla(String id, String gloss) =>
      PlantillaRemota(id, gloss, gloss.toLowerCase(), _seq());

  void escribirViejo(DateTime cuando, {List<PlantillaRemota>? p}) =>
      archivo.writeAsStringSync(
          construirPaqueteSync(p ?? [plantilla('v1', 'VIEJA')], cuando));

  group('paquete', () {
    test('construir + leer es identidad', () {
      final texto = construirPaqueteSync([plantilla('a', 'HOLA')], DateTime.now());
      final leido = leerPaqueteSync(texto)!;
      expect(leido.single.gloss, 'HOLA');
    });

    test('rechaza vacio, norm_version distinta, dims y JSON roto', () {
      final ok = jsonDecode(
              construirPaqueteSync([plantilla('a', 'HOLA')], DateTime.now()))
          as Map<String, dynamic>;
      String con(Map<String, dynamic> cambios) =>
          jsonEncode({...ok, ...cambios});
      expect(leerPaqueteSync(con({'plantillas': []})), isNull);
      expect(leerPaqueteSync(con({'norm_version': '1.0.0'})), isNull);
      expect(leerPaqueteSync(con({'t_frames': 16})), isNull);
      expect(leerPaqueteSync(con({'frame_dim': 10})), isNull);
      expect(leerPaqueteSync(con({'plantillas': [{'sign_id': 'x'}]})), isNull);
      expect(leerPaqueteSync('{no es json'), isNull);
      expect(leerPaqueteSync('[]'), isNull);
    });
  });

  group('siCorresponde', () {
    test('sin archivo previo descarga, escribe y avisa', () async {
      final r = await correr(api(
          () async => http.Response(jsonEncode([_fila('s1', 'HOLA')]), 200)));
      expect(r, ResultadoSync.actualizado);
      expect(recargas, 1);
      expect(leerPaqueteSync(archivo.readAsStringSync())!.single.gloss, 'HOLA');
      expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });

    test('con una sincronizacion de hace menos de 24 h no toca la red',
        () async {
      final ahora = DateTime(2026, 10, 20, 12);
      escribirViejo(ahora.subtract(const Duration(hours: 23)));
      final antes = archivo.readAsStringSync();
      final r = await correr(
          api(() async => http.Response('[]', 200)), ahora: ahora);
      expect(r, ResultadoSync.omitido);
      expect(pedidos, 0);
      expect(archivo.readAsStringSync(), antes);
    });

    test('con mas de 24 h vuelve a sincronizar', () async {
      final ahora = DateTime(2026, 10, 20, 12);
      escribirViejo(ahora.subtract(const Duration(hours: 25)));
      final r = await correr(
          api(() async => http.Response(jsonEncode([_fila('s2', 'ADIOS')]), 200)),
          ahora: ahora);
      expect(r, ResultadoSync.actualizado);
      expect(pedidos, 1);
      expect(recargas, 1);
      final nuevo = leerPaqueteSync(archivo.readAsStringSync())!;
      expect(nuevo.single.gloss, 'ADIOS');
    });

    test('mismo diccionario: renueva la hora pero no recarga', () async {
      final ahora = DateTime(2026, 10, 20, 12);
      // Lo guardado vino de una descarga anterior: ya paso por float16.
      escribirViejo(ahora.subtract(const Duration(hours: 30)), p: [
        PlantillaRemota(
            's1', 'HOLA', 'hola', unpackF16(packF16(_seq()), dim: kFrameDim))
      ]);
      final r = await correr(
          api(() async => http.Response(jsonEncode([_fila('s1', 'HOLA')]), 200)),
          ahora: ahora);
      expect(r, ResultadoSync.sinCambios);
      expect(recargas, 0);
      final j = jsonDecode(archivo.readAsStringSync()) as Map<String, dynamic>;
      expect(DateTime.parse(j['sincronizado_en'] as String), ahora);
    });

    test('paquete vacio: conserva el archivo anterior', () async {
      escribirViejo(DateTime(2020));
      final antes = archivo.readAsStringSync();
      final r = await correr(api(() async => http.Response('[]', 200)));
      expect(r, ResultadoSync.invalido);
      expect(archivo.readAsStringSync(), antes);
      expect(recargas, 0);
    });

    test('todas las filas con otra norm_version: conserva lo anterior',
        () async {
      escribirViejo(DateTime(2020));
      final antes = archivo.readAsStringSync();
      final r = await correr(api(() async => http.Response(
          jsonEncode([_fila('s1', 'HOLA', norm: '1.0.0')]), 200)));
      expect(r, ResultadoSync.invalido);
      expect(archivo.readAsStringSync(), antes);
    });

    test('sin red: conserva lo anterior y no lanza', () async {
      escribirViejo(DateTime(2020));
      final antes = archivo.readAsStringSync();
      final r = await correr(
          api(() async => throw const SocketException('sin red')));
      expect(r, ResultadoSync.fallo);
      expect(archivo.readAsStringSync(), antes);
      expect(pedidos, 2); // GET + 1 reintento
    });

    test('error del servidor (500): conserva lo anterior', () async {
      escribirViejo(DateTime(2020));
      final antes = archivo.readAsStringSync();
      final r = await correr(api(() async => http.Response('boom', 500)));
      expect(r, ResultadoSync.fallo);
      expect(archivo.readAsStringSync(), antes);
    });

    test('JSON basura del servidor: no lanza y conserva', () async {
      escribirViejo(DateTime(2020));
      final antes = archivo.readAsStringSync();
      final r = await correr(api(() async => http.Response('<html>', 200)));
      expect(r, ResultadoSync.fallo);
      expect(archivo.readAsStringSync(), antes);
    });

    group('no reemplaza por un diccionario mucho mas chico', () {
      List<Map<String, dynamic>> filas(int n) =>
          [for (var i = 0; i < n; i++) _fila('s$i', 'SENA$i')];
      List<PlantillaRemota> viejas(int n) =>
          [for (var i = 0; i < n; i++) plantilla('v$i', 'VIEJA$i')];

      test('3 descargadas frente a 10 guardadas: conserva el archivo', () async {
        escribirViejo(DateTime(2020), p: viejas(10));
        final antes = archivo.readAsStringSync();
        final r = await correr(
            api(() async => http.Response(jsonEncode(filas(3)), 200)));
        expect(r, ResultadoSync.invalido);
        expect(archivo.readAsStringSync(), antes);
        expect(recargas, 0);
      });

      test('exactamente la mitad si pasa', () async {
        escribirViejo(DateTime(2020), p: viejas(10));
        final r = await correr(
            api(() async => http.Response(jsonEncode(filas(5)), 200)));
        expect(r, ResultadoSync.actualizado);
        expect(leerPaqueteSync(archivo.readAsStringSync()), hasLength(5));
      });

      test('sin sincronizacion previa acepta cualquier descarga valida '
          '(el paquete del APK manda, no se compara con el)', () async {
        // La base remota trae pocas plantillas frente a las 1296 del APK: en
        // una instalacion nueva eso no es un error.
        final r = await correr(
            api(() async => http.Response(jsonEncode(filas(3)), 200)));
        expect(r, ResultadoSync.actualizado);
        expect(recargas, 1);
        expect(leerPaqueteSync(archivo.readAsStringSync()), hasLength(3));
      });

      test('demasiado chica: anota la hora del intento y no repite antes de '
          '24 h', () async {
        final ahora = DateTime(2026, 10, 20, 12);
        escribirViejo(ahora.subtract(const Duration(hours: 30)), p: viejas(10));
        final r1 = await correr(
            api(() async => http.Response(jsonEncode(filas(3)), 200)),
            ahora: ahora);
        expect(r1, ResultadoSync.invalido);
        expect(pedidos, 1);

        final r2 = await correr(
            api(() async => http.Response(jsonEncode(filas(3)), 200)),
            ahora: ahora.add(const Duration(hours: 23)));
        expect(r2, ResultadoSync.omitido);
        expect(pedidos, 1);

        final r3 = await correr(
            api(() async => http.Response(jsonEncode(filas(10)), 200)),
            ahora: ahora.add(const Duration(hours: 25)));
        expect(r3, ResultadoSync.actualizado);
        expect(pedidos, 2);
      });
    });

    test('descarga invalida sin archivo previo: tampoco se repite en cada '
        'arranque', () async {
      final ahora = DateTime(2026, 10, 20, 12);
      final r1 = await correr(api(() async => http.Response('[]', 200)),
          ahora: ahora);
      expect(r1, ResultadoSync.invalido);
      expect(archivo.existsSync(), isFalse);
      expect(pedidos, 1);

      final r2 = await correr(api(() async => http.Response('[]', 200)),
          ahora: ahora.add(const Duration(hours: 2)));
      expect(r2, ResultadoSync.omitido);
      expect(pedidos, 1);

      final r3 = await correr(api(() async => http.Response('[]', 200)),
          ahora: ahora.add(const Duration(hours: 25)));
      expect(r3, ResultadoSync.invalido);
      expect(pedidos, 2);
    });

    test('sin red no anota intento: el siguiente arranque vuelve a probar',
        () async {
      final ahora = DateTime(2026, 10, 20, 12);
      final r1 = await correr(
          api(() async => throw const SocketException('sin red')),
          ahora: ahora);
      expect(r1, ResultadoSync.fallo);
      final r2 = await correr(
          api(() async => http.Response(jsonEncode([_fila('s1', 'HOLA')]), 200)),
          ahora: ahora.add(const Duration(minutes: 5)));
      expect(r2, ResultadoSync.actualizado);
    });
  });
}
