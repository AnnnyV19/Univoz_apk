/// Registro local de errores no capturados: <documentos>/errores.jsonl.
///
/// Una linea JSON por error (hora, error, repeticiones y las primeras 20
/// lineas de la pila). Sin servicios externos: el archivo se queda en el
/// telefono y solo sale si alguien lo comparte a mano desde Configuracion
/// (modo desarrollador). Pasa de [maxBytes] -> el archivo pasa a
/// errores.jsonl.1 (una sola generacion vieja) y se empieza de nuevo.
///
/// La PRIMERA vez que aparece un error se escribe al instante (si el proceso
/// muere, la causa ya esta en disco). Un error que se repite (tipico: una
/// excepcion de pintado que salta en cada frame) no se vuelve a escribir en
/// cada repeticion: se cuentan y, al pasar la [ventana] (o al llamar a
/// [volcar], p. ej. cuando la app pasa a segundo plano), se agrega UNA linea
/// resumen con `repeticiones`. Sin eso llenaria el archivo en segundos y
/// borraria la causa original.
library registro_errores;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

const String kArchivoErrores = 'errores.jsonl';
const int kMaxBytesErrores = 1024 * 1024;
const int kLineasPila = 20;
const Duration kVentanaErrores = Duration(seconds: 10);
const int _kMaxCharsError = 2000;

/// Errores distintos que se juntan a la vez antes de escribir el mas viejo.
const int _kMaxDistintos = 20;

/// Escrituras pendientes de disco; pasado esto se descartan (y se cuentan).
const int _kMaxEnCola = 100;

class _Pendiente {
  _Pendiente(this.clave, this.primera, this.texto, this.pila);
  final String clave;
  final DateTime primera;
  final String texto;
  final String? pila;
  DateTime? ultima;
  int n = 1;
  Timer? timer;
}

class RegistroErrores {
  RegistroErrores({
    Future<Directory> Function()? directorio,
    this.maxBytes = kMaxBytesErrores,
    this.ventana = kVentanaErrores,
  }) : _directorio = directorio ?? getApplicationDocumentsDirectory;

  /// El registro de la app.
  static final RegistroErrores instancia = RegistroErrores();

  final Future<Directory> Function() _directorio;
  final int maxBytes;
  final Duration ventana;

  final Map<String, _Pendiente> _pendientes = {};
  // Escrituras en fila: dos errores seguidos no se mezclan en una linea.
  Future<void> _cola = Future<void>.value();
  int _enCola = 0;
  int _descartados = 0;

  /// Anota un error. Nunca lanza: un fallo al registrar no puede causar
  /// otro error. Un error igual (tipo + mensaje + primera linea de la pila)
  /// dentro de la ventana solo suma una repeticion.
  Future<void> registrar(Object error, StackTrace? pila, {DateTime? ahora}) {
    try {
      var texto = _aTexto(error);
      if (texto.length > _kMaxCharsError) {
        texto = '${texto.substring(0, _kMaxCharsError)}...';
      }
      final lineas = pila?.toString().trimRight().split('\n');
      final clave = '${error.runtimeType}|$texto|'
          '${lineas == null || lineas.isEmpty ? '' : lineas.first}';
      final existente = _pendientes[clave];
      if (existente != null) {
        existente.n++;
        existente.ultima = ahora ?? DateTime.now();
        return _cola;
      }
      if (_pendientes.length >= _kMaxDistintos) {
        _cerrar(_pendientes.values.first);
      }
      final nuevo = _Pendiente(clave, ahora ?? DateTime.now(), texto,
          lineas?.take(kLineasPila).join('\n'));
      nuevo.timer = Timer(ventana, () => _cerrar(nuevo));
      _pendientes[clave] = nuevo;
      // La primera vez, ya.
      _encolar(nuevo, resumen: false);
    } catch (_) {}
    return _cola;
  }

  /// Un error cuyo toString() lanza no debe tumbar el registro.
  static String _aTexto(Object error) {
    try {
      return '$error';
    } catch (_) {
      return '<${error.runtimeType}: toString() fallo>';
    }
  }

  /// Cierra la ventana de [p]: si hubo repeticiones, escribe el resumen.
  void _cerrar(_Pendiente p) {
    if (_pendientes[p.clave] != p) return;
    _pendientes.remove(p.clave);
    p.timer?.cancel();
    if (p.n > 1) _encolar(p, resumen: true);
  }

  void _encolar(_Pendiente p, {required bool resumen}) {
    if (_enCola >= _kMaxEnCola) {
      _descartados += resumen ? p.n - 1 : 1;
      return;
    }
    final descartados = _descartados;
    _descartados = 0;
    final linea = jsonEncode({
      't': p.primera.toUtc().toIso8601String(),
      'error': p.texto,
      'repeticiones': resumen ? p.n : 1,
      if (resumen) 'resumen': true,
      if (resumen && p.ultima != null)
        'ultima': p.ultima!.toUtc().toIso8601String(),
      if (descartados > 0) 'descartados_antes': descartados,
      if (!resumen && p.pila != null) 'stack': p.pila,
    });
    _enCola++;
    _cola = _cola.then((_) => _agregar(linea)).whenComplete(() => _enCola--);
  }

  /// Cierra ya las ventanas abiertas (escribe los resumenes de repeticiones)
  /// y espera al disco. Se llama al compartir y al pasar a segundo plano.
  Future<void> volcar() {
    for (final p in List.of(_pendientes.values)) {
      _cerrar(p);
    }
    return _cola;
  }

  Future<void> _agregar(String linea) async {
    try {
      final dir = await _directorio();
      final f = File('${dir.path}/$kArchivoErrores');
      if (await f.exists() &&
          await f.length() + linea.length + 1 > maxBytes) {
        final vieja = File('${f.path}.1');
        if (await vieja.exists()) await vieja.delete();
        await f.rename(vieja.path);
      }
      await f.writeAsString('$linea\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// El archivo a compartir, o null si todavia no hay errores anotados.
  Future<File?> archivoParaCompartir() async {
    await volcar();
    try {
      final f = File('${(await _directorio()).path}/$kArchivoErrores');
      return await f.exists() && await f.length() > 0 ? f : null;
    } catch (_) {
      return null;
    }
  }

  /// Engancha los dos puntos por donde se cuelan los errores de Flutter y
  /// el cierre de ventanas al pasar a segundo plano (requiere el binding
  /// inicializado). En debug sigue mostrandolos en consola como siempre.
  void instalarManejadores() {
    // Idempotente: una segunda llamada no duplica el observador.
    if (_instalado) return;
    _instalado = true;
    FlutterError.onError = (detalles) {
      unawaited(registrar(detalles.exception, detalles.stack));
      if (kDebugMode) FlutterError.presentError(detalles);
    };
    PlatformDispatcher.instance.onError = (error, pila) {
      unawaited(registrar(error, pila));
      // En debug se deja el error sin marcar para que la consola lo muestre.
      return !kDebugMode;
    };
    // Al final: sin el binding inicializado esto lanza, y para entonces los
    // dos manejadores ya estan puestos.
    WidgetsBinding.instance.addObserver(ObservadorRegistroErrores(this));
  }

  bool _instalado = false;
}

/// Al pasar a segundo plano o cerrarse la app, escribe los resumenes de
/// repeticiones pendientes: Android puede matar el proceso sin avisar.
class ObservadorRegistroErrores with WidgetsBindingObserver {
  ObservadorRegistroErrores(this.registro);
  final RegistroErrores registro;

  @override
  void didChangeAppLifecycleState(AppLifecycleState estado) {
    if (estado == AppLifecycleState.paused ||
        estado == AppLifecycleState.detached) {
      unawaited(registro.volcar());
    }
  }
}
