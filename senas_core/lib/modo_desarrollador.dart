/// Modo desarrollador: muestra herramientas de diagnostico (captura de
/// muestras, espejo, numeros del reconocedor) que la persona normal no
/// necesita. Apagado por defecto; se activa tocando 7 veces la version de la
/// app (DetectorModoDesarrollador) y se recuerda entre aperturas.
///
/// Vive en senas_core porque univoz depende de senas_core y no al reves:
/// cualquier pantalla de los dos paquetes lee ModoDesarrollador.activo o se
/// reconstruye con ModoDesarrollador.notificador.
library modo_desarrollador;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'muestras_locales.dart';

class ModoDesarrollador {
  ModoDesarrollador._();

  static const String _kArchivo = 'modo_desarrollador.json';

  /// Cambia cada vez que se enciende o apaga; para ValueListenableBuilder.
  static final ValueNotifier<bool> notificador = ValueNotifier<bool>(false);

  /// Estado actual. Lo que hace falta leer desde cualquier pantalla.
  static bool get activo => notificador.value;

  /// Solo para pruebas: carpeta donde vive el archivo en lugar de la de
  /// documentos de la app (path_provider no existe en `flutter test`).
  static Future<Directory> Function()? directorioParaPruebas;

  static void restablecerParaPruebas() => notificador.value = false;

  static Future<File> _ruta() async {
    final dir = directorioParaPruebas != null
        ? await directorioParaPruebas!()
        : await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_kArchivo');
  }

  /// Lee el valor guardado. Se llama una vez al arrancar, antes de runApp.
  /// Cualquier problema (sin archivo, corrupto) deja el modo apagado.
  static Future<void> cargar() async {
    try {
      final f = await _ruta();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        notificador.value = j is Map && j['activo'] == true;
      }
    } catch (_) {
      notificador.value = false;
    }
    // Un diagnostico guardado de antes (cuando nada lo ocultaba) no debe
    // seguir activo sin forma de apagarlo.
    if (!activo) await _apagarDiagnosticos();
  }

  /// Los ajustes de diagnostico solo se ven con el modo encendido: al
  /// apagarlo se desactivan para que no queden activos sin que nadie pueda
  /// verlos. La calibracion del avatar (RigBody) se conserva: es un ajuste
  /// de uso, no un diagnostico.
  static Future<void> _apagarDiagnosticos() async {
    try {
      final almacen = AlmacenMuestras.instancia;
      await almacen.cargar();
      if (almacen.ajustes.rigDiagnosticMode) {
        await almacen.guardarAjustes(
            almacen.ajustes.copiar()..rigDiagnosticMode = false);
      }
    } catch (_) {}
  }

  /// Enciende el modo solo en memoria, sin guardarlo ni tocar lo guardado.
  /// Para la app de desarrollo de senas_core, que es una herramienta de
  /// desarrollador y no tiene donde tocar la version para activarlo.
  static void forzarActivo() => notificador.value = true;

  /// Cambia el modo en memoria al instante (la UI reacciona de inmediato) y
  /// lo guarda despues. Un fallo al guardar no deshace el cambio: solo se
  /// perderia al cerrar la app.
  static Future<void> establecer(bool valor) async {
    notificador.value = valor;
    try {
      final f = await _ruta();
      await f.writeAsString(jsonEncode({'v': 1, 'activo': valor}));
    } catch (_) {}
    if (!valor) await _apagarDiagnosticos();
  }

  /// Invierte el modo y devuelve el nuevo valor.
  static Future<bool> alternar() async {
    final nuevo = !activo;
    await establecer(nuevo);
    return nuevo;
  }
}

/// Envuelve un texto (la version de la app) y lo vuelve el interruptor
/// secreto: [toques] seguidos, con menos de [ventana] entre uno y otro,
/// alternan el modo y avisan con un SnackBar.
class DetectorModoDesarrollador extends StatefulWidget {
  const DetectorModoDesarrollador({
    super.key,
    required this.child,
    this.toques = 7,
    this.ventana = const Duration(seconds: 3),
  });

  final Widget child;
  final int toques;
  final Duration ventana;

  @override
  State<DetectorModoDesarrollador> createState() =>
      _DetectorModoDesarrolladorState();
}

class _DetectorModoDesarrolladorState extends State<DetectorModoDesarrollador> {
  int _cuenta = 0;
  Timer? _reinicio;

  @override
  void dispose() {
    _reinicio?.cancel();
    super.dispose();
  }

  void _alTocar() {
    // Cada toque rearma el reloj: si pasa [ventana] sin otro, la cuenta
    // vuelve a cero.
    _reinicio?.cancel();
    _reinicio = Timer(widget.ventana, () => _cuenta = 0);
    _cuenta++;
    if (_cuenta < widget.toques) return;
    _cuenta = 0;
    _reinicio?.cancel();
    final activar = !ModoDesarrollador.activo;
    ModoDesarrollador.establecer(activar);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(activar
            ? 'Modo desarrollador activado'
            : 'Modo desarrollador desactivado'),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _alTocar,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(widthFactor: 1, child: widget.child),
      ),
    );
  }
}
