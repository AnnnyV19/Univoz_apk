import 'package:flutter/material.dart';

/// Encabezado morado con flecha de regreso, título "UNIVOZ" y logo.
/// Se reutiliza en Aprender, Comunicarse y Traducir señas.
class UnivozHeader extends StatelessWidget implements PreferredSizeWidget {
  final String? subtitle;

  const UnivozHeader({super.key, this.subtitle});

  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 70 : 92);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF6C63FF), Color(0xFF8B5CF6)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left,
                      color: Colors.white, size: 28),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const Text(
                  'UNIVOZ',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.favorite, color: Colors.pinkAccent),
                const SizedBox(width: 12),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(left: 20, bottom: 8),
                child: Text(
                  subtitle!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Botón rojo de SOS / Emergencia, presente en todas las pantallas
/// principales de la app.
class SosButton extends StatelessWidget {
  const SosButton({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: () {
          // TODO: activar flujo de emergencia (contacto de confianza,
          // ubicación, alerta visual/sonora según el perfil del usuario).
        },
        icon: const Icon(Icons.warning_amber_rounded, color: Colors.white),
        label: const Text(
          'SOS (Emergencia)',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w800,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE85D5D),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
      ),
    );
  }
}
