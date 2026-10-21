/// Poda de las sesiones guardadas (<documentos>/sesiones/<id>.jsonl).
///
/// Cada vez que se enciende la camara con consentimiento se crea un archivo
/// de sesion; sin tope llenarian el telefono. Al empezar una sesion se
/// borran las mas viejas hasta quedar dentro de [kMaxArchivosSesion] archivos
/// y [kMaxBytesSesiones] en total. El id de sesion empieza con el sello de
/// tiempo (ver nuevoIdSesion), asi que ordenar por nombre es ordenar por edad.
library rotacion_sesiones;

import 'dart:io';

const int kMaxArchivosSesion = 30;
const int kMaxBytesSesiones = 50 * 1024 * 1024;

/// Borra las sesiones mas viejas de [dir] hasta cumplir [maxArchivos] y
/// [maxBytes]. Nunca borra la mas nueva (podria estar abierta por el
/// grabador: en Linux/Android seguiria escribiendo en un archivo ya
/// desvinculado y perderia la sesion) ni las de [conservar] (nombres de
/// archivo, p. ej. 'id.jsonl'). Devuelve cuantas borro. Nunca lanza: podar es mantenimiento y
/// no debe impedir que la sesion nueva arranque.
Future<int> podarSesiones(
  Directory dir, {
  int maxArchivos = kMaxArchivosSesion,
  int maxBytes = kMaxBytesSesiones,
  Set<String> conservar = const {},
}) async {
  var borrados = 0;
  try {
    if (!await dir.exists()) return 0;
    final archivos = <(File, int)>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.jsonl')) {
        archivos.add((e, await e.length()));
      }
    }
    // Del mas viejo al mas nuevo.
    archivos.sort((a, b) => a.$1.path.compareTo(b.$1.path));
    var total = archivos.fold<int>(0, (s, a) => s + a.$2);
    var cuenta = archivos.length;
    for (var i = 0; i < archivos.length - 1; i++) {
      final (f, bytes) = archivos[i];
      if (cuenta <= maxArchivos && total <= maxBytes) break;
      if (conservar.contains(f.uri.pathSegments.last)) continue;
      try {
        await f.delete();
        borrados++;
        cuenta--;
        total -= bytes;
      } catch (_) {}
    }
  } catch (_) {}
  return borrados;
}

final RegExp _nombreSesion = RegExp(r'^(.+?)(?:\.part(\d+))?\.jsonl$');

/// Id de sesion y numero de parte (1 = sin sufijo) de un archivo
/// `<id>.jsonl` o `<id>.partNNN.jsonl`, o null si no es de sesion.
({String id, int parte})? nombreDeSesion(String nombreArchivo) {
  final m = _nombreSesion.firstMatch(nombreArchivo);
  if (m == null) return null;
  return (id: m.group(1)!, parte: int.tryParse(m.group(2) ?? '') ?? 1);
}

/// Todos los archivos de la sesion mas reciente de [dir], en orden de parte
/// (`<id>.jsonl`, `<id>.part002.jsonl`...). Vacio si no hay sesiones. Una
/// sesion larga se parte en varios archivos (ver sumideroArchivo): para
/// analizarla hacen falta todos.
Future<List<File>> partesDeUltimaSesion(Directory dir) async {
  if (!await dir.exists()) return const [];
  final porId = <String, List<(int, File)>>{};
  await for (final e in dir.list()) {
    if (e is! File) continue;
    final n = nombreDeSesion(e.uri.pathSegments.last);
    if (n == null) continue;
    porId.putIfAbsent(n.id, () => []).add((n.parte, e));
  }
  if (porId.isEmpty) return const [];
  final ultimo = (porId.keys.toList()..sort()).last;
  final partes = porId[ultimo]!..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final p in partes) p.$2];
}
