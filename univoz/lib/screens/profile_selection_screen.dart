import 'package:flutter/material.dart';
import 'other_person_profile_screen.dart';
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';

// NOTA SOBRE ACCESIBILIDAD:
// Cuando TalkBack está activo, PurposeScreen manda al usuario directo a
// OtherPersonProfileScreen (el perfil "ciego" ya se asume ahí), así que
// esta pantalla solo se ve sin TalkBack: es puramente táctil y en
// silencio, salvo que aquí mismo se confirme manualmente el perfil
// "ciego" (por ejemplo, alguien que configura el teléfono por otra
// persona), en cuyo caso activamos el mismo flujo de preguntas y
// respuestas por voz que usa TalkBack para las pantallas siguientes
// (ver _onContinue y BlindNarrator.activateManualBlindMode).

/// Identifica cada perfil disponible en el flujo de onboarding.
enum ProfileType { ciego, sordo, mudo, prestarCelular, oyente }

/// Configuración visual y de contenido de cada tarjeta de perfil.
class ProfileConfig {
  final ProfileType type;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconBgColor;
  final Color cardColor;
  final Color textColor;

  const ProfileConfig({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconBgColor,
    required this.cardColor,
    required this.textColor,
  });
}

/// Configuración de las preguntas de refinamiento por perfil.
/// AJUSTA estos textos: solo el de "sordo" viene confirmado por el diseño
/// que compartiste; los demás son placeholders razonables.
class RefinementConfig {
  final String title;
  final String subtitle;
  final List<String> options;

  const RefinementConfig({
    required this.title,
    required this.subtitle,
    required this.options,
  });
}

const Map<ProfileType, ProfileConfig> profileConfigs = {
  ProfileType.ciego: ProfileConfig(
    type: ProfileType.ciego,
    title: 'Soy ciego/a',
    subtitle: 'Uso la app con voz y dictado',
    icon: Icons.visibility_off,
    iconBgColor: Color(0xFFB388E8),
    cardColor: Color(0xFF8B5CF6),
    textColor: Colors.white,
  ),
  ProfileType.sordo: ProfileConfig(
    type: ProfileType.sordo,
    title: 'Soy sordo/a',
    subtitle: 'Uso subtítulos, señas, LSM y alertas visuales',
    icon: Icons.hearing_disabled,
    iconBgColor: Color(0xFFF5A855),
    cardColor: Color(0xFFA8C5F0),
    textColor: Color(0xFF1A1A2E),
  ),
  ProfileType.mudo: ProfileConfig(
    type: ProfileType.mudo,
    title: 'Soy mudo/a',
    subtitle: 'Escucho y veo, pero la app habla por mí',
    icon: Icons.volume_up,
    iconBgColor: Color(0xFFE88B8B),
    cardColor: Color(0xFFF3A9A0),
    textColor: Color(0xFF1A1A2E),
  ),
  ProfileType.prestarCelular: ProfileConfig(
    type: ProfileType.prestarCelular,
    title: 'Prestaré mi Celular',
    subtitle: 'Facilitar comunicación',
    icon: Icons.pan_tool,
    iconBgColor: Color(0xFFE88BC2),
    cardColor: Color(0xFFF0C869),
    textColor: Color(0xFF1A1A2E),
  ),
};

/// Preguntas de refinamiento para cada perfil.
/// Solo "sordo" está confirmado por tu mockup; edita el resto libremente.
const Map<ProfileType, RefinementConfig> refinementConfigs = {
  ProfileType.ciego: RefinementConfig(
    title: '¿Cómo prefieres usar la app?',
    subtitle: 'Elige una opción para personalizar tu experiencia',
    options: ['No uso lector de pantalla', 'Uso lector de pantalla'],
  ),
  ProfileType.sordo: RefinementConfig(
    title: '¿Cómo te puedo ayudar?',
    subtitle: 'Elige un perfil para personalizar tu experiencia',
    options: ['No conozco LSM', 'Conozco LSM'],
  ),
  ProfileType.mudo: RefinementConfig(
    title: '¿Conoces Lengua de Señas Mexicana?',
    subtitle: 'Esto nos ayuda a elegir cómo te comunicarás',
    options: ['No conozco LSM', 'Conozco LSM'],
  ),
  ProfileType.prestarCelular: RefinementConfig(
    title: '¿Quién usará el celular?',
    subtitle: 'Elige el perfil de la persona que lo usará',
    options: [
      'Persona con discapacidad visual',
      'Persona con discapacidad auditiva',
      'Persona con discapacidad del habla',
    ],
  ),
};

class ProfileSelectionScreen extends StatefulWidget {
  const ProfileSelectionScreen({super.key});

  @override
  State<ProfileSelectionScreen> createState() =>
      _ProfileSelectionScreenState();
}

class _ProfileSelectionScreenState extends State<ProfileSelectionScreen> {
  // Perfil cuya tarjeta está expandida mostrando sus opciones (null = grid).
  ProfileType? _expandedProfile;
  // Índice de la opción de refinamiento elegida dentro de la tarjeta expandida.
  int? _expandedOptionIndex;
  bool _selectedOyente = false;
  // Solo aplica dentro de "Prestaré mi Celular", cuando la persona que
  // usará el teléfono es sorda o muda (índices 1 y 2 de
  // refinementConfigs[prestarCelular]): a diferencia de elegir "soy
  // sordo/a" o "soy mudo/a" directamente (que ya preguntan "¿conoces
  // LSM?" en su propio refinamiento), aquí la primera pregunta es qué
  // discapacidad tiene esa persona, así que hace falta una segunda
  // pregunta para saber si conoce LSM (ver _buildExpandedCard).
  bool? _prestadoConoceLsm;

  static const Color _bgColor = Color(0xFFF7F2FA);
  static const Color _grayText = Color(0xFF6B6478);

  @override
  void initState() {
    super.initState();
    // Esta pantalla es el verdadero punto de partida de una conversación
    // nueva (ver PurposeScreen: "Comunicarme" siempre empuja una
    // instancia nueva de ProfileSelectionScreen). Reiniciamos aquí
    // ConversationProfile para que no queden pegados el perfil o las
    // respuestas de "¿conoces LSM?" de un intento anterior si, en la
    // misma sesión de la app, alguien vuelve atrás y arma una
    // conversación distinta sin cerrar la app.
    ConversationProfile.reset();
  }
  static const Color _comenzarColor = Color(0xFF8F84A6);
  static const Color _radioCardColor = Color(0xFF241B35);
  static const Color _radioAccent = Color(0xFFB388E8);

  /// `true` si, dentro de "Prestaré mi Celular", la opción elegida es
  /// "persona con discapacidad auditiva" (índice 1, sordo/a) o "persona
  /// con discapacidad del habla" (índice 2, mudo/a) — los dos casos que
  /// necesitan la pregunta extra de "¿conoce LSM?" (ver
  /// _prestadoConoceLsm) antes de poder continuar.
  bool get _prestadoNecesitaPreguntaLsm =>
      _expandedProfile == ProfileType.prestarCelular &&
      (_expandedOptionIndex == 1 || _expandedOptionIndex == 2);

  bool get _canContinue {
    if (_expandedProfile != null) {
      if (_expandedOptionIndex == null) return false;
      if (_prestadoNecesitaPreguntaLsm) return _prestadoConoceLsm != null;
      return true;
    }
    return _selectedOyente;
  }

  void _onContinue() {
    if (_selectedOyente) {
      ConversationProfile.mine = ProfileType.oyente;
      ConversationProfile.mineKnowsLsm = false;
      // Si antes se había activado el modo por voz a mano (por ejemplo,
      // se eligió "ciego" y luego se regresó con "atrás" para elegir
      // otro perfil), lo apagamos: ya no aplica, y sin esto se quedaría
      // encendido el resto de la sesión aunque el perfil ya no sea
      // "ciego" (ver BlindNarrator.disable).
      if (BlindNarrator.talkBackFlow) {
        BlindNarrator.disable();
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const OtherPersonProfileScreen()),
      );
      return;
    }
    if (_expandedProfile != null && _expandedOptionIndex != null) {
      final refinement = refinementConfigs[_expandedProfile]!;
      assert(refinement.options.isNotEmpty);
      // El propósito (comunicarme vs. aprender LSM) ya se preguntó en
      // PurposeScreen antes de llegar aquí, así que sin importar la
      // respuesta de refinamiento seguimos con el flujo de comunicación:
      // elegir el perfil de la persona con la que se va a comunicar.

      // "Prestaré mi Celular": quien realmente va a usar la app es la
      // persona con la discapacidad elegida en el refinamiento, no quien
      // lo está configurando. Antes esto guardaba el perfil como
      // "prestarCelular" tal cual, así que aunque se eligiera "persona
      // con discapacidad visual" nunca se activaba el modo por voz para
      // quien de verdad iba a usar el teléfono. Ahora usamos el perfil
      // real de esa persona.
      const lentProfiles = [
        ProfileType.ciego,
        ProfileType.sordo,
        ProfileType.mudo,
      ];
      final bool esPrestado = _expandedProfile == ProfileType.prestarCelular;
      final ProfileType effectiveProfile =
          esPrestado ? lentProfiles[_expandedOptionIndex!] : _expandedProfile!;
      ConversationProfile.mine = effectiveProfile;

      // La pregunta de refinamiento de sordo/mudo es "¿Conoces LSM?"
      // (índice 1 = "Conozco LSM"). Antes se preguntaba pero la
      // respuesta nunca se guardaba, así que ComunicarseScreen no tenía
      // forma de saber si TÚ sabes señas para decidir, por ejemplo, si
      // hace falta la cámara al hablar con otra persona sorda/muda (ver
      // resolverComunicacionModo en conversation_profile.dart). En el
      // camino "Prestaré mi Celular", cuando la persona que usará el
      // teléfono es sorda o muda, esa pregunta es la segunda ("¿conoce
      // LSM?", ver _prestadoConoceLsm/_buildExpandedCard) porque la
      // primera aquí es qué discapacidad tiene, no si sabe señas.
      ConversationProfile.mineKnowsLsm = esPrestado
          ? (_prestadoNecesitaPreguntaLsm &&
              (_prestadoConoceLsm ?? false))
          : (effectiveProfile == ProfileType.sordo ||
                  effectiveProfile == ProfileType.mudo) &&
              _expandedOptionIndex == 1;

      // Si el perfil real es "ciego" (directamente, o porque se prestó
      // el celular a alguien ciego), activamos el flujo de preguntas y
      // respuestas por voz para las pantallas siguientes (igual que si
      // hubiéramos detectado TalkBack). Si NO es ciego pero el modo por
      // voz había quedado prendido de una vuelta anterior (ver el
      // comentario en la rama "oyente" de arriba), lo apagamos.
      if (effectiveProfile == ProfileType.ciego) {
        BlindNarrator.activateManualBlindMode();
      } else if (BlindNarrator.talkBackFlow) {
        BlindNarrator.disable();
      }
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const OtherPersonProfileScreen()),
      );
    }
  }

  void _expandCard(ProfileType type) {
    setState(() {
      _expandedProfile = type;
      _expandedOptionIndex = null;
      _selectedOyente = false;
      _prestadoConoceLsm = null;
    });
  }

  void _collapseCard() {
    setState(() {
      _expandedProfile = null;
      _expandedOptionIndex = null;
      _prestadoConoceLsm = null;
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
                'Elige tu perfil',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1A1A2E),
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Elige un perfil para personalizar tu experiencia',
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
                  child: _expandedProfile == null
                      ? _buildGrid(key: const ValueKey('grid'))
                      : _buildExpandedCard(
                          profileConfigs[_expandedProfile]!,
                          refinementConfigs[_expandedProfile]!,
                          key: ValueKey(_expandedProfile),
                        ),
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

  /// Vista normal: cuadrícula 2x2 + botón "oyente".
  Widget _buildGrid({required Key key}) {
    return SingleChildScrollView(
      key: key,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _buildCard(profileConfigs[ProfileType.ciego]!)),
              const SizedBox(width: 14),
              Expanded(child: _buildCard(profileConfigs[ProfileType.sordo]!)),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _buildCard(profileConfigs[ProfileType.mudo]!)),
              const SizedBox(width: 14),
              Expanded(
                  child: _buildCard(
                      profileConfigs[ProfileType.prestarCelular]!)),
            ],
          ),
          const SizedBox(height: 14),
          _buildOyenteButton(),
        ],
      ),
    );
  }

  Widget _buildCard(ProfileConfig config) {
    return GestureDetector(
      onTap: () => _expandCard(config.type),
      child: Container(
        height: 150,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: config.cardColor,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: config.iconBgColor,
              child: Icon(config.icon, size: 18, color: Colors.white),
            ),
            const Spacer(),
            Text(
              config.title,
              style: TextStyle(
                color: config.textColor,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              config.subtitle,
              style: TextStyle(
                color: config.textColor.withOpacity(0.85),
                fontSize: 11,
                fontWeight: FontWeight.w500,
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
        setState(() {
          _selectedOyente = true;
          _expandedProfile = null;
          _expandedOptionIndex = null;
        });
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 18),
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
        child: const Text(
          'Soy oyente y no tengo\ndiscapacidades',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }

  /// Tarjeta expandida: ocupa el espacio de toda la cuadrícula y muestra
  /// las opciones de refinamiento (radio buttons) dentro de sí misma.
  Widget _buildExpandedCard(
    ProfileConfig config,
    RefinementConfig refinement, {
    required Key key,
  }) {
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
                    config.title,
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
              refinement.title,
              style: TextStyle(
                color: config.textColor,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              refinement.subtitle,
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
                children: List.generate(refinement.options.length, (i) {
                  final bool isSelected = _expandedOptionIndex == i;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: i == refinement.options.length - 1 ? 0 : 8,
                    ),
                    child: Semantics(
                      button: true,
                      selected: isSelected,
                      label: refinement.options[i],
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => setState(() {
                            _expandedOptionIndex = i;
                            // Cambiar de opción (por ejemplo, de "persona
                            // con discapacidad auditiva" a "del habla")
                            // invalida cualquier respuesta anterior de
                            // "¿conoce LSM?": vuelve a preguntarse abajo
                            // si la nueva opción también la necesita.
                            _prestadoConoceLsm = null;
                          }),
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
                                    refinement.options[i],
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
            if (config.type == ProfileType.prestarCelular &&
                _prestadoNecesitaPreguntaLsm) ...[
              const SizedBox(height: 16),
              _buildPrestadoLsmPregunta(config),
            ],
          ],
        ),
      ),
    );
  }

  /// Segunda pregunta dentro de "Prestaré mi Celular", solo cuando la
  /// persona que usará el teléfono es sorda o muda (ver
  /// _prestadoNecesitaPreguntaLsm): a diferencia de elegir "soy sordo/a"
  /// o "soy mudo/a" directamente (que ya preguntan esto en su propio
  /// refinamiento), aquí hace falta preguntarlo aparte porque la primera
  /// pregunta fue sobre qué discapacidad tiene, no si sabe LSM.
  Widget _buildPrestadoLsmPregunta(ProfileConfig config) {
    const opciones = ['No conoce LSM', 'Conoce LSM'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '¿Esa persona conoce Lengua de Señas Mexicana?',
          style: TextStyle(
            color: config.textColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: _radioCardColor,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            children: List.generate(opciones.length, (i) {
              final bool conoce = i == 1;
              final bool isSelected = _prestadoConoceLsm == conoce;
              return Padding(
                padding: EdgeInsets.only(
                  bottom: i == opciones.length - 1 ? 0 : 8,
                ),
                child: Semantics(
                  button: true,
                  selected: isSelected,
                  label: opciones[i],
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () =>
                          setState(() => _prestadoConoceLsm = conoce),
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
                                border:
                                    Border.all(color: _radioAccent, width: 2.5),
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
                                opciones[i],
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
    );
  }
}
