/// Estado de carga de la camara en "Reconocer seña": mientras el lado nativo
/// abre la camara y prepara los modelos (~1-2 s, mas la primera vez) se ve
/// que esta trabajando, no una ventana congelada.
library carga_camara;

import 'dart:async';

import 'package:flutter/material.dart';

/// Tras este tiempo se agrega la pista de que puede tardar.
const Duration kPistaCargaLenta = Duration(seconds: 4);

class CargaCamara extends StatefulWidget {
  const CargaCamara({super.key, this.compacta = false});

  /// Ventanita del telefono vertical: solo el indicador y un texto corto.
  final bool compacta;

  @override
  State<CargaCamara> createState() => _CargaCamaraState();
}

class _CargaCamaraState extends State<CargaCamara> {
  Timer? _pista;
  bool _lenta = false;

  @override
  void initState() {
    super.initState();
    _pista = Timer(kPistaCargaLenta, () {
      if (mounted) setState(() => _lenta = true);
    });
  }

  @override
  void dispose() {
    _pista?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final colores = tema.colorScheme;
    final estilo = widget.compacta
        ? tema.textTheme.bodySmall
        : tema.textTheme.bodyMedium;
    return ColoredBox(
      color:
          widget.compacta ? colores.surfaceContainerHighest : colores.surface,
      child: Semantics(
        // Sin label: los Text de dentro son lo que se lee (con label
        // TalkBack lo decia dos veces).
        liveRegion: true,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text('Preparando la cámara…',
                    textAlign: TextAlign.center, style: estilo),
                if (_lenta && !widget.compacta) ...[
                  const SizedBox(height: 6),
                  Text(
                    'La primera vez puede tardar unos segundos.',
                    textAlign: TextAlign.center,
                    style: estilo?.copyWith(color: colores.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
