import 'package:test/test.dart';

import 'package:senas_core/muestras_locales.dart';

void main() {
  test('aGlosa normaliza acentos, espacios y simbolos', () {
    expect(aGlosa('  como estás '), 'COMO_ESTAS');
    expect(aGlosa('¡Niño!'), 'NINO');
    expect(aGlosa('a   b__c'), 'A_B_C');
  });

  test('aGlosa nunca pasa de 64 caracteres ni termina en "_"', () {
    final larga = aGlosa('${'a' * 63} bb cc');
    expect(larga.length, lessThanOrEqualTo(kMaxGlosa));
    expect(larga.endsWith('_'), isFalse);
    expect(larga, 'A' * 63);
    expect(aGlosa('x' * 200).length, 64);
  });

  test('aGlosa de solo simbolos queda vacia (la pantalla no deja grabar)', () {
    expect(aGlosa('¿?!'), isEmpty);
  });
}
