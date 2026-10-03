import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'avatar_bridge.dart';

final Set<String> _registeredViews = <String>{};

Widget buildAvatarViewport({
  required AvatarBridge bridge,
  required Widget unavailable,
}) {
  final viewType = 'univoz-avatar-${identityHashCode(bridge)}';
  if (_registeredViews.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final frame = web.HTMLIFrameElement()
        ..src = Uri.base
            .resolve('assets/assets/avatar_viewer/index.html?standalone=1')
            .toString()
        ..setAttribute('allow', 'camera; microphone');
      frame.style
        ..border = '0'
        ..width = '100%'
        ..height = '100%';
      return frame;
    });
  }
  return HtmlElementView(viewType: viewType);
}
