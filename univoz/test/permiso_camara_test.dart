import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:univoz/services/permiso_camara.dart';

class _Falso implements AdaptadorPermisoCamara {
  _Falso(this.inicial, {this.trasPedir = EstadoPermisoCamara.concedido});

  EstadoPermisoCamara inicial;
  EstadoPermisoCamara trasPedir;
  int pedidos = 0;
  int ajustesAbiertos = 0;

  @override
  Future<EstadoPermisoCamara> estado() async => inicial;

  @override
  Future<EstadoPermisoCamara> pedir() async {
    pedidos++;
    return trasPedir;
  }

  @override
  Future<void> abrirAjustes() async => ajustesAbiertos++;
}

void main() {
  late bool? resultado;

  Future<void> montar(WidgetTester tester, _Falso falso) async {
    resultado = null;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => resultado =
                  await pedirPermisoCamara(context, adaptador: falso),
              child: const Text('abrir'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
  }

  const explicacion = 'Univoz usa la cámara para ver tus manos y tu cuerpo. '
      'El video nunca sale de tu teléfono.';

  testWidgets('ya concedido: true sin mostrar nada', (tester) async {
    final falso = _Falso(EstadoPermisoCamara.concedido);
    await montar(tester, falso);
    expect(resultado, isTrue);
    expect(find.text(explicacion), findsNothing);
    expect(falso.pedidos, 0);
  });

  testWidgets('sin pedir antes: explica, Continuar pide y devuelve true',
      (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegado);
    await montar(tester, falso);
    expect(find.text(explicacion), findsOneWidget);
    expect(falso.pedidos, 0);
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(falso.pedidos, 1);
    expect(resultado, isTrue);
  });

  testWidgets('Ahora no: false y no se pide el permiso', (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegado);
    await montar(tester, falso);
    await tester.tap(find.text('Ahora no'));
    await tester.pumpAndSettle();
    expect(falso.pedidos, 0);
    expect(resultado, isFalse);
  });

  testWidgets('Continuar pero el sistema niega: false con aviso',
      (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegado,
        trasPedir: EstadoPermisoCamara.denegado);
    await montar(tester, falso);
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(resultado, isFalse);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('negado para siempre: dialogo con Abrir ajustes', (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegadoPermanente);
    await montar(tester, falso);
    expect(find.text(explicacion), findsNothing);
    expect(find.text('Abrir ajustes'), findsOneWidget);
    await tester.tap(find.text('Abrir ajustes'));
    await tester.pumpAndSettle();
    expect(falso.ajustesAbiertos, 1);
    expect(falso.pedidos, 0);
    expect(resultado, isFalse);
  });

  testWidgets('negado para siempre y Ahora no: no abre ajustes',
      (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegadoPermanente);
    await montar(tester, falso);
    await tester.tap(find.text('Ahora no'));
    await tester.pumpAndSettle();
    expect(falso.ajustesAbiertos, 0);
    expect(resultado, isFalse);
  });

  testWidgets('el sistema niega para siempre al pedir: ofrece ajustes',
      (tester) async {
    final falso = _Falso(EstadoPermisoCamara.denegado,
        trasPedir: EstadoPermisoCamara.denegadoPermanente);
    await montar(tester, falso);
    await tester.tap(find.text('Continuar'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir ajustes'), findsOneWidget);
    await tester.tap(find.text('Abrir ajustes'));
    await tester.pumpAndSettle();
    expect(falso.ajustesAbiertos, 1);
    expect(resultado, isFalse);
  });
}
