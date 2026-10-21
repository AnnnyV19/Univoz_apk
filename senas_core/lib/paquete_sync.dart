/// Formato en disco del diccionario sincronizado (plantillas_sync.json) y su
/// validacion. Lo comparten la sincronizacion manual (pantalla_sync), la de
/// fondo (sincronizador_plantillas) y la carga al arrancar.
///
/// Un paquete solo es valido si trae la norm_version y las dimensiones de
/// ESTA app y al menos una plantilla, todas legibles: un diccionario a medias
/// o de otra version es peor que el anterior.
library paquete_sync;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha1;

import 'sign_norm.dart' show kNormVersion, kFrameDim, kTFrames;
import 'supabase_api.dart' show PlantillaRemota;

/// Huella del contenido (sin la hora): sirve para saber si una descarga trae
/// algo distinto de lo que ya hay.
String huellaPlantillas(List<PlantillaRemota> plantillas) => sha1
    .convert(utf8.encode(jsonEncode(plantillas.map((p) => p.toJson()).toList())))
    .toString();

String construirPaqueteSync(List<PlantillaRemota> plantillas, DateTime ahora) =>
    jsonEncode({
      'norm_version': kNormVersion,
      't_frames': kTFrames,
      'frame_dim': kFrameDim,
      'sincronizado_en': ahora.toIso8601String(),
      'huella': huellaPlantillas(plantillas),
      'plantillas': plantillas.map((p) => p.toJson()).toList(),
    });

/// Las plantillas del paquete, o null si no es valido (ver arriba).
List<PlantillaRemota>? leerPaqueteSync(String texto) {
  try {
    final j = jsonDecode(texto);
    if (j is! Map<String, dynamic>) return null;
    if (j['norm_version'] != kNormVersion ||
        (j['t_frames'] as num?)?.toInt() != kTFrames ||
        (j['frame_dim'] as num?)?.toInt() != kFrameDim) {
      return null;
    }
    final crudas = j['plantillas'];
    if (crudas is! List || crudas.isEmpty) return null;
    return [
      for (final p in crudas)
        PlantillaRemota.fromJson((p as Map).cast<String, dynamic>()),
    ];
  } catch (_) {
    return null;
  }
}

/// Hora, huella y cantidad de plantillas de la ultima sincronizacion
/// guardada en [texto], o null si el archivo no sirve (otra version, roto).
({DateTime? cuando, String? huella, int cantidad})? metadatosPaqueteSync(
    String texto) {
  try {
    final j = jsonDecode(texto);
    if (j is! Map<String, dynamic>) return null;
    if (j['norm_version'] != kNormVersion) return null;
    final c = j['sincronizado_en'];
    return (
      cuando: c is String ? DateTime.tryParse(c) : null,
      huella: j['huella'] as String?,
      cantidad: (j['plantillas'] as List?)?.length ?? 0,
    );
  } catch (_) {
    return null;
  }
}
