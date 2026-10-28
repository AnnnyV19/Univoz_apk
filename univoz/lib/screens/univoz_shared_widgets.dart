import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemUiOverlayStyle;

import '../services/conversation_profile.dart';
import '../services/perfil_guardado.dart';
import '../services/voz.dart' show LanzadorUrl, LectorVoz;
import 'profile_selection_screen.dart';
import 'qr_perfil.dart';
import 'sos.dart';

enum _AccionPerfil { miCodigo, contacto, cambiar, prestar }

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
      case _AccionPerfil.contacto:
        Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => const PantallaContactoEmergencia()),
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
        PopupMenuItem<_AccionPerfil>(
          value: _AccionPerfil.contacto,
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.emergency_outlined),
            title: Text('Contacto de emergencia'),
            subtitle: Text(
              'A quién avisa el botón SOS',
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
            ? 'Celular prestado, perfil en uso: $desc. Toca para cambiarlo.'
            : 'Mi perfil: $desc. Toca para cambiarlo.',
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

/// Encabezado con flecha de regreso, título "UNIVOZ", el chip de perfil y
/// el logo. Se reutiliza en Aprender, Comunicarse y Traducir señas.
///
/// Diseño de Lucía: barra blanca con texto en tinta, la marca en morado y
/// una línea fina debajo (antes era una barra con degradado morado).
class UnivozHeader extends StatelessWidget implements PreferredSizeWidget {
  final String? subtitle;

  const UnivozHeader({super.key, this.subtitle});

  // Alto fijo (el Scaffold lo exige): holgado para texto al 130 %.
  @override
  Size get preferredSize => Size.fromHeight(subtitle == null ? 80 : 120);

  @override
  Widget build(BuildContext context) {
    // La barra no crece con el texto grande del sistema: se limita a 1.3 para
    // que nunca desborde (el contenido de la pantalla sí escala completo).
    // Barra clara: los iconos del sistema (hora, batería) van oscuros.
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: oscuro ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: _contenido(context),
      ),
    );
  }

  Widget _contenido(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: colores.surface,
      // La línea va encima (foregroundDecoration), sin quitarle alto al
      // contenido: la barra tiene alto fijo y con texto grande no cabía.
      foregroundDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colores.outlineVariant, width: 1.5),
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
                  icon: Icon(Icons.chevron_left,
                      color: colores.onSurface, size: 28),
                  tooltip: 'Regresar',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Text(
                  'UNIVOZ',
                  style: TextStyle(
                    color: colores.primary,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 8),
                const Flexible(child: MenuPerfil()),
                const Spacer(),
                Icon(Icons.favorite, color: colores.primary),
                const SizedBox(width: 12),
              ],
            ),
            if (subtitle != null)
              Padding(
                padding: const EdgeInsets.only(left: 20, bottom: 8),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    color: colores.onSurfaceVariant,
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
///
/// Un toque solo avisa cómo se usa; hay que mantenerlo presionado
/// [duracionPresion] para abrir [PantallaSos]. Así un roce en el bolsillo
/// o un toque sin querer no abre una pantalla de emergencia.
///
/// [lanzador] y [lector] solo se pasan en pruebas (los recibe PantallaSos).
class SosButton extends StatefulWidget {
  final LanzadorUrl? lanzador;
  final LectorVoz? lector;

  const SosButton({super.key, this.lanzador, this.lector});

  /// Cuánto hay que mantenerlo presionado.
  static const Duration duracionPresion = Duration(milliseconds: 800);

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _progreso = AnimationController(
    vsync: this,
    duration: SosButton.duracionPresion,
    // Con "quitar animaciones" del sistema el controlador por defecto
    // acelera x20 y los 0.8 s serían 40 ms: se abriría con cualquier roce.
    animationBehavior: AnimationBehavior.preserve,
  )..addStatusListener(_alCambiarEstado);

  /// Ya se abrió la pantalla en esta presión; al soltar no cuenta como toque.
  bool _abierto = false;

  @override
  void dispose() {
    _progreso.dispose();
    super.dispose();
  }

  void _alCambiarEstado(AnimationStatus estado) {
    if (estado != AnimationStatus.completed || _abierto) return;
    _abierto = true;
    _abrirSos();
  }

  void _abrirSos() {
    HapticFeedback.heavyImpact();
    aperturasSos.value++;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PantallaSos(lanzador: widget.lanzador, lector: widget.lector),
      ),
    );
  }

  void _soltar({required bool fueToque}) {
    final yaAbierto = _abierto;
    _abierto = false;
    _progreso.reset();
    if (fueToque && !yaAbierto) _mostrarPista();
  }

  void _mostrarPista() {
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(const SnackBar(content: Text('Mantén presionado para SOS')));
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'SOS, emergencia',
      hint: 'Mantén presionado para abrir la pantalla de ayuda',
      onTap: _mostrarPista,
      onLongPress: _abrirSos,
      excludeSemantics: true,
      child: Tooltip(
        message: 'Mantén presionado para SOS',
        // Con el disparo por defecto (mantener presionado) el tooltip
        // compite con nuestro propio mantener-presionado y se lo gana.
        triggerMode: TooltipTriggerMode.manual,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _progreso.forward(from: 0),
          onTapUp: (_) => _soltar(fueToque: true),
          onTapCancel: () => _soltar(fueToque: false),
          child: AnimatedBuilder(
            animation: _progreso,
            // El relleno que avanza va ENCIMA del botón, del mismo tamaño;
            // el contenido va centrado (antes se pegaba arriba del rojo).
            builder: (context, _) => ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Stack(
                children: [
                  Container(
                    width: double.infinity,
                    // Mínimo 52: con texto grande el rótulo pasa a dos
                    // renglones.
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    alignment: Alignment.center,
                    color: colores.error,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              Icon(Icons.warning_amber_rounded,
                                  color: colores.onError),
                              if (_progreso.value > 0)
                                CircularProgressIndicator(
                                  key: const ValueKey('anillo-sos'),
                                  value: _progreso.value,
                                  strokeWidth: 3,
                                  color: colores.onError,
                                  backgroundColor:
                                      colores.onError.withValues(alpha: 0.3),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'SOS',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: colores.onError,
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: _progreso.value,
                          heightFactor: 1,
                          child: ColoredBox(
                            color: colores.onError.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tarjeta con un dibujo grande y una o dos palabras debajo: la usan los
/// menús de perfiles y las preguntas de sí/no. No todas las personas leen
/// el español con soltura, así que en pantalla va poco texto; la frase
/// completa ([lector]) es la que lee TalkBack.
///
/// Toma el alto que le den (va dentro de un Expanded): las pantallas que la
/// usan no se deslizan.
class TarjetaDibujo extends StatelessWidget {
  const TarjetaDibujo({
    super.key,
    required this.ilustracion,
    required this.titulo,
    required this.lector,
    required this.color,
    required this.seleccionada,
    required this.onTap,
    this.colorTexto,
  });

  /// Nombre del PNG en assets/ilustraciones/ (sin extensión).
  final String ilustracion;
  final String titulo;
  final String lector;
  final Color color;
  final Color? colorTexto;
  final bool seleccionada;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final texto = colorTexto ?? Theme.of(context).colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: seleccionada,
      label: lector,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: seleccionada ? Colors.black87 : Colors.transparent,
              width: 3,
            ),
          ),
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
                  titulo,
                  maxLines: 1,
                  style: TextStyle(
                    color: texto,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
