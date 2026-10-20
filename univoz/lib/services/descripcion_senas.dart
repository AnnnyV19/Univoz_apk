/// Descripción en palabras de cómo se hace cada seña.
///
/// Se muestra al final de cada ejercicio de "Aprender LSM", haya salido bien
/// o mal, para que quien aprende pueda comprobar la forma de la mano y el
/// movimiento sin depender solo del avatar. Es Dart puro (sin Flutter) para
/// poder probarlo con `flutter test`.
///
/// Las descripciones de las letras salen de los videos de referencia del
/// alfabeto LSM (SEP e "Incluyéndome"). La mano que se describe es la
/// derecha, vista de frente, como la ve quien aprende. Hoy solo hay
/// descripciones del abecedario; las frases se agregan cuando sus alturas y
/// movimientos estén validados con personas sordas.
library descripcion_senas;

const Map<String, String> _descripciones = {
  'A': 'Puño cerrado con el pulgar extendido hacia arriba, pegado al costado '
      'del índice.',
  'B': 'Mano abierta: los cuatro dedos juntos y hacia arriba, con el pulgar '
      'cruzado sobre la palma.',
  'C': 'Mano curvada en forma de C, con la abertura hacia un lado.',
  'D': 'Índice extendido hacia arriba; los otros dedos se curvan y el pulgar '
      'los toca.',
  'E': 'Los cuatro dedos se doblan hacia la palma, como una garra corta, y '
      'el pulgar se dobla debajo de ellos.',
  'F': 'Índice y pulgar forman un círculo; los otros tres dedos quedan '
      'extendidos hacia arriba.',
  'G': 'Mano de lado: el índice apunta hacia el costado, el pulgar hacia '
      'arriba y los demás dedos cerrados.',
  'H': 'Mano de lado: el índice y el medio, juntos y extendidos, apuntan '
      'hacia el costado.',
  'I': 'Puño con el meñique extendido hacia arriba.',
  'J': 'Meñique extendido, como la I; la mano dibuja una J en el aire.',
  'K': 'Índice extendido hacia arriba; el medio, doblado a la mitad, se '
      'apoya en el pulgar; anular y meñique cerrados. La mano se inclina '
      'hacia el centro del cuerpo y regresa.',
  'L': 'Índice hacia arriba y pulgar hacia un lado, formando una L; los '
      'otros tres dedos cerrados. La palma mira al frente.',
  'LL': 'La misma forma de la L, pero la mano se sacude de lado a lado dos '
      'veces.',
  'M': 'La mano cuelga hacia abajo: índice, medio y anular extendidos '
      'apuntando al piso; meñique y pulgar recogidos bajo ellos.',
  'N': 'La mano cuelga hacia abajo: solo índice y medio extendidos '
      'apuntando al piso; los demás dedos recogidos.',
  'NN': 'La forma de la N (dos dedos hacia abajo); la mano se balancea '
      'hacia el centro del cuerpo y regresa, como un péndulo.',
  'O': 'Los cuatro dedos y el pulgar se curvan y se tocan por las yemas, '
      'formando un círculo.',
  'P': 'Misma forma de mano que la K: índice extendido, medio doblado a la '
      'mitad apoyado en el pulgar, anular y meñique cerrados.',
  'Q': 'Índice y pulgar extendidos, los demás dedos cerrados. La mano '
      'empieza con el índice hacia arriba y gira hasta que el índice apunta '
      'hacia abajo.',
  'R': 'Índice y medio extendidos y cruzados, uno sobre el otro; anular y '
      'meñique cerrados.',
  'RR': 'La misma forma de la R (dedos cruzados), pero la mano vibra de lado '
      'a lado.',
  'S': 'Puño cerrado con el pulgar cruzado por delante de los dedos.',
  'T': 'Puño cerrado con la punta del pulgar asomando entre el índice y el '
      'medio.',
  'U': 'Índice y medio extendidos, juntos, hacia arriba.',
  'V': 'Índice y medio extendidos y separados, formando una V.',
  'W': 'Índice, medio y anular extendidos y separados, formando una W.',
  'X': 'Índice doblado en forma de gancho; los demás dedos cerrados.',
  'Y': 'Pulgar y meñique extendidos; los otros tres dedos cerrados.',
  'Z': 'El índice extendido dibuja una Z en el aire: una línea horizontal, '
      'una diagonal hacia abajo y otra línea horizontal.',
};

/// La descripción de la seña [glosa], o null si todavía no hay una (la
/// pantalla simplemente no muestra nada en ese caso).
String? descripcionDe(String glosa) => _descripciones[glosa];

/// Las glosas que tienen descripción. Sirve para el test.
Iterable<String> glosasConDescripcion() => _descripciones.keys;
