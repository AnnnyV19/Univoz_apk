import 'package:flutter/material.dart';
import 'purpose_screen.dart';
import 'how_it_works_screen.dart';
import 'profile_selection_screen.dart' show ProfileType;
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';

/// Pantalla de bienvenida de UNIVOZ.
///
/// Para usarla:
/// 1. Copia este archivo a lib/screens/welcome_screen.dart en tu proyecto.
/// 2. Agrega en pubspec.yaml (dentro de flutter: -> assets:):
///      - assets/images/logo_univoz.png
///      - assets/images/welcome_background.png
/// 3. Coloca esas dos imágenes en assets/images/.
/// 4. Navega a esta pantalla desde tu main.dart, por ejemplo:
///      home: const WelcomeScreen(),
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
  // Paleta de colores usada en el diseño
  static const Color _bgColor = Color(0xFF0D0A16);
  static const Color _accentYellow = Color(0xFFE8C547);
  static const Color _grayText = Color(0xFF9B96A8);
  static const List<Color> _buttonGradient = [
    Color(0xFF6C63FF),
    Color(0xFFB84FCE),
  ];

  @override
  void initState() {
    super.initState();
    if (BlindNarrator.isTalkBackOn) {
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
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const PurposeScreen()),
      );
    }
    // Si tras varios intentos no se reconoce nada (o no hay permiso de
    // micrófono), nos quedamos en esta pantalla: los botones táctiles
    // (COMENZAR / ¿Cómo funciona?) siguen funcionando normalmente.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Stack(
          children: [
            // ---------- Ilustración de fondo (siluetas) ----------
            // Si aún no tienes la imagen, comenta este Positioned
            // y la pantalla se verá igual pero sin la ilustración.
            Positioned(
              top: 180,
              left: 0,
              right: 0,
              height: 320,
              child: Opacity(
                opacity: 0.35,
                child: Image.asset(
                  'assets/images/welcome_background.png',
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) =>
                      const SizedBox.shrink(),
                ),
              ),
            ),

            // ---------- Contenido principal ----------
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 24),

                  // ---- Logo + nombre ----
                  Row(
                    children: [
                      // Ícono del logo (manos formando corazón)
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Image.asset(
                          'assets/images/logo_univoz.png',
                          errorBuilder: (context, error, stackTrace) =>
                              const Icon(
                            Icons.favorite,
                            color: _accentYellow,
                            size: 40,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      _buildLogoText(),
                    ],
                  ),

                  const SizedBox(height: 40),

                  // ---- Subtítulo "Comunicación sin barreras" ----
                  Align(
                    alignment: Alignment.centerRight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          'Comunicación',
                          style: TextStyle(
                            color: _grayText,
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'sin barreras',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 20,
                            fontStyle: FontStyle.italic,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ---- Frase principal ----
                  RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        height: 1.15,
                      ),
                      children: [
                        const TextSpan(text: 'Tu voz importa'),
                        TextSpan(
                          text: ',',
                          style: TextStyle(color: _accentYellow),
                        ),
                        const TextSpan(text: '\nsin importar cómo la expreses'),
                        TextSpan(
                          text: '.',
                          style: TextStyle(color: _accentYellow),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // ---- Botón "COMENZAR" ----
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: LinearGradient(
                          colors: _buttonGradient,
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _avanzarPorToque(() {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const PurposeScreen(),
                              ),
                            );
                          }),
                          child: const Center(
                            child: Text(
                              'COMENZAR',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                fontStyle: FontStyle.italic,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),

                  // ---- Botón "¿Cómo funciona?" ----
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton(
                      onPressed: () => _avanzarPorToque(() {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const HowItWorksScreen(),
                          ),
                        );
                      }),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: const Color(0xFF241D33),
                        side: const BorderSide(color: Color(0xFF3A3050)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        '¿Cómo funciona?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ---- Texto de accesibilidad ----
                  Text(
                    'UNIVOZ incluye modo de voz automático diseñado '
                    'para personas con discapacidad visual',
                    style: TextStyle(
                      color: _grayText,
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),

                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Construye el texto "UNIVOZ" con colores individuales por letra,
  /// simulando el degradado del logo.
  Widget _buildLogoText() {
    return Row(
      children: const [
        Text('UNI', style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
        Text('V', style: TextStyle(color: Color(0xFFE8C547), fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
        Text('O', style: TextStyle(color: Color(0xFF4FC3E8), fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
        Text('Z', style: TextStyle(color: Color(0xFF6C63FF), fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: 1)),
      ],
    );
  }
}
