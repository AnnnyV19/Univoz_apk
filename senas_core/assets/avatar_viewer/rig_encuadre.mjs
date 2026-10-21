// Encuadre de la camara "de los codos hacia arriba" (aportado por la rama
// app-limpia para la pantalla Aprender, 2026-10-14). Puro: sin THREE ni DOM.
//
//   'cintura' (por defecto): el de siempre -- espejo y pantalla del avatar,
//             donde interesa ver los brazos completos.
//   'codos':  de los codos hacia arriba, mas cerca. Las lecciones muestran al
//             avatar en una tarjeta bajita y ancha, y con el encuadre de
//             cintura quedaba chico y lejos.
//
// Se calcula con las medidas del modelo (no con numeros fijos) para que siga
// bien si se cambia el avatar. Dart lo elige con AvatarBridge.encuadrar().

// m      = { hombroY, brazo, topeY } a escala 1
// escala = escala actual del avatar
// reposo = cuanto bajan los brazos desde la T-pose (rad)
export function calcularEncuadreCodos(m, escala, reposo, fovGrados, aspecto,
    extraAbajo = 0) {
  // Con el brazo en reposo el codo queda a brazo*sin(reposo) bajo el hombro.
  const codoY = (m.hombroY - m.brazo * Math.sin(reposo)) * escala;
  // el codo se ve entero; extraAbajo (mundo) baja el borde si la seña lo pide
  const abajo = codoY - 0.03 * escala - Math.max(0, extraAbajo);
  const arriba = m.topeY * escala + 0.05 * escala; // aire sobre la cabeza
  const alto = arriba - abajo;
  const tanMedio = Math.tan((fovGrados * Math.PI) / 360);
  const distAlto = alto / (2 * tanMedio);
  // A lo ancho tienen que caber los dos brazos abiertos. En una tarjeta
  // ancha manda el alto; en una angosta, esto evita cortar las manos.
  const ancho = 3.6 * m.brazo * escala;
  const distAncho = ancho / (2 * tanMedio * aspecto);
  return {
    y: (arriba + abajo) / 2,
    dist: Math.min(Math.max(distAlto, distAncho, 0.55), 1.8),
    alto,
  };
}
