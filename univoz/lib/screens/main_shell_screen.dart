import 'package:flutter/material.dart';
import 'package:senas_core/pantalla_avatar.dart';
import 'comunicarse_screen.dart';
import '../services/conversation_profile.dart';

/// Contenedor principal de la app: muestra la sección "Aprender" (el avatar
/// 3D real de senas_core, [PantallaAvatar] — se le escribe, se elige una
/// seña de una lista, o se le habla, y el avatar hace la seña) o la sección
/// "Comunicarse" ([ComunicarseScreen]), según [initialIndex] — lo decide
/// [PurposeScreen] antes de llegar acá.
///
/// Ya no hay ningún menú/selector propio arriba para cambiar entre las dos
/// desde esta misma pantalla: primero hubo una barra de navegación fija
/// abajo, después un selector compacto arriba, y ambos se quitaron para
/// dejar de tener un menú permanente encima de cada sección. Para ir a la
/// otra sección hay que volver al menú principal y elegir de nuevo — igual
/// que para "Traducir una seña" o "Configuración" (ver [PurposeScreen]).
class MainShellScreen extends StatelessWidget {
  final int initialIndex;

  /// Cómo se debe comunicar la sección "Comunicarse" según la combinación
  /// de perfiles elegida (ver [resolverComunicacionModo]/[ComunicacionModo]).
  /// Solo importa cuando [initialIndex] es 1; para "Aprender" (0) esta
  /// sección ni siquiera se construye.
  final ComunicacionModo modo;

  const MainShellScreen({
    super.key,
    this.initialIndex = 0,
    this.modo = ComunicacionModo.textoVoz,
  });

  @override
  Widget build(BuildContext context) {
    if (initialIndex == 1) {
      return ComunicarseScreen(modo: modo, isActiveTab: true);
    }
    // El avatar 3D real de senas_core (escribís, elegís de una lista, o
    // hablás una palabra, y el avatar hace la seña) es la sección
    // "Aprender".
    return const PantallaAvatar();
  }
}
