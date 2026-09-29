import 'package:flutter/material.dart';
import 'screens/welcome_screen.dart';
import 'services/perfil_guardado.dart';

Future<void> main() async {
  // ensureInitialized antes de cualquier await: PerfilGuardado usa
  // path_provider, que es un plugin de plataforma y necesita el binding
  // listo. Sin esto revienta con "Binding has not yet been initialized".
  WidgetsFlutterBinding.ensureInitialized();
  // Se lee el perfil ANTES de runApp para que la primera pantalla ya sepa
  // si hay que preguntar quién eres o no. Es un archivo de pocos bytes:
  // no retrasa el arranque de forma perceptible.
  await PerfilGuardado.cargar();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WelcomeScreen(),
    );
  }
}
