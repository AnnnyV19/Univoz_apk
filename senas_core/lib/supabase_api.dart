/// Acceso directo a Supabase desde la app, por la API REST (PostgREST).
///
/// Se usa la clave publishable y row level security decide que se puede
/// hacer -- ver sql/002_app_acceso.sql. En la practica: la app puede subir
/// muestras (siempre como 'pendiente') y bajarse las aprobadas; no puede
/// modificar ni borrar nada.
///
/// Va contra la API REST a mano en vez de con el paquete supabase_flutter
/// porque de todo ese paquete solo necesitariamos esto: son cuatro pedidos
/// HTTP, y arrastrar auth + realtime + storage complica el build a cambio de
/// nada.
library supabase_api;

import 'dart:convert';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha1;
import 'package:http/http.dart' as http;

import 'config_supabase.dart';
import 'motion_contract.dart';
import 'red.dart';
import 'sign_norm.dart'
    show kNormVersion, kTFrames, kFrameDim, packF16, unpackF16;

class SupabaseError implements Exception, ErrorHumano {
  /// Texto para el equipo (puede nombrar archivos SQL o configuracion).
  final String mensaje;
  final String? _humano;

  /// [humano] es lo que ve una persona normal; sin el, [mensaje] ya lo es.
  SupabaseError(this.mensaje, {String? humano}) : _humano = humano;

  @override
  String get mensajeHumano => _humano ?? mensaje;

  @override
  String toString() => mensaje;
}

const String _kNoDisponible = 'Esto no está disponible por ahora.';

/// Una plantilla bajada de la base, lista para el DtwClassifier.
class PlantillaRemota {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;

  const PlantillaRemota(this.signId, this.gloss, this.espanol, this.seq);

  Map<String, dynamic> toJson() => {
        'sign_id': signId,
        'gloss': gloss,
        'espanol': espanol,
        'seq': seq
            .map((f) =>
                f.map((v) => double.parse(v.toStringAsFixed(5))).toList())
            .toList(),
      };

  factory PlantillaRemota.fromJson(Map<String, dynamic> j) {
    final seq = (j['seq'] as List<dynamic>)
        .map((f) =>
            (f as List<dynamic>).map((v) => (v as num).toDouble()).toList())
        .toList();
    MotionSequenceV2.fromFrames(seq);
    return PlantillaRemota(
      j['sign_id'] as String,
      j['gloss'] as String,
      (j['espanol'] as String?) ?? '',
      seq,
    );
  }
}

/// UUID v5 igual al que genera signer_uuid() en ingest_video.py, para que la
/// misma persona no cuente como dos personas distintas en v_cobertura segun
/// si la muestra entro por video o por telefono.
String signerUuid(String nombre) {
  // namespace DNS: 6ba7b810-9dad-11d1-80b4-00c04fd430c8
  const ns = <int>[
    0x6b,
    0xa7,
    0xb8,
    0x10,
    0x9d,
    0xad,
    0x11,
    0xd1,
    0x80,
    0xb4,
    0x00,
    0xc0,
    0x4f,
    0xd4,
    0x30,
    0xc8,
  ];
  final nombreBytes =
      utf8.encode('univoz-signer:${nombre.trim().toLowerCase()}');
  final h = sha1.convert([...ns, ...nombreBytes]).bytes;

  final b = List<int>.from(h.sublist(0, 16));
  b[6] = (b[6] & 0x0f) | 0x50; // version 5
  b[8] = (b[8] & 0x3f) | 0x80; // variante RFC 4122

  String hex(int desde, int hasta) => b
      .sublist(desde, hasta)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// UUID v4 aleatorio (RFC 4122) para ids que genera el cliente.
String uuidV4([Random? azar]) {
  final r = azar ?? Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variante RFC 4122
  String hex(int desde, int hasta) => b
      .sublist(desde, hasta)
      .map((x) => x.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Postgres representa BYTEA en texto como \x seguido de hexadecimal. Es el
/// formato que PostgREST devuelve al leer y acepta al escribir.
String _aHexPostgres(Uint8List bytes) {
  final sb = StringBuffer(r'\x');
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _desdeHexPostgres(String texto) {
  var t = texto;
  if (t.startsWith(r'\x') || t.startsWith(r'\X')) t = t.substring(2);
  final n = t.length ~/ 2;
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = int.parse(t.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

class SupabaseApi {
  final String url;
  final String clave;
  final http.Client _http;

  SupabaseApi({String? url, String? clave, http.Client? cliente})
      : url = (url ?? kSupabaseUrl).replaceAll(RegExp(r'/+$'), ''),
        clave = clave ?? kSupabasePublishableKey,
        _http = cliente ?? http.Client();

  Map<String, String> get _cabeceras => {
        'apikey': clave,
        'Authorization': 'Bearer $clave',
        'Content-Type': 'application/json',
      };

  Uri _uri(String recurso, [Map<String, String>? params]) =>
      Uri.parse('$url/rest/v1/$recurso').replace(queryParameters: params);

  Never _fallo(String que, http.Response r) {
    // Nunca se muestra el cuerpo de PostgREST: puede traer SQL, detalles de
    // politicas o datos internos. Solo el mensaje humano segun el estado.
    final fallo = falloDeRespuesta(r);
    final humano = switch (r.statusCode) {
      401 || 403 || 408 || 429 || >= 500 => fallo.mensaje,
      _ => '$que no se pudo completar. Revisa tu conexión e inténtalo de '
          'nuevo.',
    };
    throw SupabaseError('$humano (${fallo.tecnico})', humano: humano);
  }

  /// GET con tiempo maximo y un reintento; los fallos de red salen como
  /// SupabaseError con mensaje humano.
  Future<http.Response> _get(Uri uri,
      {Duration timeout = kTimeoutRed}) async {
    try {
      return await redGet(_http, uri, headers: _cabeceras, timeout: timeout);
    } on FalloRed catch (e) {
      throw SupabaseError('${e.mensaje} (${e.tecnico})', humano: e.mensaje);
    }
  }

  /// POST con tiempo maximo y SIN reintento.
  Future<http.Response> _post(Uri uri,
      {Map<String, String>? cabeceras,
      Object? body,
      Duration timeout = kTimeoutRed}) async {
    try {
      return await redPost(_http, uri,
          headers: cabeceras ?? _cabeceras, body: body, timeout: timeout);
    } on FalloRed catch (e) {
      throw SupabaseError('${e.mensaje} (${e.tecnico})', humano: e.mensaje);
    }
  }

  /// Pedido minimo para saber si hay red, si la URL/clave sirven y si las
  /// politicas de lectura estan puestas.
  Future<String> probar() async {
    if (!haySupabaseConfigurado) {
      throw SupabaseError(
          'Falta cargar la URL y la clave en config_supabase.dart.',
          humano: _kNoDisponible);
    }
    final r = await _get(
      _uri('v_dtw_aprobadas', {'select': 'gloss', 'limit': '1'}),
    );
    if (r.statusCode == 404) {
      throw SupabaseError(
          'No existe la vista v_dtw_aprobadas. Corre sql/002_app_acceso.sql '
          'en el SQL Editor de Supabase.',
          humano: _kNoDisponible);
    }
    if (r.statusCode >= 400) _fallo('La conexión', r);
    return 'Conexión OK';
  }

  /// Busca la sena por glosa; si no existe la crea. Devuelve su id.
  Future<String> _idDeSena(
      String gloss, String espanol, String? categoria) async {
    final existentes = await _get(
      _uri('signs', {'gloss': 'eq.$gloss', 'select': 'id', 'limit': '1'}),
    );
    if (existentes.statusCode >= 400) _fallo('Buscar la seña', existentes);

    final filas = jsonDecode(existentes.body) as List<dynamic>;
    if (filas.isNotEmpty) {
      return (filas.first as Map<String, dynamic>)['id'] as String;
    }

    final creada = await _post(
      _uri('signs'),
      cabeceras: {..._cabeceras, 'Prefer': 'return=representation'},
      body: jsonEncode({
        'gloss': gloss,
        'espanol': espanol,
        if (categoria != null && categoria.isNotEmpty) 'categoria': categoria,
      }),
    );
    if (creada.statusCode >= 400) _fallo('Crear la seña', creada);

    final nuevas = jsonDecode(creada.body) as List<dynamic>;
    if (nuevas.isEmpty) {
      throw SupabaseError('La base no devolvió el id de la seña $gloss.',
          humano: kMsgGenerico);
    }
    return (nuevas.first as Map<String, dynamic>)['id'] as String;
  }

  /// Sube una muestra. Queda en 'pendiente' -- es lo unico que row level
  /// security deja hacer, y ademas es lo correcto: nada entra al diccionario
  /// sin que alguien lo revise.
  ///
  /// Devuelve el id de la muestra creada.
  Future<String> subirMuestra({
    required String gloss,
    required String espanol,
    required List<List<double>> seq,
    String? categoria,
    String? signer,
    int? nFramesOrig,
    double? fps,
    int? duracionMs,
    int? framesInvalidos,
    double? visibilidadMin,
    double? qualityScore,
    String? checksumSha256,
  }) async {
    if (!haySupabaseConfigurado) {
      throw SupabaseError(
          'Falta cargar la URL y la clave en config_supabase.dart.',
          humano: _kNoDisponible);
    }
    MotionSequenceV2.fromFrames(seq);

    final signId = await _idDeSena(gloss, espanol, categoria);

    // El id de la muestra se genera aca y se manda en el body, con
    // return=minimal. Con return=representation Postgres aplica la politica
    // de SELECT a la fila nueva (INSERT ... RETURNING), y las 'pendiente' no
    // son legibles para la app (samples_lectura solo deja 'aprobada'): el
    // alta se rechazaria con 42501.
    final sampleId = uuidV4();
    final muestra = await _post(
      _uri('sign_samples'),
      cabeceras: {..._cabeceras, 'Prefer': 'return=minimal'},
      body: jsonEncode({
        'id': sampleId,
        'sign_id': signId,
        'origen': 'camara',
        'estado': 'pendiente',
        if (signer != null && signer.trim().isNotEmpty)
          'signer_id': signerUuid(signer),
        if (nFramesOrig != null) 'n_frames_orig': nFramesOrig,
        if (fps != null) 'fps': fps,
        if (duracionMs != null) 'duracion_ms': duracionMs,
        if (framesInvalidos != null) 'frames_invalidos': framesInvalidos,
        if (visibilidadMin != null) 'visibilidad_min': visibilidadMin,
        if (qualityScore != null) 'quality_score': qualityScore,
        if (checksumSha256 != null) 'checksum_sha256': checksumSha256,
      }),
    );
    if (muestra.statusCode >= 400) _fallo('Subir la muestra', muestra);

    final landmarks = await _post(
      _uri('sample_landmarks'),
      body: jsonEncode({
        'sample_id': sampleId,
        'norm_version': kNormVersion,
        't_frames': seq.length,
        'frame_dim': kFrameDim,
        'data': _aHexPostgres(packF16(seq)),
      }),
    );
    if (landmarks.statusCode >= 400) _fallo('Subir los landmarks', landmarks);

    return sampleId;
  }

  /// Baja todas las plantillas aprobadas de esta version de normalizacion.
  Future<List<PlantillaRemota>> descargarPlantillas() async {
    if (!haySupabaseConfigurado) {
      throw SupabaseError(
          'Falta cargar la URL y la clave en config_supabase.dart.',
          humano: _kNoDisponible);
    }

    final r = await _get(
      _uri('v_motion_v2_aprobadas', {
        // norm_version TIENE que ir en el select aunque abajo ya se filtre
        // con 'norm_version=eq.': PostgREST solo devuelve las columnas que
        // se piden aca, y el chequeo de mas abajo compara
        // m['norm_version'] != kNormVersion. Sin pedirla, ese valor llega
        // siempre null, null nunca es igual a '2.0.0', y el bucle descarta
        // TODAS las filas en silencio -- el diccionario bajaba vacio por
        // muchas muestras aprobadas que hubiera en la base.
        'select':
            'sign_id,gloss,espanol,norm_version,t_frames,frame_dim,data',
        'norm_version': 'eq.$kNormVersion',
      }),
      // El diccionario completo pesa varios MB: con datos lentos no cabe en
      // los 10 s de una peticion normal.
      timeout: kTimeoutDescargaDiccionario,
    );
    if (r.statusCode == 404) {
      throw SupabaseError('No existe la vista v_motion_v2_aprobadas. Corre '
          'sql/004_motion_v2.sql en el SQL Editor de Supabase.',
          humano: _kNoDisponible);
    }
    if (r.statusCode >= 400) _fallo('Descargar el diccionario', r);

    final filas = jsonDecode(r.body) as List<dynamic>;
    final out = <PlantillaRemota>[];
    for (final f in filas) {
      final m = f as Map<String, dynamic>;
      final crudo = m['data'];
      if (crudo is! String) continue;
      final dim = (m['frame_dim'] as num?)?.toInt() ?? kFrameDim;
      final t = (m['t_frames'] as num?)?.toInt() ?? kTFrames;
      if (dim != kFrameDim ||
          t != kTFrames ||
          (m['norm_version'] as String?) != kNormVersion) {
        continue;
      }
      final bytes = _desdeHexPostgres(crudo);
      if (bytes.length != kTFrames * kFrameDim * 2) continue;
      final seq = unpackF16(bytes, dim: dim);
      if (seq.isEmpty) continue;
      try {
        MotionSequenceV2.fromFrames(seq);
      } catch (_) {
        continue;
      }
      out.add(PlantillaRemota(
        m['sign_id'] as String,
        m['gloss'] as String,
        (m['espanol'] as String?) ?? '',
        seq,
      ));
    }
    return out;
  }

  /// Sube raw landmarks comprimidos a Storage. Nunca se invoca durante la
  /// captura normal; requiere acción explícita y políticas de Storage.
  Future<String> subirLandmarksCrudos({
    required String bucket,
    required String objectPath,
    required Uint8List gzipBytes,
  }) async {
    if (!haySupabaseConfigurado) {
      throw SupabaseError(
          'Falta cargar la URL y la clave en config_supabase.dart.',
          humano: _kNoDisponible);
    }
    final uri = Uri.parse('$url/storage/v1/object/$bucket/$objectPath');
    final r = await _post(
      uri,
      cabeceras: {
        'apikey': clave,
        'Authorization': 'Bearer $clave',
        'Content-Type': 'application/gzip',
        'x-upsert': 'false',
      },
      body: gzipBytes,
      timeout: kTimeoutSubida,
    );
    if (r.statusCode >= 400) _fallo('Subir landmarks crudos', r);
    return '$bucket/$objectPath';
  }

  void cerrar() => _http.close();
}
