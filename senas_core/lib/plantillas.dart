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
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'dtw.dart';
import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'sign_norm.dart'
    show
        isotropizarSecuencia,
        kAspectoAnalisisApp,
        kAspectoVideo,
        kFormaIso,
        kFrameDim,
        kNormVersion,
        kTFrames,
        mirrorFrame;

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
  /// clasificador. Vacio si no hay assets/aprendizaje.json.
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
/// nunca debe tumbar el diccionario.
Future<List<Template>> cargarAprendizaje(
    {String ruta = kRutaAprendizaje}) async {
  String texto;
  try {
    texto = await rootBundle.loadString(ruta);
  } catch (_) {
    return const [];
  }
  try {
    return leerAprendizaje(texto);
  } catch (_) {
    return const [];
  }
}

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
      out.add(Template(m['sign_id'] as String, m['gloss'] as String, seq,
          espanol: (m['espanol'] as String?) ?? ''));
    } catch (_) {
      // Una plantilla corrupta no debe tumbar el resto.
    }
  }
  return out;
}

/// Lee el asset del paquete. Devuelve lista vacia si no existe o esta vacio
/// -- no es un error: se puede reconocer solo con muestras locales.
Future<List<_Plantilla>> _leerPaquete(String ruta) async {
  String texto;
  try {
    texto = await rootBundle.loadString(ruta);
  } catch (_) {
    return const [];
  }

  final Map<String, dynamic> json;
  try {
    json = jsonDecode(texto) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }

  final yaCorregido = json['forma'] == kFormaIso;
  final normVersion = json['norm_version'] as String?;
  if (normVersion != null && normVersion != kNormVersion) {
    // Un paquete viejo no es comparable con lo que ve la camara: los
    // vectores se calcularon con otra formula. Mejor ignorarlo que dar
    // resultados sin sentido.
    return const [];
  }
  if ((json['frame_dim'] as num?)?.toInt() != kFrameDim ||
      (json['t_frames'] as num?)?.toInt() != kTFrames) {
    return const [];
  }

  final crudas = (json['plantillas'] as List<dynamic>?) ?? const [];
  final out = <_Plantilla>[];
  for (final p in crudas) {
    try {
      final m = p as Map<String, dynamic>;
      var seq = (m['seq'] as List<dynamic>)
          .map((f) =>
              (f as List<dynamic>).map((v) => (v as num).toDouble()).toList())
          .toList();
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

class _Plantilla {
  final String signId;
  final String gloss;
  final String espanol;
  final List<List<double>> seq;
  const _Plantilla(this.signId, this.gloss, this.espanol, this.seq);
}

/// Construye el clasificador con todo lo disponible. Llamalo de nuevo
/// despues de grabar muestras nuevas para que entren al reconocimiento.
Future<Diccionario> cargarDiccionario({String ruta = kRutaPaquete}) async {
  final almacen = AlmacenMuestras.instancia;
  await almacen.cargar();
  final ajustes = almacen.ajustes;

  final clasificador = DtwClassifier(
    maxDistance: ajustes.maxDistance,
    minMargin: ajustes.minMargin,
    // Con el espejo la biblioteca se duplica. Con 40 candidatas el prefiltro
    // por firma deja fuera alguna plantilla buena (~1 punto menos de acierto
    // medido contra las plantillas reales); con 80 el resultado es el mismo
    // que sin filtrar.
    prefilter: ajustes.espejoAutomatico ? 80 : 40,
  );

  final glosas = <String>{};
  var delPaquete = 0;
  var sincronizadas = 0;
  var locales = 0;
  var espejadas = 0;

  // Agrega la version espejada de una plantilla, si el ajuste esta activo.
  // El espejo se calcula al vuelo en vez de guardarse: es barato y evita
  // duplicar los archivos en disco. Conserva el id de la sena, para que quien
  // lea Prediction.signId reciba el de la sena real y no uno inventado.
  void agregarEspejo(String signId, String gloss, List<List<double>> seq,
      String espanol) {
    if (!ajustes.espejoAutomatico) return;
    clasificador.add(signId, gloss, seq.map(mirrorFrame).toList(),
        espanol: espanol);
    espejadas++;
  }

  // El paquete del APK manda: pasa por tools/curar_plantillas.py (forma
  // corregida con el aspecto de cada grabacion, plantilla "de muestra" de cada
  // sena elegida a mano, cuadros corruptos reparados), y lo que baja la
  // sincronizacion es el dato crudo de la base. De lo sincronizado solo se
  // agregan las glosas que el paquete no trae -- sumar las dos fuentes de la
  // misma glosa duplicaria cada plantilla. Las muestras nuevas de una glosa
  // que ya esta en el paquete entran al exportar y curar de nuevo.
  final delApk = await _leerPaquete(ruta);
  final glosasApk = <String>{};
  for (final p in delApk) {
    clasificador.add(p.signId, p.gloss, p.seq, espanol: p.espanol);
    agregarEspejo(p.signId, p.gloss, p.seq, p.espanol);
    glosas.add(p.gloss);
    glosasApk.add(p.gloss);
    delPaquete++;
  }
  for (final p in almacen.sincronizadas) {
    if (glosasApk.contains(p.gloss)) continue;
    final seq = isotropizarSecuencia(p.seq, kAspectoVideo);
    clasificador.add(p.signId, p.gloss, seq, espanol: p.espanol);
    agregarEspejo(p.signId, p.gloss, seq, p.espanol);
    glosas.add(p.gloss);
    sincronizadas++;
  }

  for (final m in almacen.muestras) {
    final seq = isotropizarSecuencia(m.seq, m.aspecto ?? kAspectoAnalisisApp);
    clasificador.add('local:${m.gloss}', m.gloss, seq, espanol: m.espanol);
    glosas.add(m.gloss);
    locales++;
    agregarEspejo('local-espejo:${m.gloss}', m.gloss, seq, m.espanol);
  }

  // Solo de aprendizaje: no van al clasificador (ver kRutaAprendizaje).
  final aprendizaje = await cargarAprendizaje();

  return Diccionario(
    clasificador,
    ResumenDiccionario(
      delPaquete: delPaquete,
      sincronizadas: sincronizadas,
      locales: locales,
      espejadas: espejadas,
      senasDistintas: glosas.length,
    ),
    aprendizaje: aprendizaje,
  );
}
