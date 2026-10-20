/// Paridad del vector 152D con la web: normalizeFrame reproduce
/// normalizeMotionFrame (assets/avatar_viewer/rig_motion_frame.mjs) sobre el
/// banco de paridad test/golden/paridad_manos.jsonl.gz: vector de
/// reconocimiento, vector de render (munecas estabilizadas), motivos y
/// calidad del frame. Las
/// manos de cada lado salen de la salida esperada de la captura web.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:senas_core/sign_norm.dart';

List<List<double>> _puntos(dynamic raw) => (raw as List)
    .map<List<double>>(
        (p) => (p as List).map((v) => (v as num).toDouble()).toList())
    .toList();

List<double>? _vector(dynamic raw) => raw == null
    ? null
    : (raw as List).map<double>((v) => (v as num).toDouble()).toList();

bool _cerca(double esperado, double obtenido) =>
    (esperado - obtenido).abs() <=
    1e-9 * (esperado.abs() > 1 ? esperado.abs() : 1);

String? _diferencia(List<double>? esperado, List<double>? obtenido) {
  if (esperado == null || obtenido == null) {
    return identical(esperado == null, obtenido == null)
        ? null
        : '${esperado == null ? 'null' : 'vector'} vs '
            '${obtenido == null ? 'null' : 'vector'}';
  }
  if (esperado.length != obtenido.length) {
    return 'largo ${esperado.length} vs ${obtenido.length}';
  }
  for (var k = 0; k < esperado.length; k++) {
    if (!_cerca(esperado[k], obtenido[k])) {
      return '[$k] ${esperado[k]} vs ${obtenido[k]}';
    }
  }
  return null;
}

/// Decodifica `vec_render` (ver tools/rig-tests/paridad/replay.mjs).
List<double>? _renderEsperado(Map<String, dynamic> esp) {
  final r = esp['vec_render'];
  final vec = _vector(esp['vec']);
  if (r == null) return vec;
  if (r == 'null') return null;
  final m = r as Map<String, dynamic>;
  if (m.containsKey('all')) return _vector(m['all']);
  final out = List<double>.from(vec!);
  m.forEach((k, v) => out[int.parse(k)] = (v as num).toDouble());
  return out;
}

List<String> _errores(Iterable<List<Object?>> triples) =>
    triples.map(jsonEncode).toList()..sort();

void main() {
  test('normalizeFrame reproduce el vector y los motivos de la web', () {
    final lineas = utf8
        .decode(gzip.decode(
            File('test/golden/paridad_manos.jsonl.gz').readAsBytesSync()))
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .map((l) => jsonDecode(l) as Map<String, dynamic>);
    var n = 0;
    final desajustes = <String>[];
    for (final l in lineas) {
      final esp = l['esp'] as Map<String, dynamic>;
      if (!esp.containsKey('vec')) continue;
      n++;
      final entrada = l['in'] as Map<String, dynamic>;
      final pose = entrada['pose'] == null ? null : _puntos(entrada['pose']);
      final mundo = entrada['world'] == null ? null : _puntos(entrada['world']);
      final cand = (entrada['cand'] as List)
          .map((c) => _puntos((c as Map<String, dynamic>)['lm']))
          .toList();
      (List<List<double>>?, List<List<double>>?) lado(String k) {
        final e = esp[k] as Map<String, dynamic>;
        final indice = (e['raw'] ?? e['detected']) as int?;
        final r = e['render'];
        return (
          indice == null ? null : cand[indice],
          r == null ? null : r == 'raw' ? cand[e['raw'] as int] : _puntos(r),
        );
      }

      final (left, renderLeft) = lado('left');
      final (right, renderRight) = lado('right');
      final donde = '${l['tramo']}#${l['i']}';

      final motivos = <MotivoNorm>[];
      final vec = normalizeFrame(pose, mundo,
          left: left, right: right, motivos: motivos);
      final d = _diferencia(_vector(esp['vec']), vec);
      if (d != null) desajustes.add('$donde vec $d');
      final obtenidos =
          _errores(motivos.map((m) => [m.stage, m.code, m.side]));
      final esperados = _errores(
          (esp['err_vector'] as List).map((e) => (e as List).cast<Object?>()));
      if (obtenidos.join() != esperados.join()) {
        desajustes.add('$donde err_vector web=$esperados dart=$obtenidos');
      }

      // Calidad como calcularCalidadFrameWeb: solo con vector valido.
      final calidad =
          vec == null ? 0.0 : calidadFrame(pose, mundo, left, right);
      final calidadWeb = (esp['quality'] as num).toDouble();
      if (!_cerca(calidadWeb, calidad)) {
        desajustes.add('$donde quality web=$calidadWeb dart=$calidad');
      }

      final render = normalizeFrame(pose, mundo,
          left: renderLeft ?? left,
          right: renderRight ?? right,
          munecasRender: {
            if (renderLeft != null) 'left': renderLeft[0],
            if (renderRight != null) 'right': renderRight[0],
          });
      final dr = _diferencia(_renderEsperado(esp), render);
      if (dr != null) desajustes.add('$donde vec_render $dr');
    }
    expect(n, greaterThan(300), reason: 'fixture casi sin vectores');
    expect(desajustes, isEmpty,
        reason: '${desajustes.length} desajustes; primeros:\n'
            '${desajustes.take(20).join('\n')}');
  });
}
