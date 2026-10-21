import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/camera_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> emitir(String canal, int t) async {
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      canal,
      codec.encodeSuccessEnvelope({'t': t}),
      (_) {},
    );
  }

  setUp(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel(kCanalMetodos), (call) async {
      if (call.method == 'iniciar') {
        return {'textureId': 1, 'espejo': false, 'ancho': 480, 'alto': 640};
      }
      return null;
    });
    for (final canal in [kCanalEventos, kCanalEventosPreview]) {
      messenger.setMockMethodCallHandler(MethodChannel(canal), (call) async {
        return null; // listen / cancel
      });
    }
  });

  test('tras voltear la camara los mismos suscriptores siguen recibiendo',
      () async {
    final puente = CameraBridge();
    final preview = <int>[];
    final fusionados = <int>[];
    final subP = puente.framesPreview.listen((f) => preview.add(f.timestampMs));
    final subF = puente.frames.listen((f) => fusionados.add(f.timestampMs));
    await Future<void>.delayed(Duration.zero);

    await emitir(kCanalEventosPreview, 1);
    await emitir(kCanalEventos, 1);

    // Voltear: detener + iniciar. Los controladores nuevos piden los
    // streams otra vez (reiniciar -> iniciar).
    await puente.detener();
    await puente.iniciar(frontal: false);
    final subP2 =
        puente.framesPreview.listen((f) => preview.add(f.timestampMs + 1000));
    await Future<void>.delayed(Duration.zero);

    await emitir(kCanalEventosPreview, 2);
    await emitir(kCanalEventos, 2);

    // El suscriptor de antes (avatar) sigue vivo y el nuevo tambien.
    expect(preview, containsAll([1, 2, 1002]));
    expect(fusionados, [1, 2]);
    await subP.cancel();
    await subP2.cancel();
    await subF.cancel();
  });
}
