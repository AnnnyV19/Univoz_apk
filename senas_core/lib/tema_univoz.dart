/// Tema unico de Univoz (Material 3). Lo usan la app univoz y el menu de
/// pruebas de senas_core, asi que las pantallas leen sus colores de
/// Theme.of(context).colorScheme en vez de repetir literales.
library tema_univoz;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

const Color _kPrimario = Color(0xFF6C63FF);
const Color _kSecundario = Color(0xFF8B5CF6);
const Color _kFondoClaro = Color(0xFFF7F2FA);
const Color _kTintaClara = Color(0xFF1A1A2E);
const Color _kErrorClaro = Color(0xFFE85D5D);

/// Alto minimo de cualquier boton: objetivo tactil de 48 dp.
const double kAltoMinimoToque = 48;

ColorScheme _esquema(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: _kPrimario,
    brightness: brightness,
  );
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: _kPrimario,
      onPrimary: Colors.white,
      secondary: _kSecundario,
      onSecondary: Colors.white,
      surface: _kFondoClaro,
      onSurface: _kTintaClara,
      surfaceContainerLowest: Colors.white,
      error: _kErrorClaro,
      onError: Colors.white,
    );
  }
  return base.copyWith(
    primary: const Color(0xFF9A94FF),
    onPrimary: const Color(0xFF1A1A2E),
    secondary: const Color(0xFFB79CFA),
    onSecondary: const Color(0xFF1A1A2E),
    surface: const Color(0xFF14131C),
    onSurface: const Color(0xFFEDEBF7),
    error: const Color(0xFFFF8A8A),
    onError: const Color(0xFF1A1A2E),
  );
}

/// Tema Material 3 de Univoz. [brightness] claro (por defecto) u oscuro.
ThemeData temaUnivoz({Brightness brightness = Brightness.light}) {
  final colores = _esquema(brightness);
  final grande =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  const minimo = Size(64, kAltoMinimoToque);
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colores,
    scaffoldBackgroundColor: colores.surface,
  );
  return base.copyWith(
    cardTheme: CardThemeData(
      color: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colores.surface,
      foregroundColor: colores.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: minimo,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: minimo,
        shape: grande,
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: minimo, shape: grande),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(minimumSize: minimo, shape: grande),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide(color: colores.outlineVariant),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colores.surfaceContainerLowest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colores.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colores.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: colores.primary, width: 2),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
