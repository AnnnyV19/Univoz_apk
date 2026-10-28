/// De una frase escrita (o dicha) a la lista de señas que hace el avatar,
/// SEGUIDAS, en vez de contestar "no tengo la seña".
///
/// Cómo decide, de izquierda a derecha:
///  1. La frase guardada más larga que empiece ahí. Así "hola, ¿cómo estás?"
///     sale HOLA + COMO_ESTAS (una sola seña para "cómo estás", que es como
///     se dice en LSM), y no COMO + ESTAS.
///  2. Si no hay ninguna, la palabra sola.
///  3. Si la palabra no está: los artículos y preposiciones cortas (el, la,
///     de, y...) se omiten, porque en LSM normalmente no se señan; cualquier
///     otra palabra (un nombre, una palabra nueva) se DELETREA con el
///     abecedario (incluye LL, RR y Ñ).
///  4. Una palabra con alguna letra que no esta guardada (por ejemplo un
///     número) no se deletrea a medias: se reporta en [PlanFrase.sinSena] y
///     se salta.
///
/// Es Dart puro (sin Flutter) para poder probarlo con `dart test`. No toca
/// las plantillas: solo decide QUÉ señas se muestran y en qué orden.
library frase_a_senas;

/// Una seña de la frase. [tipo] dice si es una seña de palabra o una letra
/// de un deletreo; [origen] es el texto de la frase que la produjo.
class PasoFrase {
  final String gloss;
  final TipoPaso tipo;
  final String origen;

  const PasoFrase(this.gloss, this.tipo, this.origen);

  @override
  String toString() => tipo == TipoPaso.letra ? '$gloss(letra)' : gloss;
}

enum TipoPaso { sena, letra }

/// Lo que se va a señar y lo que se quedó fuera.
class PlanFrase {
  final List<PasoFrase> pasos;

  /// Palabras cortas sin seña que se omitieron (artículos, preposiciones).
  final List<String> omitidas;

  /// Palabras que no se pudieron ni deletrear.
  final List<String> sinSena;

  const PlanFrase(this.pasos, this.omitidas, this.sinSena);

  bool get vacio => pasos.isEmpty;

  /// Las glosas en orden, para pruebas y diagnóstico.
  List<String> get glosas => [for (final p in pasos) p.gloss];

  /// Texto corto para la pantalla: "Hola → Cómo estás → «Ana» deletreado".
  String resumen(String Function(String gloss) etiqueta) {
    final partes = <String>[];
    var i = 0;
    while (i < pasos.length) {
      final p = pasos[i];
      if (p.tipo == TipoPaso.letra) {
        var j = i;
        while (j < pasos.length &&
            pasos[j].tipo == TipoPaso.letra &&
            pasos[j].origen == p.origen) {
          j++;
        }
        partes.add('«${p.origen}» deletreado');
        i = j;
      } else {
        partes.add(etiqueta(p.gloss));
        i++;
      }
    }
    final b = StringBuffer(partes.join(' → '));
    if (omitidas.isNotEmpty) b.write('\nSe omiten: ${omitidas.join(', ')}.');
    if (sinSena.isNotEmpty) {
      b.write('\nSin seña: ${sinSena.join(', ')}.');
    }
    return b.toString();
  }
}

/// Palabras que, si no tienen seña propia, se omiten en vez de deletrearse.
const Set<String> kPalabrasOmitibles = {
  'el', 'la', 'los', 'las', 'lo', 'un', 'una', 'unos', 'unas', //
  'de', 'del', 'al', 'a', 'y', 'e', 'o', 'u',
};

/// Máximo de señas en una frase (el visor acepta hasta 60).
const int kMaxPasosFrase = 60;

const String _conAcento = 'áàäâãéèëêíìïîóòöôõúùüûç';
const String _sinAcento = 'aaaaaeeeeiiiiooooouuuuc';

/// Minúsculas y sin acentos; la ñ se conserva (sirve para deletrear Ñ).
String _minusculaSinAcentos(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    final i = _conAcento.indexOf(c);
    b.write(i >= 0 ? _sinAcento[i] : c);
  }
  return b.toString();
}

/// Clave de búsqueda de una palabra: minúsculas, sin acentos y ñ -> n (igual
/// que la búsqueda del diccionario, que no distingue "manana" de "mañana").
String claveDePalabra(String palabra) =>
    _minusculaSinAcentos(palabra).replaceAll('ñ', 'n');

final RegExp _rePalabra = RegExp(r'[0-9a-zA-ZáàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ]+');

/// Las palabras de un texto, sin signos de puntuación.
List<String> palabrasDe(String texto) =>
    [for (final m in _rePalabra.allMatches(texto)) m.group(0)!];

/// true si la glosa es una letra del abecedario (A..Z, LL, RR, NN = Ñ).
bool esGlosaLetra(String g) =>
    g == 'LL' ||
    g == 'RR' ||
    g == 'NN' ||
    (g.length == 1 && g.codeUnitAt(0) >= 65 && g.codeUnitAt(0) <= 90);

/// Arma el plan de [texto] con el diccionario [espanolPorGlosa] (glosa ->
/// traducción al español, puede venir vacía).
PlanFrase planificarFrase(String texto, Map<String, String> espanolPorGlosa) {
  // Índice: frase normalizada -> glosa. Se indexa la traducción y la glosa
  // legible (COMO_ESTAS -> "como estas"). Las letras NO entran como palabras
  // (si no, "a" o "y" se harían con la letra).
  final indice = <String, String>{};
  var maxPalabras = 1;
  void indexar(String frase, String gloss) {
    final ps = palabrasDe(frase).map(claveDePalabra).toList();
    if (ps.isEmpty) return;
    indice.putIfAbsent(ps.join(' '), () => gloss);
    if (ps.length > maxPalabras) maxPalabras = ps.length;
  }

  final glosas = espanolPorGlosa.keys.toList()..sort();
  for (final g in glosas) {
    if (esGlosaLetra(g)) continue;
    final esp = espanolPorGlosa[g] ?? '';
    if (esp.trim().isNotEmpty) indexar(esp, g);
  }
  for (final g in glosas) {
    if (esGlosaLetra(g)) continue;
    indexar(g.replaceAll('_', ' '), g);
  }

  final palabras = palabrasDe(texto);
  final claves = palabras.map(claveDePalabra).toList();
  final pasos = <PasoFrase>[];
  final omitidas = <String>[];
  final sinSena = <String>[];
  var i = 0;
  while (i < palabras.length) {
    String? encontrada;
    var largo = 0;
    final tope =
        maxPalabras < palabras.length - i ? maxPalabras : palabras.length - i;
    for (var l = tope; l >= 1; l--) {
      final g = indice[claves.sublist(i, i + l).join(' ')];
      if (g != null) {
        encontrada = g;
        largo = l;
        break;
      }
    }
    if (encontrada != null) {
      pasos.add(PasoFrase(
          encontrada, TipoPaso.sena, palabras.sublist(i, i + largo).join(' ')));
      i += largo;
      continue;
    }
    final palabra = palabras[i];
    // Formas de la misma palabra: plural, femenino, verbo conjugado
    // ("necesito" -> NECESITAR, "amigos" -> AMIGO).
    String? variante;
    for (final v in variantesDePalabra(claves[i])) {
      final g = indice[v];
      if (g != null) {
        variante = g;
        break;
      }
    }
    if (variante != null) {
      pasos.add(PasoFrase(variante, TipoPaso.sena, palabra));
      i++;
      continue;
    }
    if (kPalabrasOmitibles.contains(claves[i])) {
      omitidas.add(palabra);
      i++;
      continue;
    }
    pasos.addAll(_deletrear(palabra, espanolPorGlosa, sinSena));
    i++;
  }
  if (pasos.length > kMaxPasosFrase) {
    sinSena.add('(la frase es muy larga: se muestran las primeras '
        '$kMaxPasosFrase señas)');
    pasos.removeRange(kMaxPasosFrase, pasos.length);
  }
  return PlanFrase(pasos, omitidas, sinSena);
}

const Map<String, String> _irregulares = {
  'quiero': 'querer', 'quieres': 'querer', 'quiere': 'querer',
  'quieren': 'querer', 'puedo': 'poder', 'puedes': 'poder',
  'puede': 'poder', 'pueden': 'poder', 'tengo': 'tener', 'tienes': 'tener',
  'tiene': 'tener', 'tienen': 'tener', 'entiendo': 'entender',
  'entiendes': 'entender', 'entiende': 'entender', 'siento': 'sentir',
  'sientes': 'sentir', 'siente': 'sentir', 'vengo': 'venir',
  'vienes': 'venir', 'viene': 'venir', 'voy': 'ir', 'vas': 'ir', 'va': 'ir',
  'vamos': 'ir', 'soy': 'ser', 'eres': 'ser', 'es': 'ser', 'somos': 'ser',
  'son': 'ser', 'estoy': 'estar', 'estas': 'estar', 'esta': 'estar',
  'estamos': 'estar', 'estan': 'estar', 'hago': 'hacer', 'haces': 'hacer',
  'hace': 'hacer', 'digo': 'decir', 'dices': 'decir', 'dice': 'decir',
  'se': 'saber', 'sabes': 'saber', 'sabe': 'saber', 'conozco': 'conocer',
  'necesito': 'necesitar', 'duele': 'doler', 'duelen': 'doler',
};

const List<String> _terminaciones = [
  'amos', 'emos', 'imos', 'ando', 'iendo', 'ado', 'ada', 'ido', 'ida',
  'as', 'es', 'an', 'en', 'o', 'a', 'e',
];

/// Otras formas en que puede estar guardada una palabra (ya en clave):
/// irregular conocido, singular, masculino e infinitivo (-ar, -er, -ir).
List<String> variantesDePalabra(String clave) {
  final out = <String>[];
  void agregar(String v) {
    if (v.length >= 2 && v != clave && !out.contains(v)) out.add(v);
  }

  final irr = _irregulares[clave];
  if (irr != null) agregar(irr);
  if (clave.endsWith('es') && clave.length > 4) {
    agregar(clave.substring(0, clave.length - 2));
  }
  if (clave.endsWith('s') && clave.length > 2) {
    agregar(clave.substring(0, clave.length - 1));
  }
  if (clave.endsWith('a') && clave.length > 3) {
    agregar('${clave.substring(0, clave.length - 1)}o');
  }
  if (clave.endsWith('as') && clave.length > 4) {
    agregar('${clave.substring(0, clave.length - 2)}o');
  }
  // Pronombre pegado al verbo: "ayudame" -> "ayuda", "dime" -> ...
  for (final p in const ['me', 'te', 'nos', 'le', 'les', 'lo', 'la']) {
    if (clave.endsWith(p) && clave.length - p.length >= 4) {
      agregar(clave.substring(0, clave.length - p.length));
    }
  }
  for (final t in _terminaciones) {
    if (clave.endsWith(t) && clave.length - t.length >= 3) {
      final raiz = clave.substring(0, clave.length - t.length);
      agregar('${raiz}ar');
      agregar('${raiz}er');
      agregar('${raiz}ir');
    }
  }
  return out;
}

/// Todo [texto] deletreado letra por letra (botón "Deletreo" de
/// Comunicarse), sin buscar señas de palabras. Mayúsculas y acentos no
/// importan; una palabra con letras que no hay va a [PlanFrase.sinSena].
PlanFrase deletrearTexto(String texto, Map<String, String> espanolPorGlosa) {
  final pasos = <PasoFrase>[];
  final sinSena = <String>[];
  for (final p in palabrasDe(texto)) {
    pasos.addAll(_deletrear(p, espanolPorGlosa, sinSena));
  }
  if (pasos.length > kMaxPasosFrase) {
    sinSena.add('(la frase es muy larga: se muestran las primeras '
        '$kMaxPasosFrase señas)');
    pasos.removeRange(kMaxPasosFrase, pasos.length);
  }
  return PlanFrase(pasos, const [], sinSena);
}

/// Deletrea [palabra]. Solo si TODAS sus letras existen: una palabra a
/// medias se entenderia mal, asi que entonces va completa a [sinSena].
List<PasoFrase> _deletrear(
    String palabra, Map<String, String> dic, List<String> sinSena) {
  final s = _minusculaSinAcentos(palabra);
  final out = <PasoFrase>[];
  var k = 0;
  while (k < s.length) {
    final dos = k + 1 < s.length ? s.substring(k, k + 2) : '';
    if ((dos == 'll' || dos == 'rr') && dic.containsKey(dos.toUpperCase())) {
      out.add(PasoFrase(dos.toUpperCase(), TipoPaso.letra, palabra));
      k += 2;
      continue;
    }
    final c = s[k];
    final g = c == 'ñ' ? 'NN' : c.toUpperCase();
    if (!dic.containsKey(g)) {
      if (!sinSena.contains(palabra)) sinSena.add(palabra);
      return const [];
    }
    out.add(PasoFrase(g, TipoPaso.letra, palabra));
    k++;
  }
  return out;
}

/// Una seña lista para mandarse al visor como parte de una frase.
class SegmentoFrase {
  final List<List<double>> frames;
  final int fps;

  const SegmentoFrase(this.frames, this.fps);
}
