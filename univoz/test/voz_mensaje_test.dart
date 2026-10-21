import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/tema_univoz.dart';
import 'package:univoz/screens/sos.dart' show aperturasSos;
import 'package:univoz/screens/voz_mensaje.dart';
import 'package:univoz/services/permiso_camara.dart';
import 'package:univoz/services/voz.dart';

class _LectorFalso implements LectorVoz {
  final List<String> dichos = [];
  int detenciones = 0;
  VoidCallback? alTerminar;
  bool falla = false;

  @override
  Future<void> hablar(String texto, {required VoidCallback alTerminar}) async {
    if (falla) throw StateError('sin motor');
    dichos.add(texto);
    this.alTerminar = alTerminar;
  }

  @override
  Future<void> detener() async => detenciones++;
}

class _DictadoFalso implements DictadoVoz {
  bool disponible = true;
  int preparaciones = 0;
  bool escuchando = false;
  void Function(String, bool)? alTexto;
  void Function(double)? alNivel;
  void Function(bool)? alTerminar;

  @override
  Future<bool> preparar() async {
    preparaciones++;
    return disponible;
  }

  @override
  Future<void> escuchar({
    required void Function(String texto, bool esFinal) alTexto,
    required void Function(double nivel) alNivel,
    required void Function(bool huboError) alTerminar,
  }) async {
    escuchando = true;
    this.alTexto = alTexto;
    this.alNivel = alNivel;
    this.alTerminar = alTerminar;
  }

  @override
  Future<void> detener() async {
    escuchando = false;
  }
}

class _PermisoFalso implements AdaptadorPermiso {
  _PermisoFalso(this.estadoInicial);
  EstadoPermiso estadoInicial;

  @override
  Future<EstadoPermiso> estado() async => estadoInicial;
  @override
  Future<EstadoPermiso> pedir() async => estadoInicial;
  @override
  Future<void> abrirAjustes() async {}
}

void main() {
  late TextEditingController controlador;
  late _LectorFalso lector;
  late _DictadoFalso dictado;

  setUp(() {
    controlador = TextEditingController();
    lector = _LectorFalso();
    dictado = _DictadoFalso();
  });

  tearDown(() => controlador.dispose());

  Future<void> montar(WidgetTester tester,
      {EstadoPermiso permiso = EstadoPermiso.concedido}) async {
    await tester.pumpWidget(MaterialApp(
      theme: temaUnivoz(),
      home: Scaffold(
        body: ControlesVozMensaje(
          controlador: controlador,
          lector: lector,
          dictado: dictado,
          permisos: _PermisoFalso(permiso),
        ),
      ),
    ));
  }

  ElevatedButton botonLeer(WidgetTester tester) =>
      tester.widget<ElevatedButton>(find.ancestor(
          of: find.text('Leer en voz alta'),
          matching: find.byType(ElevatedButton)));

  group('Leer en voz alta', () {
    testWidgets('sin texto está deshabilitado', (tester) async {
      await montar(tester);
      expect(botonLeer(tester).onPressed, isNull);
    });

    testWidgets('con texto lee y alterna con Detener', (tester) async {
      await montar(tester);
      controlador.text = 'Hola, ¿cómo estás?';
      await tester.pump();
      await tester.tap(find.text('Leer en voz alta'));
      await tester.pump();
      expect(lector.dichos, ['Hola, ¿cómo estás?']);
      expect(find.text('Detener'), findsOneWidget);

      await tester.tap(find.text('Detener'));
      await tester.pump();
      expect(lector.detenciones, 1);
      expect(find.text('Leer en voz alta'), findsOneWidget);
    });

    testWidgets('cuando termina de leer vuelve el botón', (tester) async {
      await montar(tester);
      controlador.text = 'Hola';
      await tester.pump();
      await tester.tap(find.text('Leer en voz alta'));
      await tester.pump();
      lector.alTerminar!();
      await tester.pump();
      expect(find.text('Leer en voz alta'), findsOneWidget);
    });

    testWidgets('si falla el motor avisa con un mensaje humano',
        (tester) async {
      await montar(tester);
      lector.falla = true;
      controlador.text = 'Hola';
      await tester.pump();
      await tester.tap(find.text('Leer en voz alta'));
      await tester.pump();
      expect(find.textContaining('No pude leer tu mensaje'), findsOneWidget);
      expect(find.text('Leer en voz alta'), findsOneWidget);
    });
  });

  group('Dictar con voz', () {
    testWidgets('los parciales entran al campo, después de lo ya escrito',
        (tester) async {
      await montar(tester);
      controlador.text = 'Hola';
      await tester.tap(find.text('Dictar con voz'));
      await tester.pump();
      expect(find.text('Escuchando...'), findsOneWidget);
      expect(find.byKey(const ValueKey('indicador-nivel')), findsOneWidget);

      dictado.alTexto!('quiero', false);
      expect(controlador.text, 'Hola quiero');
      dictado.alTexto!('quiero agua', false);
      expect(controlador.text, 'Hola quiero agua');
      dictado.alNivel!(0.8);
      await tester.pump();

      dictado.alTexto!('quiero agua', true);
      dictado.alTerminar!(false);
      await tester.pump();
      expect(controlador.text, 'Hola quiero agua');
      expect(find.text('Dictar con voz'), findsOneWidget);
      expect(find.byKey(const ValueKey('indicador-nivel')), findsNothing);
    });

    testWidgets('abrir SOS corta el dictado y la lectura', (tester) async {
      await montar(tester);
      controlador.text = 'Hola';
      await tester.pump();
      await tester.tap(find.text('Leer en voz alta'));
      await tester.pump();
      expect(find.text('Detener'), findsOneWidget);
      aperturasSos.value++;
      await tester.pump();
      expect(find.text('Leer en voz alta'), findsOneWidget);
      expect(lector.detenciones, 1);

      await tester.tap(find.text('Dictar con voz'));
      await tester.pump();
      expect(dictado.escuchando, isTrue);
      aperturasSos.value++;
      await tester.pump();
      expect(dictado.escuchando, isFalse);
      expect(find.text('Dictar con voz'), findsOneWidget);
    });

    testWidgets('un segundo toque deja de dictar', (tester) async {
      await montar(tester);
      await tester.tap(find.text('Dictar con voz'));
      await tester.pump();
      await tester.tap(find.text('Escuchando...'));
      await tester.pump();
      expect(dictado.escuchando, isFalse);
      expect(find.text('Dictar con voz'), findsOneWidget);
    });

    testWidgets('si termina con error avisa con un mensaje humano',
        (tester) async {
      await montar(tester);
      await tester.tap(find.text('Dictar con voz'));
      await tester.pump();
      dictado.alTerminar!(true);
      await tester.pump();
      expect(
          find.text('No pude escucharte. Inténtalo de nuevo.'), findsOneWidget);
      expect(find.text('Dictar con voz'), findsOneWidget);
    });

    testWidgets('sin permiso del micrófono no escucha', (tester) async {
      await montar(tester, permiso: EstadoPermiso.denegado);
      await tester.tap(find.text('Dictar con voz'));
      await tester.pumpAndSettle();
      expect(find.text('Permiso de micrófono'), findsOneWidget);
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(dictado.preparaciones, 0);
      expect(dictado.escuchando, isFalse);
    });

    testWidgets('si el teléfono no puede dictar, se deshabilita con tooltip',
        (tester) async {
      dictado.disponible = false;
      await montar(tester);
      await tester.tap(find.text('Dictar con voz'));
      await tester.pump();
      final boton = tester.widget<OutlinedButton>(find.ancestor(
          of: find.text('Dictar con voz'),
          matching: find.byType(OutlinedButton)));
      expect(boton.onPressed, isNull);
      expect(find.byTooltip('Tu teléfono no puede dictar por voz'),
          findsOneWidget);
    });
  });
}
