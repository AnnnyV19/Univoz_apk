import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/tema_univoz.dart';

void main() {
  group('temaUnivoz', () {
    test('claro: Material 3 con la paleta de Univoz', () {
      final tema = temaUnivoz();
      expect(tema.useMaterial3, isTrue);
      expect(tema.brightness, Brightness.light);
      expect(tema.colorScheme.primary, ColoresUnivoz.morado);
      expect(tema.colorScheme.surface, Colors.white);
      expect(tema.colorScheme.onSurface, ColoresUnivoz.tinta);
      expect(tema.colorScheme.error, const Color(0xFFDC2626));
      expect(tema.scaffoldBackgroundColor, Colors.white);
    });

    test('oscuro: esquema oscuro con primario legible', () {
      final tema = temaUnivoz(brightness: Brightness.dark);
      expect(tema.useMaterial3, isTrue);
      expect(tema.brightness, Brightness.dark);
      expect(tema.colorScheme.primary, isNot(ColoresUnivoz.morado));
      expect(tema.colorScheme.onSurface, isNot(ColoresUnivoz.tinta));
      expect(tema.colorScheme.surface.computeLuminance(), lessThan(0.05));
    });

    test('tarjetas planas con borde y snackbar flotante', () {
      final tema = temaUnivoz();
      final tarjeta = tema.cardTheme.shape as RoundedRectangleBorder;
      expect(tarjeta.borderRadius, BorderRadius.circular(kRadioUnivoz));
      expect(tarjeta.side.width, 2);
      expect(tema.cardTheme.elevation, 0);
      expect(tema.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(
          tema.pageTransitionsTheme.builders, contains(TargetPlatform.android));
    });

    test('estados verde / ambar / rojo en claro y oscuro', () {
      final claro = temaUnivoz().extension<EstadosUnivoz>();
      final oscuro =
          temaUnivoz(brightness: Brightness.dark).extension<EstadosUnivoz>();
      expect(claro, isNotNull);
      expect(oscuro, isNotNull);
      expect(claro!.error.icono, const Color(0xFFDC2626));
      // En oscuro el fondo del aviso es oscuro y el texto claro.
      expect(oscuro!.exito.fondo.computeLuminance(),
          lessThan(oscuro.exito.texto.computeLuminance()));
    });

    test('botones con alto minimo de 48 dp', () {
      final tema = temaUnivoz();
      final filled =
          tema.filledButtonTheme.style!.minimumSize!.resolve(<WidgetState>{});
      expect(filled!.height, greaterThanOrEqualTo(48));
    });
  });
}
