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
import 'frame_derivados.dart';
import 'rotacion_sesiones.dart';

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

/// Tope de un archivo de sesion. Medido en un S22+ una sesion pesa ~8 MB por
/// minuto: sin tope, un solo archivo pasaria de los 50 MB de
/// [kMaxBytesSesiones] y la poda (que nunca borra el abierto) no serviria.
const int kMaxBytesArchivoSesion = 8 * 1024 * 1024;

/// Sumidero que anexa las lineas a `<dir>/<id>.jsonl`.
///
/// Si el archivo actual pasaria de [maxBytesArchivo], sigue en
/// `<id>.part002.jsonl`, `.part003`... (el relleno a tres cifras mantiene el
/// orden por nombre) y poda los archivos ya cerrados mas viejos hasta que el
/// total quede dentro de [maxBytesTotal] y [maxArchivos]. Nunca borra el
/// archivo abierto.
SumideroSesion sumideroArchivo(
  Directory dir, {
  int maxBytesArchivo = kMaxBytesArchivoSesion,
  int maxBytesTotal = kMaxBytesSesiones,
  int maxArchivos = kMaxArchivosSesion,
}) {
  final partes = <String, int>{}; // id -> parte abierta (1 = sin sufijo)
  final tamanos = <String, int>{}; // id -> bytes del archivo abierto
  String nombre(String id, int parte) => parte <= 1
      ? '$id.jsonl'
      : '$id.part${parte.toString().padLeft(3, '0')}.jsonl';
  return (id, lineas) async {
    await dir.create(recursive: true);
    final texto = '${lineas.join('\n')}\n';
    final bytes = utf8.encode(texto).length;
    var parte = partes[id] ?? 1;
    var usado = tamanos[id];
    if (usado == null) {
      final f = File('${dir.path}/${nombre(id, parte)}');
      usado = await f.exists() ? await f.length() : 0;
    }
    var roto = false;
    // Un lote suelto mayor que el tope va entero a un archivo propio.
    if (usado > 0 && usado + bytes > maxBytesArchivo) {
      parte++;
      usado = 0;
      roto = true;
    }
    await File('${dir.path}/${nombre(id, parte)}')
        .writeAsString(texto, mode: FileMode.append, flush: true);
    partes[id] = parte;
    tamanos[id] = usado + bytes;
    if (roto || tamanos[id]! > maxBytesTotal) {
      await podarSesiones(dir,
          maxArchivos: maxArchivos,
          maxBytes: maxBytesTotal,
          conservar: {nombre(id, parte)});
    }
    return true;
  };
}

double? _r3(Object? v) =>
    v is num && v.isFinite ? (v * 1e3).round() / 1e3 : null;

/// Puntos que llegan del canal: plano (Float64List, [ancho] por punto) o ya
/// anidados.
List<List<double>>? _puntosCanal(Object? raw, int ancho) {
  if (raw is! List) return null;
  if (raw.isNotEmpty && raw.first is List) {
    return [
      for (final p in raw) [for (final v in p as List) (v as num).toDouble()]
    ];
  }
  final plano = [for (final v in raw) (v as num).toDouble()];
  return [
    for (var i = 0; i + ancho <= plano.length; i += ancho)
      plano.sublist(i, i + ancho)
  ];
}

/// Registro de un frame de camara nativa para la sesion, con el esquema de
/// las sesiones web (index.html, sesionActual.frame): `hands` lleva la
/// entrada de la captura (candidatas, compuerta, nacimiento, lados) para
/// que tools/rig-tests/paridad/replay_sesion.mjs reproduzca la captura del
/// telefono y la compare con la web.
Map<String, dynamic> frameDeSesion(LandmarkFrame f, {int? id}) {
  final vec = normalizarCacheado(f);
  final ss = signSpaceCacheado(f);
  final entrada = f.handsIn;
  final track = f.track;
  return {
    't': f.timestampMs,
    if (id != null) 'id': id,
    'mode': f.captureMode,
    if (f.imageAspect != null) 'aspect': f.imageAspect,
    if (f.inferMs != null) 'ms': {'infer': f.inferMs},
    if (f.poseRan != null) 'pose_ran': f.poseRan,
    if (f.tier != null) 'tier': f.tier,
    if (f.thermal != null) 'thermal': f.thermal,
    'pose': compactarPuntos(f.pose),
    'world': compactarPuntos(f.poseMundo),
    'hands': {
      if (entrada != null) ...{
        'candidates': [
          for (final c in (entrada['candidates'] as List? ?? const []))
            {
              'lm': compactarPuntos(_puntosCanal((c as Map)['lm'], 3)),
              'label': c['label'] ?? '',
              'conf': _r3(c['conf'] ?? .5),
            },
        ],
        'accepted': entrada['accepted'],
        'unanchored': entrada['unanchored'],
        'rejected': [
          for (final r in (entrada['rejected'] as List? ?? const []))
            {'index': (r as List)[0], 'code': r[1]},
        ],
        'passed': entrada['passed'],
        'assignment': entrada['assignment'],
        'usable': entrada['usable'],
      },
      'left': compactarPuntos(f.left),
      'right': compactarPuntos(f.right),
      'left_world': compactarPuntos(f.leftWorld),
      'right_world': compactarPuntos(f.rightWorld),
      'association': f.association,
    },
    'tracked': {
      'left': f.left != null,
      'right': f.right != null,
      if (track != null) ...{
        'left_surface': (track['left'] as Map?)?['surface'],
        'right_surface': (track['right'] as Map?)?['surface'],
        'left_state': (track['left'] as Map?)?['state'],
        'right_state': (track['right'] as Map?)?['state'],
      },
    },
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
    // Calidad web (calcularCalidadFrameWeb): 0 si el frame no da vector.
    'quality':
        calidadCacheada(f),
    'errors': [for (final e in f.errors) e['code']],
  };
}
