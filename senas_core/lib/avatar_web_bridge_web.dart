import 'dart:html' as html;

void postAvatarCommand(Map<String, dynamic> command) {
  final message = <String, dynamic>{
    'channel': 'univoz-avatar',
    ...command,
  };
  for (final element in html.document.querySelectorAll('iframe')) {
    final frame = element as html.IFrameElement;
    frame.contentWindow?.postMessage(message, '*');
  }
}
