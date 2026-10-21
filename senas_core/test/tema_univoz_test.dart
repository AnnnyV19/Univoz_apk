import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:senas_core/tema_univoz.dart';

void main() {
  group('temaUnivoz', () {
    test('claro: Material 3 con la paleta de Univoz', () {
      final tema = temaUnivoz();
      expect(tema.useMaterial3, isTrue);
      expect(tema.brightness, Brightness.light);
      expect(tema.colorScheme.primary, const Color(0xFF6C63FF));
      expect(tema.colorScheme.surface, const Color(0xFFF7F2FA));
      expect(tema.colorScheme.onSurface, const Color(0xFF1A1A2E));
      expect(tema.colorScheme.error, const Color(0xFFE85D5D));
      expect(tema.scaffoldBackgroundColor, const Color(0xFFF7F2FA));
    });

    test('oscuro: esquema oscuro con primario legible', () {
      final tema = temaUnivoz(brightness: Brightness.dark);
      expect(tema.useMaterial3, isTrue);
      expect(tema.brightness, Brightness.dark);
      expect(tema.colorScheme.primary, isNot(const Color(0xFF6C63FF)));
      expect(tema.colorScheme.onSurface, isNot(const Color(0xFF1A1A2E)));
    });

    test('formas redondeadas y snackbar flotante', () {
      final tema = temaUnivoz();
      final tarjeta = tema.cardTheme.shape as RoundedRectangleBorder;
      expect(tarjeta.borderRadius, BorderRadius.circular(20));
      expect(tema.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(
          tema.pageTransitionsTheme.builders, contains(TargetPlatform.android));
    });

    test('botones con alto minimo de 48 dp', () {
      final tema = temaUnivoz();
      final filled =
          tema.filledButtonTheme.style!.minimumSize!.resolve(<WidgetState>{});
      expect(filled!.height, greaterThanOrEqualTo(48));
    });
  });
}
