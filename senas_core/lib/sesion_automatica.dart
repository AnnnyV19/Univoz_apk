/// Sesion automatica de camara compartida por todas las pantallas.
///
/// Pide el consentimiento una sola vez (Ajustes.consentimientoSesion). Con
/// consentimiento, cada encendido de camara mide el cuerpo en segundo plano
/// y registra la sesion en <documentos>/sesiones/<id>.jsonl (puntos, nunca
/// video). El perfil medido se guarda en Ajustes.perfilCorporal.
library sesion_automatica;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'body_profile.dart' show mergeBodyProfile;
import 'controlador_captura.dart';
import 'muestras_locales.dart';
import 'sesion_captura.dart' show sumideroArchivo;

/// Devuelve true si la sesion quedo activa.
Future<bool> activarSesionConConsentimiento(
  BuildContext context,
  ControladorCaptura ctrl,
  AlmacenMuestras almacen, {
  required String pantalla,
}) async {
  var ajustes = almacen.ajustes;
  if (!ajustes.consentimientoSesion) {
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
    if (ok != true) return false;
    ajustes = ajustes.copiar()..consentimientoSesion = true;
    await almacen.guardarAjustes(ajustes);
  }
  final docs = await getApplicationDocumentsDirectory();
  ctrl.onPerfilCorporal = (perfil) {
    // Nunca perder medidas buenas por una captura con brazos ocultos.
    final nuevos = almacen.ajustes.copiar()
      ..perfilCorporal =
          mergeBodyProfile(almacen.ajustes.perfilCorporal, perfil);
    unawaited(almacen.guardarAjustes(nuevos));
  };
  ctrl.activarSesionAutomatica(
    sumidero: sumideroArchivo(Directory('${docs.path}/sesiones')),
    meta: {
      'platform': 'android',
      'screen': pantalla,
      'camera_front': ajustes.camaraFrontal,
      'calibration': ajustes.rigCalibration.toJson(),
      'body_profile': ajustes.perfilCorporal?.toJson(),
    },
  );
  return true;
}
