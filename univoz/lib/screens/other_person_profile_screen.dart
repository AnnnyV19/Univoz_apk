import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'profile_selection_screen.dart';
import 'main_shell_screen.dart';
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';

/// Pantalla para elegir el perfil de la persona con la que el usuario se
/// va a comunicar. Ofrece dos caminos:
///   1. "Conectar celular" — simula detectar automáticamente el perfil de
///      la otra persona (por ahora es una simulación de UI; la lógica real
///      de Bluetooth/NFC/QR se conecta después en el backend).
///   2. Selección manual — misma cuadrícula de perfiles que ya usamos,
///      reutilizando profileConfigs y refinementConfigs.
///
/// Nota: no incluye la tarjeta "Prestaré mi Celular" porque ese perfil solo
/// aplica a quien usa la app, no a la persona con la que se comunica.
///
/// Si [ConversationProfile.mine] es ciego/a, tampoco se ofrece "es
/// ciego/a" ni "es oyente" como perfil de la otra persona: ninguna de
/// las dos combinaciones tiene una barrera de comunicación que la app
/// deba resolver (dos personas ciegas, o una ciega y una oyente, pueden
/// simplemente hablar) — ver [_selectableProfiles].
///
/// Si [BlindNarrator.talkBackFlow] está activo, esta pantalla se
/// resuelve por completo con preguntas y respuestas de voz (ver
/// _runTalkBackFlow), sin depender de que se toque nada en pantalla —
/// pero, como la cuadrícula sigue visible y tocable al mismo tiempo,
/// cualquier selección manual interrumpe esa corrida de voz de inmediato
/// (ver [BlindNarrator.interruptFlow]) para que no se quede preguntando
/// por voz con quién comunicarse cuando ya se eligió y se avanzó de
/// pantalla.

/// Textos para describir el perfil de la OTRA persona. [profileConfigs] y
/// [refinementConfigs] (definidos en profile_selection_screen.dart) usan
/// primera persona ("Soy ciego/a", "¿Conoces LSM?"), pensados para cuando
/// el usuario describe su propio perfil; aquí sobreescribimos esos
/// textos en tercera persona para que tengan sentido al describir a la
/// persona con la que se va a comunicar.
class _OtherPersonText {
  final String title;
  final String subtitle;
  final String refinementTitle;
  final String refinementSubtitle;
  final List<String> refinementOptions;

  const _OtherPersonText({
    required this.title,
    required this.subtitle,
    required this.refinementTitle,
    required this.refinementSubtitle,
    required this.refinementOptions,
  });
}

const Map<ProfileType, _OtherPersonText> _otherPersonConfigs = {
  ProfileType.ciego: _OtherPersonText(
    title: 'Es ciego/a',
    subtitle: 'Usa la app con voz y dictado',
    refinementTitle: '¿Cómo prefiere usar la app?',
    refinementSubtitle: 'Elige una opción para personalizar la experiencia',
    refinementOptions: ['No usa lector de pantalla', 'Usa lector de pantalla'],
  ),
  ProfileType.sordo: _OtherPersonText(
    title: 'Es sordo/a',
    subtitle: 'Usa subtítulos, señas, LSM y alertas visuales',
    refinementTitle: '¿Conoce Lengua de Señas Mexicana?',
    refinementSubtitle: 'Esto nos ayuda a elegir cómo se comunicarán',
    refinementOptions: ['No conoce LSM', 'Conoce LSM'],
  ),
  ProfileType.mudo: _OtherPersonText(
    title: 'Es mudo/a',
    subtitle: 'Escucha y ve, pero la app habla por él o ella',
    refinementTitle: '¿Conoce Lengua de Señas Mexicana?',
    refinementSubtitle: 'Esto nos ayuda a elegir cómo se comunicarán',
    refinementOptions: ['No conoce LSM', 'Conoce LSM'],
  ),
};

class OtherPersonProfileScreen extends StatefulWidget {
  const OtherPersonProfileScreen({super.key});

  @override
  State<OtherPersonProfileScreen> createState() =>
      _OtherPersonProfileScreenState();
}

class _OtherPersonProfileScreenState extends State<OtherPersonProfileScreen> {
  /// Si quien usa el teléfono es ciego/a u oyente, no tiene sentido
  /// ofrecer "es ciego/a" ni "es oyente" como perfil de la otra persona:
  /// ninguna de esas combinaciones tiene una barrera de comunicación que
  /// la app deba resolver (dos personas ciegas, una ciega y una oyente,
  /// o dos oyentes, pueden simplemente hablar).
  bool get _sinBarreraConCiegoUOyente =>
      ConversationProfile.mine == ProfileType.ciego ||
      ConversationProfile.mine == ProfileType.oyente;

  /// Perfiles que se pueden elegir para la otra persona (ver
  /// [_sinBarreraConCiegoUOyente]).
  List<ProfileType> get _selectableProfiles => _sinBarreraConCiegoUOyente
      ? const [ProfileType.sordo, ProfileType.mudo]
      : const [ProfileType.ciego, ProfileType.sordo, ProfileType.mudo];

  bool get _mineIsBlind => ConversationProfile.mine == ProfileType.ciego;

  bool _scanning = false;
  ProfileType? _detectedProfile;

  ProfileType? _expandedProfile;
  int? _expandedOptionIndex;
  bool _selectedOyente = false;

  Timer? _scanTimer;

  static const Color _bgColor = Color(0xFFF7F2FA);
  static const Color _grayText = Color(0xFF6B6478);
  static const Color _comenzarColor = Color(0xFF8F84A6);
  static const Color _radioCardColor = Color(0xFF241B35);
  static const Color _radioAccent = Color(0xFFB388E8);

  @override
  void initState() {
    super.initState();
    if (BlindNarrator.talkBackFlow) {
      // TalkBack detectado, o perfil "ciego" confirmado manualmente en la
      // pantalla anterior (ver BlindNarrator.activateManualBlindMode): en
      // ambos casos esta pantalla se resuelve por completo con preguntas
      // y respuestas de voz, no con narración pasiva ni toque.
      _runTalkBackFlow();
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    // No solo detiene la voz: invalida también la corrida de
    // preguntas-por-voz activa (ver BlindNarrator.interruptFlow), para
    // que si _runTalkBackFlow seguía a mitad de una pregunta no continúe
    // hablando ni intente navegar una vez que esta pantalla ya no existe.
    BlindNarrator.interruptFlow();
    super.dispose();
  }

  /// Pregunta por voz con quién se va a comunicar el usuario y navega a
  /// MainShellScreen según la respuesta. Se usa cuando TalkBack está
  /// activo, en vez de la cuadrícula táctil.
  Future<void> _runTalkBackFlow() async {
    final int flow = BlindNarrator.beginFlow();
    bool isCurrent() => mounted && BlindNarrator.isCurrentFlow(flow);

    // Si el perfil "ciego" se activó a mano en ProfileSelectionScreen (en
    // vez de por TalkBack desde WelcomeScreen), esta es la primera vez
    // que se usa el micrófono en la sesión: calibramos aquí también (ver
    // BlindNarrator.calibrateIfNeeded, que no hace nada si ya se hizo).
    await BlindNarrator.calibrateIfNeeded();
    if (!isCurrent()) return;

    final ProfileType? answer = await _askOtherProfile(flow);
    if (!isCurrent() || answer == null) return;
    ConversationProfile.other = answer;
    if (answer == ProfileType.oyente) {
      ConversationProfile.otherKnowsLsm = false;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
      return;
    }
    bool knowsLsm = false;
    if (answer == ProfileType.sordo || answer == ProfileType.mudo) {
      final VoiceCommand cmd = await BlindNarrator.askUntil(
        '¿La otra persona conoce lengua de señas mexicana? Di sí o no.',
        accepted: [VoiceCommand.yes, VoiceCommand.no],
        isCancelled: () => !isCurrent(),
      );
      if (!isCurrent()) return;
      if (cmd == VoiceCommand.exit) {
        BlindNarrator.exitApp();
        return;
      }
      knowsLsm = cmd == VoiceCommand.yes;
    }
    ConversationProfile.otherKnowsLsm = knowsLsm;
    if (!isCurrent()) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MainShellScreen(
          initialIndex: 1,
          modo: resolverComunicacionModo(),
        ),
      ),
    );
  }

  /// Pregunta por voz el perfil de la otra persona, reintentando hasta
  /// cuatro veces. Devuelve `null` si el usuario dice "salir" (y cierra
  /// la app), si no se reconoce nada tras varios intentos, si no hay
  /// permiso de micrófono, o si [flow] quedó obsoleto (por ejemplo,
  /// porque mientras tanto se eligió un perfil a mano).
  ///
  /// Si quien usa el teléfono es ciego/a, solo se ofrecen "sordo" y
  /// "mudo": comunicarse con otra persona ciega o con alguien oyente no
  /// tiene ninguna barrera que la app deba resolver.
  Future<ProfileType?> _askOtherProfile(int flow) async {
    final bool mineIsBlind = _mineIsBlind;
    bool cancelado() => !(mounted && BlindNarrator.isCurrentFlow(flow));
    var text = await BlindNarrator.ask(
      mineIsBlind
          ? '¿La persona con la que te vas a comunicar es sorda o muda? '
              'Di sordo, muda, o sal para cerrar la app.'
          : '¿Con quién te vas a comunicar? Di ciego, sordo, mudo, u oyente. '
              'O di sal para cerrar la app.',
      isCancelled: cancelado,
    );
    for (var attempt = 0; attempt < 4; attempt++) {
      if (!(mounted && BlindNarrator.isCurrentFlow(flow))) return null;
      if (text.contains('sal')) {
        BlindNarrator.exitApp();
        return null;
      }
      if (text.contains('sord')) return ProfileType.sordo;
      if (text.contains('mud')) return ProfileType.mudo;
      if (!mineIsBlind) {
        if (text.contains('cieg')) return ProfileType.ciego;
        if (text.contains('oyente')) return ProfileType.oyente;
      }
      if (BlindNarrator.microphonePermanentlyDenied) {
        await BlindNarrator.speak('No tengo permiso para usar el '
            'micrófono. Elige a mano con quién te vas a comunicar.');
        return null;
      }
      text = await BlindNarrator.ask(
        mineIsBlind
            ? 'No entendí. Di sordo, muda, o sal.'
            : 'No entendí. Di ciego, sordo, mudo, u oyente.',
        isCancelled: cancelado,
      );
    }
    return null;
  }

  /// Narra (con lector de pantalla y con voz real vía [BlindNarrator])
  /// la pregunta de refinamiento y sus opciones para el perfil [type] de
  /// la otra persona. Solo aplica al modo manual (sin TalkBack): en el
  /// flujo por voz, _runTalkBackFlow ya se encarga de todo.
  void _announceRefinement(ProfileType type) {
    if (BlindNarrator.talkBackFlow) return;
    final other = _otherPersonConfigs[type]!;
    final optionsSpeech = other.refinementOptions
        .asMap()
        .entries
        .map((e) => 'Opción ${e.key + 1}: ${e.value}.')
        .join(' ');
    final message = '${other.title}. ${other.refinementTitle} $optionsSpeech';
    SemanticsService.announce(message, TextDirection.ltr);
    BlindNarrator.speak(message);
  }

  bool get _canContinue {
    if (_expandedProfile != null) return _expandedOptionIndex != null;
    return _selectedOyente;
  }

  void _onContinue() {
    // El usuario está completando la selección a mano: si todavía había
    // una pregunta por voz de _runTalkBackFlow esperando respuesta (por
    // ejemplo, el micrófono nunca escuchó nada y seguía reintentando),
    // la cortamos aquí mismo para que no se quede narrando "¿con quién
    // te vas a comunicar?" cuando ya se eligió y se está por avanzar.
    BlindNarrator.interruptFlow();
    if (_selectedOyente) {
      ConversationProfile.other = ProfileType.oyente;
      ConversationProfile.otherKnowsLsm = false;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
      return;
    }
    if (_expandedProfile != null && _expandedOptionIndex != null) {
      // "Conoce LSM" es el índice 1 en refinementOptions para sordo/mudo
      // (ver _otherPersonConfigs) — antes esto solo se usaba para decidir
      // el avatar; ahora resolverComunicacionModo() también lo combina
      // con ConversationProfile.mineKnowsLsm para decidir entre avatar,
      // cámara, puro texto, o "no necesitan la app" cuando las dos
      // personas son sordas/mudas (ver conversation_profile.dart).
      final bool otherKnowsLsm = _expandedOptionIndex == 1;
      ConversationProfile.other = _expandedProfile;
      ConversationProfile.otherKnowsLsm = otherKnowsLsm;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
    }
  }

  void _startScan() {
    BlindNarrator.interruptFlow();
    setState(() {
      _scanning = true;
      _detectedProfile = null;
      _expandedProfile = null;
      _selectedOyente = false;
    });
    // TODO: reemplazar esta simulación por la detección real
    // (Bluetooth / NFC / QR / lo que decida el backend).
    _scanTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _detectedProfile = ProfileType.sordo; // placeholder de ejemplo
      });
    });
  }

  void _confirmDetected() {
    if (_detectedProfile == null) return;
    final ProfileType confirmed = _detectedProfile!;
    setState(() {
      _expandedProfile = confirmed;
      _expandedOptionIndex = null;
      _detectedProfile = null;
    });
    _announceRefinement(confirmed);
  }

  void _rejectDetected() {
    setState(() => _detectedProfile = null);
  }

  void _expandCard(ProfileType type) {
    BlindNarrator.interruptFlow();
    setState(() {
      _expandedProfile = type;
      _expandedOptionIndex = null;
      _selectedOyente = false;
      _detectedProfile = null;
    });
    _announceRefinement(type);
  }

  void _collapseCard() {
    setState(() {
      _expandedProfile = null;
      _expandedOptionIndex = null;
    });
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
                '¿Con quién te vas\na comunicar?',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Conecta su celular automáticamente o elige su perfil',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _grayText,
                ),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.94, end: 1.0)
                          .animate(animation),
                      child: child,
                    ),
                  ),
                  child: _expandedProfile != null
                      ? _buildExpandedCard(
                          profileConfigs[_expandedProfile]!,
                          key: ValueKey(_expandedProfile),
                        )
                      : _buildMainContent(key: const ValueKey('main')),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _canContinue ? _onContinue : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _comenzarColor,
                    disabledBackgroundColor:
                        _comenzarColor.withOpacity(0.4),
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

  /// Contenido principal: botón de escaneo + resultado detectado (si aplica)
  /// + cuadrícula manual (2 tarjetas por fila, adaptada según cuántos
  /// perfiles apliquen — ver [_selectableProfiles]).
  Widget _buildMainContent({required Key key}) {
    final cards = [
      for (final p in _selectableProfiles) _buildCard(profileConfigs[p]!),
      if (!_sinBarreraConCiegoUOyente) _buildOyenteButton(),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final segunda = i + 1 < cards.length ? cards[i + 1] : null;
      rows.add(
        Row(
          children: [
            Expanded(child: cards[i]),
            const SizedBox(width: 14),
            Expanded(child: segunda ?? const SizedBox.shrink()),
          ],
        ),
      );
      rows.add(const SizedBox(height: 14));
    }
    if (rows.isNotEmpty) rows.removeLast();

    return SingleChildScrollView(
      key: key,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildScanButton(),
          if (_detectedProfile != null) ...[
            const SizedBox(height: 14),
            _buildDetectedCard(profileConfigs[_detectedProfile]!),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Divider(color: _grayText.withOpacity(0.3)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'o selecciona manualmente',
                  style: TextStyle(
                    color: _grayText,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Divider(color: _grayText.withOpacity(0.3)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...rows,
        ],
      ),
    );
  }

  Widget _buildScanButton() {
    return GestureDetector(
      onTap: _scanning ? null : _startScan,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6C63FF), Color(0xFFB84FCE)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            if (_scanning)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(Colors.white),
                ),
              )
            else
              const Icon(Icons.bluetooth_searching,
                  color: Colors.white, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                _scanning
                    ? 'Buscando celular cercano...'
                    : 'Conectar celular automáticamente',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetectedCard(ProfileConfig config) {
    return Container(
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
            child: Icon(config.icon, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Detectamos: ${_otherPersonConfigs[config.type]!.title}',
                  style: TextStyle(
                    color: config.textColor,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                Text(
                  '¿Es correcto?',
                  style: TextStyle(
                    color: config.textColor.withOpacity(0.8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: config.textColor),
            onPressed: _rejectDetected,
          ),
          IconButton(
            icon: Icon(Icons.check_circle, color: config.textColor),
            onPressed: _confirmDetected,
          ),
        ],
      ),
    );
  }

  Widget _buildCard(ProfileConfig config) {
    return GestureDetector(
      onTap: () => _expandCard(config.type),
      child: Container(
        height: 130,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: config.cardColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 15,
              backgroundColor: config.iconBgColor,
              child: Icon(config.icon, size: 16, color: Colors.white),
            ),
            const Spacer(),
            Text(
              _otherPersonConfigs[config.type]!.title,
              style: TextStyle(
                color: config.textColor,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOyenteButton() {
    return GestureDetector(
      onTap: () {
        BlindNarrator.interruptFlow();
        setState(() {
          _selectedOyente = true;
          _expandedProfile = null;
          _detectedProfile = null;
        });
      },
      child: Container(
        height: 130,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6FCF6F), Color(0xFF3F9142)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(18),
          border: _selectedOyente
              ? Border.all(color: Colors.black87, width: 3)
              : null,
        ),
        child: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Spacer(),
            Text(
              'Es oyente, sin\ndiscapacidades',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpandedCard(
    ProfileConfig config, {
    required Key key,
  }) {
    final other = _otherPersonConfigs[config.type]!;
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: config.cardColor,
        borderRadius: BorderRadius.circular(22),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: config.iconBgColor,
                  child:
                      Icon(config.icon, size: 20, color: Colors.white),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    other.title,
                    style: TextStyle(
                      color: config.textColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: config.textColor),
                  onPressed: _collapseCard,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              other.refinementTitle,
              style: TextStyle(
                color: config.textColor,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              other.refinementSubtitle,
              style: TextStyle(
                color: config.textColor.withOpacity(0.8),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
              decoration: BoxDecoration(
                color: _radioCardColor,
                borderRadius: BorderRadius.circular(18),
              ),
              // Cada opción es un objetivo táctil de al menos 48x48dp
              // (mínimo recomendado por las normas de accesibilidad —
              // WCAG 2.5.5 / Android — para personas con baja visión o
              // ceguera), con más separación entre opciones para evitar
              // toques accidentales.
              child: Column(
                children:
                    List.generate(other.refinementOptions.length, (i) {
                  final bool isSelected = _expandedOptionIndex == i;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom:
                          i == other.refinementOptions.length - 1 ? 0 : 8,
                    ),
                    child: Semantics(
                      button: true,
                      selected: isSelected,
                      label: other.refinementOptions[i],
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () =>
                              setState(() => _expandedOptionIndex = i),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 56),
                            padding: const EdgeInsets.symmetric(
                                vertical: 14, horizontal: 10),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: _radioAccent, width: 2.5),
                                    color: isSelected
                                        ? _radioAccent
                                        : Colors.transparent,
                                  ),
                                  child: isSelected
                                      ? const Icon(Icons.circle,
                                          size: 12, color: Colors.white)
                                      : null,
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Text(
                                    other.refinementOptions[i],
                                    style: TextStyle(
                                      color: isSelected
                                          ? _radioAccent
                                          : Colors.white70,
                                      fontWeight: isSelected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      fontSize: 17,
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
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
