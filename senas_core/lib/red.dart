/// Pedidos HTTP seguros: tiempo maximo, un reintento para lecturas y
/// errores con mensajes humanos.
///
/// Todo lo que sale a la red (Supabase, backend de IA) pasa por aca para que
/// una conexion mala nunca deje la app colgada ni le muestre a la persona un
/// texto tecnico ("SocketException: OS Error ...").
///
/// - Tiempo maximo: [kTimeoutRed] (10 s); las subidas a Storage usan
///   [kTimeoutSubida] (30 s).
/// - Un solo reintento, con espera, y SOLO para GET: leer dos veces es
///   inocuo, pero repetir un POST podria crear la muestra dos veces.
/// - Cualquier fallo se traduce a [FalloRed], cuyo `mensaje` ya esta listo
///   para mostrarse. El detalle tecnico queda en `tecnico` (solo modo
///   desarrollador, ver [mensajeHumano]).
library red;

import 'dart:async';
import 'dart:io' show SocketException, TlsException;

import 'package:http/http.dart' as http;

const Duration kTimeoutRed = Duration(seconds: 10);

/// Tiempo maximo de la descarga del diccionario (varios MB, la respuesta
/// completa): con 10 s hacen falta ~2.4 Mbps y en datos lentos nunca llegaba.
const Duration kTimeoutDescargaDiccionario = Duration(seconds: 60);
const Duration kTimeoutSubida = Duration(seconds: 30);
const Duration kEsperaReintento = Duration(milliseconds: 800);

const String kMsgSinConexion =
    'Sin conexión. Revisa tu internet e inténtalo de nuevo.';
const String kMsgTimeout = 'El servidor tardó demasiado. Inténtalo más tarde.';
const String kMsgSinPermiso = 'No tienes permiso para esta acción.';
const String kMsgServidor =
    'El servidor tuvo un problema. Inténtalo más tarde.';
const String kMsgGenerico = 'Algo salió mal. Inténtalo de nuevo.';

/// Error que ya trae un mensaje apto para mostrar a cualquier persona.
abstract interface class ErrorHumano {
  String get mensajeHumano;
}

/// Un pedido de red que fallo. `mensaje` es humano; `tecnico` es el detalle
/// crudo y NO debe mostrarse fuera del modo desarrollador.
class FalloRed implements Exception, ErrorHumano {
  final String mensaje;
  final String tecnico;
  final int? estado;

  const FalloRed(this.mensaje, {this.tecnico = '', this.estado});

  @override
  String get mensajeHumano => mensaje;

  @override
  String toString() => mensaje;
}

/// Mensaje humano para un codigo HTTP de error.
String mensajeDeEstado(int estado) => switch (estado) {
      401 || 403 => kMsgSinPermiso,
      >= 500 => kMsgServidor,
      408 || 429 => 'El servidor está ocupado. Inténtalo en unos segundos.',
      _ => 'No se pudo completar. Revisa tu conexión e inténtalo de nuevo.',
    };

/// Respuesta HTTP de error -> [FalloRed]. Nunca copia el cuerpo: puede traer
/// SQL, politicas o datos internos del servidor.
FalloRed falloDeRespuesta(http.Response r) => FalloRed(
      mensajeDeEstado(r.statusCode),
      tecnico: 'HTTP ${r.statusCode}',
      estado: r.statusCode,
    );

/// Excepcion de red/tiempo -> [FalloRed] con el mensaje humano que toca.
FalloRed falloDeExcepcion(Object e) {
  if (e is FalloRed) return e;
  if (e is TimeoutException) {
    return FalloRed(kMsgTimeout, tecnico: '$e');
  }
  if (e is SocketException || e is http.ClientException || e is TlsException) {
    return FalloRed(kMsgSinConexion, tecnico: '$e');
  }
  return FalloRed(kMsgGenerico, tecnico: '$e');
}

/// Texto para mostrar al usuario ante cualquier error. Con [dev] (modo
/// desarrollador) agrega el detalle tecnico; sin el, jamas.
String mensajeHumano(Object e, {bool dev = false}) {
  if (e is FalloRed) {
    return dev && e.tecnico.isNotEmpty ? '${e.mensaje} (${e.tecnico})' : e.mensaje;
  }
  if (e is ErrorHumano && !dev) return e.mensajeHumano;
  if (dev) return '$e';
  return falloDeExcepcion(e).mensaje;
}

bool _esFalloDeRed(Object e) =>
    e is TimeoutException ||
    e is SocketException ||
    e is http.ClientException ||
    e is TlsException;

/// GET con tiempo maximo y [reintentos] reintento(s) tras [espera] si hubo
/// un fallo de red o un 5xx. Un 4xx se devuelve sin reintentar. Si todo
/// falla por red lanza [FalloRed]; un 5xx persistente se devuelve para que
/// quien llama lo traduzca con [falloDeRespuesta].
Future<http.Response> redGet(
  http.Client cliente,
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = kTimeoutRed,
  int reintentos = 1,
  Duration espera = kEsperaReintento,
}) async {
  var intento = 0;
  while (true) {
    try {
      final r = await cliente.get(uri, headers: headers).timeout(timeout);
      if (r.statusCode >= 500 && intento < reintentos) {
        intento++;
        await Future<void>.delayed(espera);
        continue;
      }
      return r;
    } catch (e) {
      if (_esFalloDeRed(e) && intento < reintentos) {
        intento++;
        await Future<void>.delayed(espera);
        continue;
      }
      throw falloDeExcepcion(e);
    }
  }
}

/// POST con tiempo maximo y SIN reintento (no es idempotente).
Future<http.Response> redPost(
  http.Client cliente,
  Uri uri, {
  Map<String, String>? headers,
  Object? body,
  Duration timeout = kTimeoutRed,
}) async {
  try {
    return await cliente
        .post(uri, headers: headers, body: body)
        .timeout(timeout);
  } catch (e) {
    throw falloDeExcepcion(e);
  }
}
