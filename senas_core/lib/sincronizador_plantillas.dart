/// Sincronizacion en segundo plano del diccionario aprobado.
///
/// Al abrir la app se llama a [SincronizadorPlantillas.siCorresponde] SIN
/// esperarlo: si la ultima sincronizacion buena fue hace mas de 24 h baja
/// las plantillas aprobadas (v_motion_v2_aprobadas) y reemplaza
/// plantillas_sync.json. Es todo-o-nada: el paquete se valida completo y se
/// escribe a un .tmp que se renombra, asi que cualquier fallo (sin red,
/// servidor caido, paquete vacio o de otra version) deja intacto lo que ya
/// habia. Nunca se queda sin diccionario ni molesta a la persona.
library sincronizador_plantillas;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:path_provider/path_provider.dart';

import 'config_supabase.dart';
import 'escritura_atomica.dart';
import 'muestras_locales.dart';
import 'paquete_sync.dart';
import 'plantillas.dart' show contarPlantillasPaquete;
import 'supabase_api.dart';

/// Una descarga con menos de esta fraccion de lo que ya hay se rechaza: el
/// diccionario sincronizado REEMPLAZA al del APK (no se suman), asi que una
/// lista truncada o casi vacia dejaria a la app reconociendo mucho menos que
/// antes, sin que nadie lo note.
const double kFraccionMinimaSync = 0.5;

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
    Future<int> Function()? cantidadBase,
  }) async {
    if (kIsWeb || !haySupabaseConfigurado) return ResultadoSync.omitido;
    final cliente = api ?? SupabaseApi();
    try {
      final dir = await (directorio ?? getApplicationDocumentsDirectory)();
      final archivo = File('${dir.path}/$kNombreArchivoSync');
      final ahoraReal = ahora ?? DateTime.now();

      String? huellaActual;
      int? cantidadActual;
      if (await archivo.exists()) {
        final meta = metadatosPaqueteSync(await archivo.readAsString());
        huellaActual = meta?.huella;
        cantidadActual = meta?.cantidad;
        final ultima = meta?.cuando;
        // Una hora en el futuro (reloj movido) no cuenta como reciente.
        if (ultima != null &&
            !ultima.isAfter(ahoraReal) &&
            ahoraReal.difference(ultima) < vigencia) {
          return ResultadoSync.omitido;
        }
      }

      final plantillas = await cliente.descargarPlantillas();
      // Se valida exactamente lo que se va a escribir: si no se puede leer
      // de vuelta, no reemplaza nada.
      final texto = construirPaqueteSync(plantillas, ahoraReal);
      if (leerPaqueteSync(texto) == null) {
        debugPrint('[sync] descarga invalida (${plantillas.length}); '
            'se conserva el diccionario anterior');
        return ResultadoSync.invalido;
      }
      // Contra lo que hay AHORA: la sincronizacion anterior o, si nunca hubo
      // una valida, el paquete del APK.
      final actual =
          cantidadActual ?? await (cantidadBase ?? contarPlantillasPaquete)();
      if (plantillas.length < actual * kFraccionMinimaSync) {
        debugPrint('[sync] descarga demasiado chica (${plantillas.length} '
            'frente a $actual); se conserva el diccionario actual');
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
}
