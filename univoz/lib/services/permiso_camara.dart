import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Lo unico que la app necesita saber de un permiso (cámara, micrófono...).
enum EstadoPermisoCamara {
  concedido,

  /// Nunca se pidió o se negó una vez (todavía se puede volver a pedir).
  denegado,

  /// Solo se arregla desde los ajustes del teléfono.
  denegadoPermanente,
}

/// Costura sobre permission_handler: en las pruebas se cambia por un falso.
/// Sirve para cualquier permiso; el nombre es de cuando solo existía la
/// cámara (ver los alias [EstadoPermiso] y [AdaptadorPermiso]).
abstract class AdaptadorPermisoCamara {
  Future<EstadoPermisoCamara> estado();
  Future<EstadoPermisoCamara> pedir();
  Future<void> abrirAjustes();
}

/// Nombres neutros para los usos que no son la cámara.
typedef EstadoPermiso = EstadoPermisoCamara;
typedef AdaptadorPermiso = AdaptadorPermisoCamara;

class _AdaptadorPermissionHandler implements AdaptadorPermisoCamara {
  const _AdaptadorPermissionHandler(this.permiso);

  final Permission permiso;

  static EstadoPermisoCamara _traducir(PermissionStatus s) {
    if (s.isGranted) return EstadoPermisoCamara.concedido;
    if (s.isPermanentlyDenied) return EstadoPermisoCamara.denegadoPermanente;
    return EstadoPermisoCamara.denegado;
  }

  @override
  Future<EstadoPermisoCamara> estado() async => _traducir(await permiso.status);

  @override
  Future<EstadoPermisoCamara> pedir() async =>
      _traducir(await permiso.request());

  @override
  Future<void> abrirAjustes() async {
    await openAppSettings();
  }
}

/// Pide el permiso de cámara con una explicación antes del aviso del sistema.
/// Devuelve true si ya se puede abrir la cámara.
///
/// Es [pedirPermiso] con los textos de la cámara.
Future<bool> pedirPermisoCamara(
  BuildContext context, {
  AdaptadorPermisoCamara? adaptador,
}) =>
    pedirPermiso(
      context,
      Permission.camera,
      'Univoz usa la cámara para ver tus manos y tu cuerpo. '
      'El video nunca sale de tu teléfono.',
      titulo: 'Permiso de cámara',
      icono: Icons.videocam_outlined,
      mensajeNegado: 'Sin la cámara no puedo ver tus señas. '
          'Puedes permitirla cuando quieras.',
      tituloAjustes: 'La cámara está desactivada',
      textoAjustes: 'Para usar esta función, permite la cámara en los ajustes '
          'de tu teléfono. El video nunca sale de tu teléfono.',
      adaptador: adaptador,
    );

/// Pide un permiso con una explicación antes del aviso del sistema.
/// Devuelve true si ya se puede usar.
///
/// - Concedido: true, sin mostrar nada.
/// - Sin pedir o negado una vez: hoja inferior con [explicacion]; si la
///   persona continúa, se pide el permiso.
/// - Negado para siempre: diálogo que lleva a los ajustes del teléfono.
///
/// [adaptador] solo se pasa en pruebas.
Future<bool> pedirPermiso(
  BuildContext context,
  Permission permiso,
  String explicacion, {
  String titulo = 'Permiso necesario',
  IconData icono = Icons.lock_open_outlined,
  String mensajeNegado = 'Sin este permiso no puedo ayudarte con esto. '
      'Puedes permitirlo cuando quieras.',
  String tituloAjustes = 'Falta un permiso',
  String textoAjustes = 'Para usar esta función, permite el permiso en los '
      'ajustes de tu teléfono.',
  AdaptadorPermisoCamara? adaptador,
}) async {
  if (kIsWeb && adaptador == null) return true;
  final permisos = adaptador ?? _AdaptadorPermissionHandler(permiso);

  var estado = await permisos.estado();
  if (estado == EstadoPermisoCamara.concedido) return true;
  if (!context.mounted) return false;

  if (estado == EstadoPermisoCamara.denegado) {
    final continuar = await _explicar(context, titulo, explicacion, icono);
    if (!continuar || !context.mounted) return false;
    estado = await permisos.pedir();
    if (estado == EstadoPermisoCamara.concedido) return true;
    if (!context.mounted) return false;
    if (estado == EstadoPermisoCamara.denegado) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mensajeNegado)),
      );
      return false;
    }
  }

  final abrir = await _ofrecerAjustes(context, tituloAjustes, textoAjustes);
  if (abrir) await permisos.abrirAjustes();
  return false;
}

Future<bool> _explicar(BuildContext context, String titulo, String explicacion,
    IconData icono) async {
  final continuar = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) {
      final tema = Theme.of(sheet);
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExcludeSemantics(
                child: Icon(icono, size: 40, color: tema.colorScheme.primary),
              ),
              const SizedBox(height: 12),
              Text(titulo,
                  textAlign: TextAlign.center,
                  style: tema.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                explicacion,
                textAlign: TextAlign.center,
                style: tema.textTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(sheet).pop(true),
                child: const Text('Continuar'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(sheet).pop(false),
                child: const Text('Ahora no'),
              ),
            ],
          ),
        ),
      );
    },
  );
  return continuar ?? false;
}

Future<bool> _ofrecerAjustes(
    BuildContext context, String titulo, String texto) async {
  final abrir = await showDialog<bool>(
    context: context,
    builder: (dialogo) => AlertDialog(
      title: Text(titulo),
      content: Text(texto),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogo).pop(false),
          child: const Text('Ahora no'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogo).pop(true),
          child: const Text('Abrir ajustes'),
        ),
      ],
    ),
  );
  return abrir ?? false;
}
