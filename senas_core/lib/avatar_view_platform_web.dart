import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

import 'avatar_bridge.dart';

final Set<String> _registeredViews = <String>{};

Widget buildAvatarViewport({
  required AvatarBridge bridge,
  required Widget unavailable,
}) {
  final viewType = 'univoz-avatar-${identityHashCode(bridge)}';
  if (_registeredViews.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final frame = html.IFrameElement()
        ..src = Uri.base
            .resolve('assets/assets/avatar_viewer/index.html?standalone=1')
            .toString()
        ..setAttribute('allow', 'camera; microphone')
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%';
      return frame;
    });
  }
  return HtmlElementView(viewType: viewType);
}
