import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/curriculo.dart';
import '../services/descripcion_senas.dart';
import '../services/perfil_guardado.dart';
import '../services/progreso_aprendizaje.dart';
import '../widgets/visor_sena.dart';
import 'package:senas_core/tema_univoz.dart';

const Color _kFondo = ColoresUnivoz.fondoSuave;
const Color _kMorado = ColoresUnivoz.morado;
const Color _kMoradoOscuro = ColoresUnivoz.moradoOscuro;
const Color _kTexto = ColoresUnivoz.tinta;
const Color _kGris = ColoresUnivoz.tintaSuave;
const Color _kBorde = ColoresUnivoz.bordeControl;
const Color _kVerde = Color(0xFF3FBF8F);
const Color _kAmbar = Color(0xFFE8A33D);

enum _Fase { respondiendo, acierto, fallo }

enum _EstadoOpcion { normal, elegida, correcta, equivocada }

/// Una lección de "Aprender LSM": una cola de ejercicios, uno a la vez.
///
/// Sin vidas ni bloqueos: un fallo manda el ejercicio al final de la cola y
/// ya. El acierto y el fallo se avisan con color, ícono, texto y vibración,
/// nunca con sonido: quien aprende puede ser sorda.
class LeccionScreen extends StatefulWidget {
  final Leccion leccion;

  const LeccionScreen({super.key, required this.leccion});

  @override
  State<LeccionScreen> createState() => _LeccionScreenState();
}

class _LeccionScreenState extends State<LeccionScreen> {
  late final SesionLeccion _sesion;
  final ControladorVisor _visor = ControladorVisor();

  _Fase _fase = _Fase.respondiendo;
  String? _elegida;
  List<String> _tecleadas = [];

  /// El ejercicio que se acaba de contestar. Mientras se ve el aviso la cola
  /// ya avanzó, así que la pantalla sigue mostrando éste y no el siguiente.
  Ejercicio? _ultimo;
  bool _terminada = false;

  @override
  void initState() {
    super.initState();
    _sesion = SesionLeccion(
      generarLeccion(widget.leccion, nombre: PerfilGuardado.nombre),
    );
    _arrancar();
  }

  Future<void> _arrancar() async {
    await _visor.iniciar();
    if (!mounted) return;
    // El visor carga el modelo 3D después de que la página avisa que está
    // lista, y no hay un aviso de "ya cargó". Un respiro evita que la
    // primera seña se pierda; si pasa, el botón de repetir la recupera.
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    if (!mounted) return;
    _presentar();
  }

  void _presentar() {
    final e = _sesion.actual;
    if (e == null) return;
    switch (e.tipo) {
      case TipoEjercicio.miraYElige:
        _visor.senar(e.esperado.first);
        break;
      case TipoEjercicio.deletrea:
        _visor.senarVarias(e.esperado);
        break;
      case TipoEjercicio.eligeLaSena:
        // Aquí se tocan las señas para verlas: el avatar espera.
        break;
    }
  }

  bool get _puedeComprobar {
    final e = _sesion.actual;
    if (e == null) return false;
    if (e.tipo == TipoEjercicio.deletrea) {
      return _tecleadas.length == e.esperado.length;
    }
    return _elegida != null;
  }

  void _comprobar() {
    final e = _sesion.actual;
    if (e == null || !_puedeComprobar) return;
    final respuesta = e.tipo == TipoEjercicio.deletrea
        ? List<String>.from(_tecleadas)
        : [_elegida!];
    final ok = _sesion.responder(respuesta);
    if (ok) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.mediumImpact();
    }
    setState(() {
      _ultimo = e;
      _fase = ok ? _Fase.acierto : _Fase.fallo;
    });
  }

  void _continuar() {
    if (_sesion.terminada) {
      _terminar();
      return;
    }
    setState(() {
      _fase = _Fase.respondiendo;
      _elegida = null;
      _tecleadas = [];
    });
    _presentar();
  }

  Future<void> _terminar() async {
    await ProgresoAprendizaje.instancia.completar(widget.leccion);
    if (!mounted) return;
    setState(() => _terminada = true);
  }

  @override
  void dispose() {
    _visor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_terminada) {
      return _PantallaFin(
        leccion: widget.leccion,
        aciertos: _sesion.aciertosPrimera,
        total: _sesion.totalInicial,
        falladas: _sesion.glosasFalladas.map(etiquetaDe).toList(),
      );
    }

    final enPantalla = _fase == _Fase.respondiendo ? _sesion.actual : _ultimo;

    return Scaffold(
      backgroundColor: _kFondo,
      body: SafeArea(
        child: Column(
          children: [
            _cabecera(),
            Expanded(
              child: enPantalla == null
                  ? const SizedBox.shrink()
                  // Sin desplazar: el avatar toma el alto que dejan las
                  // opciones.
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                      child: _contenido(enPantalla),
                    ),
            ),
            if (enPantalla != null) _pie(enPantalla),
          ],
        ),
      ),
    );
  }

  Widget _cabecera() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 20, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Salir de la lección',
            icon: const Icon(Icons.close, color: _kGris),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: _sesion.progreso,
                minHeight: 12,
                backgroundColor: ColoresUnivoz.lavanda,
                valueColor: const AlwaysStoppedAnimation<Color>(_kMorado),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${_sesion.numeroActual}/${_sesion.totalInicial}',
            style: const TextStyle(
              color: _kGris,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- cuerpo

  /// El avatar en el alto que quede (nada se desliza).
  Widget _visorFlexible({String? etiqueta}) =>
      VisorSena(controlador: _visor, alto: null, etiqueta: etiqueta);

  Widget _contenido(Ejercicio e) {
    switch (e.tipo) {
      case TipoEjercicio.miraYElige:
        return _miraYElige(e);
      case TipoEjercicio.eligeLaSena:
        return _eligeLaSena(e);
      case TipoEjercicio.deletrea:
        return _deletrea(e);
    }
  }

  Widget _encabezado(String tipo, String titulo) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Solo la pregunta, corta; el tipo de ejercicio lo lee TalkBack.
        Text(
          titulo,
          semanticsLabel: '$tipo. $titulo',
          maxLines: 2,
          style: const TextStyle(
            color: _kTexto,
            fontSize: 21,
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  bool get _contestado => _fase != _Fase.respondiendo;

  _EstadoOpcion _estadoDe(String opcion, Ejercicio e) {
    if (!_contestado) {
      return _elegida == opcion ? _EstadoOpcion.elegida : _EstadoOpcion.normal;
    }
    if (opcion == e.esperado.first) return _EstadoOpcion.correcta;
    if (opcion == _elegida) return _EstadoOpcion.equivocada;
    return _EstadoOpcion.normal;
  }

  Widget _miraYElige(Ejercicio e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _encabezado('Mira y elige', '¿Qué seña es ésta?'),
        Expanded(child: _visorFlexible()),
        const SizedBox(height: 12),
        for (final o in e.opciones)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _BotonOpcion(
              texto: etiquetaDe(o),
              estado: _estadoDe(o, e),
              alTocar: _contestado ? null : () => setState(() => _elegida = o),
            ),
          ),
      ],
    );
  }

  Widget _eligeLaSena(Ejercicio e) {
    final palabra = etiquetaDe(e.esperado.first);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _encabezado('Elige la seña', '¿Cuál es la seña de “$palabra”?'),
        Expanded(child: _visorFlexible()),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.6,
          children: [
            for (var i = 0; i < e.opciones.length; i++)
              _BotonOpcion(
                texto: 'Seña ${i + 1}',
                icono: Icons.play_arrow_rounded,
                estado: _estadoDe(e.opciones[i], e),
                alTocar: _contestado
                    ? null
                    : () {
                        setState(() => _elegida = e.opciones[i]);
                        _visor.senar(e.opciones[i]);
                      },
              ),
          ],
        ),
      ],
    );
  }

  Widget _deletrea(Ejercicio e) {
    final n = e.esperado.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _encabezado('Deletrea', 'Arma el nombre'),
        // El rótulo cambia mientras el avatar avanza de letra, así que este
        // pedazo se redibuja con el visor.
        Expanded(
          child: AnimatedBuilder(
            animation: _visor,
            builder: (context, _) => _visorFlexible(
              etiqueta: _visor.reproduciendo
                  ? 'Letra ${_visor.posicion} de ${_visor.total}'
                  : '$n letras',
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Wrap y no Row: un nombre de 8 letras no cabe en una sola fila.
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < n; i++)
              _Casilla(
                letra: i < _tecleadas.length ? etiquetaDe(_tecleadas[i]) : '',
                estado: !_contestado
                    ? (i < _tecleadas.length
                        ? _EstadoOpcion.elegida
                        : _EstadoOpcion.normal)
                    : (_fase == _Fase.acierto
                        ? _EstadoOpcion.correcta
                        : _EstadoOpcion.equivocada),
              ),
          ],
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 5,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 1.15,
          children: [
            for (final t in e.opciones)
              _Tecla(
                letra: etiquetaDe(t),
                alTocar: _contestado || _tecleadas.length >= n
                    ? null
                    : () => setState(() => _tecleadas = [..._tecleadas, t]),
              ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ pie

  Widget _pie(Ejercicio e) {
    if (_fase == _Fase.respondiendo) {
      final esDeletrea = e.tipo == TipoEjercicio.deletrea;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Row(
          children: [
            if (esDeletrea) ...[
              Semantics(
                button: true,
                label: 'Borrar la última letra',
                child: GestureDetector(
                  onTap: _tecleadas.isEmpty
                      ? null
                      : () => setState(() =>
                          _tecleadas = _tecleadas.sublist(0, _tecleadas.length - 1)),
                  child: Container(
                    width: 60,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _kBorde, width: 2),
                    ),
                    child: const Icon(Icons.backspace_outlined, color: _kGris),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: _BotonGrande(
                texto: 'Comprobar',
                alTocar: _puedeComprobar ? _comprobar : null,
              ),
            ),
          ],
        ),
      );
    }

    final ok = _fase == _Fase.acierto;
    final esDeletrea = e.tipo == TipoEjercicio.deletrea;
    final que = esDeletrea
        ? e.esperado.map(etiquetaDe).join()
        : '“${etiquetaDe(e.esperado.first)}”';
    return _HojaResultado(
      acierto: ok,
      titulo: ok ? '¡Eso es!' : 'Casi. Era $que',
      detalle: ok
          ? (esDeletrea ? 'Deletreaste $que.' : 'Ya reconoces $que.')
          : 'Te lo vuelvo a poner más adelante.',
      descripciones: _descripcionesDe(e),
      alContinuar: _continuar,
    );
  }

  /// Cómo se hace la seña del ejercicio, para mostrarlo al final haya salido
  /// bien o mal. Al deletrear sale una línea por letra distinta ("A: …");
  /// en los demás ejercicios, la de la seña pedida. Si una seña todavía no
  /// tiene descripción, simplemente no se muestra.
  List<String> _descripcionesDe(Ejercicio e) {
    if (e.tipo != TipoEjercicio.deletrea) {
      final d = descripcionDe(e.esperado.first);
      return d == null ? const [] : [d];
    }
    final vistas = <String>{};
    final out = <String>[];
    for (final g in e.esperado) {
      if (!vistas.add(g)) continue;
      final d = descripcionDe(g);
      if (d != null) out.add('${etiquetaDe(g)}: $d');
    }
    return out;
  }
}

// ======================================================== piezas de la UI

class _BotonGrande extends StatelessWidget {
  final String texto;
  final VoidCallback? alTocar;
  final Color color;
  final Color sombra;
  final Color colorTexto;

  const _BotonGrande({
    required this.texto,
    required this.alTocar,
    this.color = _kMorado,
    this.sombra = _kMoradoOscuro,
    this.colorTexto = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final activo = alTocar != null;
    return Semantics(
      button: true,
      enabled: activo,
      label: texto,
      child: GestureDetector(
        onTap: alTocar,
        child: Container(
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: activo ? color : ColoresUnivoz.lavanda,
            borderRadius: BorderRadius.circular(18),
            boxShadow: activo
                ? [BoxShadow(color: sombra, offset: const Offset(0, 4))]
                : null,
          ),
          child: ExcludeSemantics(
            child: Text(
              texto,
              style: TextStyle(
                color: activo ? colorTexto : ColoresUnivoz.tintaTenue,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BotonOpcion extends StatelessWidget {
  final String texto;
  final IconData? icono;
  final _EstadoOpcion estado;
  final VoidCallback? alTocar;

  const _BotonOpcion({
    required this.texto,
    required this.estado,
    required this.alTocar,
    this.icono,
  });

  @override
  Widget build(BuildContext context) {
    late final Color fondo;
    late final Color borde;
    late final Color letra;
    IconData? marca;
    switch (estado) {
      case _EstadoOpcion.normal:
        fondo = Colors.white;
        borde = _kBorde;
        letra = _kTexto;
        break;
      case _EstadoOpcion.elegida:
        fondo = ColoresUnivoz.moradoTenue;
        borde = _kMorado;
        letra = const Color(0xFF3A33A8);
        break;
      case _EstadoOpcion.correcta:
        fondo = const Color(0xFFDDF5EA);
        borde = _kVerde;
        letra = const Color(0xFF17684A);
        marca = Icons.check_rounded;
        break;
      case _EstadoOpcion.equivocada:
        fondo = const Color(0xFFFFF1DB);
        borde = _kAmbar;
        letra = const Color(0xFF7A4A06);
        marca = Icons.close_rounded;
        break;
    }

    return Semantics(
      button: true,
      selected: estado == _EstadoOpcion.elegida,
      label: texto,
      child: GestureDetector(
        onTap: alTocar,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: fondo,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borde, width: 2),
            boxShadow: [BoxShadow(color: borde, offset: const Offset(0, 3))],
          ),
          child: ExcludeSemantics(
            child: Row(
              children: [
                if (icono != null) ...[
                  Icon(icono, color: letra, size: 22),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    texto,
                    style: TextStyle(
                      color: letra,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (marca != null) Icon(marca, color: letra, size: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Casilla extends StatelessWidget {
  final String letra;
  final _EstadoOpcion estado;

  const _Casilla({required this.letra, required this.estado});

  @override
  Widget build(BuildContext context) {
    final Color fondo;
    final Color borde;
    switch (estado) {
      case _EstadoOpcion.elegida:
        fondo = ColoresUnivoz.moradoTenue;
        borde = _kMorado;
        break;
      case _EstadoOpcion.correcta:
        fondo = const Color(0xFFDDF5EA);
        borde = _kVerde;
        break;
      case _EstadoOpcion.equivocada:
        fondo = const Color(0xFFFFF1DB);
        borde = _kAmbar;
        break;
      case _EstadoOpcion.normal:
        fondo = Colors.white;
        borde = const Color(0xFFC9BEE6);
        break;
    }
    return Container(
      width: 40,
      height: 54,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borde, width: 2),
      ),
      child: Text(
        letra,
        style: const TextStyle(
          color: _kTexto,
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _Tecla extends StatelessWidget {
  final String letra;
  final VoidCallback? alTocar;

  const _Tecla({required this.letra, required this.alTocar});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Letra $letra',
      child: GestureDetector(
        onTap: alTocar,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kBorde, width: 2),
            boxShadow: const [
              BoxShadow(color: _kBorde, offset: Offset(0, 3)),
            ],
          ),
          child: ExcludeSemantics(
            child: Text(
              letra,
              style: TextStyle(
                color: alTocar == null ? ColoresUnivoz.tintaTenue : _kTexto,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La hoja de abajo con el resultado. Color + ícono + texto, y se anuncia
/// sola con lector de pantalla (liveRegion).
class _HojaResultado extends StatelessWidget {
  final bool acierto;
  final String titulo;
  final String detalle;

  /// Cómo se hace la seña, una línea por seña. Vacío si no hay descripción.
  final List<String> descripciones;
  final VoidCallback alContinuar;

  const _HojaResultado({
    required this.acierto,
    required this.titulo,
    required this.detalle,
    this.descripciones = const [],
    required this.alContinuar,
  });

  @override
  Widget build(BuildContext context) {
    final fondo = acierto ? const Color(0xFFDDF5EA) : const Color(0xFFFFF1DB);
    final acento = acierto ? _kVerde : _kAmbar;
    final textoTitulo =
        acierto ? const Color(0xFF17684A) : const Color(0xFF7A4A06);
    final textoDetalle =
        acierto ? const Color(0xFF2E7A5A) : const Color(0xFF8F5A10);

    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
        decoration: BoxDecoration(
          color: fondo,
          border: Border(top: BorderSide(color: acento, width: 3)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: acento, shape: BoxShape.circle),
                  child: Icon(
                    acierto ? Icons.check_rounded : Icons.close_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: TextStyle(
                          color: textoTitulo,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        detalle,
                        style: TextStyle(
                          color: textoDetalle,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (descripciones.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ConstrainedBox(
                  // Al deletrear pueden ser hasta 8 líneas: se desplaza en
                  // vez de empujar el botón fuera de la pantalla.
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Cómo se hace',
                          style: TextStyle(
                            color: textoTitulo,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final d in descripciones)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              d,
                              style: TextStyle(
                                color: textoDetalle,
                                fontSize: 13,
                                height: 1.3,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            _BotonGrande(
              texto: 'Continuar',
              alTocar: alContinuar,
              // Acierto: el botón morado de siempre (antes verde).
              color: acierto ? _kMorado : acento,
              sombra: acierto ? _kMoradoOscuro : const Color(0xFFBC7F22),
              colorTexto: acierto ? Colors.white : const Color(0xFF3D2503),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================ fin de lección

class _PantallaFin extends StatelessWidget {
  final Leccion leccion;
  final int aciertos;
  final int total;
  final List<String> falladas;

  const _PantallaFin({
    required this.leccion,
    required this.aciertos,
    required this.total,
    required this.falladas,
  });

  @override
  Widget build(BuildContext context) {
    final progreso = ProgresoAprendizaje.instancia;
    final siguiente = progreso.despuesDe(leccion);
    final racha = progreso.racha;

    return Scaffold(
      backgroundColor: _kFondo,
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(28, 84, 28, 40),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [ColoresUnivoz.morado, ColoresUnivoz.moradoOscuro],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Column(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                      color: Colors.white, shape: BoxShape.circle),
                  child:
                      const Icon(Icons.check_rounded, color: _kVerde, size: 56),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Lección terminada',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${leccion.titulo} · ${leccion.glosas.length} '
                  '${leccion.glosas.length == 1 ? 'seña' : 'señas'}',
                  style: const TextStyle(
                    color: ColoresUnivoz.moradoTenue,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Column(
                children: [
                  Row(
                    children: [
                      _Dato(
                        valor: '$aciertos/$total',
                        etiqueta: 'a la primera',
                        color: _kVerde,
                      ),
                      const SizedBox(width: 10),
                      _Dato(
                        valor: '${progreso.senasAprendidas}',
                        etiqueta: 'señas ya',
                        color: _kMorado,
                      ),
                      const SizedBox(width: 10),
                      _Dato(
                        valor: '$racha',
                        etiqueta: racha == 1 ? 'día seguido' : 'días seguidos',
                        color: _kAmbar,
                      ),
                    ],
                  ),
                  if (falladas.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF1DB),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                            color: const Color(0xFFF0CF9A), width: 2),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.replay,
                              color: Color(0xFF7A4A06), size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Para repasar: ${falladas.join(', ')}. '
                              'Las fallaste hoy.',
                              style: const TextStyle(
                                color: Color(0xFF7A4A06),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              children: [
                if (siguiente != null)
                  _BotonGrande(
                    texto: 'Siguiente lección',
                    alTocar: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => LeccionScreen(leccion: siguiente),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text(
                    'Volver al camino',
                    style: TextStyle(
                      color: _kMoradoOscuro,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dato extends StatelessWidget {
  final String valor;
  final String etiqueta;
  final Color color;

  const _Dato({
    required this.valor,
    required this.etiqueta,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _kBorde, width: 2),
        ),
        child: Column(
          children: [
            Text(
              valor,
              style: TextStyle(
                color: color,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              etiqueta,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _kGris,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
