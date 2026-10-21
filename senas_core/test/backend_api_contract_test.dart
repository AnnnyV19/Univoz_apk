import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:senas_core/backend_api.dart';
import 'package:senas_core/supabase_api.dart';

void main() {
  test('BackendPrediction lee respuesta estable de inferencia', () {
    final result = BackendPrediction.fromJson({
      'label': 'CASA',
      'confidence': 0.94,
      'classifier': 'svm',
      'model_version': 'svm-v2',
    });

    expect(result.label, 'CASA');
    expect(result.confidence, closeTo(0.94, 1e-12));
    expect(result.classifier, 'svm');
    expect(result.toJson()['model_version'], 'svm-v2');
  });

  test('BackendPrediction permite rechazo sin etiqueta', () {
    final result = BackendPrediction.fromJson({
      'label': null,
      'confidence': 0,
      'classifier': 'knn',
      'model_version': 'baseline-v2',
    });

    expect(result.label, isNull);
    expect(result.confidence, 0);
  });

  test('Supabase no expone cuerpo interno en errores HTTP', () async {
    final api = SupabaseApi(
      url: 'https://example.test',
      clave: 'publishable-test',
      cliente: MockClient((_) async => http.Response(
            'SQLSTATE=42501 internal policy detail',
            500,
          )),
    );

    final future = api.probar();
    await expectLater(
      future,
      throwsA(
        isA<SupabaseError>().having(
          (e) => e.mensaje,
          'mensaje',
          allOf(
            contains('El servidor tuvo un problema. Inténtalo más tarde.'),
            isNot(contains('SQLSTATE')),
          ),
        ),
      ),
    );
    api.cerrar();
  });

  test('Supabase: mensajes humanos para permisos y falta de red', () async {
    SupabaseApi con(MockClient c) =>
        SupabaseApi(url: 'https://example.test', clave: 'k', cliente: c);

    final sinPermiso =
        con(MockClient((_) async => http.Response('RLS violation', 403)));
    await expectLater(
      sinPermiso.probar(),
      throwsA(isA<SupabaseError>().having((e) => e.mensajeHumano, 'humano',
          'No tienes permiso para esta acción.')),
    );

    final sinRed =
        con(MockClient((_) async => throw http.ClientException('reset')));
    await expectLater(
      sinRed.descargarPlantillas(),
      throwsA(isA<SupabaseError>().having((e) => e.mensajeHumano, 'humano',
          'Sin conexión. Revisa tu internet e inténtalo de nuevo.')),
    );
  });

  test('Supabase: una subida (POST) no se reintenta', () async {
    var llamadas = 0;
    final api = SupabaseApi(
      url: 'https://example.test',
      clave: 'k',
      cliente: MockClient((_) async {
        llamadas++;
        throw http.ClientException('reset');
      }),
    );
    await expectLater(
      api.subirLandmarksCrudos(
          bucket: 'b', objectPath: 'raw/x.json.gz', gzipBytes: Uint8List(3)),
      throwsA(isA<SupabaseError>()),
    );
    expect(llamadas, 1);
  });

  test('BackendApi: error HTTP sin cuerpo y mensaje humano', () async {
    final api = BackendApi(
      url: 'http://lan.test:8000',
      client: MockClient((_) async => http.Response('traza interna', 500)),
    );
    final seq = List.generate(32, (_) => List<double>.filled(152, 0.0));
    await expectLater(
      api.clasificar(seq),
      throwsA(isA<BackendError>()
          .having((e) => e.toString(), 'tecnico', isNot(contains('traza')))
          .having((e) => e.mensajeHumano, 'humano',
              'El servidor tuvo un problema. Inténtalo más tarde.')),
    );
  });

  test('subirMuestra: id generado en el cliente y return=minimal (RLS)',
      () async {
    final pedidos = <http.Request>[];
    final api = SupabaseApi(
      url: 'https://example.test',
      clave: 'k',
      cliente: MockClient((r) async {
        pedidos.add(r);
        if (r.method == 'GET') return http.Response('[{"id":"sid-1"}]', 200);
        return http.Response('', 201);
      }),
    );
    final seq = List.generate(32, (_) => List<double>.filled(152, 0.0));
    final devuelto = await api.subirMuestra(
        gloss: 'HOLA', espanol: 'hola', seq: seq, nFramesOrig: 40);

    final muestra =
        pedidos.firstWhere((r) => r.url.path.endsWith('/sign_samples'));
    expect(muestra.headers['Prefer'], 'return=minimal');
    final cuerpo = jsonDecode(muestra.body) as Map<String, dynamic>;
    expect(cuerpo['id'], devuelto);
    expect(cuerpo['id'], matches(RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(cuerpo['estado'], 'pendiente');

    final lm =
        pedidos.firstWhere((r) => r.url.path.endsWith('/sample_landmarks'));
    expect((jsonDecode(lm.body) as Map)['sample_id'], devuelto);
    api.cerrar();
  });
}
