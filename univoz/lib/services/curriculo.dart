import 'dart:math';

/// El camino de "Aprender LSM": unidades, lecciones y la forma de armar
/// los ejercicios de cada una.
///
/// Todo esto es Dart puro (sin Flutter) a propósito: así se puede probar
/// con `flutter test` sin celular, y no depende del avatar ni de la
/// cámara. Las glosas son las del diccionario (`plantillas.json`); el test
/// `test/curriculo_test.dart` comprueba que cada una exista ahí.

class Leccion {
  final String id;

  /// Lo que se ve en el nodo del camino ("A–E", "Saludos").
  final String titulo;

  /// Glosas del diccionario que se aprenden en esta lección.
  final List<String> glosas;

  /// Si termina pidiendo deletrear el nombre de quien usa la app.
  final bool deletrea;

  const Leccion({
    required this.id,
    required this.titulo,
    required this.glosas,
    this.deletrea = false,
  });
}

class Unidad {
  final int numero;
  final String titulo;
  final String detalle;
  final List<Leccion> lecciones;

  const Unidad({
    required this.numero,
    required this.titulo,
    required this.detalle,
    required this.lecciones,
  });
}

/// Las 44 señas que hay hoy en el diccionario, repartidas sin repetir ni
/// dejar ninguna fuera. Si el diccionario crece, aquí se agregan lecciones.
const List<Unidad> camino = [
  Unidad(
    numero: 1,
    titulo: 'El abecedario',
    detalle: 'Las 29 letras, en 5 lecciones',
    lecciones: [
      Leccion(id: 'u1l1', titulo: 'A–E', glosas: ['A', 'B', 'C', 'D', 'E']),
      Leccion(id: 'u1l2', titulo: 'F–J', glosas: ['F', 'G', 'H', 'I', 'J']),
      Leccion(
          id: 'u1l3',
          titulo: 'K–Ñ',
          glosas: ['K', 'L', 'LL', 'M', 'N', 'NN']),
      Leccion(
          id: 'u1l4', titulo: 'O–RR', glosas: ['O', 'P', 'Q', 'R', 'RR']),
      Leccion(
          id: 'u1l5',
          titulo: 'S–Z',
          glosas: ['S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z']),
    ],
  ),
  Unidad(
    numero: 2,
    titulo: 'Saludar',
    detalle: 'hola · adiós · ¿cómo estás? · bien · gracias',
    lecciones: [
      Leccion(
          id: 'u2l1',
          titulo: 'Saludos',
          glosas: ['HOLA', 'ADIOS', 'GRACIAS']),
      Leccion(
          id: 'u2l2', titulo: 'Cómo estás', glosas: ['COMO_ESTAS', 'BIEN']),
    ],
  ),
  Unidad(
    numero: 3,
    titulo: 'Disculparse',
    detalle: 'perdón · disculpa',
    lecciones: [
      Leccion(id: 'u3l1', titulo: 'Perdón', glosas: ['PERDON', 'DISCULPA']),
    ],
  ),
  Unidad(
    numero: 4,
    titulo: 'Pedir ayuda',
    detalle: 'ayuda · puedo · fácil · difícil',
    lecciones: [
      Leccion(
          id: 'u4l1',
          titulo: 'Ayuda',
          glosas: ['AYUDA', 'AYUDAR', 'ME_AYUDAS_UN_POCO']),
      Leccion(
          id: 'u4l2',
          titulo: 'Puedo',
          glosas: ['SI_PUEDO', 'NO_PUEDO', 'FACIL', 'DIFICIL']),
    ],
  ),
  Unidad(
    numero: 5,
    titulo: 'Presentarte',
    detalle: 'mi nombre es… y deletrear tu nombre',
    lecciones: [
      Leccion(
          id: 'u5l1',
          titulo: 'Tu nombre',
          glosas: ['MI_NOMBRE_ES'],
          deletrea: true),
    ],
  ),
];

/// Todas las lecciones, en el orden en que se desbloquean.
final List<Leccion> leccionesEnOrden = [
  for (final u in camino) ...u.lecciones,
];

/// Todas las glosas del camino.
final List<String> todasLasGlosas = [
  for (final l in leccionesEnOrden) ...l.glosas,
];

/// Glosas que son letras (A–Z más LL, RR y NN, que es la ñ).
final Set<String> _letras = {
  for (var c = 65; c <= 90; c++) String.fromCharCode(c),
  'LL',
  'RR',
  'NN',
};

/// Las 26 letras sueltas, para armar el teclado de deletrear.
final List<String> _soloLetras = [
  for (var c = 65; c <= 90; c++) String.fromCharCode(c),
];

bool esLetra(String glosa) => _letras.contains(glosa);

const Map<String, String> _etiquetas = {
  'NN': 'Ñ',
  'COMO_ESTAS': '¿cómo estás?',
  'ME_AYUDAS_UN_POCO': 'me ayudas un poco',
  'MI_NOMBRE_ES': 'mi nombre es',
  'SI_PUEDO': 'sí puedo',
  'NO_PUEDO': 'no puedo',
  'ADIOS': 'adiós',
  'PERDON': 'perdón',
  'FACIL': 'fácil',
  'DIFICIL': 'difícil',
};

/// Cómo se escribe una glosa en pantalla. Se arma aquí y no se toma del
/// campo `espanol` del diccionario porque ese todavía tiene acentos y
/// mayúsculas inconsistentes.
String etiquetaDe(String glosa) {
  final e = _etiquetas[glosa];
  if (e != null) return e;
  if (esLetra(glosa)) return glosa;
  return glosa.toLowerCase().replaceAll('_', ' ');
}

/// Las glosas con las que se deletrea [nombre], letra por letra.
///
/// Se quitan los acentos, la ñ se deletrea con su seña propia (NN) y
/// cualquier cosa que no sea letra se salta. Se corta en 8 letras para que
/// el ejercicio no se haga eterno.
List<String> letrasDeNombre(String? nombre) {
  const sinAcento = {
    'Á': 'A',
    'É': 'E',
    'Í': 'I',
    'Ó': 'O',
    'Ú': 'U',
    'Ü': 'U',
  };
  final out = <String>[];
  for (final r in (nombre ?? '').toUpperCase().runes) {
    final c = String.fromCharCode(r);
    if (c == 'Ñ') {
      out.add('NN');
      continue;
    }
    final l = sinAcento[c] ?? c;
    if (l.length == 1 && l.compareTo('A') >= 0 && l.compareTo('Z') <= 0) {
      out.add(l);
    }
  }
  return out.length > 8 ? out.sublist(0, 8) : out;
}

enum TipoEjercicio {
  /// El avatar hace la seña; se elige la palabra entre cuatro.
  miraYElige,

  /// Se da la palabra; se elige cuál de cuatro señas es.
  eligeLaSena,

  /// El avatar deletrea; se arma el nombre con las letras.
  deletrea,
}

class Ejercicio {
  final TipoEjercicio tipo;

  /// Lo que hay que contestar. Una sola glosa en los dos primeros tipos; en
  /// deletrear, todas las letras en orden.
  final List<String> esperado;

  /// Las cuatro opciones (glosas) o, al deletrear, las teclas.
  final List<String> opciones;

  const Ejercicio._(this.tipo, this.esperado, this.opciones);

  factory Ejercicio.miraYElige(String glosa, List<String> opciones) =>
      Ejercicio._(TipoEjercicio.miraYElige, [glosa], opciones);

  factory Ejercicio.eligeLaSena(String glosa, List<String> opciones) =>
      Ejercicio._(TipoEjercicio.eligeLaSena, [glosa], opciones);

  factory Ejercicio.deletrea(List<String> letras, List<String> teclas) =>
      Ejercicio._(TipoEjercicio.deletrea, letras, teclas);

  bool comprobar(List<String> respuesta) {
    if (respuesta.length != esperado.length) return false;
    for (var i = 0; i < esperado.length; i++) {
      if (respuesta[i] != esperado[i]) return false;
    }
    return true;
  }
}

/// Cuatro opciones para [glosa]: ella y tres que no lo son, del mismo tipo
/// (letras con letras, palabras con palabras; si no, la pregunta sería
/// trivial) y en orden al azar.
List<String> _opcionesPara(String glosa, Random azar) {
  final otras = todasLasGlosas
      .where((g) => g != glosa && esLetra(g) == esLetra(glosa))
      .toList()
    ..shuffle(azar);
  final opciones = [glosa, ...otras.take(3)]..shuffle(azar);
  return opciones;
}

/// Arma los ejercicios de una lección: primero se VE cada seña (mira y
/// elige), luego se RECUERDA (elige la seña, hasta tres) y, si la lección
/// lo pide, se deletrea el nombre.
List<Ejercicio> generarLeccion(
  Leccion leccion, {
  String? nombre,
  Random? azar,
}) {
  final rng = azar ?? Random();
  final out = <Ejercicio>[];

  final vistas = List<String>.from(leccion.glosas)..shuffle(rng);
  for (final g in vistas) {
    out.add(Ejercicio.miraYElige(g, _opcionesPara(g, rng)));
  }

  final repaso = List<String>.from(leccion.glosas)..shuffle(rng);
  for (final g in repaso.take(min(3, repaso.length))) {
    out.add(Ejercicio.eligeLaSena(g, _opcionesPara(g, rng)));
  }

  if (leccion.deletrea) {
    final letras = letrasDeNombre(nombre);
    // Sin nombre guardado se deletrea el de la app, que tiene todas sus
    // letras en el diccionario.
    final meta = letras.isEmpty ? const ['U', 'N', 'I', 'V', 'O', 'Z'] : letras;
    final teclas = <String>{...meta}.toList();
    final extras = _soloLetras.where((l) => !teclas.contains(l)).toList()
      ..shuffle(rng);
    teclas.addAll(extras.take(max(0, 10 - teclas.length)));
    teclas.shuffle(rng);
    out.add(Ejercicio.deletrea(meta, teclas));
  }
  return out;
}

/// El avance de una lección en curso. No hay vidas: fallar manda el
/// ejercicio al final de la cola, y eso es todo el castigo.
class SesionLeccion {
  final List<Ejercicio> _cola;
  final Set<Ejercicio> _fallados = {};

  /// Glosas que se fallaron alguna vez en esta lección.
  final Set<String> glosasFalladas = {};

  /// Cuántos ejercicios tenía la lección al empezar.
  final int totalInicial;

  /// Ejercicios ya resueltos bien (cuentan los reintentos).
  int hechos = 0;

  int _aciertosPrimera = 0;

  SesionLeccion(List<Ejercicio> ejercicios)
      : _cola = List<Ejercicio>.from(ejercicios),
        totalInicial = ejercicios.length;

  Ejercicio? get actual => _cola.isEmpty ? null : _cola.first;
  bool get terminada => _cola.isEmpty;

  /// Ejercicios que salieron bien a la primera.
  int get aciertosPrimera => _aciertosPrimera;

  /// 0.0 a 1.0, para la barra de arriba. Nunca retrocede.
  double get progreso => totalInicial == 0 ? 1.0 : hechos / totalInicial;

  /// "2 de 5": el que se está haciendo, sin pasarse del total.
  int get numeroActual => min(hechos + 1, totalInicial);

  /// Registra la respuesta al ejercicio actual y devuelve si fue correcta.
  bool responder(List<String> respuesta) {
    final e = _cola.removeAt(0);
    final ok = e.comprobar(respuesta);
    if (ok) {
      hechos++;
      if (!_fallados.contains(e)) _aciertosPrimera++;
    } else {
      _fallados.add(e);
      glosasFalladas.addAll(e.esperado);
      _cola.add(e);
    }
    return ok;
  }
}
