/// Derivados de un LandmarkFrame calculados una sola vez por instancia.
///
/// normalize() / normalizeForRender() / calidad / signSpace() corren en el
/// isolate de UI y cada frame fusionado los pedia 5-6 veces (alimentador del
/// avatar, escucha de quieto, anillo/grabacion, registro de sesion). Aqui se
/// memoizan por instancia con un Expando: LandmarkFrame es inmutable, asi que
/// el resultado no cambia. Los resultados son los mismos objetos para todos
/// los llamadores: tratarlos como solo lectura (nadie los muta hoy).
library frame_derivados;

import 'camera_bridge.dart';
import 'sign_norm.dart' show calidadFrame;
import 'sign_space.dart';

class _Derivados {
  bool tieneNorm = false;
  List<double>? norm;
  bool tieneRender = false;
  List<double>? render;
  double? calidad;
  bool tieneSignSpace = false;
  Map<String, double?>? signSpacePerfil;
  SignSpaceFrame? signSpace;
}

final Expando<_Derivados> _cache = Expando<_Derivados>('frame_derivados');

_Derivados _de(LandmarkFrame f) => _cache[f] ??= _Derivados();

/// [LandmarkFrame.normalize] memoizado.
List<double>? normalizarCacheado(LandmarkFrame f) {
  final d = _de(f);
  if (!d.tieneNorm) {
    d.norm = f.normalize();
    d.tieneNorm = true;
  }
  return d.norm;
}

/// [LandmarkFrame.normalizeForRender] memoizado.
List<double>? normalizarRenderCacheado(LandmarkFrame f) {
  final d = _de(f);
  if (!d.tieneRender) {
    d.render = f.normalizeForRender();
    d.tieneRender = true;
  }
  return d.render;
}

/// Calidad del frame (formula de la web); 0 si no da vector. Equivale a
/// [LandmarkFrame.calidad] pero reutiliza el vector cacheado.
double calidadCacheada(LandmarkFrame f) {
  final d = _de(f);
  return d.calidad ??= normalizarCacheado(f) == null
      ? 0.0
      : calidadFrame(f.pose, f.poseMundo, f.left, f.right);
}

/// [LandmarkFrame.signSpace] memoizado. El perfil se compara por identidad:
/// con otro mapa (o sin mapa) se recalcula y se queda con el ultimo.
SignSpaceFrame? signSpaceCacheado(LandmarkFrame f,
    {Map<String, double?>? profileMeasures}) {
  final d = _de(f);
  if (!d.tieneSignSpace || !identical(d.signSpacePerfil, profileMeasures)) {
    d.signSpace = f.signSpace(profileMeasures: profileMeasures);
    d.signSpacePerfil = profileMeasures;
    d.tieneSignSpace = true;
  }
  return d.signSpace;
}
