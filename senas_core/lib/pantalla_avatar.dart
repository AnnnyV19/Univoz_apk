/// Pantalla del avatar 3D y del diccionario: escribes, eliges de una lista, o
/// dices una palabra, y el avatar (assets/avatar/MODELO_UNIVOZ_v0.vrm) hace la
/// seña correspondiente. Es el sentido inverso de PantallaDeTranslacion: en
/// vez de camara -> texto, es texto/voz -> avatar.
///
/// La fuente de las secuencias es la misma que usa el reconocedor DTW
/// (plantillas.dart / dtw.dart): no hay un banco de datos aparte para
/// animacion, se reusan las mismas muestras aprobadas.
///
/// Distribucion (2026-10-13): antes el panel de abajo era el 40 % de la
/// pantalla y ahi cabian, apretados, el campo, "Manos", "Velocidad" y TODAS las
/// señas como botoncitos, asi que el diccionario quedaba en una o dos filas.
/// Ahora el avatar tiene una altura razonable (un tercio de la pantalla, y se
/// encoge si sale el teclado), "Manos" y "Velocidad" se abren con un boton, y
/// el resto es una lista con scroll que se filtra mientras escribes.
library pantalla_avatar;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'avatar_bridge.dart';
import 'avatar_vista.dart';
import 'avatar_toma.dart';
import 'dtw.dart';
import 'frase_a_senas.dart';
import 'muestras_locales.dart';
import 'plantillas.dart';

/// Que brazos anima el avatar. Izquierda y derecha son las del AVATAR, tal
/// como las ve quien lo mira de frente invertidas -- igual que al aprender
/// una seña de un instructor sentado enfrente.
enum _Manos { ambas, izquierda, derecha }

/// Una seña del diccionario tal como se ve en la lista.
class _EntradaDic {
  final String gloss;
  final String etiqueta;

  /// Etiqueta + glosa, sin acentos y en minusculas: contra esto se busca.
  final String clave;
  final bool esLetra;

  const _EntradaDic(this.gloss, this.etiqueta, this.clave, this.esLetra);
}

const String _conAcento = 'áàäâãéèëêíìïîóòöôõúùüûñç';
const String _sinAcento = 'aaaaaeeeeiiiiooooouuuunc';

/// Minusculas y sin acentos (la ñ queda como n), para buscar sin fijarse en
/// como se escribio.
String _sinAcentos(String s) {
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    final c = String.fromCharCode(r);
    final i = _conAcento.indexOf(c);
    b.write(i >= 0 ? _sinAcento[i] : c);
  }
  return b.toString();
}

bool _esLetraGlosa(String g) =>
    g == 'LL' ||
    g == 'RR' ||
    g == 'NN' ||
    (g.length == 1 && g.codeUnitAt(0) >= 65 && g.codeUnitAt(0) <= 90);

String _legible(String g) => g.toLowerCase().replaceAll('_', ' ');

String _capitalizar(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class PantallaAvatar extends StatefulWidget {
  const PantallaAvatar({super.key, this.cargador, this.puente, this.vista});

  /// Solo para pruebas: un puente sin WebView (AvatarBridge.sinVisor) y el
  /// widget que ocupa el lugar del visor.
  @visibleForTesting
  final AvatarBridge? puente;
  @visibleForTesting
  final Widget? vista;

  /// Solo para pruebas: de donde sale el diccionario. Por defecto es el paquete
  /// del APK mas las muestras locales ([cargarDiccionario]).
  final Future<Diccionario> Function()? cargador;

  @override
  State<PantallaAvatar> createState() => _PantallaAvatarState();
}

class _PantallaAvatarState extends State<PantallaAvatar> {
  late final AvatarBridge _bridge = widget.puente ?? AvatarBridge();
  final _controladorTexto = TextEditingController();
  final _voz = stt.SpeechToText();
  final _almacen = AlmacenMuestras.instancia;

  bool _cargando = true;
  bool _reproduciendo = false;
  bool _vozLista = false;
  bool _escuchando = false;
  bool _ajustesAbiertos = false;
  _Manos _manos = _Manos.ambas;
  String? _aviso;

  /// Lo que hay escrito en el campo; filtra la lista.
  String _consulta = '';

  /// Las señas del diccionario, ordenadas: primero palabras, al final letras.
  List<_EntradaDic> _entradas = const [];

  /// La primera plantilla de cada glosa (la que dibuja el avatar).
  final Map<String, Template> _porGlosa = {};

  /// Barra de velocidad de las señas (0.5× a 2×). Se traduce a cuadros por
  /// segundo: las plantillas son de 32 cuadros, a 30 fps duran ~1 s.
  double _velocidad = 1.0;
  String? _ultimaGlosa;

  /// La ultima frase señada (varias señas seguidas), para repetirla al
  /// cambiar la velocidad. null si lo ultimo fue una seña suelta.
  PlanFrase? _ultimaFrase;

  @override
  void initState() {
    super.initState();
    _bridge.onTerminado = () {
      if (mounted) setState(() => _reproduciendo = false);
    };
    _cargar();
    _iniciarVoz();
  }

  Future<void> _cargar() async {
    try {
      await _almacen.cargar();
      await _bridge.configurarRig(_almacen.ajustes.rigCalibration);
    } catch (_) {
      // Sin la calibracion guardada el avatar se ve con la de fabrica; eso no
      // debe dejar sin diccionario a la pantalla.
    }
    try {
      final cargador = widget.cargador;
      final d = cargador != null ? await cargador() : await cargarDiccionario();
      if (!mounted) return;
      final porGlosa = <String, Template>{};
      for (final t in d.clasificador.templates) {
        // Si hay varias muestras de la misma seña, la primera: es la que
        // dejo elegida la curacion (tools/curar_plantillas.py,
        // tools/ejemplar_avatar.py) y la que usa Aprender.
        porGlosa.putIfAbsent(t.gloss, () => t);
      }
      // Señas solo de aprendizaje (Glosario CDMX): se ven en el Diccionario
      // y las hace el avatar, pero no entran al reconocimiento. Si una seña
      // ya esta en el paquete, se queda la del paquete (la curada).
      for (final t in d.aprendizaje) {
        porGlosa.putIfAbsent(t.gloss, () => t);
      }
      setState(() {
        _porGlosa
          ..clear()
          ..addAll(porGlosa);
        _entradas = _armarEntradas(porGlosa.values);
        _cargando = false;
        if (!_bridge.compatible) {
          _aviso = 'El avatar 3D no está disponible aquí.';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _aviso = 'No pude cargar el diccionario. Cierra y abre la pantalla.';
      });
    }
  }

  List<_EntradaDic> _armarEntradas(Iterable<Template> primeras) {
    final out = <_EntradaDic>[];
    for (final t in primeras) {
      final letra = _esLetraGlosa(t.gloss);
      final esp = t.espanol.trim();
      final etiqueta = letra
          ? (t.gloss == 'NN' ? 'Letra Ñ' : 'Letra ${t.gloss}')
          : _capitalizar(esp.isNotEmpty ? esp : _legible(t.gloss));
      out.add(_EntradaDic(
        t.gloss,
        etiqueta,
        _sinAcentos('$etiqueta ${_legible(t.gloss)}'),
        letra,
      ));
    }
    out.sort((a, b) {
      if (a.esLetra != b.esLetra) return a.esLetra ? 1 : -1;
      final c = _sinAcentos(a.etiqueta).compareTo(_sinAcentos(b.etiqueta));
      return c != 0 ? c : a.gloss.compareTo(b.gloss);
    });
    return out;
  }

  Future<void> _iniciarVoz() async {
    if (kIsWeb) return;
    try {
      final ok = await _voz.initialize(
        onError: (e) {
          if (mounted) setState(() => _escuchando = false);
        },
        onStatus: (s) {
          if (s == 'done' || s == 'notListening') {
            if (mounted) setState(() => _escuchando = false);
          }
        },
      );
      if (mounted) setState(() => _vozLista = ok);
    } catch (_) {
      // Sin motor de voz del sistema: el boton del microfono avisa, y escribir
      // sigue funcionando.
      if (mounted) {
        setState(() {
          _vozLista = false;
          _aviso = 'El reconocimiento de voz no está disponible.';
        });
      }
    }
  }

  /// Las señas que coinciden con lo escrito (todas las palabras escritas
  /// tienen que aparecer, sin importar acentos ni mayusculas).
  List<_EntradaDic> get _filtradas {
    final q = _sinAcentos(_consulta.trim());
    if (q.isEmpty) return _entradas;
    final partes = q.split(RegExp(r'\s+'));
    return [
      for (final e in _entradas)
        if (partes.every((p) => e.clave.contains(p))) e
    ];
  }

  /// Busca una plantilla por glosa o por su traduccion al español. Si hay
  /// varias muestras de la misma palabra, usa la primera -- para elegir
  /// "la mejor" habria que ver calidad/quality_score, que no viaja en el
  /// paquete de plantillas.
  Template? _buscar(String texto) {
    final q = texto.trim();
    if (q.isEmpty) return null;
    final glosa = q.toUpperCase();
    final directa = _porGlosa[glosa] ?? _porGlosa[glosa.replaceAll(' ', '_')];
    if (directa != null) return directa;
    final qs = _sinAcentos(q);
    for (final e in _entradas) {
      if (_sinAcentos(e.etiqueta) == qs ||
          _sinAcentos(_legible(e.gloss)) == qs) {
        return _porGlosa[e.gloss];
      }
    }
    return null;
  }

  /// Lo que escribiste o dijiste: busca esa palabra y el avatar hace la seña.
  /// Si no hay una coincidencia exacta pero la lista ya se redujo a una sola
  /// seña, se hace esa.
  Future<void> _senarTexto(String texto) async {
    FocusScope.of(context).unfocus();
    final q = texto.trim();
    if (q.isEmpty) {
      setState(() => _aviso = 'Escribe una palabra o elige una de la lista.');
      return;
    }
    // 1. La frase completa es una seña guardada.
    final t = _buscar(q);
    if (t != null) {
      await _senar(t.gloss);
      return;
    }
    // 2. Una sola palabra a medio escribir que ya dejo UNA seña en la lista
    //    ("hol" -> Hola): se hace esa, como antes.
    final palabras = palabrasDe(q);
    if (palabras.length == 1) {
      final f = _filtradas;
      final inicio = claveDePalabra(palabras.first);
      if (f.length == 1 && f.first.clave.startsWith(inicio)) {
        await _senar(f.first.gloss);
        return;
      }
    }
    // 3. Frase: señas seguidas (frases guardadas, palabras y deletreo).
    final plan = planificarFrase(q, {
      for (final e in _porGlosa.entries) e.key: e.value.espanol,
    });
    if (plan.vacio) {
      setState(() => _aviso = 'No tengo la seña de "$q" todavía.');
      return;
    }
    if (plan.pasos.length == 1 &&
        plan.pasos.first.tipo == TipoPaso.sena &&
        plan.omitidas.isEmpty &&
        plan.sinSena.isEmpty) {
      await _senar(plan.pasos.first.gloss);
      return;
    }
    await _senarFrase(plan);
  }

  /// Etiqueta legible de una glosa (como sale en la lista).
  String _etiquetaDe(String gloss) {
    for (final e in _entradas) {
      if (e.gloss == gloss) return e.etiqueta;
    }
    return _capitalizar(_legible(gloss));
  }

  /// Varias señas seguidas. Cada una conserva su velocidad (las letras de un
  /// deletreo van un poco mas rapido que una seña suelta, como al deletrear
  /// de verdad); el visor las une sin regresar a reposo.
  Future<void> _senarFrase(PlanFrase plan) async {
    if (!_bridge.compatible) {
      setState(() => _aviso = 'El avatar 3D no está disponible aquí.');
      return;
    }
    final segmentos = <SegmentoFrase>[];
    for (final paso in plan.pasos) {
      final t = _porGlosa[paso.gloss];
      if (t == null) continue;
      final seq = prepararParaAvatar(t.seq);
      final factor =
          paso.tipo == TipoPaso.letra ? 1.6 : factorVelocidadSena(seq);
      final fps = (30 * _velocidad * factor).round().clamp(8, 60).toInt();
      segmentos.add(SegmentoFrase(seq, fps));
    }
    if (segmentos.isEmpty) {
      setState(() => _aviso = 'No tengo esas señas todavía.');
      return;
    }
    setState(() {
      _aviso = plan.resumen(_etiquetaDe);
      _reproduciendo = true;
      _ultimaGlosa = null;
      _ultimaFrase = plan;
    });
    try {
      await _bridge.reproducirFrase(segmentos);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reproduciendo = false;
        _aviso = 'No pude mostrar esa frase. Intenta de nuevo.';
      });
    }
  }

  Future<void> _senar(String gloss) async {
    if (!_bridge.compatible) {
      setState(() => _aviso = 'El avatar 3D no está disponible aquí.');
      return;
    }
    final t = _porGlosa[gloss];
    if (t == null) {
      setState(() => _aviso = 'No tengo la seña de "$gloss" todavía.');
      return;
    }
    // Copia lista para el visor: sin el tiempo muerto del principio y del
    // final (si lo tiene). No toca la plantilla ni las alturas.
    final seq = prepararParaAvatar(t.seq);

    // Si se eligio una sola mano y la seña se hace con la otra, el avatar no
    // se movia y no se sabia por que: se avisa.
    String? aviso;
    final usa = manosUsadas(seq);
    if (_manos == _Manos.izquierda && usa.derecha && !usa.izquierda) {
      aviso = 'Esta seña se hace con la mano derecha del avatar. '
          'En «Manos y velocidad» elige «Ambas» o «Der.».';
    } else if (_manos == _Manos.derecha && usa.izquierda && !usa.derecha) {
      aviso = 'Esta seña se hace con la mano izquierda del avatar. '
          'En «Manos y velocidad» elige «Ambas» o «Izq.».';
    }

    setState(() {
      _aviso = aviso;
      _reproduciendo = true;
      _ultimaGlosa = gloss;
      _ultimaFrase = null;
    });
    // Las plantillas son de 32 cuadros: a 30 por segundo duran poco mas de
    // un segundo. Una pose casi fija (la mayoria de las letras) se muestra un
    // poco mas despacio para que de tiempo de verla.
    final fps =
        (30 * _velocidad * factorVelocidadSena(seq)).round().clamp(8, 60).toInt();
    try {
      await _bridge.reproducir(seq, fps: fps);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reproduciendo = false;
        _aviso = 'No pude mostrar esa seña. Intenta de nuevo.';
      });
    }
  }

  Future<void> _cambiarManos(_Manos m) async {
    setState(() => _manos = m);
    await _bridge.configurarManos(
      izquierda: m != _Manos.derecha,
      derecha: m != _Manos.izquierda,
    );
  }

  Future<void> _alternarMicrofono() async {
    if (_escuchando) {
      await _voz.stop();
      if (mounted) setState(() => _escuchando = false);
      return;
    }
    if (!_vozLista) {
      setState(() => _aviso = 'El reconocimiento de voz no está disponible.');
      return;
    }
    final permiso = await Permission.microphone.request();
    if (!permiso.isGranted) {
      if (mounted) {
        setState(() => _aviso = 'Sin permiso de micrófono no puedo escuchar.');
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _escuchando = true;
      _aviso = null;
    });
    await _voz.listen(
      listenOptions: stt.SpeechListenOptions(localeId: 'es_MX'),
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _consulta = r.recognizedWords;
          _controladorTexto.text = _consulta;
        });
        if (r.finalResult && r.recognizedWords.trim().isNotEmpty) {
          _senarTexto(r.recognizedWords);
        }
      },
    );
  }

  void _limpiarTexto() {
    setState(() {
      _consulta = '';
      _aviso = null;
      _controladorTexto.clear();
    });
  }

  @override
  void dispose() {
    _voz.stop().catchError((_) {});
    _bridge.dispose();
    _controladorTexto.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Diccionario')),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, c) {
            // El avatar ocupa un tercio de la pantalla (entre 150 y 330), pero
            // nunca le quita al diccionario su alto minimo: con el teclado
            // abierto el avatar se encoge en vez de tapar la lista. Con
            // "Manos y velocidad" abierto el panel necesita ~110 mas.
            final minimoPanel = _ajustesAbiertos ? 310.0 : 200.0;
            final ideal = (c.maxHeight * 0.32).clamp(150.0, 330.0).toDouble();
            final altoAvatar =
                (c.maxHeight - minimoPanel).clamp(60.0, ideal).toDouble();
            return Column(
              children: [
                SizedBox(
                  height: altoAvatar,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: VistaAvatar(bridge: _bridge, vista: widget.vista),
                      ),
                      if (_reproduciendo)
                        const Positioned(
                          top: 8,
                          left: 8,
                          child: Chip(
                            avatar: Icon(Icons.front_hand, size: 18),
                            label: Text('Señando...'),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _cargando
                      ? const Center(child: CircularProgressIndicator())
                      : _panel(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _panel() {
    final tema = Theme.of(context);
    final filtradas = _filtradas;
    final hayConsulta = _consulta.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controladorTexto,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    labelText: 'Busca o escribe una palabra o frase',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: hayConsulta
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Borrar',
                            onPressed: _limpiarTexto,
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() {
                    _consulta = v;
                    _aviso = null;
                  }),
                  onSubmitted: _senarTexto,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: Icon(_escuchando ? Icons.mic : Icons.mic_none),
                tooltip: _escuchando ? 'Escuchando...' : 'Decir la palabra',
                onPressed: _alternarMicrofono,
              ),
              IconButton(
                icon: const Icon(Icons.front_hand),
                tooltip: 'Señar',
                onPressed: () => _senarTexto(_controladorTexto.text),
              ),
            ],
          ),
        ),
        if (_aviso != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              _aviso!,
              style: TextStyle(color: tema.colorScheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  hayConsulta
                      ? '${filtradas.length} de ${_entradas.length} señas'
                      : '${_entradas.length} señas',
                  style: tema.textTheme.labelMedium,
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _ajustesAbiertos = !_ajustesAbiertos),
                icon: Icon(
                  _ajustesAbiertos ? Icons.expand_less : Icons.tune,
                  size: 18,
                ),
                label: const Text('Manos y velocidad'),
              ),
            ],
          ),
        ),
        if (_ajustesAbiertos) _ajustes(),
        const Divider(height: 1),
        Expanded(child: _lista(filtradas)),
      ],
    );
  }

  Widget _ajustes() {
    final tema = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Column(
        children: [
          Row(
            children: [
              Text('Manos:', style: tema.textTheme.labelMedium),
              const SizedBox(width: 8),
              Expanded(
                child: SegmentedButton<_Manos>(
                  segments: const [
                    ButtonSegment(value: _Manos.ambas, label: Text('Ambas')),
                    ButtonSegment(value: _Manos.izquierda, label: Text('Izq.')),
                    ButtonSegment(value: _Manos.derecha, label: Text('Der.')),
                  ],
                  selected: {_manos},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => _cambiarManos(s.first),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.speed, size: 20),
              const SizedBox(width: 6),
              Text('Velocidad', style: tema.textTheme.labelMedium),
              Expanded(
                child: Slider(
                  value: _velocidad,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: '$_velocidad×',
                  onChanged: (v) => setState(() => _velocidad = v),
                  onChangeEnd: (_) {
                    final fr = _ultimaFrase;
                    final u = _ultimaGlosa;
                    if (fr != null) {
                      _senarFrase(fr);
                    } else if (u != null) {
                      _senar(u);
                    }
                  },
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '$_velocidad×',
                  textAlign: TextAlign.right,
                  style: tema.textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _lista(List<_EntradaDic> filtradas) {
    if (filtradas.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _entradas.isEmpty
                ? 'El diccionario está vacío.'
                : 'No hay señas que coincidan con "${_consulta.trim()}".\n'
                    'Prueba con otra palabra.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final cs = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      itemCount: filtradas.length,
      itemBuilder: (context, i) {
        final e = filtradas[i];
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: e.gloss == _ultimaGlosa,
          selectedTileColor: cs.secondaryContainer,
          title: Text(e.etiqueta),
          trailing: const Icon(Icons.play_circle_outline),
          onTap: () {
            FocusScope.of(context).unfocus();
            _senar(e.gloss);
          },
        );
      },
    );
  }
}
