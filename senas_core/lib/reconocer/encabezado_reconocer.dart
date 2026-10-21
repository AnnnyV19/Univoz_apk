/// Titulo de "Reconocer seña" con cuantas senas conoce el reconocedor. Con
/// el modo desarrollador suma el desglose de plantillas por fuente.
library encabezado_reconocer;

import 'package:flutter/material.dart';

import '../plantillas.dart';

/// "44 señas disponibles": glosas distintas, no plantillas (cada sena tiene
/// varias muestras y su espejo).
String textoSenasDisponibles(ResumenDiccionario? r) {
  if (r == null) return 'Cargando señas…';
  final n = r.senasDistintas;
  if (n == 0) return 'Aún no hay señas';
  return n == 1 ? '1 seña disponible' : '$n señas disponibles';
}

/// Desglose que cuadra con el total: base (paquete del APK o sincronizadas,
/// nunca las dos) + muestras locales + espejos calculados al cargar.
String textoDesglosePlantillas(ResumenDiccionario r) {
  final base = r.delPaquete + r.sincronizadas;
  final origen = r.sincronizadas > 0 ? 'sincronizadas' : 'paquete';
  return '${r.total} plantillas = $base base ($origen) + '
      '${r.locales} locales + ${r.espejadas} espejadas';
}

class EncabezadoReconocer extends StatelessWidget {
  const EncabezadoReconocer({
    super.key,
    required this.resumen,
    this.desarrollador = false,
  });

  /// Null mientras el diccionario carga.
  final ResumenDiccionario? resumen;
  final bool desarrollador;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final variante = tema.colorScheme.onSurfaceVariant;
    final r = resumen;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Reconocer seña'),
        Text(
          textoSenasDisponibles(r),
          style: tema.textTheme.bodySmall?.copyWith(color: variante),
        ),
        if (desarrollador && r != null)
          Text(
            textoDesglosePlantillas(r),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tema.textTheme.labelSmall?.copyWith(color: variante),
          ),
      ],
    );
  }
}
