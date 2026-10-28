/// Tema unico de Univoz (Material 3). Lo usan la app univoz y el menu de
/// pruebas de senas_core, asi que las pantallas leen sus colores de
/// Theme.of(context).colorScheme en vez de repetir literales.
///
/// Diseño: el de Lucía (rediseño de la interfaz, oct-2026): fondo blanco,
/// morado #791FC1, tinta #29232F, tarjetas planas con borde de 2 px y radio
/// 10, y estados verde / ámbar / rojo con fondo claro. Aquí vive en un solo
/// lugar, con su versión oscura, para que todas las pantallas lo compartan.
library tema_univoz;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Colores de marca en claro, para los pocos lugares que necesitan un valor
/// constante (degradados, ilustraciones). Todo lo demás: Theme.of(context).
class ColoresUnivoz {
  ColoresUnivoz._();

  static const Color morado = Color(0xFF791FC1);
  static const Color moradoOscuro = Color(0xFF5B1493);
  static const Color moradoClaro = Color(0xFFDCC8F5);
  static const Color moradoTenue = Color(0xFFF3EDFA);
  static const Color lavanda = Color(0xFFEDE9F4);
  static const Color tinta = Color(0xFF29232F);
  static const Color tintaSuave = Color(0xFF6E6679);
  static const Color tintaTenue = Color(0xFF7E7688);
  static const Color borde = Color(0xFFE8E5EE);
  static const Color bordeControl = Color(0xFFE2DEEC);
  static const Color fondoSuave = Color(0xFFF7F5FA);
}

/// Alto minimo de cualquier boton: objetivo tactil de 48 dp.
const double kAltoMinimoToque = 48;

/// Radio de las tarjetas y botones del diseño.
const double kRadioUnivoz = 10;

ColorScheme _esquema(Brightness brightness) {
  final base = ColorScheme.fromSeed(
    seedColor: ColoresUnivoz.morado,
    brightness: brightness,
  );
  if (brightness == Brightness.light) {
    return base.copyWith(
      primary: ColoresUnivoz.morado,
      onPrimary: Colors.white,
      primaryContainer: ColoresUnivoz.moradoTenue,
      onPrimaryContainer: ColoresUnivoz.moradoOscuro,
      secondary: ColoresUnivoz.moradoOscuro,
      onSecondary: Colors.white,
      secondaryContainer: ColoresUnivoz.moradoClaro,
      onSecondaryContainer: const Color(0xFF3B0C61),
      surface: Colors.white,
      onSurface: ColoresUnivoz.tinta,
      onSurfaceVariant: ColoresUnivoz.tintaSuave,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFAFAFC),
      surfaceContainer: ColoresUnivoz.fondoSuave,
      surfaceContainerHigh: const Color(0xFFF0EDF5),
      surfaceContainerHighest: ColoresUnivoz.lavanda,
      outline: const Color(0xFFA69EB0),
      outlineVariant: ColoresUnivoz.borde,
      error: const Color(0xFFDC2626),
      onError: Colors.white,
      errorContainer: const Color(0xFFFEF2F2),
      onErrorContainer: const Color(0xFF991B1B),
    );
  }
  return base.copyWith(
    primary: const Color(0xFFC9A2F0),
    onPrimary: const Color(0xFF2E0A4D),
    primaryContainer: const Color(0xFF4A1478),
    onPrimaryContainer: ColoresUnivoz.moradoTenue,
    secondary: ColoresUnivoz.moradoClaro,
    onSecondary: const Color(0xFF2E0A4D),
    secondaryContainer: const Color(0xFF3B2152),
    onSecondaryContainer: ColoresUnivoz.moradoTenue,
    surface: const Color(0xFF151219),
    onSurface: const Color(0xFFECE8F1),
    onSurfaceVariant: const Color(0xFFB4ABC0),
    surfaceContainerLowest: const Color(0xFF0F0D12),
    surfaceContainerLow: const Color(0xFF1B1720),
    surfaceContainer: const Color(0xFF211C27),
    surfaceContainerHigh: const Color(0xFF2A2431),
    surfaceContainerHighest: const Color(0xFF332C3B),
    outline: ColoresUnivoz.tintaTenue,
    outlineVariant: const Color(0xFF3A3342),
    error: const Color(0xFFFF8A8A),
    onError: const Color(0xFF3B0A0A),
    errorContainer: const Color(0xFF4A1515),
    onErrorContainer: const Color(0xFFFECACA),
  );
}

/// Un color de estado (éxito, aviso, error) en sus cuatro usos: icono,
/// texto, fondo y borde.
@immutable
class ColoresEstado {
  const ColoresEstado({
    required this.icono,
    required this.texto,
    required this.fondo,
    required this.borde,
  });

  final Color icono;
  final Color texto;
  final Color fondo;
  final Color borde;

  static ColoresEstado lerp(ColoresEstado a, ColoresEstado b, double t) =>
      ColoresEstado(
        icono: Color.lerp(a.icono, b.icono, t)!,
        texto: Color.lerp(a.texto, b.texto, t)!,
        fondo: Color.lerp(a.fondo, b.fondo, t)!,
        borde: Color.lerp(a.borde, b.borde, t)!,
      );
}

/// Verde / ámbar / rojo del diseño, en claro y oscuro. Se lee con
/// `EstadosUnivoz.de(context)`.
@immutable
class EstadosUnivoz extends ThemeExtension<EstadosUnivoz> {
  const EstadosUnivoz({
    required this.exito,
    required this.aviso,
    required this.error,
  });

  final ColoresEstado exito;
  final ColoresEstado aviso;
  final ColoresEstado error;

  static const claro = EstadosUnivoz(
    exito: ColoresEstado(
      icono: Color(0xFF16A34A),
      texto: Color(0xFF166534),
      fondo: Color(0xFFF0FDF4),
      borde: Color(0xFFBBF7D0),
    ),
    aviso: ColoresEstado(
      icono: Color(0xFFD97706),
      texto: Color(0xFFB45309),
      fondo: Color(0xFFFFFBEB),
      borde: Color(0xFFFDE68A),
    ),
    error: ColoresEstado(
      icono: Color(0xFFDC2626),
      texto: Color(0xFF991B1B),
      fondo: Color(0xFFFEF2F2),
      borde: Color(0xFFFECACA),
    ),
  );

  static const oscuro = EstadosUnivoz(
    exito: ColoresEstado(
      icono: Color(0xFF4ADE80),
      texto: Color(0xFFBBF7D0),
      fondo: Color(0xFF0F2A1A),
      borde: Color(0xFF1F5133),
    ),
    aviso: ColoresEstado(
      icono: Color(0xFFFBBF24),
      texto: Color(0xFFFDE68A),
      fondo: Color(0xFF2D2210),
      borde: Color(0xFF5C4515),
    ),
    error: ColoresEstado(
      icono: Color(0xFFF87171),
      texto: Color(0xFFFECACA),
      fondo: Color(0xFF2E1213),
      borde: Color(0xFF5E2122),
    ),
  );

  /// Los estados del tema actual (o los claros si el tema no los trae).
  static EstadosUnivoz de(BuildContext context) =>
      Theme.of(context).extension<EstadosUnivoz>() ??
      (Theme.of(context).brightness == Brightness.dark ? oscuro : claro);

  @override
  EstadosUnivoz copyWith({
    ColoresEstado? exito,
    ColoresEstado? aviso,
    ColoresEstado? error,
  }) =>
      EstadosUnivoz(
        exito: exito ?? this.exito,
        aviso: aviso ?? this.aviso,
        error: error ?? this.error,
      );

  @override
  EstadosUnivoz lerp(ThemeExtension<EstadosUnivoz>? other, double t) {
    if (other is! EstadosUnivoz) return this;
    return EstadosUnivoz(
      exito: ColoresEstado.lerp(exito, other.exito, t),
      aviso: ColoresEstado.lerp(aviso, other.aviso, t),
      error: ColoresEstado.lerp(error, other.error, t),
    );
  }
}

/// Tema Material 3 de Univoz. [brightness] claro (por defecto) u oscuro.
ThemeData temaUnivoz({Brightness brightness = Brightness.light}) {
  final colores = _esquema(brightness);
  final oscuro = brightness == Brightness.dark;
  final redondeado =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRadioUnivoz));
  const minimo = Size(64, kAltoMinimoToque);
  const textoBoton = TextStyle(fontWeight: FontWeight.w600, fontSize: 15);
  final bordeControl =
      oscuro ? colores.outlineVariant : ColoresUnivoz.bordeControl;
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colores,
    scaffoldBackgroundColor: colores.surface,
  );
  return base.copyWith(
    extensions: [oscuro ? EstadosUnivoz.oscuro : EstadosUnivoz.claro],
    cardTheme: CardThemeData(
      color: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        side: BorderSide(color: colores.outlineVariant, width: 2),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colores.surface,
      foregroundColor: colores.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: colores.onSurface,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: oscuro ? colores.outlineVariant : const Color(0xFFF0EDF5),
      thickness: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: minimo,
        shape: redondeado,
        textStyle: textoBoton,
        disabledBackgroundColor: colores.surfaceContainerHigh,
        disabledForegroundColor: colores.outline,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        minimumSize: minimo,
        shape: redondeado,
        elevation: 0,
        backgroundColor: colores.primary,
        foregroundColor: colores.onPrimary,
        disabledBackgroundColor: colores.surfaceContainerHigh,
        disabledForegroundColor: colores.outline,
        textStyle: textoBoton,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: minimo,
        shape: redondeado,
        foregroundColor: colores.primary,
        side: BorderSide(color: bordeControl, width: 1.5),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: minimo,
        shape: redondeado,
        foregroundColor: colores.primary,
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: colores.primary,
      inactiveTrackColor: colores.surfaceContainerHighest,
      thumbColor: colores.primary,
      overlayColor: colores.primary.withValues(alpha: 0.12),
      trackHeight: 3.5,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((estados) =>
          estados.contains(WidgetState.selected) ? colores.primary : null),
      trackColor: WidgetStateProperty.resolveWith((estados) =>
          estados.contains(WidgetState.selected)
              ? colores.secondaryContainer
              : null),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colores.primary),
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
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: TextStyle(fontSize: 13, color: colores.onSurfaceVariant),
      hintStyle: TextStyle(fontSize: 13, color: colores.outline),
      prefixIconColor: colores.primary,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        borderSide: BorderSide(color: bordeControl),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        borderSide: BorderSide(color: bordeControl),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        borderSide: BorderSide(color: colores.primary, width: 1.5),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colores.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
  );
}
