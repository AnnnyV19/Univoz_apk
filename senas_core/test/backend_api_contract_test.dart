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
            contains('no está disponible'),
            isNot(contains('SQLSTATE')),
          ),
        ),
      ),
    );
    api.cerrar();
  });
}
