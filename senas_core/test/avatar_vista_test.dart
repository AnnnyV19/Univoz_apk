import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/avatar_vista.dart';

void main() {
  late AvatarBridge bridge;

  setUp(() => bridge = AvatarBridge.sinVisor());
  tearDown(() => bridge.dispose());

  Future<void> montar(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: VistaAvatar(
              bridge: bridge,
              vista:
                  const ColoredBox(key: Key('visor'), color: Color(0xFF00FF00)),
            ),
          ),
        ),
      ));

  testWidgets('cargando tapa el visor pero lo deja montado', (tester) async {
    await montar(tester);
    expect(find.byKey(const Key('visor')), findsOneWidget);
    expect(find.byKey(const ValueKey(EstadoAvatar.cargando)), findsOneWidget);
    expect(find.bySemanticsLabel('Avatar 3D, cargando'), findsOneWidget);
    expect(find.text('Reintentar'), findsNothing);
  });

  testWidgets('listo funde el placeholder y deja solo el visor',
      (tester) async {
    await montar(tester);
    bridge.estado.value = EstadoAvatar.listo;
    await tester.pump();
    // Durante el fundido el placeholder sigue encima.
    expect(find.byKey(const ValueKey(EstadoAvatar.cargando)), findsOneWidget);
    await tester.pump(VistaAvatar.duracionFundido * 2);
    expect(find.byKey(const ValueKey(EstadoAvatar.cargando)), findsNothing);
    expect(find.byKey(const Key('visor')), findsOneWidget);
    expect(find.bySemanticsLabel('Avatar 3D'), findsOneWidget);
  });

  testWidgets('error muestra tarjeta y Reintentar vuelve a cargando',
      (tester) async {
    await montar(tester);
    bridge.estado.value = EstadoAvatar.error;
    await tester.pump(VistaAvatar.duracionFundido);
    expect(find.text('No se pudo mostrar el avatar.'), findsOneWidget);
    expect(find.bySemanticsLabel('Avatar 3D no disponible'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pump();
    expect(bridge.estado.value, EstadoAvatar.cargando);
    expect(find.byKey(const Key('visor')), findsOneWidget);
    // Reintentar rearma el limite de carga dentro del reloj falso.
    bridge.dispose();
  });

  testWidgets('el WebView no es alcanzable por TalkBack hasta estar listo',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: VistaAvatar(
        bridge: bridge,
        vista: Semantics(
            container: true,
            label: 'pagina del visor',
            child: const SizedBox()),
      ),
    ));
    expect(find.bySemanticsLabel('pagina del visor'), findsNothing);
    bridge.estado.value = EstadoAvatar.listo;
    await tester.pump(VistaAvatar.duracionFundido * 2);
    expect(find.bySemanticsLabel('pagina del visor'), findsOneWidget);
  });
}
