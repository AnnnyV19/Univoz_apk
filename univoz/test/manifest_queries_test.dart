import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el manifiesto declara las consultas que Android 11+ exige', () {
    final xml =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final consultas = xml.substring(xml.indexOf('<queries>'));
    for (final accion in [
      'android.intent.action.TTS_SERVICE', // flutter_tts
      'android.speech.RecognitionService', // speech_to_text
      'android.intent.action.DIAL', // SOS: llamar
      'android.intent.action.SENDTO', // SOS: SMS
    ]) {
      expect(consultas, contains(accion));
    }
    expect(consultas, contains('android:scheme="tel"'));
    expect(consultas, contains('android:scheme="sms"'));
  });
}
