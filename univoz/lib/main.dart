import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:senas_core/modo_desarrollador.dart';
import 'package:senas_core/registro_errores.dart';
import 'package:senas_core/sincronizador_plantillas.dart';
import 'package:senas_core/tema_univoz.dart';
import 'screens/welcome_screen.dart';
import 'services/perfil_guardado.dart';
import 'services/tutorial_visto.dart';

Future<void> main() async {
  // ensureInitialized antes de cualquier await: PerfilGuardado usa
  // path_provider, que es un plugin de plataforma y necesita el binding
  // listo. Sin esto revienta con "Binding has not yet been initialized".
  WidgetsFlutterBinding.ensureInitialized();
  // Errores no capturados -> <documentos>/errores.jsonl (solo local; se
  // comparte a mano desde Configuración con el modo desarrollador).
  RegistroErrores.instancia.instalarManejadores();
  // Se lee el perfil ANTES de runApp para que la primera pantalla ya sepa
  // si hay que preguntar quién eres o no. Es un archivo de pocos bytes:
  // no retrasa el arranque de forma perceptible.
  await PerfilGuardado.cargar();
  // Igual de pequeño: un bool en un archivo. Decide si Configuración y el
  // reconocedor muestran las herramientas de diagnóstico.
  await ModoDesarrollador.cargar();
  // Un archivo vacío: si ya se vio el tutorial de primer uso.
  await TutorialVisto.cargar();
  runApp(const MyApp());
  // Diccionario aprobado: se renueva solo si pasaron más de 24 h, sin
  // esperar a nadie. Un fallo (sin red) deja el que ya hay.
  unawaited(SincronizadorPlantillas.siCorresponde());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Univoz',
      debugShowCheckedModeBanner: false,
      theme: temaUnivoz(),
      darkTheme: temaUnivoz(brightness: Brightness.dark),
      // Claro fijo: el diseño de Lucía es claro y varias pantallas (tarjetas
      // de perfil, lección) todavía usan colores de marca fijos que no se
      // adaptan al modo oscuro del teléfono.
      themeMode: ThemeMode.light,
      // Todo es claro (fondo blanco): iconos del sistema oscuros. Las
      // pantallas con AppBar lo resuelven solas; esto cubre las que no.
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.dark,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const WelcomeScreen(),
    );
  }
}
