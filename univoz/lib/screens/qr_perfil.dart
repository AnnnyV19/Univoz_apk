import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/perfil_guardado.dart';
import '../services/tarjeta_perfil.dart';

const Color _kFondo = Color(0xFFF7F2FA);
const Color _kGris = Color(0xFF6B6478);
const Color _kMorado = Color(0xFF6C63FF);

/// Muestra el código de quien usa este teléfono, para que la otra
/// persona lo escanee.
///
/// El QR lleva el perfil adentro, no un link: se lee sin internet, en
/// modo avión, sin que nada salga del teléfono (ver [TarjetaPerfil]).
class MostrarMiCodigoScreen extends StatefulWidget {
  const MostrarMiCodigoScreen({super.key});

  @override
  State<MostrarMiCodigoScreen> createState() => _MostrarMiCodigoScreenState();
}

class _MostrarMiCodigoScreenState extends State<MostrarMiCodigoScreen> {
  late final TextEditingController _nombre =
      TextEditingController(text: PerfilGuardado.nombre ?? '');

  @override
  void dispose() {
    _nombre.dispose();
    super.dispose();
  }

  Future<void> _guardarNombre() async {
    await PerfilGuardado.guardarNombre(_nombre.text);
    if (!mounted) return;
    // El QR se redibuja porque su contenido cambió.
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Nombre guardado')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tarjeta = PerfilGuardado.miTarjeta;

    return Scaffold(
      backgroundColor: _kFondo,
      appBar: AppBar(
        backgroundColor: _kFondo,
        foregroundColor: const Color(0xFF1A1A2E),
        elevation: 0,
        title: const Text('Mi código'),
      ),
      body: tarjeta == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Primero elige tu perfil. Sin perfil no hay nada que '
                  'mostrar.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _kGris),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  'Muéstrale esta pantalla a la otra persona para que la '
                  'escanee desde su UNIVOZ. Funciona sin internet.',
                  style: const TextStyle(fontSize: 14, color: _kGris),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      // Fondo blanco siempre, aunque el tema sea oscuro: un
                      // QR sobre fondo de color no siempre lo agarra la
                      // cámara del otro teléfono.
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: QrImageView(
                      data: tarjeta.aTexto(),
                      version: QrVersions.auto,
                      size: 240,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Center(
                  child: Text(
                    tarjeta.resumen,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Tu nombre (opcional)',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Sirve para que quien te escanee vea a quién agarró, en '
                  'vez de un perfil sin nombre.',
                  style: TextStyle(fontSize: 12, color: _kGris),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _nombre,
                  maxLength: TarjetaPerfil.kMaxNombre,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _guardarNombre(),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(),
                    hintText: 'Por ejemplo: Lani',
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _guardarNombre,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kMorado,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                    child: const Text('Guardar nombre'),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Abre la cámara para leer el código de la otra persona.
///
/// Devuelve por [Navigator.pop] una [TarjetaPerfil] cuando lee uno
/// válido, o null si la persona se sale o no da permiso de cámara. Quien
/// la abre tiene que estar listo para ese null: el camino manual sigue
/// existiendo y es el que se usa entonces.
class EscanearCodigoScreen extends StatefulWidget {
  const EscanearCodigoScreen({super.key});

  @override
  State<EscanearCodigoScreen> createState() => _EscanearCodigoScreenState();
}

class _EscanearCodigoScreenState extends State<EscanearCodigoScreen> {
  final MobileScannerController _control = MobileScannerController(
    // noDuplicates evita que el mismo código dispare onDetect decenas de
    // veces por segundo mientras la cámara lo sigue viendo.
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// Una vez leído un código válido ya estamos saliendo de la pantalla;
  /// sin esta bandera, una segunda detección intentaría hacer pop de una
  /// ruta que ya se fue.
  bool _listo = false;

  /// Se muestra cuando se leyó un QR que no es de UNIVOZ, para que la
  /// persona sepa que la cámara sí funciona y el problema es el código.
  String? _aviso;

  @override
  void initState() {
    super.initState();
    _pedirPermiso();
  }

  Future<void> _pedirPermiso() async {
    final estado = await Permission.camera.request();
    if (!mounted || estado.isGranted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _control.dispose();
    super.dispose();
  }

  void _alDetectar(BarcodeCapture captura) {
    if (_listo) return;
    for (final codigo in captura.barcodes) {
      final tarjeta = TarjetaPerfil.desdeTexto(codigo.rawValue);
      if (tarjeta != null) {
        _listo = true;
        Navigator.of(context).pop(tarjeta);
        return;
      }
    }
    // Leyó algo, pero no es nuestro: el QR de un producto, de un menú,
    // cualquier cosa. Se avisa y se sigue escaneando.
    if (mounted) {
      setState(() => _aviso = 'Ese código no es de UNIVOZ. Pídele a la '
          'otra persona que abra "Mi código" en su app.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Escanear código'),
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _control, onDetect: _alDetectar),
          // Marco guía: ayuda a encuadrar y deja claro dónde apuntar.
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 40,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_aviso != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _aviso!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Apunta al código que muestra la otra persona',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
