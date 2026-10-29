/// Arma el diccionario que usa el reconocedor, combinando dos fuentes:
///
///  1. assets/plantillas.json -- las muestras aprobadas en Supabase,
///     exportadas desde la PC con tools/exportar_paquete.py. Es el
///     diccionario "oficial" del equipo y viaja dentro del APK.
///  2. Las muestras grabadas en este telefono (muestras_locales.dart), que
///     cuentan al instante, sin esperar a que alguien las apruebe.
///
/// Las dos van al mismo DtwClassifier: para reconocer no hay diferencia
/// entre una plantilla que vino de la base y una que grabaste hace un
/// minuto.
///
/// La forma de la mano de TODAS las plantillas entra al clasificador ya
/// corregida por el aspecto de la imagen en que se grabo (isotropizarSecuencia):
///  - paquete curado (campo "forma": "iso1", lo escribe tools/curar_plantillas.py):
///    ya viene corregida, con el aspecto estimado por plantilla.
///  - paquete sin curar, o sincronizadas de la base: llegan en el formato
///    2.0.0 crudo; se corrigen aqui con el aspecto de cada plantilla si lo
///    traen ("aspecto") o con 16:9, que es el de casi todos los videos.
///  - muestras locales: con el aspecto con que se grabaron (o el del bitmap de
///    analisis de la app si son anteriores a que se guardara).
///
/// Con el ajuste "espejo automatico" (activo por defecto) CADA plantilla,
/// venga de donde venga, entra tambien espejada. Asi quien sena con la otra
/// mano (o es zurdo) se reconoce sin grabar de nuevo: medido contra las
/// plantillas reales, el acierto de una consulta espejada pasa de ~9% a ~63%
/// con 1 muestra por sena, y de ~13% a ~82% con 3.
library plantillas;

import 'dart:convert';
import 'dart:isolate' show TransferableTypedData;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute, kIsWeb, visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;

import 'dtw.dart';
import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'supabase_api.dart' show PlantillaRemota;
import 'sign_norm.dart'
    show
        isotropizarSecuencia,
        kAspectoAnalisisApp,
        kAspectoVideo,
        kFormaIso,
        kFrameDim,
        kNormVersion,
        kTFrames;

const String kRutaPaquete = 'assets/plantillas.json';

/// Señas SOLO DE APRENDIZAJE (tools/exportar_aprendizaje.py; hoy el Glosario
/// Digital de LSM de INDISCAPACIDAD CDMX). Las usa el Diccionario y el avatar;
/// NUNCA entran al clasificador, asi que no cambian el reconocimiento.
const String kRutaAprendizaje = 'assets/aprendizaje.json';

/// Cuantas plantillas aporto cada fuente, para poder mostrarlo en pantalla.
class ResumenDiccionario {
  final int delPaquete;
  final int sincronizadas;
  final int locales;
  final int espejadas;
  final int senasDistintas;

  const ResumenDiccionario({
    required this.delPaquete,
    required this.sincronizadas,
    required this.locales,
    required this.espejadas,
    required this.senasDistintas,
  });

  int get total => delPaquete + sincronizadas + locales + espejadas;
  bool get vacio => total == 0;
}

class Diccionario {
  final DtwClassifier clasificador;
  final ResumenDiccionario resumen;

  /// Señas solo de aprendizaje (avatar y Diccionario), fuera del
  /// clasificador: [Template.soloReproduccion], solo con `seq`. Vacio si no
  /// hay assets/aprendizaje.json.
  final List<Template> aprendizaje;

  const Diccionario(this.clasificador, this.resumen,
      {this.aprendizaje = const []});
}

/// float16 (IEEE 754 half, como lo guarda la base) -> double.
double halfADouble(int h) {
  final signo = (h >> 15) & 1;
  final exp = (h >> 10) & 0x1f;
  final frac = h & 0x3ff;
  double v;
  if (exp == 0) {
    v = frac / 1024.0 * math.pow(2, -14);
  } else if (exp == 31) {
    v = frac == 0 ? double.infinity : double.nan;
  } else {
    v = (1 + frac / 1024.0) * math.pow(2, exp - 15);
  }
  return signo == 1 ? -v : v;
}

/// Secuencia guardada como float16 little-endian en base64 (formato de
/// assets/aprendizaje.json), en cuadros de [dim] valores.
List<List<double>> decodificarF16(String b64, {int dim = kFrameDim}) {
  final bytes = base64Decode(b64);
  final datos = ByteData.sublistView(bytes);
  final n = bytes.length ~/ 2;
  final out = <List<double>>[];
  for (var i = 0; i + dim <= n; i += dim) {
    out.add([
      for (var k = 0; k < dim; k++)
        halfADouble(datos.getUint16((i + k) * 2, Endian.little)),
    ]);
  }
  return out;
}

/// Lee assets/aprendizaje.json. Lista vacia si no esta o es de otro formato:
/// nunca debe tumbar el diccionario. Se decodifica en un isolate (~11 MB).
Future<List<Template>> cargarAprendizaje(
    {String ruta = kRutaAprendizaje}) async {
  final bytes = await _leerBytesAsset(ruta);
  if (bytes == null) return const [];
  try {
    return await compute(_aprendizajeEnBytes, bytes);
  } catch (_) {
    return const [];
  }
}

List<Template> _aprendizajeEnBytes(Uint8List bytes) =>
    leerAprendizaje(utf8.decode(bytes));

/// La parte pura de [cargarAprendizaje] (se prueba sin assets).
List<Template> leerAprendizaje(String texto) {
  final json = jsonDecode(texto) as Map<String, dynamic>;
  if (json['norm_version'] != kNormVersion ||
      (json['frame_dim'] as num?)?.toInt() != kFrameDim ||
      (json['t_frames'] as num?)?.toInt() != kTFrames ||
      json['codificacion'] != 'f16le-base64') {
    return const [];
  }
  final yaCorregido = json['forma'] == kFormaIso;
  final out = <Template>[];
  for (final p in (json['plantillas'] as List<dynamic>? ?? const [])) {
    try {
      final m = p as Map<String, dynamic>;
      var seq = decodificarF16(m['seq_f16'] as String);
      MotionSequenceV2.fromFrames(seq);
      if (seq.length != kTFrames) continue;
      if (!yaCorregido) {
        seq = isotropizarSecuencia(
            seq, (m['aspecto'] as num?)?.toDouble() ?? kAspectoVideo);
      }
      // Solo se reproduce en el avatar: sin cseq ni segs (no entra al
      // clasificador), que serian dos tercios de la memoria.
      out.add(Template.soloReproduccion(
          m['sign_id'] as String, m['gloss'] as String, seq,
          espanol: (m['espanol'] as String?) ?? ''));
    } catch (_) {
      // Una plantilla corrupta no debe tumbar el resto.
    }
  }
  return out;
}

/// Parte pura de la lectura del paquete (corre en un isolate). Lista vacia si
/// los bytes no son un paquete valido (UTF-8 o JSON roto) o es de otra version
/// del vector. Decodifica el JSON directo de los bytes, sin armar antes el
/// String de 51 MB.
List<_Plantilla> _leerPaqueteBytes(Uint8List bytes) {
  final Object? decodificado;
  try {
    decodificado = json.fuse(utf8).decode(bytes);
  } catch (_) {
    return const [];
  }
  if (decodificado is! Map<String, dynamic>) return const [];
  return _plantillasDelPaquete(decodificado);
}

List<_Plantilla> _plantillasDelPaquete(Map<String, dynamic> paquete) {
  if (!_cabeceraValida(paquete)) return const [];

  final yaCorregido = paquete['forma'] == kFormaIso;
  final crudas = (paquete['plantillas'] as List<dynamic>?) ?? const [];
  final out = <_Plantilla>[];
  for (final p in crudas) {
    try {
      final m = p as Map<String, dynamic>;
      // Cada cuadro pasa a Float64List al leerlo (8 bytes por valor en vez de
      // ~24): mientras se lee el paquete conviven el arbol del JSON y estas
      // copias, y ese era el pico de memoria al abrir el diccionario.
      var seq = <List<double>>[
        for (final f in m['seq'] as List<dynamic>) _aFloat64(f as List<dynamic>),
      ];
      MotionSequenceV2.fromFrames(seq);
      if (!yaCorregido) {
        seq = isotropizarSecuencia(
            seq, (m['aspecto'] as num?)?.toDouble() ?? kAspectoVideo);
      }
      out.add(_Plantilla(
        m['sign_id'] as String,
        m['gloss'] as String,
        (m['espanol'] as String?) ?? '',
        seq,
      ));
    } catch (_) {
      // Una plantilla corrupta no debe tumbar diccionario completo.
    }
  }
  return out;
}

Float64List _aFloat64(List<dynamic> valores) {
  final out = Float64List(valores.length);
  for (var i = 0; i < valores.length; i++) {
    out[i] = (valores[i] as num).toDouble();
  }
  return out;
}

bool _cabeceraValida(Map<String, dynamic> json) {
  final normVersion = json['norm_version'] as String?;
  if (normVersion != null && normVersion != kNormVersion) {
    // Un paquete viejo no es comparable con lo que ve la camara: los
    // vectores se calcularon con otra formula. Mejor ignorarlo que dar
    // resultados sin sentido.
    return false;
  }
  return (json['frame_dim'] as num?)?.toInt() == kFrameDim &&
      (json['t_frames'] as num?)?.toInt() == kTFrames;
}

class _Plantilla {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  const _Plantilla(this.signId, this.gloss, this.espanol, this.seq);
}

/// Una plantilla de cualquier fuente, lista para el clasificador.
class PlantillaFuente {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  const PlantillaFuente(this.signId, this.gloss, this.espanol, this.seq);
}

/// De donde vienen las plantillas base (excluyentes: ver [cargarDiccionario]).
enum OrigenPlantillas { paquete, sincronizadas }

bool _esEspejo(String signId) => signId.contains('espejo');

/// Arma el clasificador con las plantillas base (paquete o sincronizadas) y
/// las muestras locales. Con [espejar], cada plantilla suma su espejo
/// (persona zurda): medido en el paquete por leave-one-out, sin espejos una
/// sena hecha con la otra mano acierta 11 % y con espejos 65.8 %, a costa de
/// 0.6 puntos para la mano habitual (66.4 -> 65.8). No se espeja un espejo
/// ni una plantilla que ya trae el suyo (`<id>#espejo`).
///
/// [adicionales] son plantillas sincronizadas de la base de glosas que la base
/// (el paquete del APK) NO trae: el paquete manda y solo se le suman glosas
/// ausentes; sumar las dos fuentes de la misma glosa duplicaria cada plantilla.
Diccionario armarClasificador({
  required List<PlantillaFuente> base,
  required OrigenPlantillas origenBase,
  required List<PlantillaFuente> locales,
  required bool espejar,
  List<PlantillaFuente> adicionales = const [],
  double maxDistance = kMaxDistanceDefault,
  double minMargin = kMinMarginDefault,
}) {
  final clasificador = DtwClassifier(
    maxDistance: maxDistance,
    minMargin: minMargin,
    // Con el espejo la biblioteca se duplica. Con 40 candidatas el prefiltro
    // por firma deja fuera alguna plantilla buena (~1 punto menos de acierto
    // medido contra las plantillas reales); con 80 el resultado es el mismo
    // que sin filtrar.
    prefilter: espejar ? 80 : 40,
  );
  final glosas = <String>{};
  var espejadas = 0;
  void agregar(List<PlantillaFuente> fuente,
      String Function(PlantillaFuente) idEspejo) {
    final ids = fuente.map((p) => p.signId).toSet();
    for (final p in fuente) {
      final original =
          clasificador.add(p.signId, p.gloss, p.seq, espanol: p.espanol);
      glosas.add(p.gloss);
      final id = idEspejo(p);
      if (!espejar || _esEspejo(p.signId) || ids.contains(id)) continue;
      // El espejo se calcula al vuelo en vez de guardarse: es barato y evita
      // duplicar plantillas en disco. Tampoco guarda su `seq`: solo la usa el
      // boton "Ver en avatar" de Reconocer y la recalcula de la original.
      clasificador.addEspejo(id, original);
      espejadas++;
    }
  }

  agregar(base, (p) => '${p.signId}#espejo');
  agregar(adicionales, (p) => '${p.signId}#espejo');
  agregar(locales, (p) => 'local-espejo:${p.gloss}');
  return Diccionario(
    clasificador,
    ResumenDiccionario(
      delPaquete: origenBase == OrigenPlantillas.paquete ? base.length : 0,
      sincronizadas: origenBase == OrigenPlantillas.sincronizadas
          ? base.length + adicionales.length
          : adicionales.length,
      locales: locales.length,
      espejadas: espejadas,
      senasDistintas: glosas.length,
    ),
  );
}

/// Diccionario compartido por todas las pantallas (reconocer, traducir,
/// avatar, Comunicarse, visor): cada uno pesa cientos de MB, asi que se arma
/// una sola vez y se reutiliza mientras no cambie nada de lo que lo compone.
///
/// Mientras se arma se guarda el [Future] (las llamadas simultaneas lo
/// comparten); ya armado, solo una referencia debil: lo retienen las
/// pantallas que lo usan y, cuando ninguna lo tiene, el GC lo suelta (~200 MB
/// que si no quedaban ocupados todo el proceso tras pasar por Reconocer).
class _DiccionarioCompartido {
  final (String, int, bool, double, double) clave;
  Future<Diccionario>? enCurso;
  WeakReference<Diccionario>? listo;
  _DiccionarioCompartido(this.clave, this.enCurso);
}

_DiccionarioCompartido? _compartido;

/// Solo para pruebas: reemplaza la lectura de assets (rootBundle).
@visibleForTesting
Future<Uint8List?> Function(String ruta)? lectorAssetsPrueba;

/// Descarta el diccionario compartido y libera su memoria: el siguiente
/// [cargarDiccionario] lo arma de nuevo. No hace falta llamarla despues de
/// grabar, borrar o sincronizar (el almacen ya lo invalida solo); sirve en
/// pruebas y si algun dia se quiere soltar la memoria.
void olvidarDiccionarioCompartido() => _compartido = null;

/// Construye el clasificador con todo lo disponible. Se arma UNA vez y se
/// comparte: las llamadas siguientes (y las simultaneas) reciben el mismo
/// [Diccionario] mientras no cambien las muestras locales, las plantillas
/// sincronizadas, el espejo automatico ni los umbrales. Grabar, borrar y
/// sincronizar cambian [AlmacenMuestras.versionDiccionario]: la siguiente
/// pantalla que lo pida ya ve lo nuevo. Quien ya tiene un diccionario en la
/// mano sigue con ese hasta que lo vuelva a pedir.
///
/// El paquete del APK pesa ~50 MB (541 senas, 1296 plantillas) y aprendizaje
/// otros ~11 MB: leerlos, corregirlos (isotropia), centrarlos y firmarlos en
/// el hilo de la interfaz congelaba la app, asi que TODO eso corre en un
/// isolate ([compute]). Aqui solo se leen los bytes del asset y se arma el
/// encargo con lo que ya esta en memoria (sincronizadas y muestras locales).
Future<Diccionario> cargarDiccionario({String ruta = kRutaPaquete}) async {
  final almacen = AlmacenMuestras.instancia;
  await almacen.cargar();
  final ajustes = almacen.ajustes;
  final clave = (
    ruta,
    almacen.versionDiccionario,
    ajustes.espejoAutomatico,
    ajustes.maxDistance,
    ajustes.minMargin,
  );
  final previo = _compartido;
  if (previo != null && previo.clave == clave) {
    final enCurso = previo.enCurso;
    if (enCurso != null) return enCurso;
    final listo = previo.listo?.target;
    if (listo != null) return listo;
  }

  // Sin ningun await entre calcular la clave y arrancar esto: la foto de las
  // muestras que arma _cargarSinCompartir corresponde a la clave.
  final futuro = _cargarSinCompartir(almacen, ruta);
  final nuevo = _DiccionarioCompartido(clave, futuro);
  _compartido = nuevo;
  // Un fallo no se queda guardado: la proxima pantalla vuelve a intentarlo.
  // Tampoco un diccionario sin paquete cuando se pidio el paquete: leer
  // 51 MB puede fallar con poca memoria y no debe quedar asi hasta reiniciar.
  futuro.then<void>((d) {
    if (!identical(_compartido, nuevo)) return;
    if (ruta == kRutaPaquete && d.resumen.delPaquete == 0) {
      _compartido = null;
    } else {
      nuevo
        ..enCurso = null
        ..listo = WeakReference(d);
    }
  }, onError: (Object _) {
    if (identical(_compartido, nuevo)) _compartido = null;
  });
  return futuro;
}

Future<Diccionario> _cargarSinCompartir(
    AlmacenMuestras almacen, String ruta) {
  final ajustes = almacen.ajustes;
  // Las sincronizadas viajan tal cual (Float64List por plantilla): la forma
  // se corrige con 16:9, el aspecto de casi todos los videos, DENTRO del
  // isolate y solo para las glosas que el paquete no trae (ver
  // armarClasificador). Hacerlo aqui armaba copias de todas en el hilo de la
  // interfaz.
  final sincronizadas = List<PlantillaRemota>.of(almacen.sincronizadas);
  final locales = [
    for (final m in almacen.muestras)
      PlantillaFuente('local:${m.gloss}', m.gloss, m.espanol,
          isotropizarSecuencia(m.seq, m.aspecto ?? kAspectoAnalisisApp)),
  ];
  return _armarEnIsolate(ruta, sincronizadas, locales, ajustes);
}

Future<Diccionario> _armarEnIsolate(String ruta,
    List<PlantillaRemota> sincronizadas, List<PlantillaFuente> locales,
    Ajustes ajustes) async {
  final encargo = _EncargoDiccionario(
    paquete: _paraEnviar(await _leerBytesAsset(ruta)),
    aprendizaje: _paraEnviar(await _leerBytesAsset(kRutaAprendizaje)),
    sincronizadas: sincronizadas,
    locales: locales,
    espejar: ajustes.espejoAutomatico,
    maxDistance: ajustes.maxDistance,
    minMargin: ajustes.minMargin,
  );
  return compute(_construirDiccionario, encargo);
}

/// Los bytes pasan al isolate como TransferableTypedData: se copian una vez a
/// memoria nativa y el isolate los recibe sin otra copia ni pasar por su heap
/// de Dart (el paquete son 51 MB).
///
/// En web no existe TransferableTypedData ni hay isolates reales: ahi van los
/// bytes tal cual.
Object? _paraEnviar(Uint8List? bytes) => bytes == null || kIsWeb
    ? bytes
    : TransferableTypedData.fromList([bytes]);

Uint8List? _recibir(Object? enviado) => enviado is TransferableTypedData
    ? enviado.materialize().asUint8List()
    : enviado as Uint8List?;

/// Bytes de un asset, o null si no existe (no es un error: se puede reconocer
/// solo con muestras locales).
Future<Uint8List?> _leerBytesAsset(String ruta) async {
  final prueba = lectorAssetsPrueba;
  if (prueba != null) return prueba(ruta);
  try {
    final datos = await rootBundle.load(ruta);
    return datos.buffer.asUint8List(datos.offsetInBytes, datos.lengthInBytes);
  } catch (_) {
    return null;
  }
}

/// Lo que viaja al isolate de [cargarDiccionario]. Solo tipos que se pueden
/// enviar (bytes, listas y clases de datos).
class _EncargoDiccionario {
  final Object? paquete; // Uint8List o TransferableTypedData
  final Object? aprendizaje;
  final List<PlantillaRemota> sincronizadas;
  final List<PlantillaFuente> locales;
  final bool espejar;
  final double maxDistance;
  final double minMargin;
  const _EncargoDiccionario({
    required this.paquete,
    required this.aprendizaje,
    required this.sincronizadas,
    required this.locales,
    required this.espejar,
    required this.maxDistance,
    required this.minMargin,
  });
}

/// Cuerpo de [cargarDiccionario] (corre en un isolate; funcion de nivel
/// superior). Es la parte pura: bytes y listas adentro, [Diccionario] afuera.
Diccionario _construirDiccionario(_EncargoDiccionario e) {
  final bytesPaquete = _recibir(e.paquete);
  final bytesAprendizaje = _recibir(e.aprendizaje);
  // Un paquete que no se pueda leer (corrupto, otro formato) no tumba las
  // muestras locales: se sigue sin el, como si no estuviera.
  final delApk = bytesPaquete == null
      ? const <_Plantilla>[]
      : _leerPaqueteBytes(bytesPaquete);
  // El paquete del APK manda: pasa por tools/curar_plantillas.py (forma
  // corregida con el aspecto de cada grabacion, plantilla "de muestra" de cada
  // sena elegida a mano, cuadros corruptos reparados), y lo que baja la
  // sincronizacion es el dato crudo de la base. De lo sincronizado solo se
  // agregan las glosas que el paquete no trae. Las muestras nuevas de una
  // glosa que ya esta en el paquete entran al exportar y curar de nuevo.
  final glosasApk = {for (final p in delApk) p.gloss};
  final d = armarClasificador(
    base: [
      for (final p in delApk) PlantillaFuente(p.signId, p.gloss, p.espanol, p.seq),
    ],
    origenBase: OrigenPlantillas.paquete,
    adicionales: [
      for (final p in e.sincronizadas)
        if (!glosasApk.contains(p.gloss))
          PlantillaFuente(p.signId, p.gloss, p.espanol,
              isotropizarSecuencia(p.seq, kAspectoVideo)),
    ],
    locales: e.locales,
    espejar: e.espejar,
    maxDistance: e.maxDistance,
    minMargin: e.minMargin,
  );
  // Solo de aprendizaje: no van al clasificador (ver kRutaAprendizaje).
  List<Template> aprendizaje = const [];
  if (bytesAprendizaje != null) {
    try {
      aprendizaje = leerAprendizaje(utf8.decode(bytesAprendizaje));
    } catch (_) {}
  }
  return Diccionario(d.clasificador, d.resumen, aprendizaje: aprendizaje);
}
