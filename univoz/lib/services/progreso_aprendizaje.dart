import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'curriculo.dart';

/// Qué lecciones de "Aprender LSM" ya se terminaron y la racha de días.
///
/// Se guarda en el teléfono, en `progreso_aprendizaje.json`, aparte del
/// perfil (`perfil_usuario.json`) y de las muestras: borrar uno no toca los
/// otros. No sube nada a ningún lado.
///
/// Es un [ChangeNotifier] para que el camino se redibuje solo cuando se
/// termina una lección.
class ProgresoAprendizaje extends ChangeNotifier {
  ProgresoAprendizaje._();
  static final ProgresoAprendizaje instancia = ProgresoAprendizaje._();

  static const String _kArchivo = 'progreso_aprendizaje.json';
  static const int _kVersion = 1;

  final Set<String> _completadas = {};
  int _racha = 0;
  String? _ultimoDia;
  bool _cargado = false;

  bool get cargado => _cargado;

  Future<File> _ruta() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_kArchivo');
  }

  /// Lee el archivo. Si no existe o está dañado se empieza desde cero: un
  /// JSON roto no debe dejar la pantalla inservible.
  Future<void> cargar() async {
    if (_cargado) return;
    try {
      final f = await _ruta();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map) {
          final ids = j['completadas'];
          if (ids is List) {
            // Solo ids que sigan existiendo en el camino: si una lección
            // se renombra o se quita, no deja basura.
            final validos = leccionesEnOrden.map((l) => l.id).toSet();
            _completadas
              ..clear()
              ..addAll(ids.whereType<String>().where(validos.contains));
          }
          final r = j['racha'];
          _racha = r is int && r >= 0 ? r : 0;
          final d = j['ultimo_dia'];
          _ultimoDia = d is String && _diaValido(d) ? d : null;
        }
      }
    } catch (_) {
      // Archivo ilegible: se arranca limpio.
    }
    _cargado = true;
    notifyListeners();
  }

  bool completada(String idLeccion) => _completadas.contains(idLeccion);

  /// Una lección se abre cuando la anterior ya se terminó. Las ya hechas
  /// se pueden repetir.
  bool desbloqueada(Leccion l) {
    final i = leccionesEnOrden.indexWhere((x) => x.id == l.id);
    if (i <= 0) return i == 0;
    return completada(leccionesEnOrden[i - 1].id);
  }

  /// La primera lección sin terminar, o null si ya se hizo todo.
  Leccion? get siguiente {
    for (final l in leccionesEnOrden) {
      if (!completada(l.id)) return l;
    }
    return null;
  }

  /// La lección que sigue de [l], o null si es la última.
  Leccion? despuesDe(Leccion l) {
    final i = leccionesEnOrden.indexWhere((x) => x.id == l.id);
    if (i < 0 || i + 1 >= leccionesEnOrden.length) return null;
    return leccionesEnOrden[i + 1];
  }

  /// Cuántas señas distintas ya se vieron en lecciones terminadas.
  int get senasAprendidas {
    final vistas = <String>{};
    for (final l in leccionesEnOrden) {
      if (completada(l.id)) vistas.addAll(l.glosas);
    }
    return vistas.length;
  }

  /// Días seguidos practicando. Si ayer fue el último día, la racha sigue
  /// viva; si pasó más tiempo, ya se rompió y se muestra 0.
  int get racha {
    final d = _ultimoDia;
    if (d == null) return 0;
    return _diasDesde(d) <= 1 ? _racha : 0;
  }

  /// Marca la lección como terminada y actualiza la racha.
  Future<void> completar(Leccion l) async {
    _completadas.add(l.id);
    final d = _ultimoDia;
    if (d == null) {
      _racha = 1;
    } else {
      final dias = _diasDesde(d);
      if (dias == 0) {
        if (_racha == 0) _racha = 1;
      } else if (dias == 1) {
        _racha += 1;
      } else {
        _racha = 1;
      }
    }
    _ultimoDia = _hoy();
    notifyListeners();
    await _escribir();
  }

  /// Borra todo el avance.
  Future<void> reiniciar() async {
    _completadas.clear();
    _racha = 0;
    _ultimoDia = null;
    notifyListeners();
    await _escribir();
  }

  Future<void> _escribir() async {
    try {
      final f = await _ruta();
      await f.writeAsString(jsonEncode({
        'version': _kVersion,
        'completadas': _completadas.toList()..sort(),
        'racha': _racha,
        if (_ultimoDia != null) 'ultimo_dia': _ultimoDia,
      }));
    } catch (e) {
      // No poder guardar no debe tumbar la lección: se pierde el avance
      // de esta sesión, nada más.
      debugPrint('[ProgresoAprendizaje] no se pudo guardar: $e');
    }
  }

  static String _hoy() {
    final h = DateTime.now();
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${h.year}-${dos(h.month)}-${dos(h.day)}';
  }

  static bool _diaValido(String d) => DateTime.tryParse(d) != null;

  /// Días enteros desde [dia] hasta hoy. Se compara en UTC para que el
  /// cambio de horario no haga que un día mida 23 o 25 horas.
  static int _diasDesde(String dia) {
    final p = DateTime.parse(dia);
    final h = DateTime.now();
    return DateTime.utc(h.year, h.month, h.day)
        .difference(DateTime.utc(p.year, p.month, p.day))
        .inDays;
  }
}
