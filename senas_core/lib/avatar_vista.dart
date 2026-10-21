import 'package:flutter/material.dart';

import 'avatar_bridge.dart';
import 'avatar_view.dart';

/// Avatar 3D con estado de carga y de error del lado de Flutter.
///
/// El WebView (o el iframe en web) queda montado SIEMPRE debajo, para que
/// siga cargando; mientras `bridge.estado` no sea `listo` lo tapa una
/// silueta animada, y si el visor falla de verdad, una tarjeta con
/// "Reintentar". Asi un error suelto del visor ya no se ve como un cartel
/// rojo encima de un avatar a medio dibujar.
class VistaAvatar extends StatelessWidget {
  const VistaAvatar({
    super.key,
    required this.bridge,
    this.noDisponible,
    this.vista,
  });

  final AvatarBridge bridge;

  /// Lo que se muestra si la plataforma no tiene visor (ver AvatarViewport).
  final Widget? noDisponible;

  /// Reemplaza al WebView: solo para pruebas de widget sin plataforma.
  final Widget? vista;

  static const duracionFundido = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    final visor =
        vista ?? AvatarViewport(bridge: bridge, unavailable: noDisponible);
    // Sin WebView (web usa iframe con su propio aviso, o no hay soporte) no
    // hay estados que mostrar.
    if (vista == null && !bridge.disponible) return visor;
    return ValueListenableBuilder<EstadoAvatar>(
      valueListenable: bridge.estado,
      child: visor,
      builder: (context, estado, visor) => Semantics(
        container: true,
        label: switch (estado) {
          EstadoAvatar.cargando => 'Avatar 3D, cargando',
          EstadoAvatar.listo => 'Avatar 3D',
          EstadoAvatar.error => 'Avatar 3D no disponible',
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Tapado por la silueta o la tarjeta, el WebView no debe ser
            // alcanzable con TalkBack.
            ExcludeSemantics(
              excluding: estado != EstadoAvatar.listo,
              child: visor!,
            ),
            AnimatedSwitcher(
              duration: duracionFundido,
              layoutBuilder: (actual, anteriores) => Stack(
                fit: StackFit.expand,
                children: [...anteriores, if (actual != null) actual],
              ),
              child: switch (estado) {
                EstadoAvatar.listo =>
                  const SizedBox.shrink(key: ValueKey(EstadoAvatar.listo)),
                EstadoAvatar.cargando =>
                  const _AvatarCargando(key: ValueKey(EstadoAvatar.cargando)),
                EstadoAvatar.error => _AvatarError(
                    key: const ValueKey(EstadoAvatar.error),
                    motivo: bridge.mensajeError,
                    onReintentar: bridge.reintentar,
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Silueta suave con un brillo que la recorre; sin animacion si el sistema
/// pide reducir movimiento.
class _AvatarCargando extends StatefulWidget {
  const _AvatarCargando({super.key});

  @override
  State<_AvatarCargando> createState() => _AvatarCargandoState();
}

class _AvatarCargandoState extends State<_AvatarCargando>
    with SingleTickerProviderStateMixin {
  late final AnimationController _brillo = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _brillo.stop();
      _brillo.value = 0.5;
    } else if (!_brillo.isAnimating) {
      _brillo.repeat();
    }
  }

  @override
  void dispose() {
    _brillo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colores.surfaceContainerHighest,
      child: AnimatedBuilder(
        animation: _brillo,
        builder: (context, _) => CustomPaint(
          painter: _SiluetaPainter(
            progreso: _brillo.value,
            base: colores.onSurface.withValues(alpha: 0.08),
            brillo: colores.onSurface.withValues(alpha: 0.16),
          ),
        ),
      ),
    );
  }
}

class _SiluetaPainter extends CustomPainter {
  _SiluetaPainter({
    required this.progreso,
    required this.base,
    required this.brillo,
  });

  final double progreso;
  final Color base;
  final Color brillo;

  @override
  void paint(Canvas canvas, Size size) {
    // Cabeza y hombros centrados, proporcionales al lado corto.
    final lado = size.shortestSide;
    final centro = Offset(size.width / 2, size.height * 0.42);
    final radioCabeza = lado * 0.13;
    final cabeza = Rect.fromCircle(
        center: centro.translate(0, -radioCabeza * 1.3), radius: radioCabeza);
    final torso = Rect.fromCenter(
      center: centro.translate(0, radioCabeza * 1.9),
      width: lado * 0.62,
      height: radioCabeza * 2.6,
    );
    final silueta = Path()
      ..addOval(cabeza)
      ..addRRect(RRect.fromRectAndCorners(
        torso,
        topLeft: Radius.circular(lado * 0.2),
        topRight: Radius.circular(lado * 0.2),
        bottomLeft: Radius.circular(lado * 0.04),
        bottomRight: Radius.circular(lado * 0.04),
      ));
    final x = progreso * 1.6 - 0.3;
    final pintura = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [base, brillo, base],
        stops: [
          (x - 0.2).clamp(0.0, 1.0),
          x.clamp(0.0, 1.0),
          (x + 0.2).clamp(0.0, 1.0),
        ],
      ).createShader(Offset.zero & size);
    canvas.drawPath(silueta, pintura);
  }

  @override
  bool shouldRepaint(_SiluetaPainter viejo) =>
      viejo.progreso != progreso ||
      viejo.base != base ||
      viejo.brillo != brillo;
}

class _AvatarError extends StatelessWidget {
  const _AvatarError(
      {super.key, required this.motivo, required this.onReintentar});

  final String? motivo;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    return ColoredBox(
      color: tema.colorScheme.surfaceContainerHighest,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, color: tema.colorScheme.error),
                  const SizedBox(height: 8),
                  Text('No se pudo mostrar el avatar.',
                      textAlign: TextAlign.center,
                      style: tema.textTheme.titleSmall),
                  if (motivo != null) ...[
                    const SizedBox(height: 4),
                    Text(motivo!,
                        textAlign: TextAlign.center,
                        style: tema.textTheme.bodySmall),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: onReintentar,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reintentar'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
