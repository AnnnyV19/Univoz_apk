import 'dart:async';

import 'package:flutter/material.dart';
import '../services/permiso_camara.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/avatar_toma.dart'
    show factorVelocidadSena, prepararParaAvatar;
import 'package:senas_core/frase_a_senas.dart';
import 'package:senas_core/avatar_vista.dart';
import 'package:senas_core/dtw.dart';
import 'package:senas_core/muestras_locales.dart';
import 'package:senas_core/plantillas.dart';
import 'package:senas_core/skeleton_painter.dart' show PantallaDeTranslacion;
import 'univoz_shared_widgets.dart';
import 'voz_mensaje.dart';
import 'profile_selection_screen.dart' show ProfileType;
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';
import 'package:senas_core/tema_univoz.dart';

/// Pestaña "Comunicarse". Se adapta según la combinación de perfiles
/// guardada en pasos anteriores del flujo (ver
/// [ConversationProfile]/[resolverComunicacionModo]), en vez de tener una
/// pantalla separada por cada combinación posible:
///
/// - [ComunicacionModo.avatar]      -> una persona firma (sorda o muda,
///   con LSM) y la otra es ciega u oyente: pantalla partida, arriba la
///   cámara (su seña se vuelve texto y voz) y abajo el avatar (lo que la
///   otra persona escribe o dice, el avatar lo firma).
/// - [ComunicacionModo.textoVoz]    -> comunicación simple de texto/voz
///   (ej. con una persona oyente, una sorda que no conoce LSM, o una
///   muda).
/// - [ComunicacionModo.camaraSenas] -> las dos personas son sordas/mudas
///   y solo una conoce LSM: la misma pantalla partida, sin voz (quien no
///   firma escribe y el avatar lo firma).
/// - [ComunicacionModo.soloTexto]   -> las dos son sordas/mudas y
///   ninguna conoce LSM: se escriben directamente, sin botones de voz
///   (ninguna de las dos puede usarlos).
/// - [ComunicacionModo.noNecesitaApp] -> las dos son sordas/mudas y
///   ambas conocen LSM: no hace falta esta pantalla.
///
/// Si además quien usa el teléfono es ciego/a
/// ([BlindNarrator.talkBackFlow] activo, por TalkBack o por haber
/// elegido "ciego" a mano), la app conduce la conversación por voz sin
/// importar qué variante visual corresponda: pregunta qué quieres
/// decir, escucha con tolerancia a ruido (ver [BlindNarrator.askMessage])
/// y sigue preguntando por el siguiente mensaje en vez de quedarse
/// callada, personalizando las instrucciones según con quién te estás
/// comunicando. Antes esto reemplazaba TODA la pantalla por un cuadro de
/// texto plano incluso cuando el modo era [ComunicacionModo.avatar] — es
/// decir, alguien ciego hablando con una persona sorda que conoce LSM
/// nunca veía el avatar (que es justo lo que la otra persona necesita
/// ver en pantalla para leer la seña). Ahora la narración por voz corre
/// por encima de la variante visual que corresponda según el modo, no en
/// lugar de ella.
class ComunicarseScreen extends StatefulWidget {
  final ComunicacionModo modo;

  /// Si esta pestaña es la que se está viendo ahora mismo dentro de
  /// [MainShellScreen]. Como el contenedor mantiene las 2 pestañas
  /// construidas al mismo tiempo (IndexedStack), sin esto el ciclo de
  /// preguntas por voz seguiría corriendo de fondo aunque la persona
  /// haya cambiado a "Aprender".
  final bool isActiveTab;

  const ComunicarseScreen({
    super.key,
    this.modo = ComunicacionModo.textoVoz,
    this.isActiveTab = true,
  });

  @override
  State<ComunicarseScreen> createState() => _ComunicarseScreenState();
}

class _ComunicarseScreenState extends State<ComunicarseScreen> {
  final TextEditingController _controller = TextEditingController();
  final _avatarBridge = AvatarBridge();
  final _almacen = AlmacenMuestras.instancia;
  Diccionario? _diccionario;
  bool _avatarReproduciendo = false;
  bool _isSpelling = true; // Deletreo vs Palabra
  bool _listening = false;
  bool _pidiendoPermisoCamara = false;

  /// La mitad de cámara (quien firma) ya tiene permiso y está encendida.
  bool _camaraActiva = false;

  /// En la conversación por voz, espera la respuesta en señas de la otra
  /// persona (la completa la cámara al reconocer una seña).
  Completer<String>? _esperaSena;

  /// La explicación larga de la conversación por voz ya se dijo en esta
  /// sesión de la app.
  static bool _introDicha = false;

  /// Una plantilla por glosa del diccionario (la primera muestra).
  final Map<String, Template> _porGlosa = {};

  /// Avatar y cámara a la vez: una persona sabe LSM y la otra no.
  bool get _conMitades =>
      widget.modo == ComunicacionModo.avatar ||
      widget.modo == ComunicacionModo.camaraSenas;

  // Texto de instrucciones/estado que se muestra en la variante para
  // personas ciegas, para que alguien que mire la pantalla (o un
  // acompañante) sepa qué está pasando.
  String _voiceStatus = '';

  // Se incrementa cada vez que el ciclo de voz debe detenerse (por
  // ejemplo, al salir de esta pestaña) o reiniciarse (al volver a
  // ella). Un ciclo en curso se compara contra el valor actual antes de
  // seguir: si no coincide, se sabe que ya quedó obsoleto y se detiene,
  // aunque estuviera a mitad de una pregunta o una escucha.
  int _voiceFlowGeneration = 0;

  static const Set<String> _exitPhrases = {
    'salir',
    'sal',
    'salir de la app',
    'salir de la aplicación',
    'cerrar',
    'cerrar app',
    'cerrar la app',
    'cerrar la aplicación',
    'quiero salir',
  };

  @override
  void initState() {
    super.initState();
    _avatarBridge.onTerminado = () {
      if (mounted) setState(() => _avatarReproduciendo = false);
    };
    _cargarAvatar();
    if (_conMitades) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _activarCamara());
    }
    if (BlindNarrator.talkBackFlow && widget.isActiveTab) {
      _startVoiceFlow();
    }
  }

  Future<void> _cargarAvatar() async {
    try {
      await _almacen.cargar();
      await _avatarBridge.configurarRig(_almacen.ajustes.rigCalibration);
      // El diccionario pesa cientos de MB: solo se arma si esta pantalla va a
      // hacer señas con el avatar (en los demas modos nunca lo usa). Es el
      // mismo que comparten las demas pantallas, no una copia.
      if (_conMitades) await _asegurarDiccionario();
    } catch (_) {
      // El resto de la pantalla sigue disponible aunque falte diccionario.
    }
  }

  Future<void> _asegurarDiccionario() async {
    if (_diccionario != null) return;
    try {
      final diccionario = await cargarDiccionario();
      _porGlosa.clear();
      for (final t in diccionario.clasificador.templates) {
        _porGlosa.putIfAbsent(t.gloss, () => t);
      }
      if (mounted) setState(() => _diccionario = diccionario);
    } catch (_) {
      // Sin diccionario el avatar no puede señar; el resto sigue.
    }
  }

  /// Hace con el avatar lo escrito o dicho. En "Palabra" busca frases y
  /// palabras guardadas (sin importar acentos ni mayúsculas: "hola, como
  /// estas" sale HOLA + COMO_ESTAS) y deletrea lo que no tenga seña; en
  /// "Deletreo" deletrea todo letra por letra.
  Future<bool> _firmar(String texto) async {
    if (!_conMitades || texto.trim().isEmpty) return false;
    if (!_avatarBridge.compatible) {
      if (mounted) setState(() => _voiceStatus = 'Avatar 3D no disponible.');
      return false;
    }
    await _asegurarDiccionario();
    final dic = {for (final e in _porGlosa.entries) e.key: e.value.espanol};
    final plan = _isSpelling
        ? deletrearTexto(texto, dic)
        : planificarFrase(texto, dic);
    final segmentos = <SegmentoFrase>[];
    for (final paso in plan.pasos) {
      final t = _porGlosa[paso.gloss];
      if (t == null) continue;
      final seq = prepararParaAvatar(t.seq);
      // Las letras de un deletreo van más rápido, como al deletrear de
      // verdad.
      final factor =
          paso.tipo == TipoPaso.letra ? 1.6 : factorVelocidadSena(seq);
      segmentos.add(
          SegmentoFrase(seq, (30 * factor).round().clamp(8, 60).toInt()));
    }
    if (segmentos.isEmpty) {
      if (mounted) {
        setState(() => _voiceStatus = 'No encontré la seña de "$texto".');
      }
      return false;
    }
    if (mounted) {
      setState(() {
        _avatarReproduciendo = true;
        _voiceStatus = '';
      });
    }
    try {
      await _avatarBridge.reproducirFrase(segmentos);
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _avatarReproduciendo = false;
          _voiceStatus = 'No se pudo reproducir la seña.';
        });
      }
      return false;
    }
  }

  /// Pide la cámara para la mitad de quien firma. Si no la dan, queda un
  /// botón para volver a pedirla.
  Future<void> _activarCamara() async {
    if (!mounted || _camaraActiva || _pidiendoPermisoCamara) return;
    setState(() => _pidiendoPermisoCamara = true);
    final permitido = await pedirPermisoCamara(context);
    if (!mounted) return;
    setState(() {
      _pidiendoPermisoCamara = false;
      _camaraActiva = permitido;
    });
  }

  @override
  void didUpdateWidget(covariant ComunicarseScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!BlindNarrator.talkBackFlow) return;
    if (widget.isActiveTab && !oldWidget.isActiveTab) {
      // Se volvió a esta pestaña: empieza una conversación nueva.
      _startVoiceFlow();
    } else if (!widget.isActiveTab && oldWidget.isActiveTab) {
      // Se salió de esta pestaña a mitad de la conversación por voz:
      // invalida el ciclo en curso y corta lo que estuviera diciendo o
      // escuchando, en vez de seguir hablando de fondo en otra pestaña.
      _voiceFlowGeneration++;
      BlindNarrator.stop();
      BlindNarrator.cancelListening();
    }
  }

  void _startVoiceFlow() {
    final int generation = ++_voiceFlowGeneration;
    _runVoiceComposeFlow(generation);
  }

  @override
  void dispose() {
    _voiceFlowGeneration++;
    _controller.dispose();
    _avatarBridge.dispose();
    BlindNarrator.stop();
    super.dispose();
  }

  /// Instrucción inicial, personalizada según el perfil de la persona
  /// con la que se está comunicando (ver [ConversationProfile.other]).
  /// Solo se usa para la narración de quien es ciego/a: en los modos
  /// donde las dos personas son sordas/mudas ([ComunicacionModo.camaraSenas],
  /// [ComunicacionModo.soloTexto], [ComunicacionModo.noNecesitaApp]) quien
  /// usa el teléfono nunca es ciego/a (ver resolverComunicacionModo), así
  /// que esos casos no hacen falta aquí.
  String _personalizedIntro() {
    final other = ConversationProfile.other;
    final knowsLsm = ConversationProfile.otherKnowsLsm;
    if (other == ProfileType.sordo) {
      return knowsLsm
          ? 'Vas a hablar con una persona sorda que conoce lengua de '
              'señas mexicana. Dime tu mensaje y se lo vamos a mostrar '
              'firmado con el avatar y también escrito en pantalla.'
          : 'Vas a hablar con una persona sorda. Dime tu mensaje y va '
              'a aparecer escrito en la pantalla para que lo lea.';
    }
    if (other == ProfileType.mudo) {
      return 'Vas a hablar con una persona muda. Ella puede escuchar y '
          'ver, así que te va a responder por texto o señas y yo te lo '
          'voy a leer. Dime tu mensaje para empezar.';
    }
    if (other == ProfileType.oyente) {
      return 'Vas a hablar con una persona oyente. Dime tu mensaje y te '
          'lo voy a leer en voz alta para que ella lo escuche.';
    }
    // ProfileType.ciego, ProfileType.prestarCelular, o null (aún no se
    // guardó el perfil de la otra persona): instrucción genérica.
    return 'Dime el mensaje que quieres comunicar y te ayudo a '
        'compartirlo.';
  }

  bool _isExitPhrase(String text) =>
      _exitPhrases.contains(text.trim().toLowerCase());

  /// Conduce toda esta pestaña por voz para quien usa el teléfono y es
  /// ciego/a: pregunta qué quiere decir, lo pone en el cuadro de texto,
  /// y en vez de quedarse en silencio después del primer mensaje, sigue
  /// preguntando por el siguiente — hasta que la persona diga "salir".
  /// Corre por encima de la variante visual que [build] elija según
  /// [widget.modo] (ver el comentario de la clase): no reemplaza la
  /// pantalla, solo la narra y la llena por voz.
  ///
  /// [generation] identifica esta corrida en particular: si cambia de
  /// pestaña y vuelve, [_startVoiceFlow] arranca una corrida nueva con
  /// otro número, y esta corrida vieja se detiene sola en su siguiente
  /// verificación en vez de seguir hablando junto con la nueva.
  Future<void> _runVoiceComposeFlow(int generation) async {
    bool isCurrent() =>
        mounted && generation == _voiceFlowGeneration && widget.isActiveTab;

    // La explicación completa solo la primera vez en esta sesión de la app;
    // después basta con "Habla ahora." (no se repite al volver a entrar).
    var prompt = _introDicha ? 'Habla ahora.' : _personalizedIntro();
    _introDicha = true;
    if (isCurrent()) setState(() => _voiceStatus = prompt);
    var consecutiveSilence = 0;
    while (isCurrent()) {
      setState(() => _listening = true);
      final heard = await BlindNarrator.askMessage(
        prompt,
        // Sin esto, salir de esta pestaña a mitad de una pregunta no la
        // interrumpía: BlindNarrator.askMessage seguía con su propio
        // ciclo de reintentos (hasta hablar de nuevo "No escuché nada,
        // dime el mensaje...") sin enterarse de que ya no había pantalla
        // escuchando la respuesta.
        isCancelled: () => !isCurrent(),
        // Muestra en vivo lo que se va reconociendo mientras la persona
        // sigue hablando, en vez de que el texto solo aparezca hasta que
        // termina de hablar (antes no había ninguna señal de que se
        // estuviera escuchando algo, más allá del letrero "Escuchando...").
        onPartialResult: (partial) {
          if (isCurrent() && partial.isNotEmpty) {
            setState(() => _voiceStatus = 'Escuchando: $partial');
          }
        },
      );
      if (!isCurrent()) return;
      setState(() => _listening = false);
      if (_isExitPhrase(heard)) {
        BlindNarrator.exitApp();
        return;
      }
      if (heard.isEmpty) {
        consecutiveSilence++;
        if (consecutiveSilence >= 3) {
          // Tras varias rondas seguidas sin reconocer nada (micrófono
          // sin permiso, apagado, o demasiado ruido), dejamos de
          // interrumpir cada pocos segundos y avisamos una sola vez que
          // se puede seguir escribiendo a mano.
          await BlindNarrator.speak(
            'No pude escucharte. Puedes escribir tu mensaje en el '
            'cuadro de texto, o revisar que el micrófono tenga permiso '
            'concedido.',
          );
          if (mounted) {
            setState(() => _voiceStatus =
                'No se pudo escuchar el micrófono. Escribe tu mensaje '
                    'en el cuadro de texto.');
          }
          return;
        }
        prompt = 'No te escuché. Habla ahora.';
        if (isCurrent()) setState(() => _voiceStatus = prompt);
        continue;
      }
      consecutiveSilence = 0;
      setState(() {
        _controller.text = heard;
        _voiceStatus = 'Dijiste: $heard';
      });
      if (!isCurrent()) return;
      if (_conMitades) {
        final firmado = await _firmar(heard);
        if (!isCurrent()) return;
        if (!firmado) {
          await BlindNarrator.speak('No tengo esa seña.');
        } else if (_camaraActiva) {
          // Turno de la otra persona: no se sigue escuchando; la cámara
          // espera su seña, que se dice en voz alta al reconocerla.
          await BlindNarrator.speak('Ahora responde con señas.');
          if (!isCurrent()) return;
          setState(() => _voiceStatus = 'Esperando la seña...');
          final espera = _esperaSena = Completer<String>();
          await espera.future
              .timeout(const Duration(seconds: 45), onTimeout: () => '');
          _esperaSena = null;
          // Deja terminar la lectura en voz alta de la seña reconocida.
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
      } else {
        // Sin avatar de señas, la forma más directa de "entregar" el
        // mensaje es leerlo en voz alta, como si se lo mostráramos a la
        // otra persona (el avatar firmado queda pendiente de conectar).
        await BlindNarrator.speak(heard);
      }
      if (!isCurrent()) return;
      prompt = 'Habla ahora.';
      setState(() => _voiceStatus = prompt);
    }
  }

  /// Captura un mensaje por voz con un solo intento: a diferencia de
  /// [_runVoiceComposeFlow] (que toma control de TODA la pantalla por
  /// voz, pensado para cuando quien usa el teléfono es ciego/a), este es
  /// un botón simple de "presiona y habla" que cualquiera puede usar sin
  /// importar si el modo por voz de TalkBack está activo.
  ///
  /// Hace falta para [ComunicacionModo.avatar] cuando quien es ciego/a
  /// es la OTRA persona, no quien configuró su propio perfil ("mine"):
  /// en ese caso [BlindNarrator.talkBackFlow] nunca se activa en este
  /// teléfono (se activa según el perfil de "mine", ver
  /// ProfileSelectionScreen), así que sin este botón la persona ciega no
  /// tendría ninguna forma de dictar su mensaje para que el avatar lo
  /// firme. BlindNarrator.askMessage habla su instrucción sin importar
  /// si el modo por voz está activo (no pasa por [BlindNarrator.speak],
  /// que si dependería de eso), así que igual sirve como aviso audible
  /// de "ya puedes hablar" para quien no puede ver el botón.
  Future<void> _dictarMensaje() async {
    setState(() {
      _listening = true;
      _voiceStatus = 'Escuchando...';
    });
    // La instrucción hablada solo si quien dicta no ve la pantalla (la otra
    // persona es ciega, o el modo por voz está encendido). A una persona
    // oyente o sorda que toca el micrófono no se le habla.
    final hablarInstruccion = BlindNarrator.talkBackFlow ||
        ConversationProfile.other == ProfileType.ciego;
    final heard = await BlindNarrator.askMessage(
      hablarInstruccion ? 'Dime tu mensaje.' : '',
      maxAttempts: 1,
      onPartialResult: (partial) {
        if (mounted && partial.isNotEmpty) {
          setState(() => _voiceStatus = 'Escuchando: $partial');
        }
      },
    );
    if (!mounted) return;
    setState(() {
      _listening = false;
      if (heard.isNotEmpty) {
        _controller.text = heard;
        _voiceStatus = 'Dijiste: $heard';
      } else {
        _voiceStatus = 'No escuché nada. Intenta de nuevo, o escribe tu '
            'mensaje.';
      }
    });
    if (heard.isNotEmpty) await _firmar(heard);
  }

  @override
  Widget build(BuildContext context) {
    // Sin subtítulo en la barra: menos texto y más alto para el avatar.
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: const UnivozHeader(),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: _buildForModo(),
        ),
      ),
    );
  }

  /// Elige la variante visual según [widget.modo] — ver el comentario de
  /// la clase para qué representa cada uno. La narración/composición
  /// por voz para quien es ciego/a (ver [_runVoiceComposeFlow]) corre
  /// por encima de la variante elegida aquí, sin reemplazarla: por eso
  /// [ComunicacionModo.textoVoz] es el único caso que distingue entre
  /// blind/no-blind (es la única variante que también aplica cuando no
  /// hace falta avatar ni cámara).
  Widget _buildForModo() {
    switch (widget.modo) {
      case ComunicacionModo.avatar:
        return _buildLsmVariant();
      case ComunicacionModo.camaraSenas:
        return _buildLsmVariant();
      case ComunicacionModo.soloTexto:
        return _buildSoloTextoVariant();
      case ComunicacionModo.noNecesitaApp:
        return _buildNoNecesitaAppVariant();
      case ComunicacionModo.textoVoz:
        return BlindNarrator.talkBackFlow
            ? _buildBlindVariant()
            : _buildTextVoiceVariant();
    }
  }

  /// Variante especial para quien usa el teléfono y es ciego/a, cuando
  /// no hace falta avatar ni cámara ([ComunicacionModo.textoVoz]): solo
  /// el cuadro de mensaje (que se llena por voz) y el estado/instrucción
  /// actual — nada que dependa de tocar la pantalla con precisión, ya
  /// que toda la interacción real ocurre hablando y escuchando.
  Widget _buildBlindVariant() {
    // Sin desplazar: el cuadro del mensaje toma el alto que quede, así que
    // si el mensaje reconocido crece, se acomoda dentro del cuadro.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildVoiceStatusBanner(),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: 'Tu mensaje va a aparecer aquí...',
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: ColoresUnivoz.bordeControl),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        const SosButton(),
      ],
    );
  }

  /// Variante con avatar de señas ([ComunicacionModo.avatar]). Se
  /// muestra sin importar si quien usa el teléfono es ciego/a: el
  /// avatar es para que lo lea la OTRA persona (que es sorda y conoce
  /// LSM), y si además quien usa el teléfono es ciego/a,
  /// [_runVoiceComposeFlow] sigue narrando y componiendo el mensaje por
  /// voz por encima de esta misma pantalla.
  Widget _buildLsmVariant() {
    // Una persona sabe LSM y la otra no. Sin desplazar: arriba el avatar (lo
    // que la otra persona escribe o dice, el avatar lo firma) y abajo la
    // cámara, grande, como FONDO de los controles (quien firma: su seña se
    // vuelve texto y, si del otro lado alguien oye, voz). Los controles van
    // encima, chicos y semitransparentes, para no tapar la seña.
    final colores = Theme.of(context).colorScheme;
    // En camaraSenas las dos personas son sordas/mudas: nadie dicta ni
    // escucha, se escribe.
    final conVoz = widget.modo == ComunicacionModo.avatar;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (BlindNarrator.talkBackFlow) ...[
          _buildVoiceStatusBanner(),
          const SizedBox(height: 6),
        ],
        Expanded(
          flex: 4,
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: ColoresUnivoz.moradoTenue,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: VistaAvatar(bridge: _avatarBridge),
                  ),
                ),
                if (_listening)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: colores.error,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.mic,
                          color: Colors.white,
                          size: 18,
                          semanticLabel: 'Escuchando'),
                    ),
                  ),
                if (_avatarReproduciendo)
                  const Positioned(
                    right: 10,
                    bottom: 10,
                    child: Chip(
                      avatar: Icon(Icons.front_hand, size: 18),
                      label: Text('Señando...'),
                    ),
                  ),
                if (_voiceStatus.isNotEmpty && !_avatarReproduciendo)
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _voiceStatus,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          flex: 6,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_camaraActiva)
                  PantallaDeTranslacion(
                    conAvatar: false,
                    embebida: true,
                    hablarResultado: conVoz,
                    onReconocido: (texto) {
                      final espera = _esperaSena;
                      if (espera != null && !espera.isCompleted) {
                        espera.complete(texto);
                      }
                    },
                  )
                else
                  _botonActivarCamara(),
                // SOS chico arriba a la derecha (se mantiene presionado).
                const Positioned(
                  top: 56,
                  right: 10,
                  child: SosButton(compacto: true),
                ),
                // Controles encima de la cámara, abajo.
                Positioned(
                  left: 8,
                  right: 8,
                  bottom: 8,
                  child: _controlesSobreCamara(conVoz),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Deletreo/Palabra, el mensaje, Señar y el micrófono: chicos y
  /// semitransparentes sobre la cámara.
  Widget _controlesSobreCamara(bool conVoz) {
    final colores = Theme.of(context).colorScheme;
    final translucido = Colors.white.withValues(alpha: 0.88);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _pastillaModo('Deletreo', _isSpelling,
                  () => setState(() => _isSpelling = true)),
              _pastillaModo('Palabra', !_isSpelling,
                  () => setState(() => _isSpelling = false)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                textInputAction: TextInputAction.send,
                onSubmitted: _firmar,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Escribe aquí...',
                  isDense: true,
                  filled: true,
                  fillColor: translucido,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Señar sin tener que dar Enter en el teclado.
            IconButton.filled(
              onPressed: () => _firmar(_controller.text),
              icon: const Icon(Icons.play_arrow_rounded),
              tooltip: 'Señar',
            ),
            if (conVoz)
              IconButton.filled(
                onPressed: _listening ? null : _dictarMensaje,
                icon: Icon(_listening ? Icons.mic : Icons.mic_none),
                tooltip: 'Hablar para que el avatar firme',
                style: IconButton.styleFrom(
                  backgroundColor: colores.secondary,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _pastillaModo(String texto, bool elegida, VoidCallback alTocar) {
    return Semantics(
      button: true,
      selected: elegida,
      child: GestureDetector(
        onTap: alTocar,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: elegida ? ColoresUnivoz.morado : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            texto,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// Mitad de cámara antes de tener permiso: dibujo y un botón.
  Widget _botonActivarCamara() {
    return Material(
      color: ColoresUnivoz.moradoTenue,
      child: InkWell(
        onTap: _pidiendoPermisoCamara ? null : _activarCamara,
        child: Semantics(
          button: true,
          label: 'Activar la cámara para traducir las señas',
          excludeSemantics: true,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Image.asset(
                  'assets/ilustraciones/traducir.png',
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
              const SizedBox(height: 6),
              _pidiendoPermisoCamara
                  ? const CircularProgressIndicator()
                  : const Text(
                      'Activar cámara',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800),
                    ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// Variante de texto/voz simple ([ComunicacionModo.textoVoz] sin
  /// ceguera: por ejemplo con una persona oyente, una sorda que no
  /// conoce LSM, o una muda).
  Widget _buildTextVoiceVariant() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Escribe para escuchar',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: 'Escribe aquí tu mensaje...',
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: ColoresUnivoz.bordeControl),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        ControlesVozMensaje(controlador: _controller),
        const SizedBox(height: 10),
        const SosButton(),
      ],
    );
  }

  /// Variante de puro texto ([ComunicacionModo.soloTexto]): las dos
  /// personas son sordas/mudas y ninguna conoce LSM, así que no hay
  /// nada que la cámara pueda traducir. Sin botones de voz: ninguna de
  /// las dos puede oír una lectura en voz alta ni tiene sentido dictar
  /// si del otro lado nadie firma.
  Widget _buildSoloTextoVariant() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Escribe y lee',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: TextField(
            controller: _controller,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            // Letra grande: la otra persona lo lee en la pantalla.
            style: const TextStyle(fontSize: 22, height: 1.3),
            decoration: InputDecoration(
              hintText: 'Escribe aquí tu mensaje...',
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: ColoresUnivoz.bordeControl),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const SosButton(),
      ],
    );
  }

  /// Las dos personas son sordas/mudas y ambas conocen LSM
  /// ([ComunicacionModo.noNecesitaApp]): no hace falta esta pantalla,
  /// pueden firmar directamente entre ellas.
  Widget _buildNoNecesitaAppVariant() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.pan_tool, size: 56, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              'Los dos saben LSM',
              semanticsLabel: 'Los dos conocen Lengua de Señas Mexicana. '
                  'Pueden comunicarse firmando directamente, sin necesidad '
                  'de esta pantalla.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceStatusBanner() {
    return Row(
      children: [
        if (_listening)
          Container(
            margin: const EdgeInsets.only(right: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.error,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'Escuchando...',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700),
            ),
          ),
        Expanded(
          child: Text(
            _voiceStatus,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ColoresUnivoz.tintaSuave,
            ),
          ),
        ),
      ],
    );
  }
}
