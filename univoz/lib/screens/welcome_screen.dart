import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'purpose_screen.dart';
import 'tutorial_screen.dart';
import '../services/tutorial_visto.dart';
import 'how_it_works_screen.dart';
import 'profile_selection_screen.dart' show ProfileType;
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';
import '../services/perfil_guardado.dart';
import 'package:senas_core/tema_univoz.dart';

/// Pantalla de bienvenida de UNIVOZ.
///
/// Imágenes: assets/images/logo_univoz_recortado.png y
/// assets/images/fondo_bienvenida.jpg (ilustración que dio la dueña).
///
/// Es la primera pantalla, así que aquí se decide el modo de
/// accesibilidad para toda la sesión (ver [BlindNarrator]): si detecta
/// TalkBack activo, hace una pregunta por voz y espera una respuesta
/// hablada ("comenzar" o "sal"); si no, se queda en silencio y funciona
/// de forma completamente táctil, igual que antes.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  static const Color _moradoNoche = Color(0xFF3B0C61);
  static const Color _rosa = Color(0xFFF7B6D6);

  @override
  void initState() {
    super.initState();
    // Con un perfil guardado que no es "ciego" no se activa la voz para
    // ciegos: algunos teléfonos reportan "navegación accesible" con otros
    // servicios de accesibilidad (no solo TalkBack) y la app le hablaba a
    // personas oyentes.
    final perfilNoCiego =
        PerfilGuardado.hayPerfil && PerfilGuardado.tipo != ProfileType.ciego;
    if (BlindNarrator.isTalkBackOn && !perfilNoCiego) {
      BlindNarrator.activateTalkBackFlow();
      // Reiniciamos el perfil de conversación aquí porque esta es la
      // primera pantalla de una sesión nueva: si alguien ya había usado
      // la app antes (sin cerrarla del todo) y probó otra combinación
      // de perfiles, no queremos que queden pegados el perfil o las
      // respuestas de "¿conoces LSM?" de esa vez anterior.
      ConversationProfile.reset();
      // El perfil propio queda preasignado como "ciego" en cuanto se
      // detecta TalkBack, así no hace falta pasar por la cuadrícula de
      // selección de perfil (ver ProfileSelectionScreen).
      ConversationProfile.mine = ProfileType.ciego;
      _runTalkBackFlow();
    }
    // Si no hay TalkBack, no decimos nada: la app se queda en silencio
    // hasta que alguien confirme manualmente el perfil "ciego" en la
    // pantalla de selección de perfil.
  }

  @override
  void dispose() {
    BlindNarrator.stop();
    super.dispose();
  }

  /// Avanza tocando la pantalla (COMENZAR o ¿Cómo funciona?) mientras la
  /// pregunta por voz de [_runTalkBackFlow] todavía podía estar
  /// esperando una respuesta hablada: corta esa pregunta en seco (y
  /// evita que, si llega a reconocer algo tarde, navegue por su cuenta
  /// encima de donde el toque ya nos llevó) antes de seguir.
  Future<void> _avanzarPorToque(VoidCallback navegar) async {
    await BlindNarrator.interruptFlow();
    if (!mounted) return;
    navegar();
  }

  Future<void> _runTalkBackFlow() async {
    final int flow = BlindNarrator.beginFlow();
    bool isCurrent() => mounted && BlindNarrator.isCurrentFlow(flow);

    // Antes de la primera pregunta real, calibramos el reconocimiento de
    // voz con el ruido del lugar (ver BlindNarrator.calibrateIfNeeded).
    // Es la primera vez que se usa el micrófono en toda la sesión, así
    // que es el mejor lugar para hacerlo una sola vez.
    await BlindNarrator.calibrateIfNeeded();
    if (!isCurrent()) return;

    final command = await BlindNarrator.askUntil(
      'Detectamos TalkBack. ¿Quieres continuar con la experiencia '
      'personalizada para personas ciegas? Di comenzar para continuar, '
      'o sal para cerrar la app.',
      accepted: [VoiceCommand.start, VoiceCommand.yes],
      retryPrompt:
          'No entendí. Di comenzar para continuar, o sal para cerrar '
          'la app.',
      isCancelled: () => !isCurrent(),
    );
    if (!isCurrent()) return;
    if (command == VoiceCommand.exit) {
      BlindNarrator.exitApp();
      return;
    }
    if (command == VoiceCommand.start || command == VoiceCommand.yes) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PurposeScreen()),
      );
    }
    // Si tras varios intentos no se reconoce nada (o no hay permiso de
    // micrófono), nos quedamos en esta pantalla: los botones táctiles
    // (COMENZAR / ¿Cómo funciona?) siguen funcionando normalmente.
  }

  /// "Comenzar": la primera vez, el tutorial con dibujos (él lleva luego al
  /// menú); después, directo al menú.
  void _comenzar() => _avanzarPorToque(() {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => TutorialVisto.visto
                ? const PurposeScreen()
                : const TutorialScreen(),
          ),
        );
      });

  @override
  Widget build(BuildContext context) {
    // Diseño elegido por la dueña (2026-10-28): el acomodo de la propuesta
    // "Amanecer lila" con los tonos de "Noche morada" — degradado morado,
    // dos manchas de luz, la ilustración de fondo en gris muy tenue, el logo
    // grande al centro, la frase y dos botones.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _moradoNoche,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(0, -0.8),
                  radius: 1.25,
                  colors: [Color(0xFF9B45E0), ColoresUnivoz.morado, _moradoNoche],
                  stops: [0, 0.35, 1],
                ),
              ),
            ),
            // Ilustración de fondo: en gris y casi transparente, para que
            // se adivine sin competir con el texto.
            Opacity(
              opacity: 0.16,
              child: ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  0.33, 0.33, 0.33, 0, 0, //
                  0.33, 0.33, 0.33, 0, 0, //
                  0.33, 0.33, 0.33, 0, 0, //
                  0, 0, 0, 1, 0,
                ]),
                child: Image.asset(
                  'assets/images/fondo_bienvenida.jpg',
                  fit: BoxFit.cover,
                  alignment: const Alignment(-0.08, 0),
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ),
            const Positioned(
              top: 140,
              left: -70,
              child: _ManchaDeLuz(color: Color(0x59C9A2F0), tamano: 240),
            ),
            const Positioned(
              top: 300,
              right: -60,
              child: _ManchaDeLuz(color: Color(0x40F7B6D6), tamano: 220),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Spacer(flex: 2),
                    // Logo grande y el nombre.
                    Semantics(
                      label: 'Univoz',
                      excludeSemantics: true,
                      child: Column(
                        children: [
                          SizedBox(
                            height: 96,
                            child: Image.asset(
                              'assets/images/logo_univoz_recortado.png',
                              errorBuilder: (_, __, ___) => const Icon(
                                Icons.favorite,
                                color: Colors.white,
                                size: 72,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'UNIVOZ',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(flex: 3),
                    // Frase principal.
                    RichText(
                      text: const TextSpan(
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          height: 1.12,
                          letterSpacing: -0.4,
                        ),
                        children: [
                          TextSpan(text: 'Tu voz importa'),
                          TextSpan(
                            text: ',',
                            style: TextStyle(color: _rosa),
                          ),
                          TextSpan(text: '\nsin importar cómo la expreses'),
                          TextSpan(
                            text: '.',
                            style: TextStyle(color: _rosa),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Señas · voz · texto',
                      semanticsLabel: 'Señas, voz y texto. UNIVOZ incluye '
                          'modo de voz automático diseñado para personas con '
                          'discapacidad visual.',
                      style: TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(flex: 2),
                    SizedBox(
                      height: 56,
                      child: FilledButton(
                        onPressed: _comenzar,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: ColoresUnivoz.moradoOscuro,
                          elevation: 6,
                          shadowColor: Colors.black38,
                          shape: const StadiumBorder(),
                        ),
                        child: const Text(
                          'Comenzar',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 52,
                      child: TextButton(
                        onPressed: () => _avanzarPorToque(() {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const HowItWorksScreen(),
                            ),
                          );
                        }),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          shape: const StadiumBorder(),
                        ),
                        child: const Text(
                          '¿Cómo funciona?',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mancha de luz difusa del fondo.
class _ManchaDeLuz extends StatelessWidget {
  const _ManchaDeLuz({required this.color, required this.tamano});

  final Color color;
  final double tamano;

  @override
  Widget build(BuildContext context) {
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 46, sigmaY: 46),
      child: Container(
        width: tamano,
        height: tamano,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}
