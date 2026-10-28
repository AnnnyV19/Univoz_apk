import 'package:flutter/material.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/avatar_vista.dart';
import 'package:senas_core/avatar_toma.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/tema_univoz.dart';

/// Quien maneja el avatar de una pantalla de "Aprender": carga el
/// diccionario, reproduce señas (una o varias seguidas) y recuerda la
/// velocidad.
///
/// La velocidad es una sola para toda la app mientras esté abierta: si
/// alguien aprende mejor a 0.5×, no debería tener que volver a ponerla en
/// cada ejercicio.
class ControladorVisor extends ChangeNotifier {
  final AvatarBridge bridge = AvatarBridge();

  static double _ultimaVelocidad = 1.0;
  static const double velocidadMin = 0.5;
  static const double velocidadMax = 2.0;

  /// Las secuencias se arman una vez por versión del diccionario: grabar,
  /// borrar o sincronizar la sube y la siguiente pantalla ve lo nuevo (y
  /// suelta las `seq` del diccionario anterior).
  static (int, Future<Map<String, List<List<double>>>>)? _cacheSecuencias;

  Map<String, List<List<double>>> _secuencias = const {};
  double _velocidad = _ultimaVelocidad;
  bool _listo = false;
  bool _reproduciendo = false;
  bool _descartado = false;

  List<String> _cola = const [];
  int _indice = 0;
  int _generacion = 0;
  DateTime _ultimoInicio = DateTime.fromMillisecondsSinceEpoch(0);

  ControladorVisor() {
    bridge.onTerminado = _alTerminar;
    // Aprender muestra al avatar en una tarjeta chica: de los codos para
    // arriba se lee mucho mejor la seña que de cuerpo entero.
    bridge.encuadrar(AvatarBridge.encuadreCodos);
  }

  double get velocidad => _velocidad;
  bool get listo => _listo;
  bool get reproduciendo => _reproduciendo;

  /// Posición (desde 1) de la glosa que se está haciendo y cuántas son.
  int get posicion => _indice + 1;
  int get total => _cola.length;

  /// Si el diccionario tiene la seña de [glosa].
  bool tiene(String glosa) => _secuencias.containsKey(glosa);

  static Future<Map<String, List<List<double>>>> _leerSecuencias() {
    final version = AlmacenMuestras.instancia.versionDiccionario;
    final previo = _cacheSecuencias;
    if (previo != null && previo.$1 == version) return previo.$2;
    final futuro = () async {
      final d = await cargarDiccionario();
      final out = <String, List<List<double>>>{};
      for (final t in d.clasificador.templates) {
        // Si hay varias muestras de la misma seña, la primera: es lo que
        // hace PantallaAvatar y mantiene las dos pantallas coherentes.
        out.putIfAbsent(t.gloss, () => t.seq);
      }
      return out;
    }();
    _cacheSecuencias = (version, futuro);
    return futuro;
  }

  Future<void> iniciar() async {
    try {
      final almacen = AlmacenMuestras.instancia;
      await almacen.cargar();
      await bridge.configurarRig(almacen.ajustes.rigCalibration);
    } catch (_) {
      // Sin la calibración guardada el avatar se ve con la de fábrica.
    }
    try {
      _secuencias = await _leerSecuencias();
    } catch (_) {
      _cacheSecuencias = null; // que el próximo intento vuelva a leerlo
    }
    if (_descartado) return;
    _listo = true;
    notifyListeners();
  }

  void cambiarVelocidad(double v) {
    _velocidad = v.clamp(velocidadMin, velocidadMax).toDouble();
    _ultimaVelocidad = _velocidad;
    notifyListeners();
  }

  /// Hace una sola seña.
  Future<void> senar(String glosa) => senarVarias([glosa]);

  /// Hace varias señas una tras otra (para deletrear).
  Future<void> senarVarias(List<String> glosas) async {
    _generacion++;
    _cola = List<String>.from(glosas);
    _indice = 0;
    await _reproducirActual();
  }

  /// Vuelve a hacer lo último desde el principio, con la velocidad de ahora.
  Future<void> repetir() async {
    if (_cola.isEmpty) return;
    await senarVarias(_cola);
  }

  Future<void> _reproducirActual() async {
    final gen = _generacion;
    if (_indice >= _cola.length) {
      _reproduciendo = false;
      notifyListeners();
      return;
    }
    final cruda = _secuencias[_cola[_indice]];
    if (cruda == null) {
      _reproduciendo = false;
      notifyListeners();
      return;
    }
    // Copia para el visor sin el tiempo muerto del principio y del final (si
    // lo tiene): varias señas traen la mano ausente la mitad de los cuadros y
    // el avatar parecía no hacer nada. No toca la plantilla ni las alturas.
    final seq = prepararParaAvatar(cruda);
    _reproduciendo = true;
    notifyListeners();
    _ultimoInicio = DateTime.now();

    // Las plantillas son de 32 cuadros: a 30 por segundo dura poco más de
    // un segundo. Cambiar los cuadros por segundo es cambiar la velocidad.
    // Una seña suelta que es casi una pose fija (la mayoría de las letras) se
    // muestra un poco más despacio; al deletrear varias seguidas, no.
    final factor = _cola.length == 1 ? factorVelocidadSena(seq) : 1.0;
    final fps = (30 * _velocidad * factor).round().clamp(8, 60).toInt();

    // El visor tarda en arrancar (carga el modelo 3D). Mientras la página
    // no responde, reintentar en vez de fallar la primera vez.
    for (var i = 0; i < 25; i++) {
      if (gen != _generacion || _descartado) return;
      try {
        await bridge.reproducir(seq, fps: fps);
        return;
      } on FormatException {
        break; // la secuencia no es válida: reintentar no la arregla
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (gen == _generacion && !_descartado) {
      _reproduciendo = false;
      notifyListeners();
    }
  }

  Future<void> _alTerminar() async {
    if (_descartado) return;
    // Cortar una seña a la mitad también avisa "fin": ese aviso llega
    // enseguida, y una seña de verdad dura más de esto incluso a 2×.
    if (DateTime.now().difference(_ultimoInicio) <
        const Duration(milliseconds: 200)) {
      return;
    }
    final gen = _generacion;
    if (_indice + 1 < _cola.length) {
      _indice++;
      notifyListeners();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (gen != _generacion || _descartado) return;
      await _reproducirActual();
    } else {
      _reproduciendo = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _descartado = true;
    _generacion++;
    bridge.dispose();
    super.dispose();
  }
}

/// El avatar con su barra de velocidad. Es EL widget para mostrar al avatar
/// en "Aprender": la barra viene incluida, así que ninguna pantalla puede
/// olvidarla.
class VisorSena extends StatelessWidget {
  final ControladorVisor controlador;
  final double alto;

  /// Texto chiquito arriba a la izquierda ("Letra 3 de 4").
  final String? etiqueta;

  const VisorSena({
    super.key,
    required this.controlador,
    this.alto = 268,
    this.etiqueta,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controlador,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: alto,
              width: double.infinity,
              decoration: BoxDecoration(
                color: ColoresUnivoz.moradoTenue,
                borderRadius: BorderRadius.circular(22),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: VistaAvatar(bridge: controlador.bridge),
                    ),
                    if (!controlador.listo)
                      const Positioned.fill(
                        child: Center(
                          child: CircularProgressIndicator(
                            color: ColoresUnivoz.morado,
                          ),
                        ),
                      ),
                    if (etiqueta != null)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            etiqueta!,
                            style: const TextStyle(
                              color: ColoresUnivoz.moradoOscuro,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: Semantics(
                        button: true,
                        label: 'Repetir la seña',
                        child: GestureDetector(
                          onTap: controlador.listo ? controlador.repetir : null,
                          child: Container(
                            width: 46,
                            height: 46,
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x2E3C2864),
                                  blurRadius: 6,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.replay,
                                color: ColoresUnivoz.morado, size: 22),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            BarraVelocidadSenas(controlador: controlador),
          ],
        );
      },
    );
  }
}

/// La barra de velocidad de las señas: de 0.5× (despacio, para ver bien la
/// forma de la mano) a 2×. Al soltarla, la seña se repite a la velocidad
/// nueva para que se vea el efecto de inmediato.
class BarraVelocidadSenas extends StatelessWidget {
  final ControladorVisor controlador;

  const BarraVelocidadSenas({super.key, required this.controlador});

  static String _texto(double v) {
    final t = v
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return '$t×';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.speed, size: 20, color: ColoresUnivoz.tintaSuave),
        const SizedBox(width: 6),
        const Text(
          'Velocidad',
          style: TextStyle(
            color: ColoresUnivoz.tinta,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        Expanded(
          child: Slider(
            value: controlador.velocidad,
            min: ControladorVisor.velocidadMin,
            max: ControladorVisor.velocidadMax,
            divisions: 6, // 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2
            label: _texto(controlador.velocidad),
            activeColor: ColoresUnivoz.morado,
            onChanged: controlador.cambiarVelocidad,
            onChangeEnd: (_) {
              if (controlador.listo) controlador.repetir();
            },
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            _texto(controlador.velocidad),
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: ColoresUnivoz.moradoOscuro,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
