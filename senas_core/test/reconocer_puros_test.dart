import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:senas_core/camera_bridge.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/reconocer/encabezado_reconocer.dart';
import 'package:senas_core/reconocer/guia_encuadre.dart';
import 'package:senas_core/reconocer/tarjeta_resultado.dart';
import 'package:senas_core/sign_norm.dart' show kFrameDim;

/// Frame valido (golden de sign_norm): hombros en x 0.38 / 0.62, las dos
/// manos dentro de cuadro.
Map<String, dynamic> _crudo() {
  final data =
      jsonDecode(File('test/golden/golden_cases.json').readAsStringSync())
          as Map<String, dynamic>;
  final f = ((data['cases'] as List).first as Map)['frames'][0] as Map;
  // Copia profunda: cada caso muta su propia pose.
  return jsonDecode(jsonEncode({
    't': 0,
    'pose': f['pose'],
    'poseMundo': f['pose_mundo'],
    'left': f['left'],
    'right': f['right'],
  })) as Map<String, dynamic>;
}

LandmarkFrame _frame([void Function(Map<String, dynamic> m)? cambiar]) {
  final m = _crudo();
  cambiar?.call(m);
  return LandmarkFrame.fromMap(m);
}

List<dynamic> _punto(Map<String, dynamic> m, int i) =>
    (m['pose'] as List)[i] as List<dynamic>;

Prediction _pred(double d, double margen, {bool? aceptada}) => Prediction(
    'HOLA', 'h1', 'hola', d, margen, aceptada ?? (d <= .55 && margen >= .12));

void main() {
  group('nivelConfianza', () {
    test('alta solo con distancia holgada y margen doble', () {
      // 0.6 x 0.55 = 0.33 ; 2 x 0.12 = 0.24
      expect(nivelConfianza(_pred(.30, .30), umbral: .55, margenMin: .12),
          NivelConfianza.alta);
      expect(nivelConfianza(_pred(.33, .24), umbral: .55, margenMin: .12),
          NivelConfianza.alta,
          reason: 'los limites cuentan como alta');
    });

    test('aceptada sin holgura es media', () {
      expect(nivelConfianza(_pred(.34, .30), umbral: .55, margenMin: .12),
          NivelConfianza.media,
          reason: 'distancia apenas sobre 0.6 x umbral');
      expect(nivelConfianza(_pred(.30, .23), umbral: .55, margenMin: .12),
          NivelConfianza.media,
          reason: 'margen bajo el doble del minimo');
      expect(nivelConfianza(_pred(.55, .12), umbral: .55, margenMin: .12),
          NivelConfianza.media);
    });

    test('rechazada siempre es baja', () {
      expect(nivelConfianza(_pred(.60, .30), umbral: .55, margenMin: .12),
          NivelConfianza.baja);
      expect(nivelConfianza(_pred(.20, .05), umbral: .55, margenMin: .12),
          NivelConfianza.baja);
      // Aun con numeros de alta, si el clasificador la rechazo es baja.
      expect(
          nivelConfianza(_pred(.10, .90, aceptada: false),
              umbral: .55, margenMin: .12),
          NivelConfianza.baja);
    });

    test('usa los umbrales activos de Ajustes', () {
      // Con umbral 0.4 la alta pide d <= 0.24 y margen >= 0.4.
      expect(nivelConfianza(_pred(.30, .50, aceptada: true),
              umbral: .4, margenMin: .2),
          NivelConfianza.media);
      expect(nivelConfianza(_pred(.24, .40, aceptada: true),
              umbral: .4, margenMin: .2),
          NivelConfianza.alta);
    });

    test('cada nivel tiene su texto', () {
      expect(NivelConfianza.alta.texto, 'Alta');
      expect(NivelConfianza.media.texto, 'Media');
      expect(NivelConfianza.baja.texto, 'Baja');
    });
  });

  group('pistaEncuadre', () {
    test('frame bien encuadrado no da pista', () {
      expect(pistaEncuadre(_frame()), isNull);
    });

    test('sin persona no da pista (lo cubre la silueta)', () {
      expect(pistaEncuadre(null), isNull);
      expect(pistaEncuadre(LandmarkFrame.fromMap({'t': 0})), isNull);
      expect(personaDetectada(LandmarkFrame.fromMap({'t': 0})), isFalse);
      expect(personaDetectada(null), isFalse);
      expect(personaDetectada(_frame()), isTrue);
    });

    test('hombros fuera de cuadro o demasiado anchos: alejate', () {
      expect(
          pistaEncuadre(_frame((m) {
            _punto(m, 11)[1] = 1.3; // hombro izq bajo el borde
          })),
          kPistaAlejate);
      expect(
          pistaEncuadre(_frame((m) {
            _punto(m, 11)[0] = 0.05;
            _punto(m, 12)[0] = 0.95; // 0.9 del ancho
          })),
          kPistaAlejate);
    });

    test('hombros con poca visibilidad: no veo tus hombros', () {
      expect(
          pistaEncuadre(_frame((m) {
            _punto(m, 12)[3] = 0.3;
          })),
          kPistaSinHombros);
    });

    test('persona muy chica: acercate', () {
      expect(
          pistaEncuadre(_frame((m) {
            _punto(m, 11)[0] = 0.46;
            _punto(m, 12)[0] = 0.56; // 0.10 del ancho
          })),
          kPistaAcercate);
    });

    test('en imagen horizontal el ancho se mide contra el lado corto', () {
      // 0.12 del ancho en 16:9 son 0.21 del alto: no es "muy chica".
      final f = _frame((m) {
        _punto(m, 11)[0] = 0.44;
        _punto(m, 12)[0] = 0.56;
        m['image_w'] = 1280;
        m['image_h'] = 720;
      });
      expect(pistaEncuadre(f), isNull);
    });

    test('mano detectada saliendo del cuadro: mano fuera de cuadro', () {
      expect(
          pistaEncuadre(_frame((m) {
            final mano = m['right'] as List;
            mano[0] = [1.05, 0.58, 0.0]; // muneca fuera
          })),
          kPistaManoFuera);
    });

    test('las manos en reposo fuera de imagen no cuentan', () {
      // Sin manos detectadas (bajadas): el cuerpo esta bien.
      expect(
          pistaEncuadre(_frame((m) {
            m['left'] = null;
            m['right'] = null;
          })),
          isNull);
    });

    test('prioridad: el cuerpo antes que la mano', () {
      expect(
          pistaEncuadre(_frame((m) {
            _punto(m, 12)[3] = 0.3;
            (m['right'] as List)[0] = [1.05, 0.58, 0.0];
          })),
          kPistaSinHombros);
    });
  });

  group('HisteresisPista', () {
    test('aparece solo si la misma pista dura 1 s', () {
      final h = HisteresisPista();
      expect(h.actualizar('A', 0), isNull);
      expect(h.actualizar('A', 900), isNull);
      expect(h.actualizar('A', 1000), 'A');
    });

    test('una pista distinta reinicia la cuenta', () {
      final h = HisteresisPista();
      h.actualizar('A', 0);
      h.actualizar('B', 800);
      expect(h.actualizar('B', 1700), isNull);
      expect(h.actualizar('B', 1800), 'B');
    });

    test('se oculta tras 0.5 s seguidos sin problema', () {
      final h = HisteresisPista();
      h.actualizar('A', 0);
      expect(h.actualizar('A', 1000), 'A');
      expect(h.actualizar(null, 1100), 'A');
      expect(h.actualizar(null, 1500), 'A');
      expect(h.actualizar(null, 1600), isNull);
    });

    test('un frame suelto sin problema no la apaga', () {
      final h = HisteresisPista();
      h.actualizar('A', 0);
      h.actualizar('A', 1000);
      h.actualizar(null, 1100);
      expect(h.actualizar('A', 1200), 'A');
      // El OK vuelve a contar desde cero.
      expect(h.actualizar(null, 1300), 'A');
      expect(h.actualizar(null, 1700), 'A');
      expect(h.actualizar(null, 1800), isNull);
    });

    test('un parpadeo de problema no la enciende', () {
      final h = HisteresisPista();
      expect(h.actualizar('A', 0), isNull);
      expect(h.actualizar(null, 300), isNull);
      expect(h.actualizar('A', 600), isNull);
      expect(h.actualizar('A', 1400), isNull,
          reason: 'la cuenta empezo de nuevo en 600');
      expect(h.actualizar('A', 1600), 'A');
    });

    test('mientras otra pista madura, la visible se queda', () {
      final h = HisteresisPista();
      h.actualizar('A', 0);
      h.actualizar('A', 1000);
      expect(h.actualizar('B', 1100), 'A');
      expect(h.actualizar('B', 2100), 'B');
    });

    test('reloj hacia atras (camara reiniciada) reinicia sin colgarse', () {
      final h = HisteresisPista();
      h.actualizar('A', 5000);
      expect(h.actualizar('A', 10), isNull);
      expect(h.actualizar('A', 1010), 'A');
    });

    test('limpiar la apaga al instante', () {
      final h = HisteresisPista();
      h.actualizar('A', 0);
      h.actualizar('A', 1000);
      h.limpiar();
      expect(h.visible, isNull);
      expect(h.actualizar('A', 1100), isNull);
    });
  });

  group('textos del encabezado', () {
    ResumenDiccionario r({
      int paquete = 0,
      int sincronizadas = 0,
      int locales = 0,
      int espejadas = 0,
      int senas = 0,
    }) =>
        ResumenDiccionario(
          delPaquete: paquete,
          sincronizadas: sincronizadas,
          locales: locales,
          espejadas: espejadas,
          senasDistintas: senas,
        );

    test('senas disponibles en singular y plural', () {
      expect(textoSenasDisponibles(r(senas: 44)), '44 señas disponibles');
      expect(textoSenasDisponibles(r(senas: 1)), '1 seña disponible');
      expect(textoSenasDisponibles(r()), 'Aún no hay señas');
      expect(textoSenasDisponibles(null), 'Cargando señas…');
    });

    test('desglose suma base + locales + espejadas', () {
      expect(textoDesglosePlantillas(r(paquete: 146, espejadas: 146, senas: 44)),
          '292 plantillas = 146 base (paquete) + 0 locales + 146 espejadas');
      expect(
          textoDesglosePlantillas(
              r(sincronizadas: 150, locales: 3, espejadas: 153, senas: 45)),
          '306 plantillas = 150 base (sincronizadas) + 3 locales + 153 espejadas');
    });
  });

  group('alternativas', () {
    final seq = [List<double>.filled(kFrameDim, 0.0)];
    final t = [
      for (final g in ['HOLA', 'AGUA', 'ADIOS', 'GRACIAS'])
        MapEntry(0.3, Template('id_$g', g, seq)),
    ];

    test('aceptada: sin la ganadora, hasta 3', () {
      final alt = alternativasDe(_pred(.2, .3), t);
      expect(alt.map((e) => e.value.gloss), ['AGUA', 'ADIOS', 'GRACIAS']);
    });

    test('rechazada: la mas parecida tambien se ofrece', () {
      final alt = alternativasDe(_pred(.9, .3), t);
      expect(alt.map((e) => e.value.gloss), ['HOLA', 'AGUA', 'ADIOS']);
    });

    test('texto de una plantilla: espanol o la glosa legible', () {
      expect(textoDePlantilla(Template('x', 'COMO_ESTAS', seq)), 'como estas');
      expect(textoDePlantilla(Template('x', 'HOLA', seq, espanol: 'Hola')),
          'Hola');
    });
  });
}
