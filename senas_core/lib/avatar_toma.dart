/// Ayudas para MOSTRAR una seña en el avatar sin tocar los datos.
///
/// Todo lo de aquí trabaja sobre una COPIA de la secuencia que se manda al
/// visor: nunca cambia la plantilla guardada ni lo que usa el reconocedor.
/// Tampoco mueve ni normaliza la altura de ninguna muñeca ni de ninguna mano
/// (regla del proyecto): lo único que se decide es QUÉ TRAMO DE TIEMPO se
/// muestra y a qué velocidad.
///
/// Por qué existe. Varias plantillas traen la mano ausente al principio o al
/// final (el video empezaba con las manos abajo, o el detector la perdió al
/// terminar): HOLA no, pero SI_PUEDO tiene 8 cuadros sin mano al inicio y 9 al
/// final, o sea que de 32 cuadros solo 15 tienen mano. El visor dibuja un
/// brazo únicamente en los cuadros con mano, así que el avatar se quedaba
/// quieto la mitad del tiempo y luego hacía una seña cortísima: "no hace
/// nada". Aquí se recorta ese tiempo muerto y la parte con mano se estira a
/// los 32 cuadros que el visor exige (se ve más lenta y más clara).
///
/// El diseño de los cuadros es el de sign_norm.dart (152 valores):
///   0..23   cuerpo: 8 puntos x (x, y, z)  [hombros, codos, muñecas, caderas]
///   24..26  muñeca izquierda (detector de manos)   27..29  la derecha
///   30, 31  presencia de mano izquierda / derecha
///   32..91  forma de la mano izquierda    92..151  la derecha
library avatar_toma;

import 'dart:math' as math;

import 'sign_norm.dart'
    show
        kFrameDim,
        kOffLocL,
        kOffLocR,
        kOffPresL,
        kOffPresR,
        kOffShapeL,
        kOffShapeR,
        kTFrames;

/// Una mano cuenta como presente en un cuadro con presencia >= 0.5 (igual que
/// el visor).
const double _kPresente = 0.5;

/// Si entre el inicio y el final sobran menos cuadros sin mano que esto, la
/// secuencia se deja como viene.
const int kMinCuadrosMuertos = 6;

/// Si la parte con mano dura menos que esto, no hay datos suficientes para
/// estirarla sin inventar movimiento: se deja como viene.
const int kMinCuadrosConMano = 8;

/// Debajo de este "movimiento" (ver [movimientoDe]) la seña es casi una pose
/// fija (la mayoría de las letras): conviene mostrarla más despacio.
const double kMovimientoPoseFija = 1.0;

bool _hayMano(List<double> f) =>
    f[kOffPresL] >= _kPresente || f[kOffPresR] >= _kPresente;

/// Primer y último cuadro de la seña en los que hay alguna mano.
class VentanaSena {
  final int inicio;
  final int fin;
  const VentanaSena(this.inicio, this.fin);

  int get largo => fin - inicio + 1;
}

/// La ventana con mano de [seq], o null si ningún cuadro tiene mano.
VentanaSena? ventanaConMano(List<List<double>> seq) {
  var primero = -1;
  var ultimo = -1;
  for (var i = 0; i < seq.length; i++) {
    if (_hayMano(seq[i])) {
      if (primero < 0) primero = i;
      ultimo = i;
    }
  }
  return primero < 0 ? null : VentanaSena(primero, ultimo);
}

/// Devuelve la secuencia lista para el visor: si al principio y al final hay
/// [kMinCuadrosMuertos] cuadros o más sin mano, recorta ese tiempo y estira lo
/// que queda a [kTFrames] cuadros. Si no hace falta, devuelve [seq] tal cual
/// (la misma lista, sin copiar).
List<List<double>> prepararParaAvatar(List<List<double>> seq) {
  final n = seq.length;
  if (n != kTFrames || seq.first.length != kFrameDim) return seq;
  final v = ventanaConMano(seq);
  if (v == null) return seq;
  final muertos = v.inicio + (n - 1 - v.fin);
  if (muertos < kMinCuadrosMuertos) return seq;
  if (v.largo < kMinCuadrosConMano) return seq;
  return remuestrearSecuencia(seq, v.inicio, v.fin);
}

/// Estira los cuadros [a]..[b] de [seq] a [salida] cuadros por interpolación
/// lineal. Sigue las mismas reglas que `interpolarFrame` del visor: solo
/// mezcla lo que existe en los dos cuadros vecinos (un punto del cuerpo, o una
/// mano que está presente en ambos); lo demás lo toma del cuadro más cercano.
List<List<double>> remuestrearSecuencia(
  List<List<double>> seq,
  int a,
  int b, {
  int salida = kTFrames,
}) {
  assert(a >= 0 && b < seq.length && a <= b);
  final out = <List<double>>[];
  for (var k = 0; k < salida; k++) {
    final pos = salida == 1 ? a.toDouble() : a + (b - a) * k / (salida - 1);
    final i0 = math.min(b, math.max(a, pos.floor()));
    final i1 = math.min(b, i0 + 1);
    out.add(_mezclar(seq[i0], seq[i1], pos - i0));
  }
  return out;
}

List<double> _mezclar(List<double> a, List<double> b, double f) {
  final cerca = f < 0.5 ? a : b;
  final out = List<double>.from(cerca);
  if (identical(a, b) || f <= 0) return out;
  // Cuerpo: 8 puntos de 3 valores. Un punto en (0,0,0) es "sin dato".
  for (var p = 0; p < 8; p++) {
    final c = p * 3;
    if (_hayPunto(a, c) && _hayPunto(b, c)) {
      for (var k = 0; k < 3; k++) {
        out[c + k] = a[c + k] + (b[c + k] - a[c + k]) * f;
      }
    }
  }
  _mezclarMano(a, b, f, out, kOffPresL, kOffLocL, kOffShapeL);
  _mezclarMano(a, b, f, out, kOffPresR, kOffLocR, kOffShapeR);
  return out;
}

bool _hayPunto(List<double> v, int c) =>
    v[c] * v[c] + v[c + 1] * v[c + 1] + v[c + 2] * v[c + 2] > 1e-12;

void _mezclarMano(List<double> a, List<double> b, double f, List<double> out,
    int offPres, int offLoc, int offShape) {
  if (a[offPres] < _kPresente || b[offPres] < _kPresente) return;
  for (var k = 0; k < 3; k++) {
    out[offLoc + k] = a[offLoc + k] + (b[offLoc + k] - a[offLoc + k]) * f;
  }
  for (var k = 0; k < 60; k++) {
    out[offShape + k] =
        a[offShape + k] + (b[offShape + k] - a[offShape + k]) * f;
  }
}

final List<int> _dimsBrazo = [
  for (var d = 6; d < 18; d++) d, // codos y muñecas del cuerpo
  for (var d = 24; d < 30; d++) d, // muñecas del detector de manos
];

double _rango(List<List<double>> seq, int d) {
  var lo = double.infinity;
  var hi = double.negativeInfinity;
  for (final f in seq) {
    final v = f[d];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  return hi - lo;
}

/// Desviación típica media de la forma de una mano, solo en los cuadros en que
/// esa mano está presente.
double _desvForma(List<List<double>> seq, int offPres, int offShape) {
  final cuadros = [
    for (final f in seq)
      if (f[offPres] >= _kPresente) f
  ];
  if (cuadros.length < 3) return 0.0;
  var total = 0.0;
  for (var k = offShape; k < offShape + 60; k++) {
    var suma = 0.0;
    for (final f in cuadros) {
      suma += f[k];
    }
    final media = suma / cuadros.length;
    var varianza = 0.0;
    for (final f in cuadros) {
      final dif = f[k] - media;
      varianza += dif * dif;
    }
    total += math.sqrt(varianza / cuadros.length);
  }
  return total / 60;
}

/// Una sola cifra de "cuánto se ve moverse" la seña: cuánto se mueven los
/// brazos (en anchos de hombro) más diez veces cuánto cambia la forma de la
/// mano, ponderado por la fracción de cuadros con mano. Es la misma cifra que
/// calcula tools/diag_avatar_quieto.py: 0 = pose fija; las letras estáticas
/// dan < 0.35 y las señas con movimiento claro pasan de 2.
double movimientoDe(List<List<double>> seq) {
  if (seq.isEmpty) return 0.0;
  var cuadrosL = 0;
  var cuadrosR = 0;
  for (final f in seq) {
    if (f[kOffPresL] >= _kPresente) cuadrosL++;
    if (f[kOffPresR] >= _kPresente) cuadrosR++;
  }
  final pres = math.max(cuadrosL, cuadrosR) / seq.length;
  var brazo = 0.0;
  for (final d in _dimsBrazo) {
    brazo = math.max(brazo, _rango(seq, d));
  }
  final forma = math.max(
    _desvForma(seq, kOffPresL, kOffShapeL),
    _desvForma(seq, kOffPresR, kOffShapeR),
  );
  return (brazo + 10.0 * forma) * math.min(1.0, pres / 0.8);
}

/// Cuánto multiplicar la velocidad al mostrar una seña SUELTA: una pose casi
/// fija se muestra más despacio (0.7×) para que dé tiempo de ver la mano; el
/// resto, a la velocidad que haya elegido la persona.
double factorVelocidadSena(List<List<double>> seq) =>
    movimientoDe(seq) < kMovimientoPoseFija ? 0.7 : 1.0;

/// Qué manos usa una seña. `izquierda` y `derecha` son las del AVATAR (el
/// visor anima su brazo izquierdo con el canal izquierdo de la plantilla).
class ManosUsadas {
  final bool izquierda;
  final bool derecha;
  const ManosUsadas(this.izquierda, this.derecha);
}

/// Una mano "se usa" si está presente al menos en la cuarta parte de los
/// cuadros (y nunca en menos de 2).
ManosUsadas manosUsadas(List<List<double>> seq) {
  var l = 0;
  var r = 0;
  for (final f in seq) {
    if (f[kOffPresL] >= _kPresente) l++;
    if (f[kOffPresR] >= _kPresente) r++;
  }
  final minimo = math.max(2, (seq.length * 0.25).round());
  return ManosUsadas(l >= minimo, r >= minimo);
}
