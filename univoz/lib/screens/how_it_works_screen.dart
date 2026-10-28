import 'package:flutter/material.dart';
import 'main_shell_screen.dart';
import '../services/blind_narrator.dart';
import 'package:senas_core/componentes_univoz.dart';
import 'package:senas_core/tema_univoz.dart';

/// Pantalla "¿Cómo funciona?": tarjetas por función con el diseño de
/// Lucía (fondo blanco, tarjetas con borde).
///
/// Es una de las pantallas que se narran en voz alta para personas
/// ciegas (ver [BlindNarrator]), antes de que se elija un perfil.
class HowItWorksScreen extends StatefulWidget {
  const HowItWorksScreen({super.key});

  @override
  State<HowItWorksScreen> createState() => _HowItWorksScreenState();
}

class _HowItWorksScreenState extends State<HowItWorksScreen> {
  static const List<Color> _buttonGradient = [
    ColoresUnivoz.morado,
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
    final colores = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              IconButton(
                icon: Icon(Icons.chevron_left,
                    color: colores.onSurface, size: 32),
                tooltip: 'Regresar',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  '¿Cómo funciona?',
                  style: TextStyle(
                    color: colores.onSurface,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  'Descubre todo lo que puedes hacer',
                  style: TextStyle(
                    color: colores.onSurfaceVariant,
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
    final colores = Theme.of(context).colorScheme;
    return TarjetaUnivoz(
      margen: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconoCaja(icon, tamano: 40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colores.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: colores.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.35,
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
