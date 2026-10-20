import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'conversation_profile.dart';
import 'perfiles.dart';
import 'tarjeta_perfil.dart';

/// Guarda en el teléfono el perfil de QUIEN USA la app — y solo ese.
///
/// Por qué solo la mitad de [ConversationProfile]: lo que una persona ES
/// (sorda, ciega, oyente) y si sabe LSM es identidad, casi nunca cambia, y
/// preguntarlo en cada conversación es puro estorbo. Con quién se va a
/// comunicar cambia cada vez, así que guardarlo sería un error, no una
/// función: [ConversationProfile.other] y [otherKnowsLsm] se quedan en
/// memoria y se limpian con [ConversationProfile.resetOtro].
///
/// Por qué un archivo propio y no la clase `Ajustes` de senas_core (que ya
/// está persistida y donde esto cabría en dos líneas): `ProfileType` es un
/// concepto de la app, y senas_core es el motor de reconocimiento. Meter
/// perfiles de discapacidad ahí vuelve a borrar la frontera entre los dos
/// paquetes — y además no compilaría, porque `ProfileType` vive en univoz y
/// senas_core no puede importar de la app sin invertir la dependencia.
///
/// NO se guarda nunca cuando el perfil viene de "Prestaré mi Celular": en
/// ese caso quien usa el teléfono no es su dueño, y persistir su perfil
/// haría que la app le mienta a la dueña la próxima vez que lo abra (ver
/// `esPrestado` en ProfileSelectionScreen._onContinue).
class PerfilGuardado {
  PerfilGuardado._();

  static const String _kArchivo = 'perfil_usuario.json';

  /// Versión del formato del archivo. Si algún día cambia la forma de lo
  /// que se guarda, subir esto hace que un archivo viejo se ignore en vez
  /// de leerse mal.
  static const int _kVersion = 1;

  static ProfileType? _tipo;
  static bool _sabeLsm = false;
  static String? _nombre;
  static bool _cargado = false;

  static bool get hayPerfil => _tipo != null;
  static ProfileType? get tipo => _tipo;
  static bool get sabeLsm => _sabeLsm;

  /// Nombre con el que esta persona se identifica ante quien escanea su
  /// código. Opcional: sin el, el codigo funciona igual, solo que la otra
  /// persona ve el perfil sin nombre.
  static String? get nombre => _nombre;

  /// Lo que se dibuja como QR. null si todavia no hay perfil elegido: no
  /// hay nada que mostrar.
  static TarjetaPerfil? get miTarjeta => _tipo == null
      ? null
      : TarjetaPerfil(nombre: _nombre, tipo: _tipo!, sabeLsm: _sabeLsm);

  static Future<File> _ruta() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_kArchivo');
  }

  /// Lee el perfil del disco y lo deja aplicado en [ConversationProfile].
  /// Se llama una sola vez, desde main() antes de runApp.
  ///
  /// Cualquier problema al leer (archivo corrupto, versión distinta) se
  /// trata como "no hay perfil": la app pregunta de nuevo, que es molesto
  /// pero correcto. Reventar en el arranque por un archivo de preferencias
  /// sería mucho peor.
  static Future<void> cargar() async {
    if (_cargado) return;
    _cargado = true;
    try {
      final f = await _ruta();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if ((j['v'] as num?)?.toInt() != _kVersion) return;
      final t = _porNombre(j['tipo'] as String?);
      // prestarCelular no es un perfil de persona: es un camino que en
      // _onContinue ya se traduce al perfil real. Si apareciera aquí, el
      // archivo está mal y se ignora.
      if (t == null || t == ProfileType.prestarCelular) return;
      _tipo = t;
      _sabeLsm = j['sabe_lsm'] as bool? ?? false;
      _nombre = TarjetaPerfil.desdeTexto(jsonEncode({
        'v': TarjetaPerfil.kVersion,
        'n': j['nombre'],
        't': t.name,
        'lsm': _sabeLsm,
      }))?.nombre;
    } catch (_) {
      _tipo = null;
      _sabeLsm = false;
      _nombre = null;
    }
    aplicar();
  }

  /// Copia el perfil guardado a [ConversationProfile]. Se usa al arrancar y
  /// cada vez que se empieza una conversación saltándose la selección de
  /// perfil, porque ProfileSelectionScreen.initState llama a
  /// [ConversationProfile.reset], que borra todo.
  static void aplicar() {
    if (_tipo == null) return;
    ConversationProfile.mine = _tipo;
    ConversationProfile.mineKnowsLsm = _sabeLsm;
  }

  static Future<void> guardar(ProfileType tipo, bool sabeLsm) async {
    if (tipo == ProfileType.prestarCelular) return;
    _tipo = tipo;
    _sabeLsm = sabeLsm;
    _cargado = true;
    await _escribir();
  }

  /// Cambia solo el nombre, conservando el perfil. Se llama desde la
  /// pantalla del codigo QR.
  static Future<void> guardarNombre(String? nuevo) async {
    final limpio = (nuevo ?? '').trim();
    _nombre = limpio.isEmpty
        ? null
        : (limpio.length <= TarjetaPerfil.kMaxNombre
            ? limpio
            : limpio.substring(0, TarjetaPerfil.kMaxNombre));
    await _escribir();
  }

  /// Escribe el archivo completo. Siempre escribe los tres campos juntos,
  /// para que guardar el perfil no borre el nombre ni al reves.
  static Future<void> _escribir() async {
    if (_tipo == null) return;
    try {
      final f = await _ruta();
      await f.writeAsString(jsonEncode({
        'v': _kVersion,
        'tipo': _tipo!.name,
        'sabe_lsm': _sabeLsm,
        if (_nombre != null) 'nombre': _nombre,
      }));
    } catch (_) {
      // Si no se pudo escribir, el perfil sigue válido en memoria para
      // esta sesión. Se vuelve a preguntar la próxima vez que se abra la
      // app, que es degradación aceptable.
    }
  }

  /// "No soy yo": borra el perfil del disco y de memoria.
  static Future<void> olvidar() async {
    _tipo = null;
    _sabeLsm = false;
    _nombre = null;
    ConversationProfile.mine = null;
    ConversationProfile.mineKnowsLsm = false;
    try {
      final f = await _ruta();
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Ídem: en memoria ya quedó olvidado.
    }
  }

  static ProfileType? _porNombre(String? nombre) {
    if (nombre == null) return null;
    for (final t in ProfileType.values) {
      if (t.name == nombre) return t;
    }
    return null;
  }

  /// Texto corto del perfil GUARDADO. Para lo que se está usando ahora
  /// mismo (que puede ser otro, si el teléfono está prestado) hay que
  /// mirar [ConversationProfile.mine] — ver MenuPerfil.
  static String? get descripcion => descripcionPerfil(_tipo, _sabeLsm);
}
