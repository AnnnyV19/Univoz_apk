import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/camera_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Un solo canal: cada evento lleva la marca `fusionado`.
  Future<void> emitir(int t, {bool fusionado = true}) async {
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      kCanalEventos,
      codec.encodeSuccessEnvelope({'t': t, 'fusionado': fusionado}),
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
    messenger.setMockMethodCallHandler(const MethodChannel(kCanalEventos),
        (call) async {
      return null; // listen / cancel
    });
  });

  test('tras voltear la camara los mismos suscriptores siguen recibiendo',
      () async {
    final puente = CameraBridge();
    final preview = <int>[];
    final fusionados = <int>[];
    final subP = puente.framesPreview.listen((f) => preview.add(f.timestampMs));
    final subF = puente.frames.listen((f) => fusionados.add(f.timestampMs));
    await Future<void>.delayed(Duration.zero);

    await emitir(1);

    // Voltear: detener + iniciar. Los controladores nuevos piden los
    // streams otra vez (reiniciar -> iniciar).
    await puente.detener();
    await puente.iniciar(frontal: false);
    final subP2 =
        puente.framesPreview.listen((f) => preview.add(f.timestampMs + 1000));
    await Future<void>.delayed(Duration.zero);

    await emitir(2);

    // El suscriptor de antes (avatar) sigue vivo y el nuevo tambien.
    expect(preview, containsAll([1, 2, 1002]));
    expect(fusionados, [1, 2]);
    await subP.cancel();
    await subP2.cancel();
    await subF.cancel();
  });

  test('un evento nativo se reparte: preview recibe todos, frames solo fusionados',
      () async {
    final puente = CameraBridge();
    final preview = <LandmarkFrame>[];
    final fusionados = <LandmarkFrame>[];
    final subP = puente.framesPreview.listen(preview.add);
    final subF = puente.frames.listen(fusionados.add);
    await Future<void>.delayed(Duration.zero);

    await emitir(1);
    await emitir(2, fusionado: false);
    await emitir(3);

    expect(preview.map((f) => f.timestampMs), [1, 2, 3]);
    expect(fusionados.map((f) => f.timestampMs), [1, 3]);
    // Misma decodificacion: ambos consumidores reciben el MISMO objeto.
    expect(identical(preview.first, fusionados.first), isTrue);
    expect(preview[1].fusionado, isFalse);
    await subP.cancel();
    await subF.cancel();
  });

  test('los errores nativos solo los ve frames, no framesPreview', () async {
    final puente = CameraBridge();
    final erroresP = <Object>[];
    final erroresF = <Object>[];
    final subP = puente.framesPreview.listen((_) {}, onError: erroresP.add);
    final subF = puente.frames.listen((_) {}, onError: erroresF.add);
    await Future<void>.delayed(Duration.zero);

    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      kCanalEventos,
      codec.encodeErrorEnvelope(code: 'mediapipe', message: 'x'),
      (_) {},
    );

    expect(erroresF, hasLength(1));
    expect(erroresP, isEmpty);
    await subP.cancel();
    await subF.cancel();
  });
}
