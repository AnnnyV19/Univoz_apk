import 'package:flutter/material.dart';
import 'purpose_screen.dart';
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
              const SizedBox(height: 16),
              // Sin desplazar y con poco texto: cada función es un dibujo
              // con su nombre. La explicación completa la dice la voz (ver
              // initState) y TalkBack.
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildFeatureCard(
                              ilustracion: 'aprender',
                              title: 'Aprender',
                              description: 'Aprender señas: diccionario '
                                  'visual de LSM con animaciones 3D del '
                                  'avatar',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildFeatureCard(
                              ilustracion: 'comunicarse',
                              title: 'Comunicarse',
                              description: 'Comunicarse: escribe o dicta '
                                  'texto y el avatar lo traduce a señas en '
                                  'tiempo real',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildFeatureCard(
                              ilustracion: 'traducir',
                              title: 'Traducir',
                              description: 'Traducir señas: la cámara '
                                  'detecta tus señas y las convierte a '
                                  'texto o voz',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildFeatureCard(
                              ilustracion: 'accesibilidad',
                              title: 'Para todos',
                              description: 'Accesibilidad: diseñada para '
                                  'personas con discapacidad visual, '
                                  'auditiva o de comunicación',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
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
                            // Al menú de ¿para qué quieres usar Univoz?, no directo a
                            // Aprender.
                            builder: (_) => const PurposeScreen(),
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
    required String ilustracion,
    required String title,
    required String description,
  }) {
    final colores = Theme.of(context).colorScheme;
    return Semantics(
      label: description,
      excludeSemantics: true,
      child: TarjetaUnivoz(
        margen: EdgeInsets.zero,
        relleno: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: Column(
          children: [
            Expanded(
              child: Image.asset(
                'assets/ilustraciones/$ilustracion.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title,
                maxLines: 1,
                style: TextStyle(
                  color: colores.onSurface,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
