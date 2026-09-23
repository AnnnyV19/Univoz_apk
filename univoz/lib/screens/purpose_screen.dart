import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:senas_core/skeleton_painter.dart' show PantallaDeTranslacion;
import 'profile_selection_screen.dart';
import 'other_person_profile_screen.dart';
import 'main_shell_screen.dart';
import 'traducir_senas_screen.dart';
import '../services/blind_narrator.dart';

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
/// ahora desde la cuarta opción de aquí, "Configuración".
enum CommunicationPurpose {
  comunicarse,
  aprenderLsm,
  traducirSenas,
  configuracion,
}

class PurposeScreen extends StatefulWidget {
  const PurposeScreen({super.key});

  @override
  State<PurposeScreen> createState() => _PurposeScreenState();
}

class _PurposeScreenState extends State<PurposeScreen> {
  CommunicationPurpose? _selected;
  bool _pidiendoPermisoCamara = false;

  static const Color _bgColor = Color(0xFFF7F2FA);
  static const Color _grayText = Color(0xFF6B6478);
  static const Color _comenzarColor = Color(0xFF8F84A6);

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
        Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => const OtherPersonProfileScreen()),
        );
        return;
      }
      if (text.contains('aprend') ||
          text.contains('seña') ||
          text.contains('lsm')) {
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
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ProfileSelectionScreen()),
          );
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
        case CommunicationPurpose.configuracion:
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const TraducirSenasScreen()),
          );
          break;
      }
    });
  }

  /// Pide permiso de cámara antes de abrir el reconocedor de señas
  /// (mismo patrón que TraducirSenasScreen/ComunicarseScreen). Devuelve
  /// true si ya se puede continuar.
  Future<bool> _asegurarPermisoCamara() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    setState(() => _pidiendoPermisoCamara = true);
    final resultado = await Permission.camera.request();
    if (mounted) setState(() => _pidiendoPermisoCamara = false);
    if (resultado.isGranted) return true;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'Sin permiso de cámara no se puede traducir lengua de señas.'),
        action: SnackBarAction(label: 'Ajustes', onPressed: openAppSettings),
      ),
    );
    return false;
  }

  Future<void> _abrirCamaraTraductora() async {
    if (!await _asegurarPermisoCamara()) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PantallaDeTranslacion()),
    );
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
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left, size: 32),
                    tooltip: 'Regresar',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  const ExcludeSemantics(
                    child: Icon(Icons.favorite, color: Color(0xFFB84FCE)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '¿Para qué quieres\nusar UNIVOZ?',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Elige una opción para personalizar tu experiencia',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _grayText,
                ),
              ),
              const SizedBox(height: 28),

              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildOptionCard(
                        purpose: CommunicationPurpose.comunicarse,
                        icon: Icons.chat_bubble_outline,
                        iconBgColor: const Color(0xFFA8C5F0),
                        cardColor: const Color(0xFFA8C5F0),
                        title: 'Comunicarme con alguien',
                        subtitle:
                            'Elige tu perfil y el de la persona con la que quieres hablar',
                        textColor: const Color(0xFF1A1A2E),
                      ),
                      const SizedBox(height: 14),
                      _buildOptionCard(
                        purpose: CommunicationPurpose.aprenderLsm,
                        icon: Icons.pan_tool,
                        iconBgColor: const Color(0xFFE88BC2),
                        cardColor: const Color(0xFFF0C869),
                        title: 'Quiero aprender LSM',
                        subtitle: 'Aprender con avatar 3D a mi propio ritmo',
                        textColor: const Color(0xFF1A1A2E),
                      ),
                      const SizedBox(height: 14),
                      _buildOptionCard(
                        purpose: CommunicationPurpose.traducirSenas,
                        icon: Icons.camera_alt,
                        iconBgColor: const Color(0xFF6C63FF),
                        cardColor: const Color(0xFFB8B2E8),
                        title: 'Traducir una seña',
                        subtitle:
                            'Abre la cámara y traduce lengua de señas a texto, sin armar una conversación',
                        textColor: const Color(0xFF1A1A2E),
                      ),
                      const SizedBox(height: 14),
                      _buildOptionCard(
                        purpose: CommunicationPurpose.configuracion,
                        icon: Icons.settings,
                        iconBgColor: const Color(0xFF3FBF8F),
                        cardColor: const Color(0xFFCDEEDF),
                        title: 'Configuración',
                        subtitle: 'Agregar muestras, espejo y ajustes de '
                            'reconocimiento',
                        textColor: const Color(0xFF1A1A2E),
                      ),
                      if (_pidiendoPermisoCamara)
                        const Padding(
                          padding: EdgeInsets.only(top: 14),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
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
                    disabledBackgroundColor: _comenzarColor.withOpacity(0.4),
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

  Widget _buildOptionCard({
    required CommunicationPurpose purpose,
    required IconData icon,
    required Color iconBgColor,
    required Color cardColor,
    required String title,
    required String subtitle,
    required Color textColor,
  }) {
    final bool isSelected = _selected == purpose;
    return GestureDetector(
      onTap: () => setState(() => _selected = purpose),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(18),
          border: isSelected
              ? Border.all(color: Colors.black87, width: 3)
              : null,
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: iconBgColor,
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: textColor.withOpacity(0.85),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
