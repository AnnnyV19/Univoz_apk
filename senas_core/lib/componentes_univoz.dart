/// Piezas del diseño de Univoz (rediseño de Lucía, oct-2026) que comparten
/// las pantallas: tarjeta con borde, encabezado de sección, ajuste con
/// deslizador, interruptor, aviso de estado y ficha de dato. Toman sus
/// colores del tema (tema_univoz.dart), así que funcionan en claro y oscuro.
library componentes_univoz;

import 'package:flutter/material.dart';

import 'tema_univoz.dart';

/// Tarjeta plana con borde de 2 px (el `cardTheme` del tema).
/// [destacada]: borde del color principal y una sombra suave.
class TarjetaUnivoz extends StatelessWidget {
  const TarjetaUnivoz({
    super.key,
    required this.child,
    this.destacada = false,
    this.margen = const EdgeInsets.only(bottom: 16),
    this.relleno = const EdgeInsets.all(16),
  });

  final Widget child;
  final bool destacada;
  final EdgeInsetsGeometry margen;
  final EdgeInsetsGeometry relleno;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: margen,
      padding: relleno,
      decoration: BoxDecoration(
        color: destacada ? colores.surfaceContainerLow : colores.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        border: Border.all(
          color: destacada ? colores.primary : colores.outlineVariant,
          width: 2,
        ),
        boxShadow: destacada
            ? [
                BoxShadow(
                  color: colores.primary.withValues(alpha: 0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}

/// Cuadro de color tenue con un icono, a la izquierda de un título.
class IconoCaja extends StatelessWidget {
  const IconoCaja(this.icono, {super.key, this.tamano = 36, this.relleno = false});

  final IconData icono;
  final double tamano;

  /// true: degradado del color principal con el icono en blanco (para la
  /// tarjeta destacada).
  final bool relleno;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      width: tamano,
      height: tamano,
      decoration: BoxDecoration(
        color: relleno ? null : colores.primaryContainer,
        gradient: relleno
            ? LinearGradient(
                colors: [colores.primary, colores.secondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icono,
          size: tamano * 0.56,
          color: relleno ? colores.onPrimary : colores.primary),
    );
  }
}

/// Icono + título + descripción, con una línea divisoria debajo.
class EncabezadoSeccion extends StatelessWidget {
  const EncabezadoSeccion({
    super.key,
    required this.icono,
    required this.titulo,
    this.descripcion,
    this.divisor = true,
  });

  final IconData icono;
  final String titulo;
  final String? descripcion;
  final bool divisor;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icono, size: 20, color: colores.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                titulo,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colores.onSurface,
                ),
              ),
            ),
          ],
        ),
        if (descripcion != null) ...[
          const SizedBox(height: 4),
          Text(
            descripcion!,
            style: TextStyle(
              fontSize: 12.5,
              color: colores.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
        if (divisor) ...[
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

/// Valor pequeño en una pastilla de color tenue (p. ej. "0.55").
class PastillaValor extends StatelessWidget {
  const PastillaValor(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colores.primaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        texto,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colores.primary,
        ),
      ),
    );
  }
}

/// Ajuste con deslizador: etiqueta, valor en pastilla y ayuda debajo.
class AjusteDeslizador extends StatelessWidget {
  const AjusteDeslizador({
    super.key,
    required this.etiqueta,
    required this.valor,
    required this.min,
    required this.max,
    required this.divisiones,
    required this.ayuda,
    required this.onChanged,
  });

  final String etiqueta;
  final double valor;
  final double min;
  final double max;
  final int divisiones;
  final String ayuda;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Expanded: la etiqueta puede ser larga y en pantalla angosta
              // un Text suelto en un Row se sale del cuadro.
              Expanded(
                child: Text(
                  etiqueta,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: colores.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PastillaValor(valor.toStringAsFixed(2)),
            ],
          ),
          Slider(
            value: valor.clamp(min, max),
            min: min,
            max: max,
            divisions: divisiones,
            onChanged: onChanged,
          ),
          Text(
            ayuda,
            style: TextStyle(fontSize: 11.5, color: colores.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Interruptor con título y explicación. Es un SwitchListTile (accesible y
/// con toda la fila tocable) con el estilo del diseño.
class AjusteInterruptor extends StatelessWidget {
  const AjusteInterruptor({
    super.key,
    required this.titulo,
    this.subtitulo,
    required this.valor,
    required this.onChanged,
  });

  final String titulo;
  final String? subtitulo;
  final bool valor;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      title: Text(
        titulo,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          color: colores.onSurface,
        ),
      ),
      subtitle: subtitulo == null
          ? null
          : Text(
              subtitulo!,
              style: TextStyle(
                fontSize: 11.5,
                color: colores.onSurfaceVariant,
                height: 1.3,
              ),
            ),
      value: valor,
      onChanged: onChanged,
    );
  }
}

/// Fila de acción dentro de una tarjeta (icono, título, detalle opcional).
class AccionFila extends StatelessWidget {
  const AccionFila({
    super.key,
    required this.icono,
    required this.titulo,
    this.detalle,
    required this.onTap,
    this.peligro = false,
  });

  final IconData icono;
  final String titulo;
  final String? detalle;
  final VoidCallback onTap;
  final bool peligro;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final color = peligro ? colores.error : colores.primary;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icono, color: color),
      title: Text(
        titulo,
        style: TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w500,
          color: peligro ? colores.error : colores.onSurface,
        ),
      ),
      subtitle: detalle == null
          ? null
          : Text(detalle!,
              style:
                  TextStyle(fontSize: 11.5, color: colores.onSurfaceVariant)),
      onTap: onTap,
    );
  }
}

/// Tipo de aviso: verde (listo), ámbar (información / falta algo), rojo.
enum TipoAviso { exito, info, error }

/// Aviso con fondo claro, borde e icono según su tipo.
class AvisoUnivoz extends StatelessWidget {
  const AvisoUnivoz(
    this.texto, {
    super.key,
    this.tipo = TipoAviso.exito,
    this.seleccionable = false,
    this.compacto = false,
    this.margen = const EdgeInsets.only(bottom: 16),
  });

  final String texto;
  final TipoAviso tipo;
  final bool seleccionable;
  final bool compacto;
  final EdgeInsetsGeometry margen;

  @override
  Widget build(BuildContext context) {
    final estados = EstadosUnivoz.de(context);
    final c = switch (tipo) {
      TipoAviso.exito => estados.exito,
      TipoAviso.info => estados.aviso,
      TipoAviso.error => estados.error,
    };
    final icono = switch (tipo) {
      TipoAviso.exito => Icons.check_circle_outline_rounded,
      TipoAviso.info => Icons.info_outline_rounded,
      TipoAviso.error => Icons.error_outline_rounded,
    };
    final estilo = TextStyle(
      color: c.texto,
      fontSize: compacto ? 11.5 : 12.5,
      fontWeight: FontWeight.w500,
      height: 1.35,
    );
    return Container(
      width: double.infinity,
      margin: margen,
      padding: compacto
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
          : const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.fondo,
        borderRadius: BorderRadius.circular(compacto ? 8 : kRadioUnivoz),
        border: Border.all(color: c.borde, width: compacto ? 1 : 2),
      ),
      child: Row(
        crossAxisAlignment:
            compacto ? CrossAxisAlignment.center : CrossAxisAlignment.start,
        children: [
          Icon(icono, color: c.icono, size: compacto ? 14 : 18),
          SizedBox(width: compacto ? 6 : 10),
          Expanded(
            child: seleccionable
                ? SelectableText(texto, style: estilo)
                : Text(texto, style: estilo),
          ),
        ],
      ),
    );
  }
}

/// Recuadro pequeño con un dato (icono + valor + etiqueta).
class FichaDato extends StatelessWidget {
  const FichaDato({
    super.key,
    required this.icono,
    required this.valor,
    required this.etiqueta,
  });

  final IconData icono;
  final String valor;
  final String etiqueta;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colores.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colores.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, size: 13, color: colores.primary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  valor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: colores.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            etiqueta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              color: colores.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Indicador de trabajo en curso dentro de un recuadro.
class ProgresoUnivoz extends StatelessWidget {
  const ProgresoUnivoz(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colores.surfaceContainer,
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        border: Border.all(color: colores.outlineVariant, width: 2),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colores.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
