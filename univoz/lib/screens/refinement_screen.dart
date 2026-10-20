import 'package:flutter/material.dart';
import 'profile_selection_screen.dart';
import 'other_person_profile_screen.dart';

/// Pantalla de refinamiento genérica: se usa para las 4 opciones
/// (ciego, sordo, mudo, prestar celular). Muestra un título/subtítulo
/// y una lista de opciones tipo radio button según el perfil elegido.
///
/// El texto exacto para "sordo" viene de tu mockup (LSM). Los demás son
/// placeholders en [refinementConfigs] (ver profile_selection_screen.dart)
/// que puedes editar cuando tengas el diseño definitivo de cada uno.
class RefinementScreen extends StatefulWidget {
  final ProfileType profile;

  const RefinementScreen({super.key, required this.profile});

  @override
  State<RefinementScreen> createState() => _RefinementScreenState();
}

class _RefinementScreenState extends State<RefinementScreen> {
  int? _selectedIndex;

  static const Color _bgColor = Color(0xFFF7F2FA);
  static const Color _grayText = Color(0xFF6B6478);
  static const Color _comenzarColor = Color(0xFF8F84A6);
  static const Color _radioCardColor = Color(0xFF241B35);
  static const Color _radioAccent = Color(0xFFB388E8);

  @override
  Widget build(BuildContext context) {
    final config = profileConfigs[widget.profile]!;
    final refinement = refinementConfigs[widget.profile]!;

    return Scaffold(
      backgroundColor: _bgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 32),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const Icon(Icons.favorite, color: Color(0xFFB84FCE)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                refinement.title,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                refinement.subtitle,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _grayText,
                ),
              ),
              const SizedBox(height: 24),

              // ---- Tarjeta de contexto (perfil elegido) ----
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: config.cardColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: config.iconBgColor,
                      child:
                          Icon(config.icon, size: 20, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            config.title,
                            style: TextStyle(
                              color: config.textColor,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            config.subtitle,
                            style: TextStyle(
                              color: config.textColor.withValues(alpha: 0.85),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // ---- Tarjeta con opciones tipo radio ----
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    vertical: 14, horizontal: 16),
                decoration: BoxDecoration(
                  color: _radioCardColor,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  children: List.generate(refinement.options.length, (i) {
                    final bool isSelected = _selectedIndex == i;
                    return Padding(
                      padding: EdgeInsets.only(
                        bottom: i == refinement.options.length - 1 ? 0 : 12,
                      ),
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedIndex = i),
                        child: Row(
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _radioAccent,
                                  width: 2,
                                ),
                                color: isSelected
                                    ? _radioAccent
                                    : Colors.transparent,
                              ),
                              child: isSelected
                                  ? const Icon(Icons.circle,
                                      size: 8, color: Colors.white)
                                  : null,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                refinement.options[i],
                                style: TextStyle(
                                  color: isSelected
                                      ? _radioAccent
                                      : Colors.white70,
                                  fontWeight: isSelected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),

              const Spacer(),

              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _selectedIndex != null
                      ? () {
                          // El propósito (comunicarme vs. aprender LSM) ya se
                          // preguntó en PurposeScreen antes de llegar aquí, así
                          // que seguimos con el flujo de comunicación sin
                          // importar la respuesta de refinamiento.
                          // TODO: guardar refinement.options[_selectedIndex!]
                          // en el estado/perfil del usuario.
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  const OtherPersonProfileScreen(),
                            ),
                          );
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _comenzarColor,
                    disabledBackgroundColor: _comenzarColor.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Text(
                    'Comenzar ahora',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
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
}
