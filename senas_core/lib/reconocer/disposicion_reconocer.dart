/// Acomodo de "Reconocer seña": donde van el avatar, la camara y el panel
/// del resultado segun el espacio. Aparte de la pantalla para poder probarlo
/// a tamanos de telefono reales (la pantalla no se puede montar en pruebas:
/// el WebView necesita plataforma).
///
/// Regla dura: la camara va JUNTO al avatar, nunca encima. En Android el
/// WebView es una platform view y tapa un Texture que quede sobre el.
library disposicion_reconocer;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Alto que se le guarda al panel en el telefono vertical: nombre de la
/// sena (hasta dos lineas), confianza y la primera fila de alternativas sin
/// desplazar. Una parte es fija (margenes, tamanos tactiles) y otra crece
/// con la escala de texto.
double reservaPanel(double escalaTexto) => 70 + 140 * escalaTexto;

/// Alto minimo de la fila del avatar aunque la pantalla sea muy baja.
const double kAltoMinimoArriba = 96;

/// Selector Automatico | Manual, con la explicacion de cada modo.
class SelectorModo extends StatelessWidget {
  const SelectorModo({
    super.key,
    required this.automatico,
    required this.onCambiar,
  });

  final bool automatico;
  final ValueChanged<bool> onCambiar;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: true,
          icon: Icon(Icons.auto_awesome),
          label: Text('Automático'),
          tooltip: 'Reconozco la seña sola cuando terminas de hacerla',
        ),
        ButtonSegment(
          value: false,
          icon: Icon(Icons.touch_app_outlined),
          label: Text('Manual'),
          tooltip: 'Tú tocas Grabar al empezar y Detener al terminar',
        ),
      ],
      selected: {automatico},
      onSelectionChanged: (s) {
        if (s.first != automatico) onCambiar(s.first);
      },
    );
  }
}

class DisposicionReconocer extends StatelessWidget {
  const DisposicionReconocer({
    super.key,
    required this.avatar,
    required this.camara,
    required this.panel,
    this.aspectoCamara = 3 / 4,
  });

  /// Visor del avatar; null si la plataforma no tiene (solo camara).
  final Widget? avatar;

  /// Vista de la camara. [compacta]: el recuadro chico del telefono
  /// vertical, ya con su tamano exacto.
  final Widget Function(bool compacta) camara;

  /// Resultado, avisos y pistas (se desplaza si no cabe).
  final Widget panel;

  /// Ancho / alto de la imagen de la camara.
  final double aspectoCamara;

  @override
  Widget build(BuildContext context) {
    final escalaTexto = MediaQuery.textScalerOf(context).scale(16) / 16;
    // Orientacion por la pantalla, no por el area que queda: en un telefono
    // bajo con letra grande el area libre puede salir mas ancha que alta.
    final pantalla = MediaQuery.sizeOf(context);
    return LayoutBuilder(builder: (context, c) {
      final vertical = avatar != null &&
          c.maxWidth < 600 &&
          pantalla.height > pantalla.width;
      if (!vertical) {
        // Ancho (tableta, horizontal): avatar y camara lado a lado 3:2 y el
        // resultado abajo.
        return Column(
          children: [
            Expanded(
              child: avatar == null
                  ? camara(false)
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 3, child: avatar!),
                        Expanded(flex: 2, child: camara(false)),
                      ],
                    ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: c.maxHeight * 0.45),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: panel,
              ),
            ),
          ],
        );
      }
      // Telefono vertical: arriba el avatar con la camara en un recuadro a
      // su derecha; abajo el panel a todo el ancho. En pantallas bajas (o
      // con letra grande) la fila de arriba cede alto para que el resultado
      // y las primeras alternativas se vean sin desplazar.
      final reserva = reservaPanel(escalaTexto);
      final altoArriba = math.max(kAltoMinimoArriba,
          math.min(c.maxHeight * 0.55, c.maxHeight - reserva));
      final altoFila = altoArriba - 8;
      final anchoCamara =
          math.max(0.0, math.min(c.maxWidth * 0.38, altoFila * aspectoCamara));
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: SizedBox(
              height: altoFila,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: avatar!),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: anchoCamara,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: aspectoCamara,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: camara(true),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: panel,
            ),
          ),
        ],
      );
    });
  }
}
