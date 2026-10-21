/// Sincronizacion en segundo plano del diccionario aprobado.
///
/// Al abrir la app se llama a [SincronizadorPlantillas.siCorresponde] SIN
/// esperarlo: si el ultimo intento fue hace mas de 24 h baja las plantillas
/// aprobadas (v_motion_v2_aprobadas) y reemplaza plantillas_sync.json. Es
/// todo-o-nada: el paquete se valida completo y se escribe a un .tmp que se
/// renombra, asi que cualquier fallo (sin red, servidor caido, paquete vacio
/// o de otra version) deja intacto lo que ya habia. Nunca se queda sin
/// diccionario ni molesta a la persona.
///
/// El paquete del APK manda: de lo sincronizado solo entran las glosas que el
/// paquete no trae (ver armarClasificador). Por eso aqui no se lee ni se
/// cuenta el paquete del APK (51 MB): la unica referencia para validar una
/// descarga es la sincronizacion anterior.
library sincronizador_plantillas;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'config_supabase.dart';
import 'escritura_atomica.dart';
import 'muestras_locales.dart';
import 'paquete_sync.dart';
import 'supabase_api.dart';

/// Una descarga con menos de esta fraccion de la sincronizacion ANTERIOR se
/// rechaza: la nueva reemplaza a la anterior (no se suman), asi que una lista
/// truncada o casi vacia haria que se pierdan las glosas nuevas que ya se
/// habian bajado, sin que nadie lo note. No compara con el paquete del APK
/// (ese manda siempre y nunca se reemplaza); sin sincronizacion anterior se
/// acepta cualquier descarga valida.
const double kFraccionMinimaSync = 0.5;

/// Hora del ultimo intento que NO dejo un archivo nuevo (descarga invalida o
/// demasiado chica). Sin ella, esas descargas se repetirian en cada arranque.
const String kNombreArchivoIntentoSync = 'plantillas_sync_intento.txt';

enum ResultadoSync {
  /// No tocaba (reciente, web o sin Supabase configurado).
  omitido,

  /// Se bajo lo mismo que ya habia; solo se renovo la hora.
  sinCambios,

  /// Hay diccionario nuevo en disco y el almacen ya lo recargo.
  actualizado,

  /// Fallo la red o el servidor; se conserva lo anterior.
  fallo,

  /// La descarga no paso la validacion; se conserva lo anterior.
  invalido,
}

class SincronizadorPlantillas {
  SincronizadorPlantillas._();

  static const Duration vigencia = Duration(hours: 24);

  /// Sincroniza si la ultima vez fue hace mas de [vigencia]. Nunca lanza.
  /// Los parametros son para pruebas.
  static Future<ResultadoSync> siCorresponde({
    SupabaseApi? api,
    Future<Directory> Function()? directorio,
    DateTime? ahora,
    Future<void> Function()? alActualizar,
  }) async {
    if (kIsWeb || !haySupabaseConfigurado) return ResultadoSync.omitido;
    final cliente = api ?? SupabaseApi();
    try {
      final dir = await (directorio ?? getApplicationDocumentsDirectory)();
      final archivo = File('${dir.path}/$kNombreArchivoSync');
      final intento = File('${dir.path}/$kNombreArchivoIntentoSync');
      final ahoraReal = ahora ?? DateTime.now();

      String? huellaActual;
      int? cantidadActual;
      DateTime? ultima;
      if (await archivo.exists()) {
        final meta = metadatosPaqueteSync(await archivo.readAsString());
        huellaActual = meta?.huella;
        cantidadActual = meta?.cantidad;
        ultima = meta?.cuando;
      }
      final ultimoIntento = await _leerIntento(intento);
      if (ultimoIntento != null &&
          (ultima == null || ultimoIntento.isAfter(ultima))) {
        ultima = ultimoIntento;
      }
      // Una hora en el futuro (reloj movido) no cuenta como reciente.
      if (ultima != null &&
          !ultima.isAfter(ahoraReal) &&
          ahoraReal.difference(ultima) < vigencia) {
        return ResultadoSync.omitido;
      }

      final plantillas = await cliente.descargarPlantillas();
      // Se valida exactamente lo que se va a escribir: si no se puede leer
      // de vuelta, no reemplaza nada.
      final texto = construirPaqueteSync(plantillas, ahoraReal);
      if (leerPaqueteSync(texto) == null) {
        debugPrint('[sync] descarga invalida (${plantillas.length}); '
            'se conserva el diccionario anterior');
        await _anotarIntento(intento, ahoraReal);
        return ResultadoSync.invalido;
      }
      // Contra la sincronizacion anterior, si la hay. Sin ella se acepta
      // cualquier descarga valida: el paquete del APK manda y esta solo le
      // suma glosas.
      if (cantidadActual != null &&
          plantillas.length < cantidadActual * kFraccionMinimaSync) {
        debugPrint('[sync] descarga demasiado chica (${plantillas.length} '
            'frente a $cantidadActual); se conserva la anterior');
        await _anotarIntento(intento, ahoraReal);
        return ResultadoSync.invalido;
      }
      await escribirAtomico(archivo, texto);

      if (huellaActual != null && huellaActual == huellaPlantillas(plantillas)) {
        debugPrint('[sync] sin cambios');
        return ResultadoSync.sinCambios;
      }
      await (alActualizar ??
          AlmacenMuestras.instancia.recargarSincronizadas)();
      debugPrint('[sync] ${plantillas.length} plantillas actualizadas');
      return ResultadoSync.actualizado;
    } catch (e) {
      debugPrint('[sync] fallo, se conserva lo anterior: $e');
      return ResultadoSync.fallo;
    } finally {
      // Solo se cierra el cliente propio.
      if (api == null) cliente.cerrar();
    }
  }

  static Future<DateTime?> _leerIntento(File archivo) async {
    try {
      if (!await archivo.exists()) return null;
      return DateTime.tryParse((await archivo.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  /// Guarda la hora de un intento que no dejo archivo nuevo. Nunca lanza: si
  /// no se puede escribir, lo unico que pasa es que se reintenta antes.
  static Future<void> _anotarIntento(File archivo, DateTime cuando) async {
    try {
      await escribirAtomico(archivo, cuando.toIso8601String());
    } catch (_) {}
  }
}
