import 'package:flutter/material.dart';

import 'avatar_bridge.dart';
import 'avatar_view_platform.dart' as platform;

/// Visor único del avatar usado por todas las pantallas que muestran señas.
/// En Android usa WebView; en web usa un iframe con el mismo visor.
class AvatarViewport extends StatelessWidget {
  const AvatarViewport({
    super.key,
    required this.bridge,
    this.unavailable,
  });

  final AvatarBridge bridge;
  final Widget? unavailable;

  @override
  Widget build(BuildContext context) => platform.buildAvatarViewport(
        bridge: bridge,
        unavailable: unavailable ?? const _AvatarNoDisponible(),
      );
}

class _AvatarNoDisponible extends StatelessWidget {
  const _AvatarNoDisponible();

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Color(0xFFEDE4FB),
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Avatar 3D disponible en Android o web local.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
