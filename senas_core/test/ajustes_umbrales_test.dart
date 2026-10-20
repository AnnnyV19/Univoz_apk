/// Migracion de los umbrales guardados en el telefono.
///
/// Cuando cambio la distancia del DTW (presencia de mano, ver kWPres en
/// dtw.dart), un maxDistance/minMargin guardado con la escala anterior dejo de
/// significar lo mismo. Estas pruebas fijan que se reemplaza por los valores
/// por defecto nuevos, y que lo demas del archivo de ajustes se conserva.
///
///   flutter test test/ajustes_umbrales_test.dart
import 'package:test/test.dart';

import 'package:senas_core/dtw.dart';
import 'package:senas_core/muestras_locales.dart';

void main() {
  test('Ajustes nuevos usan los umbrales por defecto de dtw.dart', () {
    final a = Ajustes();
    expect(a.maxDistance, kMaxDistanceDefault);
    expect(a.minMargin, kMinMarginDefault);
  });

  test('un archivo sin version_umbrales (escala vieja) vuelve a los por defecto',
      () {
    final a = Ajustes.fromJson({
      'max_distance': 0.55,
      'min_margin': 0.12,
      'camara_frontal': false,
      'espejo_automatico': false,
    });
    expect(a.maxDistance, kMaxDistanceDefault);
    expect(a.minMargin, kMinMarginDefault);
    // El resto de los ajustes no se toca.
    expect(a.camaraFrontal, isFalse);
    expect(a.espejoAutomatico, isFalse);
  });

  test('con la version actual se respetan los umbrales que eligio la persona',
      () {
    final a = Ajustes.fromJson({
      'version_umbrales': kVersionUmbrales,
      'max_distance': 0.80,
      'min_margin': 0.20,
    });
    expect(a.maxDistance, 0.80);
    expect(a.minMargin, 0.20);
  });

  test('toJson escribe la version y la ida y vuelta no cambia nada', () {
    final j = Ajustes(maxDistance: 0.70, minMargin: 0.22).toJson();
    expect(j['version_umbrales'], kVersionUmbrales);

    final b = Ajustes.fromJson(j);
    expect(b.maxDistance, 0.70);
    expect(b.minMargin, 0.22);
  });
}
