import 'package:flutter/material.dart';

import '../services/conversation_profile.dart';
import '../services/perfil_guardado.dart';
import '../services/perfiles.dart';
import 'profile_selection_screen.dart';
import 'qr_perfil.dart';

enum _AccionPerfil { miCodigo, cambiar, prestar }

/// Chip con el perfil de quien está usando la app y un menú para
/// cambiarlo. Se usa en la barra morada de [UnivozHeader] y también en
/// las barras simples del onboarding (¿con quién te vas a comunicar?),
/// que no usan ese encabezado.
///
/// Muestra [ConversationProfile.mine], no el perfil guardado en disco: si
/// el teléfono está prestado los dos difieren, y lo honesto es mostrar el
/// que está en uso. Cuando difieren se marca como "Prestado".
class MenuPerfil extends StatefulWidget {
  /// true sobre la barra morada (texto blanco), false sobre el fondo
  /// claro del onboarding (texto oscuro).
  final bool sobreFondoOscuro;

  /// Se llama al volver de cambiar el perfil. La pantalla que lo use
  /// tiene que redibujarse: por ejemplo, los perfiles que se pueden
  /// elegir para la otra persona dependen del propio (ver
  /// `_selectableProfiles` en OtherPersonProfileScreen).
  final VoidCallback? onCambio;

  const MenuPerfil({
    super.key,
    this.sobreFondoOscuro = false,
    this.onCambio,
  });

  @override
  State<MenuPerfil> createState() => _MenuPerfilState();
}

class _MenuPerfilState extends State<MenuPerfil> {
  void _alElegir(_AccionPerfil accion) {
    switch (accion) {
      case _AccionPerfil.miCodigo:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const MostrarMiCodigoScreen()),
        );
        break;
      case _AccionPerfil.cambiar:
        _abrir(ModoSeleccionPerfil.editar);
        break;
      case _AccionPerfil.prestar:
        _abrir(ModoSeleccionPerfil.prestado);
        break;
    }
  }

  Future<void> _abrir(ModoSeleccionPerfil modo) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProfileSelectionScreen(modo: modo)),
    );
    if (!mounted) return;
    setState(() {});
    widget.onCambio?.call();
  }

  @override
  Widget build(BuildContext context) {
    // ConversationProfile.mine es el perfil EN USO; cae a null mientras
    // se está eligiendo uno nuevo (ProfileSelectionScreen.initState llama
    // a reset). En ese hueco mostramos el guardado, para que el chip no
    // desaparezca de la barra al entrar y salir de esa pantalla.
    final bool enUso = ConversationProfile.mine != null;
    final ProfileType? tipo =
        enUso ? ConversationProfile.mine : PerfilGuardado.tipo;
    final bool lsm =
        enUso ? ConversationProfile.mineKnowsLsm : PerfilGuardado.sabeLsm;

    final String? desc = descripcionPerfil(tipo, lsm);
    // Ni guardado ni en uso: no hay nada que mostrar ni que cambiar.
    if (desc == null) return const SizedBox.shrink();

    // El teléfono está prestado cuando lo que se está usando no es lo que
    // quedó guardado (ver ModoSeleccionPerfil.prestado y la tarjeta
    // "Prestaré mi Celular").
    final bool prestado = enUso &&
        (!PerfilGuardado.hayPerfil ||
            PerfilGuardado.tipo != tipo ||
            PerfilGuardado.sabeLsm != lsm);

    final Color texto =
        widget.sobreFondoOscuro ? Colors.white : const Color(0xFF3B3450);
    final Color fondo = widget.sobreFondoOscuro
        ? Colors.white.withValues(alpha: 0.18)
        : const Color(0xFFE9E2F5);

    return PopupMenuButton<_AccionPerfil>(
      tooltip: 'Mi perfil',
      position: PopupMenuPosition.under,
      onSelected: _alElegir,
      itemBuilder: (_) => const [
        PopupMenuItem<_AccionPerfil>(
          value: _AccionPerfil.miCodigo,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.qr_code_2),
            title: Text('Mostrar mi código'),
            subtitle: Text(
              'Para que la otra persona lo escanee',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem<_AccionPerfil>(
          value: _AccionPerfil.cambiar,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Cambiar mi perfil'),
          ),
        ),
        PopupMenuItem<_AccionPerfil>(
          value: _AccionPerfil.prestar,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.phone_iphone),
            title: Text('No soy yo'),
            subtitle: Text(
              'Prestar el celular, sin cambiar lo guardado',
              style: TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
      child: Semantics(
        button: true,
        label: prestado
            ? 'Celular prestado, perfil en uso: $desc. Tocá para cambiarlo.'
            : 'Mi perfil: $desc. Tocá para cambiarlo.',
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: fondo,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  prestado ? Icons.phone_iphone : Icons.person_outline,
                  size: 16,
                  color: texto,
                ),
                const SizedBox(width: 6),
                // Flexible + ellipsis: "Sordo/a · sin LSM" comparte
                // renglón con la flecha de regreso y el corazón, y en
                // pantallas angostas no siempre cabe entero.
                Flexible(
                  child: Text(
                    prestado ? 'Prestado · $desc' : desc,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: texto,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Icon(Icons.arrow_drop_down, size: 18, color: texto),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Encabezado morado con flecha de regreso, título "UNIVOZ", el chip de
/// perfil y el logo. Se reutiliza en Aprender, Comunicarse y Traducir
/// señas.
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
                const SizedBox(width: 8),
                const Flexible(child: MenuPerfil(sobreFondoOscuro: true)),
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
