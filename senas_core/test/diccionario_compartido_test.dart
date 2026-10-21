import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/sign_norm.dart';

class _Rutas extends PathProviderPlatform {
  _Rutas(this.ruta);
  final String ruta;
  @override
  Future<String?> getApplicationDocumentsPath() async => ruta;
}

List<List<double>> _seq({double x = 0}) {
  final data = jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  final v = (((data['cases'] as List).first as Map)['expected_frames'] as List)
      .first as List;
  final frame = v.map((s) => (s as num).toDouble()).toList();
  // Un lado distinto del otro para que el espejo no sea igual a la original.
  frame[kOffLocL] = 0.3 + x;
  frame[kOffLocR] = -0.2;
  return List.generate(kTFrames, (_) => List<double>.from(frame));
}

Uint8List _paquete(List<(String, String)> senas) => Uint8List.fromList(utf8.encode(
      jsonEncode({
        'norm_version': kNormVersion,
        'frame_dim': kFrameDim,
        't_frames': kTFrames,
        'forma': kFormaIso,
        'plantillas': [
          for (final (id, gloss) in senas)
            {
              'sign_id': id,
              'gloss': gloss,
              'espanol': gloss.toLowerCase(),
              'seq': _seq(),
              'aspecto': 1.78,
            },
        ],
      }),
    ));

void main() {
  late Directory tmp;
  final almacen = AlmacenMuestras.instancia;
  var lecturas = 0;
  Uint8List? paquete;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tmp = Directory.systemTemp.createTempSync('dicc_compartido_');
    PathProviderPlatform.instance = _Rutas(tmp.path);
    await almacen.cargar();
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  setUp(() async {
    lecturas = 0;
    paquete = _paquete([('p1', 'HOLA'), ('p2', 'AGUA')]);
    lectorAssetsPrueba = (ruta) async {
      if (ruta == kRutaPaquete) lecturas++;
      return ruta == kRutaPaquete ? paquete : null;
    };
    olvidarDiccionarioCompartido();
    for (final g in almacen.porGlosa.map((e) => e.key).toList()) {
      await almacen.borrarGlosa(g);
    }
    await almacen.guardarAjustes(Ajustes());
  });
  tearDown(() {
    lectorAssetsPrueba = null;
    olvidarDiccionarioCompartido();
  });

  Future<void> grabar(String gloss) => almacen.agregar(
      gloss: gloss, espanol: gloss.toLowerCase(), seq: _seq(), nFramesOrig: 32);

  group('diccionario compartido', () {
    test('llamadas repetidas y simultaneas reciben la MISMA instancia',
        () async {
      final juntas = await Future.wait([cargarDiccionario(), cargarDiccionario()]);
      final despues = await cargarDiccionario();
      expect(identical(juntas[0], juntas[1]), isTrue);
      expect(identical(juntas[0], despues), isTrue);
      expect(lecturas, 1);
      expect(despues.resumen.delPaquete, 2);
      expect(despues.resumen.espejadas, 2);
    });

    test('grabar, borrar y sincronizar lo invalidan', () async {
      final a = await cargarDiccionario();
      await grabar('ADIOS');
      final b = await cargarDiccionario();
      expect(identical(a, b), isFalse);
      expect(b.resumen.locales, 1);

      final b2 = await cargarDiccionario();
      expect(identical(b, b2), isTrue);

      await almacen.borrarGlosa('ADIOS');
      final c = await cargarDiccionario();
      expect(identical(b, c), isFalse);
      expect(c.resumen.locales, 0);

      await almacen.recargarSincronizadas();
      final d = await cargarDiccionario();
      expect(identical(c, d), isFalse);
    });

    test('si el paquete no se pudo leer, no se queda guardado', () async {
      var fallar = true;
      lectorAssetsPrueba = (ruta) async {
        if (ruta != kRutaPaquete) return null;
        lecturas++;
        if (fallar) return null;
        return paquete;
      };
      final a = await cargarDiccionario();
      expect(a.resumen.delPaquete, 0);

      fallar = false;
      final b = await cargarDiccionario();
      expect(identical(a, b), isFalse);
      expect(b.resumen.delPaquete, 2);
      expect(lecturas, 2);
    });

    test('borrar una muestra por id tambien lo invalida', () async {
      await grabar('ADIOS');
      final a = await cargarDiccionario();
      await almacen.borrar(almacen.muestras.single.id);
      final b = await cargarDiccionario();
      expect(identical(a, b), isFalse);
      expect(b.resumen.locales, 0);
    });

    test('subir una muestra a la base no lo invalida', () async {
      await grabar('ADIOS');
      final a = await cargarDiccionario();
      await almacen.marcarSubida(almacen.muestras.single.id);
      final b = await cargarDiccionario();
      expect(identical(a, b), isTrue);
    });

    test('cambiar espejo o umbrales lo invalida; otros ajustes no', () async {
      final a = await cargarDiccionario();

      final otraCamara = Ajustes.fromJson(almacen.ajustes.toJson())
        ..camaraFrontal = !almacen.ajustes.camaraFrontal;
      await almacen.guardarAjustes(otraCamara);
      expect(identical(a, await cargarDiccionario()), isTrue);

      final sinEspejo = Ajustes.fromJson(almacen.ajustes.toJson())
        ..espejoAutomatico = false;
      await almacen.guardarAjustes(sinEspejo);
      final b = await cargarDiccionario();
      expect(identical(a, b), isFalse);
      expect(b.resumen.espejadas, 0);

      final umbral = Ajustes.fromJson(almacen.ajustes.toJson())
        ..maxDistance = 0.4;
      await almacen.guardarAjustes(umbral);
      final c = await cargarDiccionario();
      expect(identical(b, c), isFalse);
      expect(c.clasificador.maxDistance, 0.4);
    });

    test('un fallo no se queda guardado: la siguiente llamada reintenta',
        () async {
      lectorAssetsPrueba = (_) async => throw StateError('disco');
      await expectLater(cargarDiccionario(), throwsStateError);
      lectorAssetsPrueba = (ruta) async =>
          ruta == kRutaPaquete ? _paquete([('p1', 'HOLA')]) : null;
      final d = await cargarDiccionario();
      expect(d.resumen.delPaquete, 1);
    });
  });

  group('paquete ilegible (M4)', () {
    test('bytes que no son UTF-8: se sigue con las muestras locales', () async {
      paquete = Uint8List.fromList([0xff, 0xfe, 0xfd, 0x80, 0x81]);
      await grabar('ADIOS');
      final d = await cargarDiccionario();
      expect(d.resumen.delPaquete, 0);
      expect(d.resumen.locales, 1);
      expect(d.clasificador.templates.map((t) => t.gloss).toSet(), {'ADIOS'});
    });

    test('JSON roto o que no es un objeto: tambien', () async {
      await grabar('ADIOS');
      for (final basura in ['{ esto no es json', '[1, 2, 3]']) {
        paquete = Uint8List.fromList(utf8.encode(basura));
        olvidarDiccionarioCompartido();
        final d = await cargarDiccionario();
        expect(d.resumen.delPaquete, 0, reason: basura);
        expect(d.resumen.locales, 1, reason: basura);
      }
    });
  });

  group('memoria de las plantillas', () {
    test('el espejo no guarda seq pero la devuelve igual que si la guardara',
        () {
      final original = Template('p1', 'HOLA', _seq(), espanol: 'hola');
      final espejo = Template.espejoDe('p1#espejo', original);
      final eager =
          Template('p1#espejo', 'HOLA', _seq().map(mirrorFrame).toList());

      expect(original.guardaSeq, isTrue);
      expect(espejo.guardaSeq, isFalse);
      expect(espejo.gloss, 'HOLA');
      expect(espejo.espanol, 'hola');
      expect(espejo.seq, eager.seq);
      expect(espejo.cseq, eager.cseq);
      expect(espejo.segs, eager.segs);
      expect(espejo.seq.every((f) => f is Float64List), isTrue);
    });

    test('segs y la firma son Float64List', () {
      final t = Template('p1', 'HOLA', _seq());
      expect(t.segs, hasLength(kNSegmentos));
      expect(t.segs.every((f) => f is Float64List), isTrue);
      expect(signature(_seq()), isA<Float64List>());
      expect(firmaSegmentos(const []).every((f) => f is Float64List), isTrue);
    });

    test('soloReproduccion guarda seq y nada del clasificador', () {
      final t = Template.soloReproduccion('a1', 'ZAPATOS', _seq(),
          espanol: 'zapatos');
      expect(t.seq, hasLength(kTFrames));
      expect(t.seq.every((f) => f is Float64List), isTrue);
      expect(t.cseq, isEmpty);
      expect(t.segs, isEmpty);
    });

    test('el clasificador con espejos ligeros decide igual que con espejos '
        'completos', () {
      final base = [
        PlantillaFuente('p1', 'HOLA', 'hola', _seq()),
        PlantillaFuente('p2', 'AGUA', 'agua', _seq(x: 0.2)),
      ];
      final ligero = armarClasificador(
          base: base,
          origenBase: OrigenPlantillas.paquete,
          locales: const [],
          espejar: true);
      final completo = DtwClassifier(prefilter: 80);
      for (final p in base) {
        completo.add(p.signId, p.gloss, p.seq);
        completo.add('${p.signId}#espejo', p.gloss,
            p.seq.map(mirrorFrame).toList());
      }
      for (final consulta in [_seq(), _seq(x: 0.2), _seq(x: 0.1)]) {
        final a = ligero.clasificador.rank(consulta);
        final b = completo.rank(consulta);
        expect(a.map((e) => (e.value.signId, e.key)).toList(),
            b.map((e) => (e.value.signId, e.key)).toList());
      }
    });
  });
}
