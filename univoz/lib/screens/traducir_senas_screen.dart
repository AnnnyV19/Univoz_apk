import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:permission_handler/permission_handler.dart';
import 'package:senas_core/pantalla_ajustes.dart';
import 'package:senas_core/pantalla_captura.dart';
import 'package:senas_core/pantalla_espejo.dart';
import 'package:senas_core/pantalla_sync.dart';
import 'univoz_shared_widgets.dart';

/// Pantalla "Configuración" del apartado de señas: agregar muestras nuevas,
/// modo espejo, ajustes de reconocimiento y sincronizar con el equipo.
/// "Reconocer seña" (la cámara que traduce una seña suelta) y "Avatar 3D"
/// ya no viven acá — el primero se abre directo desde "Traducir una seña"
/// en el menú principal (ver PurposeScreen._abrirCamaraTraductora) y el
/// segundo es la pestaña "Aprender" de MainShellScreen — así que esta
/// pantalla se llega solo como la 4ta opción "Configuración" del menú
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
  static const Color _bgColor = Color(0xFFF7F2FA);

  bool _pidiendoPermiso = false;

  /// Pide permiso de cámara antes de abrir cualquier pantalla que la use.
  /// Devuelve true si ya se puede continuar.
  Future<bool> _asegurarPermisoCamara() async {
    if (kIsWeb) return true;
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    setState(() => _pidiendoPermiso = true);
    final resultado = await Permission.camera.request();
    if (mounted) setState(() => _pidiendoPermiso = false);
    if (resultado.isGranted) return true;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Sin permiso de cámara no se puede reconocer ni grabar señas.'),
        action: SnackBarAction(
          label: 'Ajustes',
          onPressed: openAppSettings,
        ),
      ),
    );
    return false;
  }

  Future<void> _abrirConCamara(Widget pantalla) async {
    if (!await _asegurarPermisoCamara()) return;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => pantalla));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
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
                'Agregá muestras nuevas, probá el modo espejo o ajustá cómo '
                'la cámara reconoce tus señas.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    _tarjeta(
                      icono: Icons.add_a_photo_outlined,
                      color: Colors.green,
                      titulo: 'Agregar muestras',
                      detalle: 'Grabá una seña nueva y etiquetala con su '
                          'palabra para mejorar el reconocimiento.',
                      onTap: () => _abrirConCamara(const PantallaCaptura()),
                    ),
                    _tarjeta(
                      icono: Icons.flip_camera_android_outlined,
                      color: Colors.pink,
                      titulo: 'Espejo',
                      detalle: 'Movéte frente a la cámara y el avatar te '
                          'copia en vivo.',
                      onTap: () => _abrirConCamara(const PantallaEspejo()),
                    ),
                    _tarjeta(
                      icono: Icons.tune,
                      color: Colors.orange,
                      titulo: 'Ajustes de reconocimiento',
                      detalle: 'Calibrá los umbrales de reconocimiento, '
                          'cámara frontal/trasera y espejo.',
                      onTap: () => _abrirConCamara(const PantallaAjustes()),
                    ),
                    _tarjeta(
                      icono: Icons.cloud_sync_outlined,
                      color: Colors.blue,
                      titulo: 'Sincronizar',
                      detalle: 'Subí tus muestras nuevas al equipo y bajá '
                          'el diccionario aprobado. Necesita internet, no '
                          'cámara.',
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PantallaSync()),
                      ),
                    ),
                    if (_pidiendoPermiso)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const SosButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tarjeta({
    required IconData icono,
    required MaterialColor color,
    required String titulo,
    required String detalle,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: color.shade50,
                child: Icon(icono, color: color.shade700, size: 26),
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
                            fontSize: 12.5, color: Colors.grey.shade700)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey.shade400),
            ],
          ),
        ),
      ),
    );
  }
}
