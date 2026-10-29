import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:test/test.dart';

import 'package:senas_core/paquete_sync.dart';
import 'package:senas_core/sign_norm.dart';
import 'package:senas_core/supabase_api.dart';

List<List<double>> _seq({double paso = 0.0}) {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final v = (((data['cases'] as List).first as Map)['expected_frames'] as List)
      .first as List;
  final frame = v.map((x) => (x as num).toDouble()).toList();
  return List.generate(
      kTFrames, (i) => [for (final x in frame) x + paso * i]);
}

PlantillaRemota _p(String id, {double paso = 0.0}) =>
    PlantillaRemota(id, id.toUpperCase(), id, _seq(paso: paso));

void main() {
  group('PlantillaRemota guarda los cuadros en un Float64List', () {
    test('seq devuelve los mismos valores que se le dieron', () {
      final original = _seq(paso: 0.001);
      final p = PlantillaRemota('a', 'A', 'a', original);
      expect(p.plano, isA<Float64List>());
      expect(p.plano.length, kTFrames * kFrameDim);
      expect(p.seq, original);
      expect(p.seq.every((f) => f is Float64List && f.length == kFrameDim),
          isTrue);
    });

    test('toJson -> fromJson conserva lo redondeado a 5 decimales', () {
      final p = _p('a', paso: 0.000123456);
      final j = jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>;
      final q = PlantillaRemota.fromJson(j);
      expect(q.seq, p.toJson()['seq']);
      expect(q.signId, 'a');
      expect(q.espanol, 'a');
    });

    test('un cuadro de otro tamano se rechaza', () {
      expect(() => PlantillaRemota('a', 'A', 'a', [List.filled(10, 0.0)]),
          throwsArgumentError);
    });

    test('unpackF16Plano da los mismos valores que unpackF16', () {
      final bytes = packF16(_seq(paso: 0.01));
      final plano = unpackF16Plano(bytes);
      expect(plano, isA<Float64List>());
      expect([for (final f in unpackF16(bytes)) ...f], plano);
    });
  });

  group('armarPaqueteSync', () {
    final ahora = DateTime(2026, 10, 21, 9);

    test('mismos bytes y huella que codificar el mapa completo', () {
      final ps = [_p('a'), _p('b', paso: 0.01)];
      final armado = armarPaqueteSync(ps, ahora);
      final lista = ps.map((p) => p.toJson()).toList();
      final huella = sha1.convert(utf8.encode(jsonEncode(lista))).toString();
      expect(armado.huella, huella);
      expect(armado.huella, huellaPlantillas(ps));
      expect(
          utf8.decode(armado.bytes),
          jsonEncode({
            'norm_version': kNormVersion,
            't_frames': kTFrames,
            'frame_dim': kFrameDim,
            'sincronizado_en': ahora.toIso8601String(),
            'huella': huella,
            'plantillas': lista,
          }));
      expect(armado.valido, isTrue);
      expect(armado.cantidad, 2);
      expect(leerPaqueteSync(construirPaqueteSync(ps, ahora)), hasLength(2));
    });

    test('vacio no es valido', () {
      expect(armarPaqueteSync(const [], ahora).valido, isFalse);
    });
  });

  group('metadatos del paquete (archivo chico de al lado)', () {
    late Directory dir;
    late File paquete;
    late File meta;
    final ahora = DateTime(2026, 10, 21, 9);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('meta_');
      paquete = File('${dir.path}/plantillas_sync.json');
      meta = File('${dir.path}/$kNombreArchivoMetaSync');
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('escribirPaqueteSync deja paquete y metadatos coherentes', () async {
      final armado = armarPaqueteSync([_p('a'), _p('b', paso: 0.01)], ahora);
      await escribirPaqueteSync(paquete, armado);
      expect(paquete.readAsBytesSync(), armado.bytes);
      final m = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      expect(m['bytes'], armado.bytes.length);
      final leido = (await leerMetadatosSync(paquete))!;
      expect(leido.cantidad, 2);
      expect(leido.huella, armado.huella);
      expect(leido.cuando, ahora);
    });

    test('usa el archivo chico sin leer el paquete', () async {
      final armado = armarPaqueteSync([_p('a')], ahora);
      await escribirPaqueteSync(paquete, armado);
      // Se cambia un dato SOLO en el archivo chico: si sale, no se leyo el
      // paquete.
      final m = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
      m['cantidad'] = 77;
      meta.writeAsStringSync(jsonEncode(m));
      expect((await leerMetadatosSync(paquete))!.cantidad, 77);
    });

    test('sin archivo chico cae al paquete', () async {
      final armado = armarPaqueteSync([_p('a'), _p('b', paso: 0.01)], ahora);
      paquete.writeAsBytesSync(armado.bytes);
      final leido = (await leerMetadatosSync(paquete))!;
      expect(leido.cantidad, 2);
      expect(leido.huella, armado.huella);
      expect(leido.cuando, ahora);
    });

    test('paquete reemplazado (tamano distinto) ignora el archivo chico',
        () async {
      await escribirPaqueteSync(paquete, armarPaqueteSync([_p('a')], ahora));
      final otro = armarPaqueteSync([_p('x'), _p('y', paso: 0.02)], ahora);
      paquete.writeAsBytesSync(otro.bytes);
      expect((await leerMetadatosSync(paquete))!.cantidad, 2);
    });

    test('archivo chico roto cae al paquete; sin paquete es null', () async {
      expect(await leerMetadatosSync(paquete), isNull);
      paquete.writeAsBytesSync(armarPaqueteSync([_p('a')], ahora).bytes);
      meta.writeAsStringSync('{no es json');
      expect((await leerMetadatosSync(paquete))!.cantidad, 1);
    });
  });
}
