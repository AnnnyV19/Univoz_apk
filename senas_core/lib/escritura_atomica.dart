/// Escritura de archivos que no deja a medias el original.
///
/// Se escribe un `.tmp` PROPIO de cada llamada en la MISMA carpeta y se
/// renombra encima del destino: el rename dentro de un mismo sistema de
/// archivos es atomico, asi que si la app muere a mitad de la escritura queda
/// el archivo anterior completo (o el nuevo completo), nunca uno cortado.
///
/// Las escrituras al mismo archivo se hacen en fila (una a la vez): con un
/// solo .tmp compartido, dos guardados superpuestos (p. ej. ajustes + una
/// muestra nueva) se pisarian el .tmp y dejarian el destino corrupto.
/// Gana la ultima en llamar, siempre con el contenido completo.
library escritura_atomica;

import 'dart:async';
import 'dart:io';

final Map<String, Future<void>> _colas = {};
int _contador = 0;

/// [flush] fuerza el fsync antes del rename: solo hace falta ante un corte
/// de energia, no ante el cierre de la app (el rename ya garantiza eso), y
/// cuesta decenas de ms por escritura. Por defecto no se fuerza.
Future<void> escribirAtomico(File destino, String contenido,
        {bool flush = false}) =>
    _atomico(destino, (tmp) => tmp.writeAsString(contenido, flush: flush));

Future<void> escribirAtomicoBytes(File destino, List<int> bytes,
        {bool flush = true}) =>
    _atomico(destino, (tmp) => tmp.writeAsBytes(bytes, flush: flush));

Future<void> _atomico(
    File destino, Future<File> Function(File tmp) escribir) {
  final clave = destino.absolute.path;
  final anterior = _colas[clave] ?? Future<void>.value();
  final actual = anterior.then((_) => _escribirUna(destino, escribir));
  // Lo que queda en la cola nunca falla: el error le llega solo a quien
  // llamo, y una escritura fallida no frena a las siguientes.
  late final Future<void> enCola;
  enCola = actual.then<void>((_) {}, onError: (_) {}).whenComplete(() {
    if (identical(_colas[clave], enCola)) _colas.remove(clave);
  });
  _colas[clave] = enCola;
  return actual;
}

Future<void> _escribirUna(
    File destino, Future<File> Function(File tmp) escribir) async {
  final tmp = File('${destino.path}.$pid.${_contador++}.tmp');
  try {
    await escribir(tmp);
    await tmp.rename(destino.path);
  } catch (_) {
    // Sin dejar basura: el destino original no se toco.
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Borra los `.tmp` huerfanos de [dir] (sin entrar a subcarpetas) con mas de
/// [edad] de antiguedad: quedan cuando la app muere entre escribir el tmp y
/// renombrarlo. Los recientes se respetan (pueden ser una escritura en
/// curso). Devuelve cuantos borro; nunca lanza.
Future<int> barrerTmpHuerfanos(
  Directory dir, {
  Duration edad = const Duration(minutes: 1),
  DateTime? ahora,
}) async {
  var borrados = 0;
  try {
    if (!await dir.exists()) return 0;
    final limite = (ahora ?? DateTime.now()).subtract(edad);
    await for (final e in dir.list()) {
      if (e is! File || !e.path.endsWith('.tmp')) continue;
      try {
        if ((await e.lastModified()).isBefore(limite)) {
          await e.delete();
          borrados++;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return borrados;
}
