import 'package:flutter/material.dart';
import 'package:senas_core/tema_univoz.dart';

/// Perfiles de persona y su configuración de presentación.
///
/// Vive en services/ y no en screens/ a propósito: [ConversationProfile] y
/// [PerfilGuardado] necesitan [ProfileType], y antes lo importaban desde
/// profile_selection_screen.dart — es decir, un servicio dependía de una
/// pantalla. Con esto la dependencia va en el sentido correcto: las
/// pantallas dependen de los servicios, nunca al revés.
///
/// profile_selection_screen.dart re-exporta este archivo, así que los
/// `import 'profile_selection_screen.dart' show ProfileType;` que ya
/// existían siguen funcionando sin tocarlos.

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

  /// Dibujo de la tarjeta (assets/ilustraciones/<nombre>.png).
  final String ilustracion;

  /// Una o dos palabras para la pantalla; [title] y [subtitle] completos
  /// quedan para TalkBack.
  final String corto;

  const ProfileConfig({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconBgColor,
    required this.cardColor,
    required this.textColor,
    required this.ilustracion,
    required this.corto,
  });
}

/// Configuración de las preguntas de refinamiento por perfil.
/// AJUSTA estos textos: solo el de "sordo" viene confirmado por el diseño
/// que compartiste; los demás son placeholders razonables.
class RefinementConfig {
  final String title;
  final String subtitle;
  final List<String> options;

  /// Dibujo y palabra corta de cada opción, en el orden de [options].
  final List<String> ilustraciones;
  final List<String> cortos;

  const RefinementConfig({
    required this.title,
    required this.subtitle,
    required this.options,
    required this.ilustraciones,
    required this.cortos,
  });
}

const Map<ProfileType, ProfileConfig> profileConfigs = {
  ProfileType.ciego: ProfileConfig(
    type: ProfileType.ciego,
    title: 'Soy ciego/a',
    subtitle: 'Uso la app con voz y dictado',
    icon: Icons.visibility_off,
    iconBgColor: ColoresUnivoz.moradoClaro,
    cardColor: ColoresUnivoz.morado,
    textColor: Colors.white,
    ilustracion: 'ciego',
    corto: 'Ciego/a',
  ),
  ProfileType.sordo: ProfileConfig(
    type: ProfileType.sordo,
    title: 'Soy sordo/a',
    subtitle: 'Uso subtítulos, señas, LSM y alertas visuales',
    icon: Icons.hearing_disabled,
    iconBgColor: Color(0xFFF5A855),
    cardColor: Color(0xFFA8C5F0),
    textColor: ColoresUnivoz.tinta,
    ilustracion: 'sordo',
    corto: 'Sordo/a',
  ),
  ProfileType.mudo: ProfileConfig(
    type: ProfileType.mudo,
    title: 'Soy mudo/a',
    subtitle: 'Escucho y veo, pero la app habla por mí',
    icon: Icons.volume_up,
    iconBgColor: Color(0xFFE88B8B),
    cardColor: Color(0xFFF3A9A0),
    textColor: ColoresUnivoz.tinta,
    ilustracion: 'mudo',
    corto: 'Mudo/a',
  ),
  ProfileType.prestarCelular: ProfileConfig(
    type: ProfileType.prestarCelular,
    title: 'Prestaré mi Celular',
    subtitle: 'Facilitar comunicación',
    icon: Icons.pan_tool,
    iconBgColor: Color(0xFFE88BC2),
    cardColor: Color(0xFFF0C869),
    textColor: ColoresUnivoz.tinta,
    ilustracion: 'prestar',
    corto: 'Presto mi celular',
  ),
};

/// Preguntas de refinamiento para cada perfil.
/// Solo "sordo" está confirmado por tu mockup; edita el resto libremente.
const Map<ProfileType, RefinementConfig> refinementConfigs = {
  ProfileType.ciego: RefinementConfig(
    title: '¿Cómo prefieres usar la app?',
    subtitle: 'Elige una opción para personalizar tu experiencia',
    options: ['No uso lector de pantalla', 'Uso lector de pantalla'],
    ilustraciones: ['lector_no', 'lector_si'],
    cortos: ['Sin lector', 'Con lector'],
  ),
  ProfileType.sordo: RefinementConfig(
    title: '¿Cómo te puedo ayudar?',
    subtitle: 'Elige un perfil para personalizar tu experiencia',
    options: ['No conozco LSM', 'Conozco LSM'],
    ilustraciones: ['lsm_no', 'lsm_si'],
    cortos: ['No sé LSM', 'Sé LSM'],
  ),
  ProfileType.mudo: RefinementConfig(
    title: '¿Conoces Lengua de Señas Mexicana?',
    subtitle: 'Esto nos ayuda a elegir cómo te comunicarás',
    options: ['No conozco LSM', 'Conozco LSM'],
    ilustraciones: ['lsm_no', 'lsm_si'],
    cortos: ['No sé LSM', 'Sé LSM'],
  ),
  ProfileType.prestarCelular: RefinementConfig(
    title: '¿Quién usará el celular?',
    subtitle: 'Elige el perfil de la persona que lo usará',
    options: [
      'Persona con discapacidad visual',
      'Persona con discapacidad auditiva',
      'Persona con discapacidad del habla',
    ],
    ilustraciones: ['ciego', 'sordo', 'mudo'],
    cortos: ['Ciego/a', 'Sordo/a', 'Mudo/a'],
  ),
};

/// Texto corto del perfil de una persona, para el chip de la barra y el
/// menú. Corto a propósito: comparte renglón con la flecha de regreso y
/// el corazón, así que "Oyente, sin discapacidades" no cabe.
///
/// Devuelve null cuando no hay perfil, o cuando es `prestarCelular` —
/// que no es un perfil de persona sino un camino que ProfileSelection
/// ya traduce al perfil real de quien va a usar el teléfono.
String? descripcionPerfil(ProfileType? tipo, bool sabeLsm) {
  switch (tipo) {
    case null:
    case ProfileType.prestarCelular:
      return null;
    case ProfileType.ciego:
      return 'Ciego/a';
    case ProfileType.oyente:
      return 'Oyente';
    case ProfileType.sordo:
      return sabeLsm ? 'Sordo/a · LSM' : 'Sordo/a · sin LSM';
    case ProfileType.mudo:
      return sabeLsm ? 'Mudo/a · LSM' : 'Mudo/a · sin LSM';
  }
}
