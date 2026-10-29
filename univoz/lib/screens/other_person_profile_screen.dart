import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'profile_selection_screen.dart';
import 'main_shell_screen.dart';
import 'qr_perfil.dart';
import 'univoz_shared_widgets.dart';
import '../services/tarjeta_perfil.dart';
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';
import 'package:senas_core/tema_univoz.dart';

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

  /// Palabra corta en pantalla para cada respuesta (los dibujos son los de
  /// [refinementConfigs]); [refinementOptions] completas van a TalkBack.
  final List<String> cortos;

  const _OtherPersonText({
    required this.title,
    required this.subtitle,
    required this.refinementTitle,
    required this.refinementSubtitle,
    required this.refinementOptions,
    required this.cortos,
  });
}

const Map<ProfileType, _OtherPersonText> _otherPersonConfigs = {
  ProfileType.ciego: _OtherPersonText(
    title: 'Es ciego/a',
    subtitle: 'Usa la app con voz y dictado',
    refinementTitle: '¿Cómo prefiere usar la app?',
    refinementSubtitle: 'Elige una opción para personalizar la experiencia',
    refinementOptions: ['No usa lector de pantalla', 'Usa lector de pantalla'],
    cortos: ['Sin lector', 'Con lector'],
  ),
  ProfileType.sordo: _OtherPersonText(
    title: 'Es sordo/a',
    subtitle: 'Usa subtítulos, señas, LSM y alertas visuales',
    refinementTitle: '¿Conoce Lengua de Señas Mexicana?',
    refinementSubtitle: 'Esto nos ayuda a elegir cómo se comunicarán',
    refinementOptions: ['No conoce LSM', 'Conoce LSM'],
    cortos: ['No sabe LSM', 'Sabe LSM'],
  ),
  ProfileType.mudo: _OtherPersonText(
    title: 'Es mudo/a',
    subtitle: 'Escucha y ve, pero la app habla por él o ella',
    refinementTitle: '¿Conoce Lengua de Señas Mexicana?',
    refinementSubtitle: 'Esto nos ayuda a elegir cómo se comunicarán',
    refinementOptions: ['No conoce LSM', 'Conoce LSM'],
    cortos: ['No sabe LSM', 'Sabe LSM'],
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

  /// Tarjeta leida del QR. Cuando existe, ya sabemos TAMBIEN si la otra
  /// persona conoce LSM y como se llama, asi que no hay que preguntarle
  /// el refinamiento: se confirma y se entra directo a la conversacion.
  TarjetaPerfil? _detectedTarjeta;

  ProfileType? _expandedProfile;
  int? _expandedOptionIndex;
  bool _selectedOyente = false;

  Timer? _scanTimer;

  static const Color _grayText = ColoresUnivoz.tintaSuave;
  static const Color _comenzarColor = ColoresUnivoz.morado;

  /// El perfil propio cambió desde el chip de arriba. Hay que redibujar
  /// y limpiar lo que estuviera elegido: los perfiles que se ofrecen para
  /// la otra persona dependen del propio (ver [_selectableProfiles]), así
  /// que una selección hecha con el perfil anterior puede haber dejado de
  /// ser una opción válida.
  void _alCambiarMiPerfil() {
    _scanTimer?.cancel();
    ConversationProfile.resetOtro();
    if (!mounted) return;
    setState(() {
      _expandedProfile = null;
      _expandedOptionIndex = null;
      _selectedOyente = false;
      _detectedProfile = null;
      _scanning = false;
    });
  }

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
      if (!mounted) return;
      Navigator.of(context).push(
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
    if (!isCurrent() || !mounted) return;
    Navigator.of(context).push(
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
    if (mounted) {
      SemanticsService.sendAnnouncement(
          View.of(context), message, TextDirection.ltr);
    }
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
      Navigator.of(context).push(
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
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
    }
  }

  Future<void> _startScan() async {
    BlindNarrator.interruptFlow();
    setState(() {
      _scanning = true;
      _detectedProfile = null;
      _detectedTarjeta = null;
      _expandedProfile = null;
      _selectedOyente = false;
    });
    final tarjeta = await Navigator.of(context).push<TarjetaPerfil>(
      MaterialPageRoute(builder: (_) => const EscanearCodigoScreen()),
    );
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _detectedTarjeta = tarjeta;
      _detectedProfile = tarjeta?.tipo;
    });
    // tarjeta == null es salirse o no dar permiso de camara. No es un
    // error que haya que anunciar: la cuadricula manual sigue ahi abajo
    // y es el camino de siempre.
  }

  void _confirmDetected() {
    if (_detectedProfile == null) return;
    final ProfileType confirmed = _detectedProfile!;

    // Con un codigo escaneado ya sabemos si conoce LSM, asi que
    // preguntarselo seria redundante: se entra directo a la conversacion.
    final tarjeta = _detectedTarjeta;
    if (tarjeta != null) {
      ConversationProfile.other = confirmed;
      ConversationProfile.otherKnowsLsm = tarjeta.sabeLsm;
      setState(() {
        _detectedProfile = null;
        _detectedTarjeta = null;
      });
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
      return;
    }

    setState(() {
      _expandedProfile = confirmed;
      _expandedOptionIndex = null;
      _detectedProfile = null;
    });
    _announceRefinement(confirmed);
  }

  void _rejectDetected() {
    setState(() {
      _detectedProfile = null;
      _detectedTarjeta = null;
    });
  }

  /// Preguntas que no cambian nada y se saltan:
  ///  - de una persona ciega no importa si usa lector de pantalla (el
  ///    teléfono es el tuyo);
  ///  - si tú eres sordo/a o mudo/a y sabes LSM, la otra persona sorda o
  ///    muda con la que necesitas la app es porque NO sabe LSM (si supiera,
  ///    se entenderían firmando).
  bool _preguntaSobra(ProfileType type) {
    if (type == ProfileType.ciego) return true;
    final mine = ConversationProfile.mine;
    final yoFirmo = (mine == ProfileType.sordo || mine == ProfileType.mudo) &&
        ConversationProfile.mineKnowsLsm;
    return yoFirmo && (type == ProfileType.sordo || type == ProfileType.mudo);
  }

  void _expandCard(ProfileType type) {
    BlindNarrator.interruptFlow();
    if (_preguntaSobra(type)) {
      ConversationProfile.other = type;
      ConversationProfile.otherKnowsLsm = false;
      setState(() {
        _expandedProfile = null;
        _expandedOptionIndex = null;
        _selectedOyente = false;
        _detectedProfile = null;
      });
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MainShellScreen(
            initialIndex: 1,
            modo: resolverComunicacionModo(),
          ),
        ),
      );
      return;
    }
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
                  // El perfil propio se eligió en la pantalla anterior (o
                  // venía guardado y esa pantalla ni se mostró). Acá es
                  // donde se nota si está mal, así que tiene que poder
                  // corregirse sin regresar.
                  Flexible(child: MenuPerfil(onCambio: _alCambiarMiPerfil)),
                  const ExcludeSemantics(
                    child: Icon(Icons.favorite, color: Color(0xFFB84FCE)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '¿Con quién te vas\na comunicar?',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 14),
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
                        _comenzarColor.withValues(alpha: 0.4),
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
  /// + cuadrícula (2 tarjetas por fila, según cuántos perfiles apliquen —
  /// ver [_selectableProfiles]). Sin desplazar: las filas se reparten el
  /// alto que queda.
  Widget _buildMainContent({required Key key}) {
    final cards = [
      for (final p in _selectableProfiles) _buildCard(profileConfigs[p]!),
      if (!_sinBarreraConCiegoUOyente) _buildOyenteButton(),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < cards.length; i += 2) {
      final segunda = i + 1 < cards.length ? cards[i + 1] : null;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 12));
      rows.add(
        Expanded(
          child: Row(
            children: [
              Expanded(child: cards[i]),
              const SizedBox(width: 12),
              Expanded(child: segunda ?? const SizedBox.shrink()),
            ],
          ),
        ),
      );
    }

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildScanButton(),
        if (_detectedProfile != null) ...[
          const SizedBox(height: 12),
          _buildDetectedCard(profileConfigs[_detectedProfile]!),
        ],
        const SizedBox(height: 14),
        const Row(
          children: [
            Expanded(child: Divider()),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'o elige',
                semanticsLabel: 'o selecciona su perfil manualmente',
                style: TextStyle(
                  color: _grayText,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Expanded(child: Divider()),
          ],
        ),
        const SizedBox(height: 12),
        ...rows,
      ],
    );
  }

  Widget _buildScanButton() {
    return GestureDetector(
      onTap: _scanning ? null : _startScan,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Theme.of(context).colorScheme.primary, const Color(0xFFB84FCE)],
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
              const Icon(Icons.qr_code_scanner,
                  color: Colors.white, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                _scanning
                    ? 'Abriendo la cámara...'
                    : 'Escanear su código',
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
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: config.cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: SizedBox(
              width: 64,
              height: 48,
              child: Image.asset(
                'assets/ilustraciones/${config.ilustracion}.png',
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
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
                    color: config.textColor.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: config.textColor),
            tooltip: 'No es correcto',
            onPressed: _rejectDetected,
          ),
          IconButton(
            icon: Icon(Icons.check_circle, color: config.textColor),
            tooltip: 'Es correcto',
            onPressed: _confirmDetected,
          ),
        ],
      ),
    );
  }

  Widget _buildCard(ProfileConfig config) {
    final other = _otherPersonConfigs[config.type]!;
    return TarjetaDibujo(
      ilustracion: config.ilustracion,
      titulo: config.corto,
      lector: '${other.title}. ${other.subtitle}',
      color: config.cardColor,
      colorTexto: config.textColor,
      seleccionada: false,
      onTap: () => _expandCard(config.type),
    );
  }

  /// "Es oyente": antes un botón verde; ahora en el morado tenue del
  /// diseño de Lucía.
  Widget _buildOyenteButton() {
    return TarjetaDibujo(
      ilustracion: 'oyente',
      titulo: 'Oyente',
      lector: 'Es oyente, sin discapacidades',
      color: ColoresUnivoz.moradoTenue,
      seleccionada: _selectedOyente,
      onTap: () {
        BlindNarrator.interruptFlow();
        setState(() {
          _selectedOyente = true;
          _expandedProfile = null;
          _detectedProfile = null;
        });
      },
    );
  }

  Widget _buildExpandedCard(
    ProfileConfig config, {
    required Key key,
  }) {
    final other = _otherPersonConfigs[config.type]!;
    final dibujos = refinementConfigs[config.type]!.ilustraciones;
    return Container(
      key: key,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 14),
      decoration: BoxDecoration(
        color: config.cardColor,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: SizedBox(
                  width: 56,
                  height: 42,
                  child: Image.asset(
                    'assets/ilustraciones/${config.ilustracion}.png',
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    other.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: config.textColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.close, color: config.textColor),
                tooltip: 'Cerrar',
                onPressed: _collapseCard,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              other.refinementTitle,
              maxLines: 2,
              style: TextStyle(
                color: config.textColor,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Row(
                children: [
                  for (var i = 0; i < other.refinementOptions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: TarjetaDibujo(
                        ilustracion: dibujos[i],
                        titulo: other.cortos[i],
                        lector: other.refinementOptions[i],
                        color: Colors.white,
                        seleccionada: _expandedOptionIndex == i,
                        onTap: () => setState(() => _expandedOptionIndex = i),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
