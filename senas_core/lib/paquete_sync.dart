/// Formato en disco del diccionario sincronizado (plantillas_sync.json) y su
/// validacion. Lo comparten la sincronizacion manual (pantalla_sync), la de
/// fondo (sincronizador_plantillas) y la carga al arrancar.
///
/// Un paquete solo es valido si trae la norm_version y las dimensiones de
/// ESTA app y al menos una plantilla, todas legibles: un diccionario a medias
/// o de otra version es peor que el anterior.
library paquete_sync;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show compute;

import 'escritura_atomica.dart';
import 'sign_norm.dart' show kNormVersion, kFrameDim, kTFrames;
import 'supabase_api.dart' show PlantillaRemota;

/// Datos chicos del paquete (hora, huella, cantidad, tamano) que se guardan
/// al lado de plantillas_sync.json: sin ellos, saber si toca sincronizar
/// obligaba a leer y decodificar todo el paquete (decenas de MB) en el hilo
/// de la interfaz en cada arranque.
const String kNombreArchivoMetaSync = 'plantillas_sync_meta.json';

/// Huella del contenido (sin la hora): sirve para saber si una descarga trae
/// algo distinto de lo que ya hay.
String huellaPlantillas(List<PlantillaRemota> plantillas) => sha1
    .convert(
        utf8.encode(jsonEncode(plantillas.map((p) => p.toJson()).toList())))
    .toString();

/// Un paquete ya armado: los bytes listos para escribir y lo que hace falta
/// saber de el sin volver a leerlo.
class PaqueteSyncArmado {
  final Uint8List bytes;
  final String huella;
  final int cantidad;

  /// Si se puede leer de vuelta (mismas reglas que [leerPaqueteSync]).
  final bool valido;
  final DateTime sincronizadoEn;
  const PaqueteSyncArmado(
      this.bytes, this.huella, this.cantidad, this.valido, this.sincronizadoEn);

  /// Contenido de [kNombreArchivoMetaSync]. Lleva el tamano del paquete: si
  /// el paquete se reemplazo sin tocar esto, no coincide y no se usa.
  String get metadatos => jsonEncode({
        'norm_version': kNormVersion,
        'sincronizado_en': sincronizadoEn.toIso8601String(),
        'huella': huella,
        'cantidad': cantidad,
        'bytes': bytes.length,
      });
}

/// Arma el paquete en una sola pasada: cada plantilla se pasa a JSON una vez,
/// de ahi salen la huella, el texto y la validacion (sin volver a decodificar
/// lo recien codificado). Produce los mismos bytes que antes.
PaqueteSyncArmado armarPaqueteSync(
    List<PlantillaRemota> plantillas, DateTime ahora) {
  var valido = plantillas.isNotEmpty;
  final mapas = <Map<String, dynamic>>[];
  for (final p in plantillas) {
    final j = p.toJson();
    mapas.add(j);
    if (!valido) continue;
    try {
      // Lo mismo que hace leerPaqueteSync con cada una, sin pasar por texto.
      PlantillaRemota.fromJson(j);
    } catch (_) {
      valido = false;
    }
  }
  // La lista se codifica una vez: es lo que firma la huella y es el mismo
  // texto que va dentro del paquete.
  final lista = jsonEncode(mapas);
  final huella = sha1.convert(utf8.encode(lista)).toString();
  final cabecera = jsonEncode({
    'norm_version': kNormVersion,
    't_frames': kTFrames,
    'frame_dim': kFrameDim,
    'sincronizado_en': ahora.toIso8601String(),
    'huella': huella,
  });
  final texto =
      '${cabecera.substring(0, cabecera.length - 1)},"plantillas":$lista}';
  return PaqueteSyncArmado(Uint8List.fromList(utf8.encode(texto)), huella,
      plantillas.length, valido, ahora);
}

/// [armarPaqueteSync] en otro isolate: con ~1000 plantillas son segundos de
/// JSON que no deben correr en el hilo de la interfaz.
Future<PaqueteSyncArmado> armarPaqueteSyncEnIsolate(
        List<PlantillaRemota> plantillas, DateTime ahora) =>
    compute(_armarPaquete, (plantillas, ahora));

PaqueteSyncArmado _armarPaquete((List<PlantillaRemota>, DateTime) e) =>
    armarPaqueteSync(e.$1, e.$2);

String construirPaqueteSync(List<PlantillaRemota> plantillas, DateTime ahora) =>
    utf8.decode(armarPaqueteSync(plantillas, ahora).bytes);

/// Escribe el paquete y despues sus metadatos (en ese orden: si se corta entre
/// los dos, el tamano no coincide y se cae al camino lento). Nunca deja
/// metadatos de un paquete anterior.
Future<void> escribirPaqueteSync(File paquete, PaqueteSyncArmado armado) async {
  final meta = File('${paquete.parent.path}/$kNombreArchivoMetaSync');
  await escribirAtomicoBytes(paquete, armado.bytes, flush: false);
  try {
    await escribirAtomico(meta, armado.metadatos);
  } catch (_) {
    try {
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }
}

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
MetadatosSync? metadatosPaqueteSync(String texto) {
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

typedef MetadatosSync = ({DateTime? cuando, String? huella, int cantidad});

/// Metadatos del paquete guardado en [paquete], o null si no hay o no sirve.
/// Usa el archivo chico de al lado si coincide con el paquete; si falta, esta
/// roto o es de otro paquete, lee el paquete entero (en otro isolate).
Future<MetadatosSync?> leerMetadatosSync(File paquete) async {
  if (!await paquete.exists()) return null;
  try {
    final meta = File('${paquete.parent.path}/$kNombreArchivoMetaSync');
    if (await meta.exists()) {
      final j = jsonDecode(await meta.readAsString());
      if (j is Map<String, dynamic> &&
          j['norm_version'] == kNormVersion &&
          j['bytes'] == await paquete.length() &&
          j['cantidad'] is int) {
        final c = j['sincronizado_en'];
        return (
          cuando: c is String ? DateTime.tryParse(c) : null,
          huella: j['huella'] as String?,
          cantidad: j['cantidad'] as int,
        );
      }
    }
  } catch (_) {}
  return compute(_metadatosDeArchivo, paquete.path);
}

MetadatosSync? _metadatosDeArchivo(String ruta) =>
    metadatosPaqueteSync(File(ruta).readAsStringSync());
