import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/registro_errores.dart';

class _Contador extends RegistroErrores {
  _Contador(Directory dir) : super(directorio: () async => dir);
  int volcados = 0;

  @override
  Future<void> volcar() {
    volcados++;
    return super.volcar();
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('instalarManejadores es idempotente: un solo observador', () async {
    final dir = Directory.systemTemp.createTempSync('errores_inst_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final antesFlutter = FlutterError.onError;
    final antesPlataforma = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = antesFlutter;
      PlatformDispatcher.instance.onError = antesPlataforma;
    });
    final registro = _Contador(dir);
    registro.instalarManejadores();
    final onError = FlutterError.onError;
    registro.instalarManejadores();
    expect(FlutterError.onError, same(onError));

    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(registro.volcados, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
