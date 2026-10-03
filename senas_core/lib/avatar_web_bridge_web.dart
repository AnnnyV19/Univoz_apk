import 'dart:js_interop';

import 'package:web/web.dart' as web;

void postAvatarCommand(Map<String, dynamic> command) {
  final message = <String, dynamic>{
    'channel': 'univoz-avatar',
    ...command,
  }.jsify();
  final frames = web.document.querySelectorAll('iframe');
  for (var i = 0; i < frames.length; i++) {
    final frame = frames.item(i) as web.HTMLIFrameElement;
    frame.contentWindow?.postMessage(message, '*'.toJS);
  }
}
