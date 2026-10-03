/// Grabador de sesion de camara (SessionLogV1, JSONL) para Android.
///
/// Espejo de assets/avatar_viewer/rig_session.mjs: una linea JSON por
/// registro (session_start, frame, event, session_end), cada una con `seq`
/// para deduplicar. Registra TODO lo que pasa en la sesion para encontrar
/// fallos (landmarks crudos, manos, cara, vectores, errores, tiempos);
/// nunca video ni imagenes. tools/analizar_sesion.py lee el mismo formato.
library sesion_captura;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'camera_bridge.dart';

const String kSessionSchema = 'SessionLogV1';

typedef SumideroSesion = Future<bool> Function(String id, List<String> lineas);

String nuevoIdSesion([DateTime? ahora]) {
  final t = (ahora ?? DateTime.now()).toUtc();
  String dos(int v) => v.toString().padLeft(2, '0');
  final sello = '${t.year}${dos(t.month)}${dos(t.day)}T'
      '${dos(t.hour)}${dos(t.minute)}${dos(t.second)}Z';
  const letras = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = math.Random();
  final sufijo = List.generate(6, (_) => letras[r.nextInt(letras.length)]).join();
  return '$sello-$sufijo';
}

double? _r4(double v) => v.isFinite ? (v * 1e4).round() / 1e4 : null;

List<List<double?>>? compactarPuntos(List<List<double>>? puntos) =>
    puntos?.map((p) => p.map(_r4).toList(growable: false)).toList(growable: false);

class SesionCaptura {
  final String sessionId;
  final SumideroSesion sumidero;
  final int flushEvery;
  final int maxPending;
  final int Function() _ahora;

  final List<({String linea, bool descartable})> _pendiente = [];
  int _seq = 0, _frames = 0, _eventos = 0, _descartados = 0, _enviados = 0;
  bool _cerrada = false;
  Future<bool>? _enVuelo;

  SesionCaptura({
    String? sessionId,
    Map<String, dynamic> meta = const {},
    required this.sumidero,
    this.flushEvery = 60,
    this.maxPending = 20000,
    int Function()? ahora,
  })  : sessionId = sessionId ?? nuevoIdSesion(),
        _ahora = ahora ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _push({
      'kind': 'session_start',
      'schema': kSessionSchema,
      'session_id': this.sessionId,
      'started_at_ms': _ahora(),
      'meta': meta,
    }, false);
  }

  bool get cerrada => _cerrada;
  Map<String, int> get stats => {
        'frames': _frames,
        'events': _eventos,
        'dropped': _descartados,
        'sent': _enviados,
        'pending': _pendiente.length,
      };

  void _push(Map<String, dynamic> registro, bool descartable) {
    final linea = jsonEncode({'seq': _seq++, ...registro});
    _pendiente.add((linea: linea, descartable: descartable));
    if (_pendiente.length > maxPending) {
      final i = _pendiente.indexWhere((p) => p.descartable);
      if (i >= 0) {
        _pendiente.removeAt(i);
        _descartados++;
      }
    }
    if (_pendiente.length >= flushEvery) unawaited(flush());
  }

  void frame(Map<String, dynamic> datos) {
    if (_cerrada) return;
    _frames++;
    _push({'kind': 'frame', ...datos}, true);
  }

  void evento(String tipo, [Map<String, dynamic> datos = const {}]) {
    if (_cerrada) return;
    _eventos++;
    _push({'kind': 'event', 'type': tipo, 't_ms': _ahora(), ...datos}, false);
  }

  Future<bool> flush() async {
    final previo = _enVuelo;
    if (previo != null) return previo;
    if (_pendiente.isEmpty) return true;
    final lote = _pendiente.map((p) => p.linea).toList(growable: false);
    final f = () async {
      var ok = false;
      try {
        ok = await sumidero(sessionId, lote);
      } catch (_) {}
      if (ok) {
        _pendiente.removeRange(0, math.min(lote.length, _pendiente.length));
        _enviados += lote.length;
      }
      return ok;
    }();
    _enVuelo = f;
    try {
      return await f;
    } finally {
      _enVuelo = null;
    }
  }

  Future<void> cerrar({String razon = 'stop'}) async {
    if (_cerrada) return;
    _push({
      'kind': 'session_end',
      't_ms': _ahora(),
      'frames': _frames,
      'events': _eventos,
      'dropped': _descartados,
      'reason': razon,
    }, false);
    _cerrada = true;
    await flush();
    if (_pendiente.isNotEmpty) await flush();
  }
}

/// Sumidero que anexa las lineas a `<dir>/<id>.jsonl`.
SumideroSesion sumideroArchivo(Directory dir) => (id, lineas) async {
      await dir.create(recursive: true);
      await File('${dir.path}/$id.jsonl')
          .writeAsString('${lineas.join('\n')}\n', mode: FileMode.append, flush: true);
      return true;
    };

/// Registro de un frame de camara nativa para la sesion.
Map<String, dynamic> frameDeSesion(LandmarkFrame f, {int? id}) {
  final vec = f.normalize();
  final ss = f.signSpace();
  return {
    't': f.timestampMs,
    if (id != null) 'id': id,
    'mode': f.captureMode,
    if (f.imageAspect != null) 'aspect': f.imageAspect,
    'pose': compactarPuntos(f.pose),
    'world': compactarPuntos(f.poseMundo),
    'hands': {
      'left': compactarPuntos(f.left),
      'right': compactarPuntos(f.right),
      'left_world': compactarPuntos(f.leftWorld),
      'right_world': compactarPuntos(f.rightWorld),
      'association': f.association,
    },
    'tracked': {'left': f.left != null, 'right': f.right != null},
    'face': f.face == null ? null : {'pts': compactarPuntos(f.face)},
    'skew_ms': f.sourceSkewMs,
    'vec': vec?.map(_r4).toList(growable: false),
    'sign_space': ss == null
        ? null
        : {
            'v': ss.values.map(_r4).toList(growable: false),
            'mask': ss.mask,
            'mode': ss.mode,
          },
    'quality': f.visibilidadMin,
    'errors': [for (final e in f.errors) e['code']],
  };
}
