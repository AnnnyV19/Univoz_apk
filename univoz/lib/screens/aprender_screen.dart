import 'package:flutter/material.dart';
import 'package:senas_core/pantalla_avatar.dart' show PantallaAvatar;

import '../services/curriculo.dart';
import '../services/progreso_aprendizaje.dart';
import 'leccion_screen.dart';
import 'univoz_shared_widgets.dart';

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
  static const Color _bgColor = Color(0xFFF7F2FA);
  static const Color _morado = Color(0xFF6C63FF);
  static const Color _moradoOscuro = Color(0xFF4F46C9);
  static const Color _rosa = Color(0xFFE85DA0);
  static const Color _verde = Color(0xFF3FBF8F);
  static const Color _texto = Color(0xFF1A1A2E);
  static const Color _gris = Color(0xFF5B5470);

  final ProgresoAprendizaje _progreso = ProgresoAprendizaje.instancia;
  final GlobalKey _claveActual = GlobalKey();
  bool _centrado = false;

  @override
  void initState() {
    super.initState();
    _progreso.cargar();
  }

  /// Al abrir, lleva la vista hasta la lección en la que se quedó.
  void _irALaActual() {
    if (_centrado || !_progreso.cargado) return;
    _centrado = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _claveActual.currentContext;
      if (c != null && mounted) {
        Scrollable.ensureVisible(
          c,
          alignment: 0.35,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
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
        _irALaActual();
        final actual = _progreso.siguiente;
        return Scaffold(
          backgroundColor: _bgColor,
          appBar: const UnivozHeader(),
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                  child: _resumen(),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                    child: Column(
                      children: [
                        for (final u in camino) _unidad(u, actual),
                        if (actual == null) _todoListo(),
                      ],
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: SosButton(),
                ),
              ],
            ),
          ),
        );
      },
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
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFDDD3EE), width: 1.5),
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
                  color: const Color(0xFFFFF1DB),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.local_fire_department,
                        size: 16, color: Color(0xFFE8A33D)),
                    const SizedBox(width: 4),
                    Text(
                      '$racha',
                      style: const TextStyle(
                        color: Color(0xFF7A4A06),
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
                    backgroundColor: const Color(0xFFE3DAF2),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: abierta ? const Color(0xFFEDE4FB) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: abierta
                  ? null
                  : Border.all(color: const Color(0xFFDDD3EE), width: 1.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: abierta ? _morado : const Color(0xFFE3DAF2),
                    borderRadius: BorderRadius.circular(10),
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
                      Text(
                        u.detalle,
                        style: const TextStyle(
                          color: _gris,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
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
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < u.lecciones.length; i++)
            _nodo(u.lecciones[i], i, actual),
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
          boxShadow: [BoxShadow(color: Color(0xFF2E9570), offset: Offset(0, 4))],
        ),
        child: const Icon(Icons.check_rounded, color: Colors.white, size: 30),
      );
    } else {
      circulo = Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: const Color(0xFFE3DAF2),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFDDD3EE), width: 2),
        ),
        child: const Icon(Icons.lock_outline,
            color: Color(0xFF8077A0), size: 24),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Align(
        alignment: Alignment(posiciones[i % posiciones.length], 0),
        child: Semantics(
          button: true,
          label: 'Lección ${l.titulo}, $estado',
          child: GestureDetector(
            key: esActual ? _claveActual : null,
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
                        borderRadius: BorderRadius.circular(12),
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
                          color: bloqueada ? const Color(0xFF8077A0) : _gris,
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
        color: const Color(0xFFDDF5EA),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _verde, width: 2),
      ),
      child: const Text(
        '¡Terminaste todo el camino! Ya puedes presentarte en LSM y '
        'deletrear tu nombre. Cualquier lección se puede repetir.',
        style: TextStyle(
          color: Color(0xFF17684A),
          fontSize: 14,
          fontWeight: FontWeight.w700,
          height: 1.4,
        ),
      ),
    );
  }
}
