import 'package:flutter/material.dart';
import '../services/permiso_camara.dart';
import 'package:senas_core/skeleton_painter.dart' show PantallaDeTranslacion;
import 'profile_selection_screen.dart';
import 'other_person_profile_screen.dart';
import 'main_shell_screen.dart';
import 'traducir_senas_screen.dart';
import 'univoz_shared_widgets.dart';
import 'acerca_screen.dart';
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';
import '../services/perfil_guardado.dart';
import 'package:senas_core/tema_univoz.dart';

/// Primera pregunta después de la bienvenida: ¿para qué quieres usar
/// UNIVOZ? Si el usuario quiere comunicarse con alguien, lo mandamos a
/// elegir su perfil (y luego el de la otra persona); si quiere aprender
/// Lengua de Señas Mexicana, lo mandamos directo a esa sección; y si solo
/// quiere traducir una seña con la cámara (sin armar una conversación),
/// lo mandamos directo al traductor.
///
/// "Traducir señas" vivía antes como una pestaña fija en la barra de
/// abajo (ver MainShellScreen), visible todo el tiempo aunque no
/// aplicara. Como en realidad es parte de comunicarse (el mismo
/// reconocedor de cámara se usa dentro de "Comunicarse" cuando dos
/// personas sordas/mudas no comparten LSM — ver ComunicarseScreen), y
/// como acceso directo tiene más sentido como una opción más de este
/// menú principal, no como una pestaña permanente.
///
/// Si [BlindNarrator.talkBackFlow] está activo (TalkBack detectado en la
/// bienvenida), esta pantalla se responde por voz y, como el perfil
/// "ciego" ya quedó asumido, "comunicarme" salta directo a elegir con
/// quién te vas a comunicar (sin pasar por la cuadrícula de perfiles).
/// Si no, es puramente táctil y en silencio, como antes.
///
/// "Traducir una seña" abre la cámara de una vez (PantallaDeTranslacion)
/// en vez de pasar primero por el menú de TraducirSenasScreen: ese menú
/// también tenía "Reconocer seña" (ahora redundante, ya que es
/// justamente lo que hace esta opción) y "Avatar 3D" (que ahora vive en
/// "Quiero aprender LSM", ver MainShellScreen). Lo que le quedó a ese
/// menú (agregar muestras, espejo, ajustes de reconocimiento) se alcanza
/// ahora desde la tuerca de arriba de esta pantalla ("Configuración").
enum CommunicationPurpose {
  comunicarse,
  aprenderLsm,
  traducirSenas,
}

class PurposeScreen extends StatefulWidget {
  const PurposeScreen({super.key});

  @override
  State<PurposeScreen> createState() => _PurposeScreenState();
}

class _PurposeScreenState extends State<PurposeScreen> {
  CommunicationPurpose? _selected;
  bool _pidiendoPermisoCamara = false;

  static const Color _grayText = ColoresUnivoz.tintaSuave;
  static const Color _comenzarColor = ColoresUnivoz.morado;

  @override
  void initState() {
    super.initState();
    if (BlindNarrator.talkBackFlow) {
      _runTalkBackFlow();
    }
    // Si no hay TalkBack activo, esta pantalla se queda en silencio: es
    // táctil hasta que se confirme un perfil (ver ProfileSelectionScreen
    // y OtherPersonProfileScreen).
  }

  @override
  void dispose() {
    BlindNarrator.stop();
    super.dispose();
  }

  /// Avanza tocando una tarjeta mientras la pregunta por voz de
  /// [_runTalkBackFlow] todavía podía estar esperando una respuesta
  /// hablada: corta esa pregunta en seco antes de seguir, para que no
  /// se quede narrando "¿para qué quieres usar Univoz?" encima de la
  /// pantalla nueva.
  Future<void> _avanzarPorToque(VoidCallback navegar) async {
    await BlindNarrator.interruptFlow();
    if (!mounted) return;
    navegar();
  }

  Future<void> _runTalkBackFlow() async {
    final int flow = BlindNarrator.beginFlow();
    bool isCurrent() => mounted && BlindNarrator.isCurrentFlow(flow);

    var text = await BlindNarrator.ask(
      '¿Para qué quieres usar Univoz? Di comunicarme, para elegir con '
      'quién te vas a comunicar. O di aprender, para aprender lengua de '
      'señas mexicana. O di sal para cerrar la app.',
      isCancelled: () => !isCurrent(),
    );
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!isCurrent()) return;
      if (text.contains('sal')) {
        BlindNarrator.exitApp();
        return;
      }
      if (text.contains('comunic') || text.contains('hablar')) {
        // El perfil "ciego" ya se asumió por TalkBack, así que saltamos
        // la cuadrícula de selección de perfil y vamos directo a elegir
        // con quién se va a comunicar.
        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const OtherPersonProfileScreen()),
        );
        return;
      }
      if (text.contains('aprend') ||
          text.contains('seña') ||
          text.contains('lsm')) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => const MainShellScreen(initialIndex: 0),
          ),
        );
        return;
      }
      if (BlindNarrator.microphonePermanentlyDenied) {
        await BlindNarrator.speak('No tengo permiso para usar el '
            'micrófono. Usa las tarjetas en pantalla para continuar.');
        return;
      }
      text = await BlindNarrator.ask(
        'No entendí. Di comunicarme, aprender, o sal.',
        isCancelled: () => !isCurrent(),
      );
    }
  }

  void _onContinue() {
    if (_selected == null) return;
    _avanzarPorToque(() {
      switch (_selected!) {
        case CommunicationPurpose.comunicarse:
          _irAComunicarse();
          break;
        case CommunicationPurpose.aprenderLsm:
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) => const MainShellScreen(initialIndex: 0),
            ),
          );
          break;
        case CommunicationPurpose.traducirSenas:
          _abrirCamaraTraductora();
          break;
      }
    });
  }

  /// "Comunicarme": si ya hay un perfil propio guardado en el teléfono,
  /// se salta "Elige tu perfil" y va directo a elegir con quién. Lo que
  /// eres se pregunta una vez; con quién hablas, cada conversación.
  void _irAComunicarse() {
    if (!PerfilGuardado.hayPerfil) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
      );
      return;
    }
    // ProfileSelectionScreen.initState hacía este reinicio por nosotros.
    // Al saltarla hay que dejar el estado equivalente a mano: el perfil
    // propio tomado del disco, y los datos de la otra persona en limpio
    // por si quedó algo de una conversación anterior de esta misma
    // sesión.
    PerfilGuardado.aplicar();
    ConversationProfile.resetOtro();
    // Mismo enganche que hace ProfileSelectionScreen al confirmar
    // "ciego": sin esto, saltarse esa pantalla dejaría sin control por
    // voz justo a quien lo necesita.
    if (PerfilGuardado.tipo == ProfileType.ciego) {
      BlindNarrator.activateManualBlindMode();
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OtherPersonProfileScreen()),
    );
  }

  Future<void> _abrirCamaraTraductora() async {
    setState(() => _pidiendoPermisoCamara = true);
    final permitido = await pedirPermisoCamara(context);
    if (mounted) setState(() => _pidiendoPermisoCamara = false);
    if (!permitido || !mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => const PantallaDeTranslacion(conAvatar: false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
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
                    tooltip: 'Regresar',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  // Acá se ve el perfil guardado antes de entrar a
                  // "Comunicarme", que a partir de ahora ya no vuelve a
                  // preguntarlo. Sin esto no habría forma de saber con
                  // qué perfil va a arrancar la conversación.
                  Flexible(child: MenuPerfil(onCambio: () => setState(() {}))),
                  // Configuración (agregar muestras, espejo y ajustes de
                  // reconocimiento) va en la tuerca, fuera de las opciones.
                  IconButton(
                    key: const ValueKey('purpose-configuracion'),
                    icon: Icon(Icons.settings_outlined,
                        size: 28,
                        color: Theme.of(context).colorScheme.primary),
                    tooltip: 'Configuración',
                    onPressed: () => _avanzarPorToque(() {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TraducirSenasScreen()),
                      );
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '¿Para qué quieres\nusar UNIVOZ?',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 16),
              // Sin desplazar: las tres opciones se reparten el alto que
              // hay, con un dibujo grande y pocas palabras (no todos leen
              // el español con soltura). La descripción va para TalkBack.
              Expanded(
                child: Column(
                  children: [
                    _buildOptionCard(
                      key: const ValueKey('purpose-comunicarse'),
                      purpose: CommunicationPurpose.comunicarse,
                      ilustracion: 'comunicarse',
                      cardColor: const Color(0xFFA8C5F0),
                      title: 'Comunicarme',
                      subtitle: 'Elige tu perfil y el de la persona con la '
                          'que quieres hablar',
                    ),
                    const SizedBox(height: 12),
                    _buildOptionCard(
                      key: const ValueKey('purpose-traducir-senas'),
                      purpose: CommunicationPurpose.traducirSenas,
                      ilustracion: 'traducir',
                      cardColor: const Color(0xFFB8B2E8),
                      title: 'Traducir una seña',
                      subtitle: 'Abre la cámara y traduce lengua de señas a '
                          'texto, sin armar una conversación',
                      ocupado: _pidiendoPermisoCamara,
                    ),
                    const SizedBox(height: 12),
                    _buildOptionCard(
                      key: const ValueKey('purpose-aprender-lsm'),
                      purpose: CommunicationPurpose.aprenderLsm,
                      ilustracion: 'aprender',
                      cardColor: const Color(0xFFF0C869),
                      title: 'Aprender LSM',
                      subtitle: 'Aprender con avatar 3D a mi propio ritmo',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _selected != null ? _onContinue : null,
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
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AcercaScreen()),
                  ),
                  icon: const Icon(Icons.info_outline, size: 18),
                  label: const Text('Acerca de y créditos'),
                  style: TextButton.styleFrom(foregroundColor: _grayText),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Opción del menú: dibujo grande y su nombre. Ocupa el alto que le
  /// toque (Expanded) para que nada se tenga que desplazar.
  Widget _buildOptionCard({
    Key? key,
    required CommunicationPurpose purpose,
    required String ilustracion,
    required Color cardColor,
    required String title,
    required String subtitle,
    bool ocupado = false,
  }) {
    final bool isSelected = _selected == purpose;
    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: '$title. $subtitle',
        excludeSemantics: true,
        child: GestureDetector(
          key: key,
          onTap: () => setState(() => _selected = purpose),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(18),
              border: isSelected
                  ? Border.all(color: Colors.black87, width: 3)
                  : null,
            ),
            child: Row(
              children: [
                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Image.asset(
                    'assets/ilustraciones/$ilustracion.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                      fontSize: 19,
                      height: 1.15,
                    ),
                  ),
                ),
                if (ocupado)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
