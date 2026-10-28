import 'package:flutter/material.dart';
import 'package:senas_core/tema_univoz.dart';

import '../services/tutorial_visto.dart';
import 'purpose_screen.dart';

/// Tutorial de primer uso: pocas pantallas, un dibujo grande y dos o tres
/// palabras cada una (no todas las personas leen el español con soltura).
/// La frase completa de cada paso es la que lee TalkBack. Se ve una sola vez
/// (TutorialVisto); "Saltar" también cuenta como visto.
class TutorialScreen extends StatefulWidget {
  const TutorialScreen({super.key});

  @override
  State<TutorialScreen> createState() => _TutorialScreenState();
}

class _Paso {
  const _Paso(this.titulo, this.pista, this.lector,
      {this.ilustracion, this.icono, this.colorIcono});

  final String titulo;
  final String pista;
  final String lector;
  final String? ilustracion;
  final IconData? icono;
  final Color? colorIcono;
}

const List<_Paso> _pasos = [
  _Paso('Comunicarte', 'Elige con quién hablas',
      'Comunicarte: eliges tu perfil y el de la otra persona, y la app '
          'traduce entre voz, texto y señas.',
      ilustracion: 'comunicarse'),
  _Paso('Traducir señas', 'La cámara lee tu seña',
      'Traducir una seña: la cámara mira tu seña y la convierte en texto '
          'y voz.',
      ilustracion: 'traducir'),
  _Paso('Aprender LSM', 'Lecciones cortas',
      'Aprender LSM: lecciones cortas con el avatar, a tu ritmo.',
      ilustracion: 'aprender'),
  _Paso('SOS', 'Mantén presionado',
      'SOS: mantén presionado el botón rojo para pedir ayuda.',
      icono: Icons.warning_amber_rounded, colorIcono: Color(0xFFDC2626)),
  _Paso('Ajustes', 'Toca la tuerca',
      'Ajustes: toca la tuerca de arriba para cambiar la cámara, la voz y '
          'el reconocimiento.',
      icono: Icons.settings_outlined, colorIcono: ColoresUnivoz.morado),
];

class _TutorialScreenState extends State<TutorialScreen> {
  int _i = 0;

  void _terminar() {
    TutorialVisto.marcar();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PurposeScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final paso = _pasos[_i];
    final ultimo = _i == _pasos.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _terminar,
                  child: const Text('Saltar'),
                ),
              ),
              Expanded(
                child: Semantics(
                  label: paso.lector,
                  excludeSemantics: true,
                  liveRegion: true,
                  child: Column(
                    children: [
                      Expanded(
                        child: paso.ilustracion != null
                            ? Image.asset(
                                'assets/ilustraciones/${paso.ilustracion}.png',
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    const SizedBox.shrink(),
                              )
                            : FittedBox(
                                child: Container(
                                  padding: const EdgeInsets.all(28),
                                  decoration: BoxDecoration(
                                    color: (paso.colorIcono ?? colores.primary)
                                        .withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(paso.icono,
                                      size: 96, color: paso.colorIcono),
                                ),
                              ),
                      ),
                      const SizedBox(height: 16),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          paso.titulo,
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: colores.onSurface,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          paso.pista,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: colores.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // Puntos: en qué paso vas.
              ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var k = 0; k < _pasos.length; k++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: k == _i ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: k == _i
                              ? colores.primary
                              : colores.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  if (_i > 0) ...[
                    SizedBox(
                      height: 56,
                      width: 56,
                      child: OutlinedButton(
                        onPressed: () => setState(() => _i--),
                        style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.zero),
                        child: const Icon(Icons.chevron_left,
                            semanticLabel: 'Anterior'),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        onPressed: ultimo
                            ? _terminar
                            : () => setState(() => _i++),
                        child: Text(
                          ultimo ? 'Empezar' : 'Siguiente',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
