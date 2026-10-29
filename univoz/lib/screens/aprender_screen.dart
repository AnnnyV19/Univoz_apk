import 'package:flutter/material.dart';
import 'package:senas_core/pantalla_avatar.dart' show PantallaAvatar;

import '../services/curriculo.dart';
import '../services/progreso_aprendizaje.dart';
import 'leccion_screen.dart';
import 'univoz_shared_widgets.dart';
import 'package:senas_core/tema_univoz.dart';

/// "Aprender LSM": un camino de unidades y lecciones, como Duolingo pero
/// sin vidas ni castigos, hecho con las señas que ya hay en el diccionario.
///
/// Las lecciones se abren de una en una. Las ya hechas se pueden repetir.
/// El diccionario libre (escribir o decir una palabra y ver al avatar
/// señarla) sigue disponible en el botón "Diccionario".
class AprenderScreen extends StatefulWidget {
  const AprenderScreen({super.key});

  @override
  State<AprenderScreen> createState() => _AprenderScreenState();
}

class _AprenderScreenState extends State<AprenderScreen> {
  static const Color _bgColor = Colors.white;
  static const Color _morado = ColoresUnivoz.morado;
  static const Color _moradoOscuro = ColoresUnivoz.moradoOscuro;
  static const Color _rosa = Color(0xFFE85DA0);
  // Las lecciones terminadas antes eran verdes; ahora van en el morado del
  // diseño de Lucía.
  static const Color _verde = ColoresUnivoz.morado;
  static const Color _texto = ColoresUnivoz.tinta;
  static const Color _gris = ColoresUnivoz.tintaSuave;

  final ProgresoAprendizaje _progreso = ProgresoAprendizaje.instancia;
  /// Unidad que se ve (una a la vez, sin desplazar). null: la de la
  /// lección que sigue.
  int? _unidadVista;

  @override
  void initState() {
    super.initState();
    _progreso.cargar();
  }

  int _unidadDe(Leccion? l) {
    if (l == null) return camino.length - 1;
    for (var i = 0; i < camino.length; i++) {
      if (camino[i].lecciones.any((x) => x.id == l.id)) return i;
    }
    return 0;
  }

  Future<void> _abrir(Leccion l) async {
    if (!_progreso.desbloqueada(l)) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Termina la lección anterior para abrir ésta.'),
          ),
        );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => LeccionScreen(leccion: l)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progreso,
      builder: (context, _) {
        final actual = _progreso.siguiente;
        return Scaffold(
          backgroundColor: _bgColor,
          appBar: const UnivozHeader(),
          body: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                children: [
                  _resumen(),
                  const SizedBox(height: 10),
                  Expanded(child: _unidadPagina(actual)),
                  const SizedBox(height: 10),
                  const SosButton(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Una unidad a la vez, con flechas para pasar a la anterior o la
  /// siguiente (nada se desliza). Las lecciones se reparten el alto.
  Widget _unidadPagina(Leccion? actual) {
    final idx = (_unidadVista ?? _unidadDe(actual)).clamp(0, camino.length - 1);
    final u = camino[idx];
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              onPressed:
                  idx > 0 ? () => setState(() => _unidadVista = idx - 1) : null,
              icon: const Icon(Icons.chevron_left, size: 30),
              tooltip: 'Unidad anterior',
            ),
            Expanded(child: _unidad(u, actual)),
            IconButton(
              onPressed: idx < camino.length - 1
                  ? () => setState(() => _unidadVista = idx + 1)
                  : null,
              icon: const Icon(Icons.chevron_right, size: 30),
              tooltip: 'Unidad siguiente',
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Column(
            children: [
              for (var i = 0; i < u.lecciones.length; i++)
                Expanded(child: _nodo(u.lecciones[i], i, actual)),
              if (actual == null && idx == camino.length - 1) _todoListo(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _resumen() {
    final total = todasLasGlosas.length;
    final vistas = _progreso.senasAprendidas;
    final racha = _progreso.racha;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        border: Border.all(color: ColoresUnivoz.borde, width: 2),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Aprender LSM',
                  style: TextStyle(
                    color: _texto,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_fire_department,
                        size: 16, color: Color(0xFFD97706)),
                    const SizedBox(width: 4),
                    Text(
                      '$racha',
                      style: const TextStyle(
                        color: Color(0xFFB45309),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PantallaAvatar()),
                ),
                icon: const Icon(Icons.menu_book_outlined,
                    size: 18, color: _moradoOscuro),
                label: const Text(
                  'Diccionario',
                  style: TextStyle(
                    color: _moradoOscuro,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : vistas / total,
                    minHeight: 8,
                    backgroundColor: ColoresUnivoz.lavanda,
                    valueColor: const AlwaysStoppedAnimation<Color>(_morado),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$vistas de $total señas',
                style: const TextStyle(
                  color: _gris,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _unidad(Unidad u, Leccion? actual) {
    final hechas = u.lecciones.where((l) => _progreso.completada(l.id)).length;
    final abierta = u.lecciones.any((l) => _progreso.desbloqueada(l));
    return Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: abierta ? ColoresUnivoz.moradoTenue : Colors.white,
              borderRadius: BorderRadius.circular(kRadioUnivoz),
              border: Border.all(
                  color: abierta ? _morado : ColoresUnivoz.borde, width: 2),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: abierta ? _morado : ColoresUnivoz.lavanda,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${u.numero}',
                    style: TextStyle(
                      color: abierta ? Colors.white : _gris,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.titulo,
                        style: const TextStyle(
                          color: _texto,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '$hechas/${u.lecciones.length}',
                  style: const TextStyle(
                    color: _moradoOscuro,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          );
  }

  /// Los nodos serpentean (izquierda, centro, derecha, centro...) para que
  /// el camino se sienta camino y no una lista.
  Widget _nodo(Leccion l, int i, Leccion? actual) {
    const posiciones = [-0.55, 0.0, 0.55, 0.0];
    final hecha = _progreso.completada(l.id);
    final esActual = actual != null && actual.id == l.id;
    final bloqueada = !hecha && !esActual;

    final String estado = hecha
        ? 'terminada'
        : esActual
            ? 'es la que sigue'
            : 'bloqueada';

    final Widget circulo;
    if (esActual) {
      circulo = Container(
        width: 78,
        height: 78,
        decoration: const BoxDecoration(
          color: _rosa,
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Color(0xFFC23F80), offset: Offset(0, 5))],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              l.titulo,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              '${l.glosas.length} ${l.glosas.length == 1 ? 'seña' : 'señas'}',
              style: const TextStyle(
                color: Color(0xFFFFE3F1),
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    } else if (hecha) {
      circulo = Container(
        width: 62,
        height: 62,
        decoration: const BoxDecoration(
          color: _verde,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(color: ColoresUnivoz.moradoOscuro, offset: Offset(0, 4)),
          ],
        ),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 30),
      );
    } else {
      circulo = Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: ColoresUnivoz.lavanda,
          shape: BoxShape.circle,
          border: Border.all(color: ColoresUnivoz.bordeControl, width: 2),
        ),
        child: const Icon(Icons.lock_outline,
            color: ColoresUnivoz.tintaTenue, size: 24),
      );
    }

    return Align(
      alignment: Alignment(posiciones[i % posiciones.length], 0),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Semantics(
          button: true,
          label: 'Lección ${l.titulo}, $estado',
          child: GestureDetector(
            onTap: () => _abrir(l),
            child: ExcludeSemantics(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (esActual)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _texto,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'Vas aquí',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  circulo,
                  if (!esActual)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        l.titulo,
                        style: TextStyle(
                          color: bloqueada ? ColoresUnivoz.tintaTenue : _gris,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _todoListo() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: ColoresUnivoz.moradoTenue,
        borderRadius: BorderRadius.circular(kRadioUnivoz),
        border: Border.all(color: ColoresUnivoz.moradoClaro, width: 2),
      ),
      child: const Text(
        '¡Terminaste todo el camino! Ya puedes presentarte en LSM y '
        'deletrear tu nombre. Cualquier lección se puede repetir.',
        style: TextStyle(
          color: ColoresUnivoz.moradoOscuro,
          fontSize: 14,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
    );
  }
}
