/// Tarjeta del resultado de "Reconocer seña": la sena reconocida en grande,
/// que tan seguro esta el reconocedor (Alta / Media / Baja), las
/// alternativas para corregir ("¿Quisiste decir…?") y, con el modo
/// desarrollador, los numeros crudos del DTW.
library tarjeta_resultado;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../dtw.dart';

/// Que tan seguro esta el reconocedor de un resultado.
enum NivelConfianza {
  alta('Alta'),
  media('Media'),
  baja('Baja');

  const NivelConfianza(this.texto);
  final String texto;
}

/// Nivel de [p] contra los umbrales ACTIVOS del clasificador ([umbral] =
/// distancia maxima, [margenMin] = margen minimo; Ajustes los cambia).
/// Rechazada: baja. Aceptada con holgura (distancia hasta 0.6 x umbral y
/// margen de al menos el doble del minimo): alta. Cualquier otra: media.
NivelConfianza nivelConfianza(Prediction p,
    {required double umbral, required double margenMin}) {
  if (!p.aceptada) return NivelConfianza.baja;
  if (p.distance <= umbral * 0.6 && p.margin >= margenMin * 2) {
    return NivelConfianza.alta;
  }
  return NivelConfianza.media;
}

/// Cuantas alternativas se ofrecen como mucho.
const int kMaxAlternativas = 3;

/// Candidatas para "¿Quisiste decir…?" a partir del ranking sin glosas
/// repetidas ([candidatas], la mas parecida primero). Aceptada: sin la
/// ganadora (ya se muestra). Rechazada: la mas parecida tambien se ofrece,
/// porque no se mostro como resultado.
List<MapEntry<double, Template>> alternativasDe(
    Prediction p, List<MapEntry<double, Template>> candidatas) {
  final resto = p.aceptada
      ? candidatas.where((e) => e.value.gloss != p.gloss)
      : candidatas;
  return resto.take(kMaxAlternativas).toList();
}

/// Lo que se muestra (y se dice) de una plantilla: su espanol, o la glosa
/// vuelta legible, igual que Prediction.textoHablado.
String textoDePlantilla(Template t) =>
    Prediction(t.gloss, t.signId, t.espanol, 0, 0, true).textoHablado;

class TarjetaResultado extends StatefulWidget {
  const TarjetaResultado({
    super.key,
    required this.prediccion,
    required this.umbral,
    required this.margenMin,
    this.candidatas = const [],
    this.elegida,
    this.desarrollador = false,
    this.onAlternativa,
    this.onHablar,
    this.onVerEnAvatar,
  });

  final Prediction prediccion;
  final double umbral;
  final double margenMin;

  /// Ranking sin glosas repetidas, la mas parecida primero.
  final List<MapEntry<double, Template>> candidatas;

  /// La alternativa que la persona eligio para corregir, o null.
  final Template? elegida;

  /// Muestra distancia, margen y la distancia de cada candidata.
  final bool desarrollador;

  final ValueChanged<Template>? onAlternativa;
  final VoidCallback? onHablar;

  /// Reproduce la sena mostrada en el avatar; null lo oculta.
  final VoidCallback? onVerEnAvatar;

  static const duracionEntrada = Duration(milliseconds: 260);

  @override
  State<TarjetaResultado> createState() => _TarjetaResultadoState();
}

class _TarjetaResultadoState extends State<TarjetaResultado> {
  @override
  void initState() {
    super.initState();
    // Cada resultado nuevo es una tarjeta nueva (la pantalla cambia la key):
    // un toque suave confirma sin mirar. Corregir no vibra.
    if (widget.prediccion.aceptada && widget.elegida == null) {
      HapticFeedback.lightImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final sinAnimacion = MediaQuery.disableAnimationsOf(context);
    final tarjeta = _contenido(context);
    if (sinAnimacion) return tarjeta;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: TarjetaResultado.duracionEntrada,
      curve: Curves.easeOutCubic,
      child: tarjeta,
      builder: (context, v, hijo) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.94 + 0.06 * v, child: hijo),
      ),
    );
  }

  Widget _contenido(BuildContext context) {
    final w = widget;
    final p = w.prediccion;
    final tema = Theme.of(context);
    final colores = tema.colorScheme;
    final elegida = w.elegida;
    final hayResultado = p.aceptada || elegida != null;
    final fondo =
        hayResultado ? colores.primaryContainer : colores.surfaceContainerHigh;
    final tinta =
        hayResultado ? colores.onPrimaryContainer : colores.onSurface;
    final nivel =
        nivelConfianza(p, umbral: w.umbral, margenMin: w.margenMin);
    final alternativas = elegida == null
        ? alternativasDe(p, w.candidatas)
        : w.candidatas
            .where((e) => e.value.gloss != elegida.gloss)
            .take(kMaxAlternativas)
            .toList();
    final texto = elegida != null ? textoDePlantilla(elegida) : p.textoHablado;

    return Semantics(
      container: true,
      liveRegion: true,
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        color: fondo,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hayResultado)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        texto,
                        // Senas de varias palabras con letra grande: hasta
                        // 3 lineas antes de recortar.
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: tema.textTheme.headlineMedium?.copyWith(
                            color: tinta, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (w.onHablar != null)
                      IconButton(
                        icon: Icon(Icons.volume_up, color: tinta),
                        tooltip: 'Repetir en voz alta',
                        onPressed: w.onHablar,
                      ),
                  ],
                )
              else
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text('No estoy seguro. Inténtalo de nuevo.',
                      style: tema.textTheme.titleMedium
                          ?.copyWith(color: tinta)),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (elegida != null)
                    _Etiqueta(
                      icono: Icons.edit_outlined,
                      texto: 'Corregida por ti',
                      fondo: colores.secondaryContainer,
                      tinta: colores.onSecondaryContainer,
                    )
                  else
                    _ChipConfianza(nivel: nivel),
                  if (hayResultado && w.onVerEnAvatar != null)
                    TextButton.icon(
                      onPressed: w.onVerEnAvatar,
                      style: TextButton.styleFrom(
                        foregroundColor: tinta,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.accessibility_new),
                      label: const Text('Ver en avatar'),
                    ),
                ],
              ),
              if (w.desarrollador) ...[
                const SizedBox(height: 4),
                if (!p.aceptada && p.gloss != null)
                  Text('la más parecida fue ${p.textoHablado}',
                      style: tema.textTheme.bodySmall
                          ?.copyWith(color: tinta.withValues(alpha: 0.8))),
                Text(
                  'distancia ${p.distance.toStringAsFixed(3)} '
                  '(máx ${w.umbral.toStringAsFixed(2)})  ·  '
                  'margen ${p.margin.toStringAsFixed(3)} '
                  '(mín ${w.margenMin.toStringAsFixed(2)})',
                  style: tema.textTheme.labelSmall
                      ?.copyWith(color: tinta.withValues(alpha: 0.8)),
                ),
              ],
              if (alternativas.isNotEmpty) ...[
                const SizedBox(height: 6),
                // La pregunta va en la misma fila que las alternativas: en
                // un telefono chico la primera se ve sin desplazar.
                Wrap(
                  spacing: 8,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('¿Quisiste decir…?',
                        style:
                            tema.textTheme.labelLarge?.copyWith(color: tinta)),
                    for (final e in alternativas)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          w.desarrollador
                              ? '${textoDePlantilla(e.value)} · '
                                  '${e.key.toStringAsFixed(3)}'
                              : textoDePlantilla(e.value),
                          overflow: TextOverflow.ellipsis,
                        ),
                        tooltip: 'Era «${textoDePlantilla(e.value)}»',
                        onPressed: w.onAlternativa == null
                            ? null
                            : () => w.onAlternativa!(e.value),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChipConfianza extends StatelessWidget {
  const _ChipConfianza({required this.nivel});

  final NivelConfianza nivel;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final (icono, fondo, tinta) = switch (nivel) {
      NivelConfianza.alta => (
          Icons.verified_outlined,
          colores.primary,
          colores.onPrimary
        ),
      NivelConfianza.media => (
          Icons.thumbs_up_down_outlined,
          colores.surfaceContainerLowest,
          colores.onSurface
        ),
      NivelConfianza.baja => (
          Icons.help_outline,
          colores.surfaceContainerHighest,
          colores.onSurfaceVariant
        ),
    };
    return Semantics(
      label: 'Confianza ${nivel.texto.toLowerCase()}',
      excludeSemantics: true,
      child: _Etiqueta(
        icono: icono,
        texto: 'Confianza ${nivel.texto}',
        fondo: fondo,
        tinta: tinta,
      ),
    );
  }
}

class _Etiqueta extends StatelessWidget {
  const _Etiqueta({
    required this.icono,
    required this.texto,
    required this.fondo,
    required this.tinta,
  });

  final IconData icono;
  final String texto;
  final Color fondo;
  final Color tinta;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 16, color: tinta),
            const SizedBox(width: 4),
            Text(texto,
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: tinta, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
