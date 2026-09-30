import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'avatar_bridge.dart';

Widget buildAvatarViewport({
  required AvatarBridge bridge,
  required Widget unavailable,
}) {
  if (!bridge.disponible) return unavailable;
  return WebViewWidget(controller: bridge.controller!);
}
