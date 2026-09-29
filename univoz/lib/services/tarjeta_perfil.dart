import 'dart:convert';

import 'perfiles.dart';

/// Lo que viaja dentro del código QR: quién es la persona y cómo se
/// comunica. Nada más.
///
/// El QR lleva el DATO, no un link. Esa es la diferencia entre que
/// funcione sin internet o no: un QR con una URL obliga al teléfono a
/// abrir una página, y sin datos se queda esperando. Este se lee entero
/// en el momento, en modo avión, sin que nada salga del teléfono.
///
/// Son unos 40 bytes, así que entra en un QR chiquito y se escanea
/// rápido incluso con poca luz.
class TarjetaPerfil {
  /// Cómo se llama quien muestra el código. Es opcional y solo sirve
  /// para que la otra persona vea a quién agarró en vez de un perfil
  /// anónimo.
  final String? nombre;

  final ProfileType tipo;
  final bool sabeLsm;

  const TarjetaPerfil({
    this.nombre,
    required this.tipo,
    required this.sabeLsm,
  });

  /// Versión del formato. Si algún día cambia lo que se manda, subir
  /// esto hace que una app vieja rechace el código en vez de leerlo mal
  /// y arrancar una conversación con el perfil equivocado.
  static const int kVersion = 1;

  /// Tope del nombre. Un QR crece con lo que lleva dentro, y uno enorme
  /// se vuelve difícil de enfocar; además evita que alguien meta medio
  /// libro en el campo.
  static const int kMaxNombre = 24;

  String aTexto() => jsonEncode({
        'v': kVersion,
        if (nombre != null && nombre!.isNotEmpty) 'n': nombre,
        't': tipo.name,
        'lsm': sabeLsm,
      });

  /// Lee un código escaneado. Devuelve null si no es nuestro o no se
  /// entiende.
  ///
  /// Todo lo que entra por la cámara es texto de afuera: puede ser el QR
  /// de un paquete, de un menú de restaurante, o basura. Por eso se
  /// valida campo por campo y ante cualquier duda se devuelve null, para
  /// que la pantalla caiga a la selección manual en vez de inventarse un
  /// perfil.
  static TarjetaPerfil? desdeTexto(String? texto) {
    if (texto == null || texto.isEmpty || texto.length > 512) return null;
    Object? crudo;
    try {
      crudo = jsonDecode(texto);
    } catch (_) {
      return null;
    }
    if (crudo is! Map) return null;

    if ((crudo['v'] as num?)?.toInt() != kVersion) return null;

    final tipo = _tipoPorNombre(crudo['t']);
    // prestarCelular no es un perfil de persona, es un camino de la UI:
    // si llega en un código, el código está mal armado.
    if (tipo == null || tipo == ProfileType.prestarCelular) return null;

    final lsm = crudo['lsm'];
    if (lsm != null && lsm is! bool) return null;

    return TarjetaPerfil(
      nombre: _limpiarNombre(crudo['n']),
      tipo: tipo,
      sabeLsm: lsm as bool? ?? false,
    );
  }

  static ProfileType? _tipoPorNombre(Object? valor) {
    if (valor is! String) return null;
    for (final t in ProfileType.values) {
      if (t.name == valor) return t;
    }
    return null;
  }

  /// Quita saltos de línea y caracteres de control (que podrían romper
  /// el dibujado del texto en pantalla) y recorta al tope.
  static String? _limpiarNombre(Object? valor) {
    if (valor is! String) return null;
    final limpio = valor
        .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (limpio.isEmpty) return null;
    return limpio.length <= kMaxNombre
        ? limpio
        : limpio.substring(0, kMaxNombre);
  }

  /// Texto para la tarjeta de confirmación: "Lani · Sordo/a · LSM".
  String get resumen {
    final perfil = descripcionPerfil(tipo, sabeLsm) ?? '';
    return (nombre == null || nombre!.isEmpty) ? perfil : '$nombre · $perfil';
  }
}
