/// A quién llamar o escribir cuando alguien mantiene presionado SOS.
///
/// Se guarda en el teléfono (ver `PerfilGuardado.contactoEmergencia`) y
/// no sale de ahí: solo se usa para armar la llamada o el SMS en el
/// momento.
class ContactoEmergencia {
  final String nombre;

  /// Solo dígitos, con un "+" al inicio si lo trae. Ya sin espacios ni
  /// guiones: es lo que se le pasa tal cual a `tel:` y `sms:`.
  final String telefono;

  const ContactoEmergencia({required this.nombre, required this.telefono});

  /// Tope del nombre: va en el texto de los botones ("Llamar a ...").
  static const int kMaxNombre = 30;

  /// Un teléfono internacional (E.164) tiene hasta 15 dígitos; menos de 7
  /// no es un número marcable.
  static const int kMinDigitos = 7;
  static const int kMaxDigitos = 15;

  /// null si [texto] sirve como nombre; si no, qué decirle a la persona.
  static String? validarNombre(String? texto) {
    final limpio = (texto ?? '').trim();
    if (limpio.isEmpty) return 'Escribe el nombre de tu contacto.';
    if (limpio.length > kMaxNombre) {
      return 'Usa un nombre más corto (máximo $kMaxNombre letras).';
    }
    return null;
  }

  /// Quita lo que la gente escribe por costumbre (espacios, guiones,
  /// paréntesis, puntos) y deja dígitos y, si venía, el "+" inicial.
  /// Devuelve null si queda algo que no es número.
  static String? normalizarTelefono(String? texto) {
    final t = (texto ?? '').trim();
    if (t.isEmpty) return null;
    final sinAdornos = t.replaceAll(RegExp(r'[\s\-().]'), '');
    if (!RegExp(r'^\+?\d+$').hasMatch(sinAdornos)) return null;
    return sinAdornos;
  }

  /// null si [texto] sirve como teléfono; si no, qué decirle a la persona.
  static String? validarTelefono(String? texto) {
    if ((texto ?? '').trim().isEmpty) {
      return 'Escribe el teléfono de tu contacto.';
    }
    final n = normalizarTelefono(texto);
    final digitos = n?.replaceAll('+', '').length ?? 0;
    if (n == null || digitos < kMinDigitos || digitos > kMaxDigitos) {
      return 'Revisa el número: debe tener de $kMinDigitos a $kMaxDigitos '
          'dígitos.';
    }
    return null;
  }

  /// null si falta algo o no se entiende. Lo usan el formulario y la
  /// lectura del archivo guardado, que no se fía de lo que haya en disco.
  static ContactoEmergencia? crear(String? nombre, String? telefono) {
    if (validarNombre(nombre) != null || validarTelefono(telefono) != null) {
      return null;
    }
    return ContactoEmergencia(
      nombre: nombre!.trim(),
      telefono: normalizarTelefono(telefono)!,
    );
  }

  Map<String, String> toJson() => {'nombre': nombre, 'telefono': telefono};

  static ContactoEmergencia? desdeJson(Object? crudo) {
    if (crudo is! Map) return null;
    final n = crudo['nombre'];
    final t = crudo['telefono'];
    if (n is! String || t is! String) return null;
    return crear(n, t);
  }

  @override
  bool operator ==(Object other) =>
      other is ContactoEmergencia &&
      other.nombre == nombre &&
      other.telefono == telefono;

  @override
  int get hashCode => Object.hash(nombre, telefono);
}
