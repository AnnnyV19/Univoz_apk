/// Guia de encuadre en vivo de "Reconocer seña": una pastilla sobre la
/// camara que dice que acomodar ("Aléjate un poco", "Mano fuera de
/// cuadro"...) y una silueta de referencia mientras no hay nadie en cuadro.
///
/// Las pistas salen de las mismas validaciones por frame que decide si un
/// frame sirve (sign_norm.dart: visibilidad de hombros, poseGeometriaValida,
/// manoUtilizable). No hay pista de luz: el pipeline no da una senal de poca
/// luz distinguible de "no veo tus hombros".
library guia_encuadre;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../camera_bridge.dart';
import '../sign_norm.dart'
    show
        kLShoulder,
        kMargenCuerpo,
        kMinVisibility,
        kRShoulder,
        manoUtilizable,
        poseGeometriaValida;

const String kPistaAlejate = 'Aléjate un poco';
const String kPistaSinHombros = 'No veo tus hombros';
const String kPistaAcercate = 'Acércate un poco';
const String kPistaManoFuera = 'Mano fuera de cuadro';
const String kPistaMunecaOculta = 'Brazos a la altura del pecho, muñecas a la vista';

const int _kMunecaIzq = 15;
const int _kMunecaDer = 16;

/// Ancho de hombros, medido contra el lado corto de la imagen, por debajo
/// del cual la persona esta lejos (las manos quedan de pocos pixeles).
const double kHombrosMinimo = 0.15;

/// Por encima de este ancho la persona esta tan cerca que las senas junto a
/// la cara o a los lados se salen del cuadro.
const double kHombrosMaximo = 0.70;

const int _kNariz = 0;

bool _visible(List<double> p) => p.length >= 4 && p[3] >= kMinVisibility;

bool _finito(List<double> p) =>
    p.length >= 2 && p[0].isFinite && p[1].isFinite;

bool _dentroConMargen(List<double> p) =>
    p[0] >= -kMargenCuerpo &&
    p[0] <= 1 + kMargenCuerpo &&
    p[1] >= -kMargenCuerpo &&
    p[1] <= 1 + kMargenCuerpo;

/// Hay alguien frente a la camara: pose con la nariz o algun hombro visible.
/// Sin persona no se da pista de encuadre; se muestra la silueta.
bool personaDetectada(LandmarkFrame? f) {
  final pose = f?.pose;
  if (pose == null || pose.length < 33) return false;
  return [_kNariz, kLShoulder, kRShoulder]
      .any((i) => _finito(pose[i]) && _visible(pose[i]));
}

/// Que tiene que acomodar la persona para que el frame sirva, o null si esta
/// bien (o si no hay nadie: ver [personaDetectada]). Por prioridad: primero
/// el cuerpo (sin hombros no hay reconocimiento), despues las manos.
String? pistaEncuadre(LandmarkFrame? f) {
  if (!personaDetectada(f)) return null;
  final pose = f!.pose!;
  final ls = pose[kLShoulder];
  final rs = pose[kRShoulder];

  // Hombros mas alla del borde: demasiado cerca (o corrido a un lado).
  for (final h in [ls, rs]) {
    if (_finito(h) && !_dentroConMargen(h)) return kPistaAlejate;
  }
  if (!_finito(ls) || !_finito(rs) || !_visible(ls) || !_visible(rs)) {
    return kPistaSinHombros;
  }
  // Ancho de hombros contra el lado corto de la imagen: en horizontal la x
  // normalizada encoge con el ancho.
  final aspecto = f.imageAspect ?? 0.75;
  final ancho = (rs[0] - ls[0]).abs() * math.max(1.0, aspecto);
  if (ancho > kHombrosMaximo) return kPistaAlejate;

  // Misma geometria que decide si el frame sirve para reconocer.
  final geometria = poseGeometriaValida(pose, f.poseMundo);
  if (!geometria.ok) {
    switch (geometria.code) {
      case 'shoulder_out_of_frame':
        return kPistaAlejate;
      case 'pose_anchor_unsafe':
        return kPistaSinHombros;
    }
  }
  if (ancho < kHombrosMinimo) return kPistaAcercate;

  // Solo manos que el detector ve: las que descansan abajo, fuera de la
  // imagen, no son un problema.
  for (final mano in [f.left, f.right]) {
    if (mano == null) continue;
    final v = manoUtilizable(mano);
    if (v.code == 'wrist_out_of_frame' || v.code == 'hand_out_of_frame') {
      return kPistaManoFuera;
    }
  }
  // Muneca dentro de la imagen pero con visibilidad baja y sin mano
  // detectada de ese lado: brazo tapado o muy bajo. Es la causa nº 1 de manos
  // perdidas durante la seña (vis_mun <= 0.4). Los brazos que descansan
  // abajo salen del cuadro y no entran aqui.
  if (pose.length > _kMunecaDer) {
    final lados = [(_kMunecaIzq, f.left), (_kMunecaDer, f.right)];
    for (final (i, mano) in lados) {
      final m = pose[i];
      if (mano == null && _finito(m) && m.length >= 4 && !_visible(m)) {
        if (m[0] >= 0 && m[0] <= 1 && m[1] >= 0 && m[1] <= 1) {
          return kPistaMunecaOculta;
        }
      }
    }
  }
  return null;
}

/// Evita que la pista parpadee con el ruido de cada frame: una pista se
/// muestra si la MISMA dura [mostrarTras] seguidos, y se quita tras
/// [ocultarTras] seguidos sin problema. Mientras otra pista madura, la
/// visible se queda. Tiempos en ms de cualquier reloj monotono.
class HisteresisPista {
  HisteresisPista({
    this.mostrarTras = const Duration(seconds: 1),
    this.ocultarTras = const Duration(milliseconds: 500),
  });

  final Duration mostrarTras;
  final Duration ocultarTras;

  String? _visible;
  String? _candidata;
  int? _candidataDesde;
  int? _okDesde;
  int? _ultimoMs;

  String? get visible => _visible;

  /// Pasa la pista del frame actual ([pista] null = todo bien) en
  /// [ahoraMs]; devuelve la que hay que mostrar.
  String? actualizar(String? pista, int ahoraMs) {
    final ultimo = _ultimoMs;
    _ultimoMs = ahoraMs;
    if (ultimo != null && ahoraMs < ultimo) {
      // Reloj hacia atras (camara reiniciada): se empieza de nuevo.
      limpiar();
      _ultimoMs = ahoraMs;
    }
    if (pista == null) {
      _candidata = null;
      _candidataDesde = null;
      final ok = _okDesde ??= ahoraMs;
      if (ahoraMs - ok >= ocultarTras.inMilliseconds) _visible = null;
      return _visible;
    }
    _okDesde = null;
    if (pista != _candidata) {
      _candidata = pista;
      _candidataDesde = ahoraMs;
    }
    if (ahoraMs - _candidataDesde! >= mostrarTras.inMilliseconds) {
      _visible = pista;
    }
    return _visible;
  }

  /// Quita la pista ya (camara reiniciada, pantalla en error).
  void limpiar() {
    _visible = null;
    _candidata = null;
    _candidataDesde = null;
    _okDesde = null;
    _ultimoMs = null;
  }
}

/// Capa sobre la vista de la camara: silueta mientras no hay nadie y la
/// pastilla de encuadre. Escucha [frame] (el preview, ~30 FPS) por su cuenta
/// y solo se reconstruye cuando cambia lo que se ve.
class GuiaEncuadre extends StatefulWidget {
  const GuiaEncuadre({super.key, required this.frame, this.ahora});

  final ValueListenable<LandmarkFrame?> frame;

  /// Reloj en ms; solo para pruebas.
  final int Function()? ahora;

  @override
  State<GuiaEncuadre> createState() => _GuiaEncuadreState();
}

class _GuiaEncuadreState extends State<GuiaEncuadre> {
  final _pista = HisteresisPista();
  // La silueta aparece tras medio segundo sin nadie y se va en cuanto hay
  // alguien: sin parpadeos cuando la deteccion duda un frame.
  final _sinPersona = HisteresisPista(
    mostrarTras: const Duration(milliseconds: 500),
    ocultarTras: Duration.zero,
  );
  final _reloj = Stopwatch()..start();
  String? _texto;
  bool _silueta = false;

  int _ahora() => widget.ahora?.call() ?? _reloj.elapsedMilliseconds;

  @override
  void initState() {
    super.initState();
    widget.frame.addListener(_alFrame);
    _alFrame();
  }

  @override
  void didUpdateWidget(GuiaEncuadre viejo) {
    super.didUpdateWidget(viejo);
    if (viejo.frame != widget.frame) {
      viejo.frame.removeListener(_alFrame);
      widget.frame.addListener(_alFrame);
    }
  }

  @override
  void dispose() {
    widget.frame.removeListener(_alFrame);
    super.dispose();
  }

  void _alFrame() {
    final f = widget.frame.value;
    final ahora = _ahora();
    final texto = _pista.actualizar(pistaEncuadre(f), ahora);
    final silueta =
        _sinPersona.actualizar(personaDetectada(f) ? null : 'sin_persona', ahora) !=
            null;
    if (texto == _texto && silueta == _silueta) return;
    setState(() {
      _texto = texto;
      _silueta = silueta;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final sinAnimacion = MediaQuery.disableAnimationsOf(context);
    final duracion =
        sinAnimacion ? Duration.zero : const Duration(milliseconds: 250);
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: _silueta ? 1 : 0,
            duration: duracion,
            child: CustomPaint(
              painter: SiluetaGuiaPainter(
                color: colores.surfaceContainerLowest.withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
        Positioned(
          left: 6,
          right: 6,
          top: 8,
          child: Center(
            child: AnimatedSwitcher(
              duration: duracion,
              child: _texto == null
                  ? const SizedBox.shrink(key: ValueKey('sin_pista_encuadre'))
                  : _Pastilla(key: ValueKey(_texto), texto: _texto!),
            ),
          ),
        ),
      ],
    );
  }
}

class _Pastilla extends StatelessWidget {
  const _Pastilla({super.key, required this.texto});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final colores = tema.colorScheme;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colores.inverseSurface.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.center_focus_weak,
                  size: 16, color: colores.onInverseSurface),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  texto,
                  textAlign: TextAlign.center,
                  style: tema.textTheme.labelLarge
                      ?.copyWith(color: colores.onInverseSurface),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Contorno de cabeza y hombros donde conviene pararse: lo que la camara
/// necesita ver (hombros y el espacio de las manos).
class SiluetaGuiaPainter extends CustomPainter {
  SiluetaGuiaPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final lado = size.shortestSide;
    final cx = size.width / 2;
    final radioCabeza = lado * 0.12;
    final centroCabeza = Offset(cx, size.height * 0.36);
    final hombrosY = centroCabeza.dy + radioCabeza * 2.0;
    final medioAncho = lado * 0.30;
    final trazo = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(
        Rect.fromCenter(
            center: centroCabeza,
            width: radioCabeza * 1.7,
            height: radioCabeza * 2.1),
        trazo);
    final cuello = centroCabeza.dy + radioCabeza * 1.1;
    final hombros = Path()
      ..moveTo(cx - medioAncho, size.height * 0.98)
      ..lineTo(cx - medioAncho, hombrosY + lado * 0.08)
      ..quadraticBezierTo(
          cx - medioAncho, hombrosY, cx - medioAncho * 0.55, hombrosY)
      ..quadraticBezierTo(cx - radioCabeza * 0.5, hombrosY,
          cx - radioCabeza * 0.45, cuello)
      ..moveTo(cx + radioCabeza * 0.45, cuello)
      ..quadraticBezierTo(cx + radioCabeza * 0.5, hombrosY,
          cx + medioAncho * 0.55, hombrosY)
      ..quadraticBezierTo(
          cx + medioAncho, hombrosY, cx + medioAncho, hombrosY + lado * 0.08)
      ..lineTo(cx + medioAncho, size.height * 0.98);
    canvas.drawPath(hombros, trazo);
  }

  @override
  bool shouldRepaint(SiluetaGuiaPainter viejo) => viejo.color != color;
}
