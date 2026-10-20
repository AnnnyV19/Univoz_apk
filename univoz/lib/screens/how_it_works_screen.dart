import 'package:flutter/material.dart';
import 'main_shell_screen.dart';
import '../services/blind_narrator.dart';

/// Pantalla "¿Cómo funciona?" — diseño morado con tarjetas por función.
///
/// Es una de las pantallas que se narran en voz alta para personas
/// ciegas (ver [BlindNarrator]), antes de que se elija un perfil.
class HowItWorksScreen extends StatefulWidget {
  const HowItWorksScreen({super.key});

  @override
  State<HowItWorksScreen> createState() => _HowItWorksScreenState();
}

class _HowItWorksScreenState extends State<HowItWorksScreen> {
  static const Color _bgColor = Color(0xFF5B3A8E);
  static const List<Color> _buttonGradient = [
    Color(0xFF6C63FF),
    Color(0xFFB84FCE),
  ];

  @override
  void initState() {
    super.initState();
    BlindNarrator.speak(
      'Cómo funciona Univoz. Aprender señas: diccionario visual de '
      'lengua de señas mexicana con animaciones tres D del avatar. '
      'Comunicarse: escribe o dicta texto y el avatar lo traduce a '
      'señas en tiempo real. Traducir señas: la cámara detecta tus '
      'señas y las convierte a texto o voz. Accesibilidad: diseñada '
      'para personas con discapacidad visual, auditiva o de '
      'comunicación. Toca Comenzar para continuar.',
    );
  }

  @override
  void dispose() {
    BlindNarrator.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              IconButton(
                icon: const Icon(Icons.chevron_left,
                    color: Colors.white, size: 32),
                tooltip: 'Regresar',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(height: 8),
              const Center(
                child: Text(
                  '¿Cómo funciona?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Center(
                child: Text(
                  'Descubre todo lo que puedes hacer',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    _buildFeatureCard(
                      icon: Icons.menu_book,
                      title: 'Aprender señas',
                      description:
                          'Diccionario visual de LSM con animaciones 3D '
                          'del avatar',
                    ),
                    _buildFeatureCard(
                      icon: Icons.chat_bubble_outline,
                      title: 'Comunicarse',
                      description:
                          'Escribe o dicta texto y el avatar lo traduce '
                          'a señas en tiempo real',
                    ),
                    _buildFeatureCard(
                      icon: Icons.camera_alt_outlined,
                      title: 'Traducir señas',
                      description:
                          'La cámara detecta tus señas y las convierte '
                          'a texto o voz',
                    ),
                    _buildFeatureCard(
                      icon: Icons.favorite_border,
                      title: 'Accesibilidad',
                      description:
                          'Diseñada para personas con discapacidad '
                          'visual, auditiva o de comunicación',
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      colors: _buttonGradient,
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    ),
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const MainShellScreen(),
                          ),
                        );
                      },
                      child: const Center(
                        child: Text(
                          'COMENZAR',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: const Color(0xFFE8E0F5),
            child: Icon(icon, color: const Color(0xFF6C63FF), size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF3A2A5C),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(
                    color: Color(0xFF6B6478),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
