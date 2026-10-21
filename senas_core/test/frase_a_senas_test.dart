import 'package:senas_core/frase_a_senas.dart';
import 'package:test/test.dart';

void main() {
  // Un diccionario chico con la misma forma que el real (glosa -> español).
  final dic = <String, String>{
    'HOLA': 'hola',
    'COMO': 'cómo',
    'COMO_ESTAS': '¿Cómo estás?',
    'BUENOS_DIAS': 'buenos días',
    'MI_NOMBRE_ES': 'mi nombre es',
    'MI': 'mi',
    'GRACIAS': 'gracias',
    'POR_FAVOR': 'por favor',
    'NECESITAR': 'necesitar',
    'DOCTOR': 'doctor',
    'AMIGO': 'amigo',
    'AYUDA': 'ayuda',
    'NO_PUEDO': 'no puedo',
    '1': '1',
    for (final l in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('')) l: l,
    'LL': 'LL',
    'RR': 'RR',
    'NN': 'Ñ',
  };

  test('frase guardada mas larga primero: HOLA + COMO_ESTAS', () {
    final p = planificarFrase('hola, ¿cómo estás?', dic);
    expect(p.glosas, ['HOLA', 'COMO_ESTAS']);
    expect(p.omitidas, isEmpty);
    expect(p.sinSena, isEmpty);
  });

  test('sin acentos ni mayusculas', () {
    expect(planificarFrase('BUENOS DIAS', dic).glosas, ['BUENOS_DIAS']);
  });

  test('nombre propio se deletrea', () {
    final p = planificarFrase('Mi nombre es Ana', dic);
    expect(p.glosas, ['MI_NOMBRE_ES', 'A', 'N', 'A']);
    expect(p.pasos.skip(1).every((x) => x.tipo == TipoPaso.letra), isTrue);
    expect(p.pasos.last.origen, 'Ana');
  });

  test('LL, RR y Ñ al deletrear', () {
    expect(planificarFrase('llorar', dic).glosas,
        ['LL', 'O', 'R', 'A', 'R']);
    expect(planificarFrase('perro', dic).glosas, ['P', 'E', 'RR', 'O']);
    expect(planificarFrase('niño', dic).glosas, ['N', 'I', 'NN', 'O']);
  });

  test('articulos sin seña se omiten, no se deletrean', () {
    final p = planificarFrase('necesito un doctor', dic);
    expect(p.glosas, ['NECESITAR', 'DOCTOR']);
    expect(p.omitidas, ['un']);
  });

  test('plural, femenino, conjugacion y pronombre pegado', () {
    expect(planificarFrase('amigos', dic).glosas, ['AMIGO']);
    expect(planificarFrase('amiga', dic).glosas, ['AMIGO']);
    expect(planificarFrase('ayúdame', dic).glosas, ['AYUDA']);
    expect(planificarFrase('no puedo', dic).glosas, ['NO_PUEDO']);
  });

  test('lo que no tiene ni letra se reporta', () {
    final p = planificarFrase('7', dic);
    expect(p.vacio, isTrue);
    expect(p.sinSena, ['7']);
    expect(planificarFrase('1', dic).glosas, ['1']);
  });

  test('las letras no se usan como palabras', () {
    // "a" e "y" no deben salir como las letras A e Y.
    final p = planificarFrase('hola y gracias a ti', dic);
    expect(p.glosas.take(2), ['HOLA', 'GRACIAS']);
    expect(p.omitidas, containsAll(['y', 'a']));
  });

  test('resumen legible', () {
    final p = planificarFrase('hola Ana', dic);
    expect(p.resumen((g) => g.toLowerCase()), 'hola → «Ana» deletreado');
  });

  test('tope de señas', () {
    final p = planificarFrase(List.filled(80, 'hola').join(' '), dic);
    expect(p.pasos.length, kMaxPasosFrase);
    expect(p.sinSena, isNotEmpty);
  });
}
