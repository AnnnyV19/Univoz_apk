import 'package:flutter/material.dart';
import 'package:senas_core/modo_desarrollador.dart';
import 'package:senas_core/pantalla_ajustes.dart';
import 'package:senas_core/pantalla_captura.dart';
import 'package:senas_core/pantalla_espejo.dart';
import 'package:senas_core/pantalla_sync.dart';
import '../services/perfil_guardado.dart';
import '../services/permiso_camara.dart';
import 'privacidad_screen.dart';
import 'sos.dart';
import 'univoz_shared_widgets.dart';

/// Texto de versión al pie de Configuración. Tocarlo 7 veces enciende o
/// apaga el modo desarrollador (ver [DetectorModoDesarrollador]).
const String kVersionApp = 'Univoz 0.9.0 beta';

/// Pantalla "Configuración" del apartado de señas: ajustes de reconocimiento
/// el modo espejo y sincronizar el diccionario. Con el modo desarrollador
/// encendido también aparece agregar muestras.
/// "Reconocer seña" (la cámara que traduce una seña suelta) y "Avatar 3D"
/// ya no viven acá — el primero se abre directo desde "Traducir una seña"
/// en el menú principal (ver PurposeScreen._abrirCamaraTraductora) y el
/// segundo es la pestaña "Aprender" de MainShellScreen — así que esta
/// pantalla se llega solo desde la tuerca ("Configuración") del menú
/// principal.
///
/// "Sincronizar" (PantallaSync, de senas_core) no vivía en ningún menú de
/// esta app todavía — quedaba armada pero sin ningún botón que la abriera.
/// No necesita permiso de cámara (solo internet, ya cubierto por el
/// permiso de INTERNET del manifest), así que se abre directo, sin pasar
/// por _abrirConCamara.
class TraducirSenasScreen extends StatefulWidget {
  const TraducirSenasScreen({super.key});

  @override
  State<TraducirSenasScreen> createState() => _TraducirSenasScreenState();
}

class _TraducirSenasScreenState extends State<TraducirSenasScreen> {
  /// Abre una pantalla que usa la cámara, pidiendo antes el permiso.
  Future<void> _abrirConCamara(Widget pantalla) async {
    if (!await pedirPermisoCamara(context)) return;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => pantalla));
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colores.surface,
      appBar: const UnivozHeader(subtitle: 'Configuración de señas'),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Configuración de reconocimiento de señas',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 4),
              Text(
                'Ajusta cómo la cámara reconoce tus señas y mantén al día '
                'tu diccionario.',
                style: TextStyle(fontSize: 12, color: colores.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Expanded(
                // El modo desarrollador se enciende o apaga desde la versión
                // de abajo: la lista se rearma sola al cambiar.
                child: ValueListenableBuilder<bool>(
                  valueListenable: ModoDesarrollador.notificador,
                  builder: (context, dev, _) => ListView(
                    children: [
                      if (dev)
                        _tarjeta(
                          icono: Icons.add_a_photo_outlined,
                          titulo: 'Agregar muestras',
                          detalle: 'Graba una seña nueva y etiquétala con su '
                              'palabra para mejorar el reconocimiento.',
                          onTap: () => _abrirConCamara(const PantallaCaptura()),
                        ),
                      _tarjeta(
                        icono: Icons.flip_camera_android_outlined,
                        titulo: 'Espejo',
                        detalle: 'Muévete frente a la cámara y el avatar te '
                            'copia en vivo.',
                        onTap: () => _abrirConCamara(
                            const PantallaEspejo(modoProducto: true)),
                      ),
                      // Sin cámara: solo se cambian números guardados.
                      _tarjeta(
                        icono: Icons.tune,
                        titulo: 'Ajustes de reconocimiento',
                        detalle:
                            'Afina qué tan estricto es el reconocimiento y '
                            'elige la cámara frontal o trasera.',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const PantallaAjustes()),
                        ),
                      ),
                      _tarjeta(
                        icono: Icons.cloud_sync_outlined,
                        titulo: 'Sincronizar',
                        detalle: dev
                            ? 'Sube tus muestras nuevas al equipo y baja '
                                'el diccionario aprobado. Necesita internet, '
                                'no cámara.'
                            : 'Descarga el diccionario más reciente. '
                                'Necesita internet, no cámara.',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const PantallaSync()),
                        ),
                      ),
                      _tarjeta(
                        icono: Icons.emergency_outlined,
                        titulo: 'Contacto de emergencia',
                        detalle: PerfilGuardado.contactoEmergencia == null
                            ? 'Elige a quién avisa el botón SOS.'
                            : 'Avisas a ${PerfilGuardado.contactoEmergencia!.nombre}. '
                                'Toca para cambiarlo.',
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const PantallaContactoEmergencia()),
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                      _tarjeta(
                        icono: Icons.privacy_tip_outlined,
                        titulo: 'Privacidad',
                        detalle: 'Qué hace Univoz con tu cámara, tu voz y '
                            'tus datos, y cómo borrarlos.',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const PrivacidadScreen()),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: DetectorModoDesarrollador(
                  child: Text(
                    kVersionApp,
                    style: TextStyle(
                        fontSize: 12, color: colores.onSurfaceVariant),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const SosButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tarjeta({
    required IconData icono,
    required String titulo,
    required String detalle,
    required VoidCallback onTap,
  }) {
    final colores = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: colores.primaryContainer,
                child: Icon(icono, color: colores.primary, size: 26),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titulo,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(detalle,
                        style: TextStyle(
                            fontSize: 12.5, color: colores.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: colores.outline),
            ],
          ),
        ),
      ),
    );
  }
}
