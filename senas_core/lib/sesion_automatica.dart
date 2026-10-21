/// Sesion automatica de camara compartida por todas las pantallas.
///
/// Pide el consentimiento una sola vez (Ajustes.consentimientoPreguntado). Con
/// consentimiento, cada encendido de camara mide el cuerpo en segundo plano
/// y registra la sesion en <documentos>/sesiones/<id>.jsonl (puntos, nunca
/// video). El perfil medido se guarda en Ajustes.perfilCorporal.
library sesion_automatica;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'body_profile.dart' show mergeBodyProfile;
import 'controlador_captura.dart';
import 'muestras_locales.dart';
import 'rotacion_sesiones.dart';
import 'sesion_captura.dart' show sumideroArchivo;

/// Plataforma para la meta de la sesion (web-safe, sin dart:io).
String nombrePlataformaSesion() => defaultTargetPlatform.name;

/// Pide el consentimiento solo la primera vez y recuerda la respuesta, Si o
/// No (Ajustes.consentimientoPreguntado); se cambia en Ajustes. Devuelve el
/// consentimiento vigente.
Future<bool> asegurarConsentimiento(
    BuildContext context, AlmacenMuestras almacen) async {
  final ajustes = almacen.ajustes;
  if (ajustes.consentimientoPreguntado) return ajustes.consentimientoSesion;
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Medir y registrar la sesión'),
      content: const Text(
        'Para adaptar el avatar a tu cuerpo y mejorar la detección, cada '
        'vez que enciendas la cámara se medirán tus proporciones y se '
        'registrará la sesión (puntos del cuerpo, manos y cara; nunca '
        'video ni imágenes). Se guarda solo en este teléfono y puedes '
        'borrarlo en Ajustes.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('No'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Acepto'),
        ),
      ],
    ),
  );
  // Cerrar el dialogo sin responder (null) no cuenta como un No definitivo.
  if (ok == null) return false;
  await almacen.guardarAjustes(almacen.ajustes.copiar()
    ..consentimientoSesion = ok
    ..consentimientoPreguntado = true);
  return ok;
}

/// Devuelve true si la sesion quedo activa.
Future<bool> activarSesionConConsentimiento(
  BuildContext context,
  ControladorCaptura ctrl,
  AlmacenMuestras almacen, {
  required String pantalla,
}) async {
  if (!await asegurarConsentimiento(context, almacen)) return false;
  final ajustes = almacen.ajustes;
  final docs = await getApplicationDocumentsDirectory();
  final dirSesiones = Directory('${docs.path}/sesiones');
  // Antes de abrir la sesion nueva: deja sitio dentro del tope de archivos
  // y de bytes (borra las mas viejas).
  await podarSesiones(dirSesiones, maxArchivos: kMaxArchivosSesion - 1);
  ctrl.onPerfilCorporal = (perfil) {
    // Nunca perder medidas buenas por una captura con brazos ocultos.
    final nuevos = almacen.ajustes.copiar()
      ..perfilCorporal =
          mergeBodyProfile(almacen.ajustes.perfilCorporal, perfil);
    unawaited(almacen.guardarAjustes(nuevos));
  };
  ctrl.activarSesionAutomatica(
    sumidero: sumideroArchivo(dirSesiones),
    meta: {
      'platform': nombrePlataformaSesion(),
      'screen': pantalla,
      'camera_front': ajustes.camaraFrontal,
      'calibration': ajustes.rigCalibration.toJson(),
      'body_profile': ajustes.perfilCorporal?.toJson(),
    },
  );
  return true;
}
