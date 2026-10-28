import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/tema_univoz.dart';
import 'package:univoz/screens/sos.dart';
import 'package:univoz/screens/traducir_senas_screen.dart';
import 'package:univoz/screens/univoz_shared_widgets.dart';
import 'package:univoz/services/contacto_emergencia.dart';
import 'package:univoz/services/conversation_profile.dart';
import 'package:univoz/services/perfil_guardado.dart';
import 'package:univoz/services/perfiles.dart';
import 'package:univoz/services/voz.dart';

class _LanzadorFalso implements LanzadorUrl {
  final List<Uri> abiertos = [];
  bool resultado = true;

  @override
  Future<bool> abrir(Uri uri) async {
    abiertos.add(uri);
    return resultado;
  }
}

class _LectorFalso implements LectorVoz {
  final List<String> dichos = [];
  int detenciones = 0;
  VoidCallback? alTerminar;

  @override
  Future<void> hablar(String texto, {required VoidCallback alTerminar}) async {
    dichos.add(texto);
    this.alTerminar = alTerminar;
  }

  @override
  Future<void> detener() async => detenciones++;
}

void main() {
  late _LanzadorFalso lanzador;
  late _LectorFalso lector;

  setUp(() {
    // Sin disco: lo guardado vive solo en memoria durante la prueba.
    PerfilGuardado.directorioParaPruebas =
        () async => throw const FileSystemException('sin disco');
    PerfilGuardado.restablecerParaPruebas();
    ConversationProfile.reset();
    ConversationProfile.mine = ProfileType.sordo;
    lanzador = _LanzadorFalso();
    lector = _LectorFalso();
  });

  tearDown(() {
    PerfilGuardado.directorioParaPruebas = null;
    PerfilGuardado.restablecerParaPruebas();
    ConversationProfile.reset();
  });

  Widget app(Widget home) => MaterialApp(theme: temaUnivoz(), home: home);

  Widget conBoton() => app(Scaffold(
        body: Center(child: SosButton(lanzador: lanzador, lector: lector)),
      ));

  const mensaje = 'Necesito ayuda. Soy una persona sorda. Por favor, '
      'escríbeme o háblame de frente y despacio.';
  const mensajeCiego = 'Necesito ayuda. Soy una persona ciega. Por favor, '
      'dime quién eres y qué está pasando, y avísame antes de tocarme.';

  group('SosButton', () {
    testWidgets('un toque solo muestra la pista', (tester) async {
      await tester.pumpWidget(conBoton());
      await tester.tap(find.text('SOS'));
      await tester.pump();
      expect(find.text('Mantén presionado para SOS'), findsWidgets);
      expect(find.byType(PantallaSos), findsNothing);
    });

    testWidgets('mantenerlo presionado 0.8 s abre PantallaSos', (tester) async {
      await tester.pumpWidget(conBoton());
      final gesto = await tester
          .startGesture(tester.getCenter(find.text('SOS')));
      // El toque se confirma tras kPressTimeout (100 ms).
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 300));
      // A mitad de camino se ve el anillo y todavía no se abrió nada.
      expect(find.byKey(const ValueKey('anillo-sos')), findsOneWidget);
      expect(find.byType(PantallaSos), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaSos), findsOneWidget);
      await gesto.up();
      await tester.pumpAndSettle();
      // Soltar después de abrir no cuenta como toque: sin pista encima.
      expect(find.text('Mantén presionado para SOS'), findsNothing);
    });

    testWidgets('soltar antes de tiempo no abre y avisa cómo se usa',
        (tester) async {
      await tester.pumpWidget(conBoton());
      final gesto = await tester
          .startGesture(tester.getCenter(find.text('SOS')));
      await tester.pump(const Duration(milliseconds: 300));
      await gesto.up();
      await tester.pumpAndSettle();
      expect(find.byType(PantallaSos), findsNothing);
      expect(find.text('Mantén presionado para SOS'), findsWidgets);
      expect(find.byKey(const ValueKey('anillo-sos')), findsNothing);
    });

    testWidgets('con "quitar animaciones" sigue pidiendo los 0.8 s',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await tester.pumpWidget(conBoton());
      final gesto = await tester
          .startGesture(tester.getCenter(find.text('SOS')));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PantallaSos), findsNothing);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaSos), findsOneWidget);
      await gesto.up();
      await tester.pumpAndSettle();
    });

    testWidgets('el lector de pantalla puede abrirlo con su acción',
        (tester) async {
      final semantica = tester.ensureSemantics();
      await tester.pumpWidget(conBoton());
      tester.semantics.longPress(find.semantics.byLabel('SOS, emergencia'));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaSos), findsOneWidget);
      semantica.dispose();
    });
  });

  group('PantallaSos', () {
    Widget pantalla() => app(PantallaSos(lanzador: lanzador, lector: lector));

    testWidgets('sin contacto ofrece configurarlo (y sigue el 911)',
        (tester) async {
      await tester.pumpWidget(pantalla());
      expect(find.text(mensaje), findsOneWidget);
      expect(find.text('Configurar contacto de emergencia'), findsOneWidget);
      expect(find.textContaining('Llamar a '), findsNothing);
      expect(find.text('Llamar al 911'), findsOneWidget);
      expect(find.text('Leer en voz alta'), findsOneWidget);
    });

    testWidgets('con contacto: llamar y SMS arman tel: y sms:', (tester) async {
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '+525512345678'));
      await tester.pumpWidget(pantalla());
      expect(find.text('Configurar contacto de emergencia'), findsNothing);

      await tester.tap(find.text('Llamar a Mamá'));
      await tester.pump();
      expect(lanzador.abiertos.single.toString(), 'tel:+525512345678');

      await tester.tap(find.text('Enviar SMS a Mamá'));
      await tester.pump();
      final sms = lanzador.abiertos.last;
      expect(sms.scheme, 'sms');
      expect(sms.path, '+525512345678');
      expect(sms.queryParameters['body'],
          'Necesito ayuda. Te escribo desde Univoz.');
    });

    testWidgets('el 911 pide confirmar antes de llamar', (tester) async {
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Llamar al 911'));
      await tester.pumpAndSettle();
      expect(find.text('¿Llamar al 911?'), findsOneWidget);
      expect(lanzador.abiertos, isEmpty);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(lanzador.abiertos, isEmpty);

      await tester.tap(find.text('Llamar al 911'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Llamar'));
      await tester.pumpAndSettle();
      expect(lanzador.abiertos.single.toString(), 'tel:911');
    });

    testWidgets('incluye el nombre del perfil en el mensaje', (tester) async {
      await PerfilGuardado.guardar(ProfileType.sordo, true);
      await PerfilGuardado.guardarNombre('Ana');
      await tester.pumpWidget(pantalla());
      expect(
          find.text('Necesito ayuda. Me llamo Ana. Soy una persona sorda. '
              'Por favor, escríbeme o háblame de frente y despacio.'),
          findsOneWidget);
    });

    testWidgets('el SMS lleva el nombre de la dueña', (tester) async {
      await PerfilGuardado.guardar(ProfileType.sordo, false);
      await PerfilGuardado.guardarNombre('Ana');
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Enviar SMS a Mamá'));
      await tester.pump();
      expect(lanzador.abiertos.single.queryParameters['body'],
          'Soy Ana, necesito ayuda. Te escribo desde Univoz.');
    });

    testWidgets('con el celular prestado no sale el nombre de la dueña',
        (tester) async {
      await PerfilGuardado.guardar(ProfileType.sordo, true);
      await PerfilGuardado.guardarNombre('Ana');
      ConversationProfile.mine = ProfileType.ciego;
      await tester.pumpWidget(pantalla());
      expect(find.text(mensajeCiego), findsOneWidget);
    });

    testWidgets(
        'prestado con el MISMO perfil que la dueña: tampoco sale '
        'su nombre ni su mensaje propio', (tester) async {
      await PerfilGuardado.guardar(ProfileType.sordo, true);
      await PerfilGuardado.guardarNombre('Ana');
      await PerfilGuardado.guardarMensajeSos(
          mencionarCondicion: false, personalizado: 'Mensaje de Ana');
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      ConversationProfile.mine = ProfileType.sordo;
      ConversationProfile.prestado = true;
      await tester.pumpWidget(pantalla());
      expect(find.text(mensaje), findsOneWidget);
      await tester.tap(find.text('Enviar SMS a Mamá'));
      await tester.pump();
      expect(lanzador.abiertos.single.queryParameters['body'],
          'Te escribo desde el teléfono de Ana con Univoz: la persona que lo '
          'está usando necesita ayuda.');
    });

    testWidgets('prestado y sin nombre de la dueña: SMS sin nombre',
        (tester) async {
      await PerfilGuardado.guardar(ProfileType.sordo, true);
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      ConversationProfile.prestado = true;
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Enviar SMS a Mamá'));
      await tester.pump();
      expect(lanzador.abiertos.single.queryParameters['body'],
          'Te escribo con Univoz desde un teléfono prestado: la persona que '
          'lo está usando necesita ayuda.');
    });

    testWidgets('leer en voz alta alterna con Detener', (tester) async {
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Leer en voz alta'));
      await tester.pump();
      expect(lector.dichos, [mensaje]);
      expect(find.text('Detener'), findsOneWidget);

      await tester.tap(find.text('Detener'));
      await tester.pump();
      expect(lector.detenciones, greaterThan(0));
      expect(find.text('Leer en voz alta'), findsOneWidget);
    });

    testWidgets('si no abre la llamada avisa con un mensaje humano',
        (tester) async {
      lanzador.resultado = false;
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Llamar a Mamá'));
      await tester.pump();
      expect(find.textContaining('No pude abrir el teléfono'), findsOneWidget);
    });

    testWidgets('configurar contacto desde la pantalla lo muestra al volver',
        (tester) async {
      await tester.pumpWidget(pantalla());
      await tester.tap(find.text('Configurar contacto de emergencia'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('campo-nombre-contacto')), 'Papá');
      await tester.enterText(
          find.byKey(const ValueKey('campo-telefono-contacto')),
          '55 1234 5678');
      await tester.tap(find.text('Guardar contacto'));
      await tester.pumpAndSettle();
      expect(find.text('Llamar a Papá'), findsOneWidget);
      expect(PerfilGuardado.contactoEmergencia?.telefono, '5512345678');
    });
  });

  group('PantallaContactoEmergencia', () {
    testWidgets('valida nombre y teléfono antes de guardar', (tester) async {
      await tester.pumpWidget(app(const PantallaContactoEmergencia()));
      await tester.tap(find.text('Guardar contacto'));
      await tester.pump();
      expect(find.text('Escribe el nombre de tu contacto.'), findsOneWidget);
      expect(find.text('Escribe el teléfono de tu contacto.'), findsOneWidget);

      await tester.enterText(
          find.byKey(const ValueKey('campo-nombre-contacto')), 'Mamá');
      await tester.enterText(
          find.byKey(const ValueKey('campo-telefono-contacto')), '123');
      await tester.tap(find.text('Guardar contacto'));
      await tester.pump();
      expect(find.textContaining('Revisa el número'), findsOneWidget);
      expect(PerfilGuardado.contactoEmergencia, isNull);
    });
  });

  group('Acceso desde Configuración', () {
    testWidgets('la tarjeta abre el formulario del contacto', (tester) async {
      await tester.pumpWidget(app(const TraducirSenasScreen()));
      await tester.scrollUntilVisible(find.text('Contacto de emergencia'), 200);
      await tester.tap(find.text('Contacto de emergencia'));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaContactoEmergencia), findsOneWidget);
    });
  });

  group('mensajeSos', () {
    test('cada perfil dice cómo ayudarle, con el texto exacto', () {
      expect(
          mensajeSos(tipo: ProfileType.sordo),
          'Necesito ayuda. Soy una persona sorda. Por favor, escríbeme o '
          'háblame de frente y despacio.');
      expect(
          mensajeSos(tipo: ProfileType.mudo),
          'Necesito ayuda. Te escucho bien, pero me comunico por escrito. '
          'Por favor, lee mi pantalla.');
      expect(
          mensajeSos(tipo: ProfileType.ciego),
          'Necesito ayuda. Soy una persona ciega. Por favor, dime quién '
          'eres y qué está pasando, y avísame antes de tocarme.');
      for (final t in [ProfileType.oyente, ProfileType.prestarCelular, null]) {
        expect(mensajeSos(tipo: t),
            'Necesito ayuda. Por favor, llama a emergencias o a mi contacto.');
      }
    });

    test('quien sabe LSM lo dice (solo el perfil sordo)', () {
      expect(
          mensajeSos(tipo: ProfileType.sordo, sabeLsm: true),
          'Necesito ayuda. Soy una persona sorda. Por favor, escríbeme o '
          'háblame de frente y despacio. Me comunico en Lengua de Señas '
          'Mexicana.');
      expect(mensajeSos(tipo: ProfileType.mudo, sabeLsm: true),
          mensajeSos(tipo: ProfileType.mudo));
    });

    test('el nombre va justo después de "Necesito ayuda."', () {
      expect(
          mensajeSos(tipo: ProfileType.mudo, nombre: ' Ana '),
          'Necesito ayuda. Me llamo Ana. Te escucho bien, pero me comunico '
          'por escrito. Por favor, lee mi pantalla.');
      expect(mensajeSos(nombre: '  '),
          'Necesito ayuda. Por favor, llama a emergencias o a mi contacto.');
    });

    test('sin mencionar la condición sale el texto neutro, con nombre', () {
      expect(
          mensajeSos(
              tipo: ProfileType.sordo,
              sabeLsm: true,
              nombre: 'Ana',
              mencionarCondicion: false),
          'Necesito ayuda. Me llamo Ana. Por favor, llama a emergencias o a '
          'mi contacto.');
    });

    test('SMS al contacto', () {
      expect(mensajeSmsContacto('Ana'),
          'Soy Ana, necesito ayuda. Te escribo desde Univoz.');
      expect(
          mensajeSmsContacto(null), 'Necesito ayuda. Te escribo desde Univoz.');
      expect(
          mensajeSmsContacto('  '), 'Necesito ayuda. Te escribo desde Univoz.');
    });

    test('SMS desde un teléfono prestado', () {
      expect(
          mensajeSmsPrestado('Ana'),
          'Te escribo desde el teléfono de Ana con Univoz: la persona que lo '
          'está usando necesita ayuda.');
      expect(
          mensajeSmsPrestado(null),
          'Te escribo con Univoz desde un teléfono prestado: la persona que '
          'lo está usando necesita ayuda.');
      expect(mensajeSmsPrestado('  '), mensajeSmsPrestado(null));
    });
  });

  group('mensajeSosActual', () {
    test('usa si la persona usa LSM (la de quien tiene el teléfono)', () {
      ConversationProfile.mineKnowsLsm = true;
      expect(mensajeSosActual(),
          endsWith('Me comunico en Lengua de Señas Mexicana.'));
    });

    test('el interruptor de condición y el mensaje propio se respetan',
        () async {
      await PerfilGuardado.guardar(ProfileType.sordo, false);
      await PerfilGuardado.guardarNombre('Ana');
      await PerfilGuardado.guardarMensajeSos(mencionarCondicion: false);
      expect(
          mensajeSosActual(),
          'Necesito ayuda. Me llamo Ana. Por favor, llama a emergencias o a '
          'mi contacto.');

      await PerfilGuardado.guardarMensajeSos(
          mencionarCondicion: false, personalizado: '  Estoy herida.  ');
      expect(mensajeSosActual(), 'Estoy herida.');

      // Restaurar: vacío vuelve al sugerido.
      await PerfilGuardado.guardarMensajeSos(
          mencionarCondicion: true, personalizado: '');
      expect(mensajeSosActual(), contains('Soy una persona sorda.'));
    });
  });

  group('Mensaje de emergencia en el formulario', () {
    testWidgets('vista previa en vivo, guardar y restaurar', (tester) async {
      await tester.pumpWidget(app(const PantallaContactoEmergencia()));
      await tester.scrollUntilVisible(
          find.byKey(const ValueKey('vista-previa-sos')), 300,
          scrollable: find.byType(Scrollable).first);
      String previa() => tester
          .widget<Text>(find.byKey(const ValueKey('texto-vista-previa')))
          .data!;
      expect(previa(), mensaje);

      await tester
          .ensureVisible(find.byKey(const ValueKey('interruptor-condicion')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('interruptor-condicion')));
      await tester.pumpAndSettle();
      expect(previa(),
          'Necesito ayuda. Por favor, llama a emergencias o a mi contacto.');
      expect(PerfilGuardado.mencionarCondicion, isFalse);

      await tester.enterText(
          find.byKey(const ValueKey('campo-mensaje-sos')), 'Estoy herida.');
      await tester.pump();
      expect(previa(), 'Estoy herida.');

      await tester.ensureVisible(find.text('Guardar mensaje'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar mensaje'));
      await tester.pumpAndSettle();
      expect(PerfilGuardado.mensajeSosPersonalizado, 'Estoy herida.');

      // El aviso va en línea: no es un SnackBar que tape "Restaurar".
      expect(find.text('Mensaje guardado.'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.ensureVisible(find.text('Restaurar mensaje sugerido'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restaurar mensaje sugerido'));
      await tester.pumpAndSettle();
      expect(PerfilGuardado.mensajeSosPersonalizado, isNull);
      expect(previa(),
          'Necesito ayuda. Por favor, llama a emergencias o a mi contacto.');
    });

    testWidgets('"Guardar contacto" guarda también el mensaje escrito',
        (tester) async {
      await tester.pumpWidget(app(const PantallaContactoEmergencia()));
      await tester.enterText(
          find.byKey(const ValueKey('campo-nombre-contacto')), 'Mamá');
      await tester.enterText(
          find.byKey(const ValueKey('campo-telefono-contacto')), '5512345678');
      await tester.enterText(
          find.byKey(const ValueKey('campo-mensaje-sos')), 'Estoy herida.');
      await tester.tap(find.text('Guardar contacto'));
      await tester.pumpAndSettle();
      expect(PerfilGuardado.contactoEmergencia?.nombre, 'Mamá');
      expect(PerfilGuardado.mensajeSosPersonalizado, 'Estoy herida.');
    });

    testWidgets('atrás con un mensaje sin guardar pregunta antes de salir',
        (tester) async {
      await tester.pumpWidget(app(Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const PantallaContactoEmergencia())),
                  child: const Text('abrir'),
                ),
              ))));
      Future<void> abrirYEscribir() async {
        await tester.tap(find.text('abrir'));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const ValueKey('campo-mensaje-sos')), 'Estoy herida.');
        await tester.pump();
      }

      // Seguir editando (tocar fuera) no sale ni guarda.
      await abrirYEscribir();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('¿Guardar tu mensaje?'), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaContactoEmergencia), findsOneWidget);
      expect(PerfilGuardado.mensajeSosPersonalizado, isNull);

      // No guardar: sale y no guarda.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('No guardar'));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaContactoEmergencia), findsNothing);
      expect(PerfilGuardado.mensajeSosPersonalizado, isNull);

      // Guardar: sale y guarda.
      await abrirYEscribir();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar'));
      await tester.pumpAndSettle();
      expect(find.byType(PantallaContactoEmergencia), findsNothing);
      expect(PerfilGuardado.mensajeSosPersonalizado, 'Estoy herida.');
    });

    testWidgets('sin cambios, atrás sale sin preguntar', (tester) async {
      await tester.pumpWidget(app(Builder(
          builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const PantallaContactoEmergencia())),
                  child: const Text('abrir'),
                ),
              ))));
      await tester.tap(find.text('abrir'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PantallaContactoEmergencia), findsNothing);
    });

    testWidgets('el mensaje propio se corta a 280 caracteres', (tester) async {
      await tester.pumpWidget(app(const PantallaContactoEmergencia()));
      await tester.enterText(
          find.byKey(const ValueKey('campo-mensaje-sos')), 'a' * 400);
      final campo = tester.widget<TextField>(find.descendant(
          of: find.byKey(const ValueKey('campo-mensaje-sos')),
          matching: find.byType(TextField)));
      expect(campo.controller!.text.length, PerfilGuardado.kMaxMensajeSos);
    });
  });

  group('ContactoEmergencia', () {
    test('normaliza el teléfono', () {
      expect(ContactoEmergencia.normalizarTelefono('(55) 1234-5678'),
          '5512345678');
      expect(ContactoEmergencia.normalizarTelefono('+52 55 1234 5678'),
          '+525512345678');
      expect(ContactoEmergencia.normalizarTelefono('55a1234'), isNull);
      expect(ContactoEmergencia.normalizarTelefono('5+5123456'), isNull);
    });

    test('rechaza números muy cortos o muy largos', () {
      expect(ContactoEmergencia.validarTelefono('123456'), isNotNull);
      expect(ContactoEmergencia.validarTelefono('1234567'), isNull);
      expect(ContactoEmergencia.validarTelefono('1234567890123456'), isNotNull);
    });

    test('rechaza nombre vacío o demasiado largo', () {
      expect(ContactoEmergencia.validarNombre('   '), isNotNull);
      expect(ContactoEmergencia.validarNombre('a' * 31), isNotNull);
      expect(ContactoEmergencia.validarNombre('Ana'), isNull);
    });
  });

  group('PerfilGuardado con contacto', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('perfil_guardado_test');
      PerfilGuardado.directorioParaPruebas = () async => tmp;
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('guardar y volver a abrir la app conserva el contacto', () async {
      await PerfilGuardado.guardar(ProfileType.sordo, true);
      await PerfilGuardado.guardarNombre('Ana');
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '+525512345678'));
      PerfilGuardado.restablecerParaPruebas();
      expect(PerfilGuardado.contactoEmergencia, isNull);

      await PerfilGuardado.cargar();
      expect(PerfilGuardado.tipo, ProfileType.sordo);
      expect(PerfilGuardado.sabeLsm, isTrue);
      expect(PerfilGuardado.nombre, 'Ana');
      expect(PerfilGuardado.contactoEmergencia,
          const ContactoEmergencia(nombre: 'Mamá', telefono: '+525512345678'));
    });

    test('el contacto se guarda aunque no haya perfil, y no pisa al perfil',
        () async {
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      PerfilGuardado.restablecerParaPruebas();
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.hayPerfil, isFalse);
      expect(PerfilGuardado.contactoEmergencia?.nombre, 'Mamá');
    });

    test('un archivo viejo sin contacto carga con contacto null', () async {
      await File('${tmp.path}/perfil_usuario.json').writeAsString(
          '{"v":1,"tipo":"sordo","sabe_lsm":true,"nombre":"Ana"}');
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.hayPerfil, isTrue);
      expect(PerfilGuardado.nombre, 'Ana');
      expect(PerfilGuardado.contactoEmergencia, isNull);
    });

    test('las preferencias del mensaje de SOS se guardan y se leen', () async {
      await PerfilGuardado.guardarMensajeSos(
          mencionarCondicion: false, personalizado: 'Estoy herida.');
      PerfilGuardado.restablecerParaPruebas();
      expect(PerfilGuardado.mencionarCondicion, isTrue);
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.mencionarCondicion, isFalse);
      expect(PerfilGuardado.mensajeSosPersonalizado, 'Estoy herida.');

      // Volver a los valores por defecto sin perfil ni contacto borra el
      // archivo.
      await PerfilGuardado.guardarMensajeSos(mencionarCondicion: true);
      expect(File('${tmp.path}/perfil_usuario.json').existsSync(), isFalse);
    });

    test('un archivo viejo sin los campos nuevos usa los valores por defecto',
        () async {
      expect(File('${tmp.path}/perfil_usuario.json').existsSync(), isFalse);
      await File('${tmp.path}/perfil_usuario.json')
          .writeAsString('{"v":1,"tipo":"sordo","sabe_lsm":true,'
              '"contacto":{"nombre":"Mamá","telefono":"5512345678"}}');
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.mencionarCondicion, isTrue);
      expect(PerfilGuardado.mensajeSosPersonalizado, isNull);
      expect(PerfilGuardado.contactoEmergencia?.nombre, 'Mamá');
    });

    test('quitar el contacto lo borra del archivo', () async {
      await PerfilGuardado.guardarContacto(
          const ContactoEmergencia(nombre: 'Mamá', telefono: '5512345678'));
      await PerfilGuardado.guardarContacto(null);
      PerfilGuardado.restablecerParaPruebas();
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.contactoEmergencia, isNull);
    });

    test('un contacto roto en el archivo se ignora sin tumbar el perfil',
        () async {
      await File('${tmp.path}/perfil_usuario.json').writeAsString(
          '{"v":1,"tipo":"sordo","sabe_lsm":false,"contacto":{"nombre":"X","telefono":"abc"}}');
      await PerfilGuardado.cargar();
      expect(PerfilGuardado.hayPerfil, isTrue);
      expect(PerfilGuardado.contactoEmergencia, isNull);
    });
  });
}
