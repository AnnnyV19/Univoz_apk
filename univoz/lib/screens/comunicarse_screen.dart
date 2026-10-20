import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:senas_core/skeleton_painter.dart' show PantallaDeTranslacion;
import 'univoz_shared_widgets.dart';
import 'profile_selection_screen.dart' show ProfileType;
import '../services/blind_narrator.dart';
import '../services/conversation_profile.dart';

/// Pestaña "Comunicarse". Se adapta según la combinación de perfiles
/// guardada en pasos anteriores del flujo (ver
/// [ConversationProfile]/[resolverComunicacionModo]), en vez de tener una
/// pantalla separada por cada combinación posible:
///
/// - [ComunicacionModo.avatar]      -> la otra persona es sorda y SÍ
///   conoce LSM: se muestra el avatar firmando, deletreo/palabra y
///   teclado en pantalla (además del texto).
/// - [ComunicacionModo.textoVoz]    -> comunicación simple de texto/voz
///   (ej. con una persona oyente, una sorda que no conoce LSM, o una
///   muda).
/// - [ComunicacionModo.camaraSenas] -> las dos personas son sordas/mudas
///   y solo una de las dos conoce LSM: se usa la cámara (el mismo
///   reconocedor de "Traducir señas") para traducir a texto lo que
///   firma quien sabe, y la respuesta se escribe directamente.
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
  final TextEditingController _traducidoController = TextEditingController();
  bool _isSpelling = true; // Deletreo vs Palabra
  bool _listening = false;
  bool _pidiendoPermisoCamara = false;

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

  static const Color _bgColor = Color(0xFFF7F2FA);

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
    if (BlindNarrator.talkBackFlow && widget.isActiveTab) {
      _startVoiceFlow();
    }
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
    _traducidoController.dispose();
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

  bool _isExitPhrase(String text) => _exitPhrases.contains(text.trim().toLowerCase());

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
    bool isCurrent() => mounted &&
        generation == _voiceFlowGeneration &&
        widget.isActiveTab;

    var prompt = _personalizedIntro();
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
        prompt = 'No escuché nada. Dime el mensaje que quieres '
            'comunicar, o di salir para salir de esta pantalla.';
        if (isCurrent()) setState(() => _voiceStatus = prompt);
        continue;
      }
      consecutiveSilence = 0;
      setState(() {
        _controller.text = heard;
        _voiceStatus = 'Dijiste: $heard';
      });
      await BlindNarrator.speak('Dijiste: $heard.');
      if (!isCurrent()) return;
      if (widget.modo == ComunicacionModo.avatar) {
        await BlindNarrator.speak('Tu mensaje quedó listo para '
            'mostrarse firmado.');
      } else {
        // Sin avatar de señas, la forma más directa de "entregar" el
        // mensaje es leerlo en voz alta, como si se lo mostráramos a la
        // otra persona (el avatar firmado queda pendiente de conectar).
        await BlindNarrator.speak(heard);
      }
      if (!isCurrent()) return;
      prompt = '¿Quieres decir algo más? Dime tu siguiente mensaje, o '
          'di salir para salir de esta pantalla.';
      setState(() => _voiceStatus = prompt);
    }
  }

  /// Pide permiso de cámara antes de abrir el reconocedor de señas
  /// (mismo patrón que TraducirSenasScreen). Devuelve true si ya se
  /// puede continuar.
  Future<bool> _asegurarPermisoCamara() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;
    setState(() => _pidiendoPermisoCamara = true);
    final resultado = await Permission.camera.request();
    if (mounted) setState(() => _pidiendoPermisoCamara = false);
    if (resultado.isGranted) return true;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
            'Sin permiso de cámara no se puede traducir lengua de señas.'),
        action: SnackBarAction(label: 'Ajustes', onPressed: openAppSettings),
      ),
    );
    return false;
  }

  Future<void> _abrirCamaraTraductora() async {
    if (!await _asegurarPermisoCamara()) return;
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PantallaDeTranslacion()),
    );
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
    final heard = await BlindNarrator.askMessage(
      'Dime tu mensaje.',
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
  }

  @override
  Widget build(BuildContext context) {
    final String? subtitulo = switch (widget.modo) {
      ComunicacionModo.avatar => 'Avatar en Lengua de Señas',
      ComunicacionModo.camaraSenas => 'Traducir señas',
      _ => null,
    };
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: UnivozHeader(subtitle: subtitulo),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
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
        return _buildCameraSenasVariant();
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
    // Con scroll en vez de un Column con Expanded a pantalla completa:
    // así, si el mensaje que se va reconociendo en vivo (ver
    // _runVoiceComposeFlow) crece a varias líneas, el resto del
    // contenido se acomoda en vez de aplastarse ("verse encimado").
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_listening)
                Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE85D5D),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Text(
                    'Escuchando...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  _voiceStatus,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B6478),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 220,
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
                  borderSide: const BorderSide(color: Color(0xFFB388E8)),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const SosButton(),
        ],
      ),
    );
  }

  /// Variante con avatar de señas ([ComunicacionModo.avatar]). Se
  /// muestra sin importar si quien usa el teléfono es ciego/a: el
  /// avatar es para que lo lea la OTRA persona (que es sorda y conoce
  /// LSM), y si además quien usa el teléfono es ciego/a,
  /// [_runVoiceComposeFlow] sigue narrando y componiendo el mensaje por
  /// voz por encima de esta misma pantalla.
  Widget _buildLsmVariant() {
    // Todo el contenido va dentro de un scroll: antes era un Column fijo
    // (con un Expanded para el recuadro del avatar) y, apenas se le
    // agregó el letrero de estado de voz arriba, ya no cabía completo en
    // pantallas más chicas — eso es lo que se veía "encimado" (el
    // recuadro del avatar, los botones y el teclado se aplastaban unos
    // sobre otros en vez de acomodarse). Con scroll, cada sección tiene
    // su tamaño natural y, si no cabe todo de una vez, se desliza en vez
    // de recortarse.
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (BlindNarrator.talkBackFlow) ...[
            _buildVoiceStatusBanner(),
            const SizedBox(height: 10),
          ],
          Text(
            'Firmar y hablar, cada quien a su manera',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: Colors.grey.shade900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Quien firma abre la cámara para que se lea en voz alta lo '
            'que dice; quien habla usa el micrófono y el avatar lo '
            'firma en pantalla.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _lsmActionButton(
                  icon: Icons.videocam,
                  label: 'Traducir señas\ny leerlas en voz alta',
                  color: const Color(0xFF6C63FF),
                  busy: _pidiendoPermisoCamara,
                  onTap: _pidiendoPermisoCamara
                      ? null
                      : _abrirCamaraTraductora,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _lsmActionButton(
                  icon: _listening ? Icons.mic : Icons.mic_none,
                  label: _listening
                      ? 'Escuchando...'
                      : 'Hablar para que\nel avatar firme',
                  color: _listening
                      ? const Color(0xFFE85D5D)
                      : const Color(0xFF8B5CF6),
                  busy: false,
                  onTap: _listening ? null : _dictarMensaje,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            height: 200,
            decoration: BoxDecoration(
              color: const Color(0xFFEDE4FB),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Stack(
              children: [
                const Center(
                  child: Icon(Icons.person,
                      size: 100, color: Color(0xFF8B5CF6)),
                ),
                if (_listening)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE85D5D),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'Escuchando...',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _segmentButton(
                  label: 'Deletreo',
                  selected: _isSpelling,
                  color: const Color(0xFF3FBF8F),
                  onTap: () => setState(() => _isSpelling = true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _segmentButton(
                  label: 'Palabra',
                  selected: !_isSpelling,
                  color: const Color(0xFFE85DA0),
                  onTap: () => setState(() => _isSpelling = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              hintText: 'Tu mensaje aquí...',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // El teclado en pantalla no le sirve a quien es ciego/a (no
          // puede verlo para tocar la tecla correcta): cuando el modo
          // por voz está activo, el cuadro de texto ya se llena
          // hablando (ver _dictarMensaje / _runVoiceComposeFlow), así
          // que no hace falta mostrarlo.
          if (!BlindNarrator.talkBackFlow) ...[
            _buildSimpleKeyboard(),
            const SizedBox(height: 12),
          ],
          const SosButton(),
        ],
      ),
    );
  }

  Widget _lsmActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required bool busy,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ],
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
        const Text(
          'Escribe para escuchar',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1A1A2E),
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
                borderSide: const BorderSide(color: Color(0xFFB388E8)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: () {
              // TODO: convertir _controller.text a voz (TTS) y reproducir.
            },
            icon: const Icon(Icons.volume_up, color: Colors.white),
            label: const Text('Leer en voz alta',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: OutlinedButton.icon(
            onPressed: () {
              setState(() => _listening = !_listening);
              // TODO: iniciar/detener dictado por voz (speech-to-text).
            },
            icon: Icon(Icons.mic,
                color: _listening ? Colors.red : const Color(0xFF3A2A5C)),
            label: Text(
              _listening ? 'Escuchando...' : 'Dictar con voz',
              style: const TextStyle(color: Color(0xFF3A2A5C)),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF3A2A5C)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const SosButton(),
        const SizedBox(height: 14),
        _buildAudioPlayerPlaceholder(),
      ],
    );
  }

  /// Variante de cámara ([ComunicacionModo.camaraSenas]): las dos
  /// personas son sordas/mudas y solo una de las dos conoce LSM. Se usa
  /// el mismo reconocedor de señas de "Traducir señas" (cámara +
  /// MediaPipe) para convertir a texto lo que firma quien sabe LSM; la
  /// respuesta de quien no firma se escribe directamente, porque
  /// ninguna de las dos personas puede oír una lectura en voz alta.
  Widget _buildCameraSenasVariant() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Traducir señas a texto',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Uno de los dos conoce Lengua de Señas Mexicana: abre la '
          'cámara para traducir sus señas a texto. El otro responde '
          'escribiendo directamente, ya que ninguno puede oír una '
          'lectura en voz alta.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _pidiendoPermisoCamara ? null : _abrirCamaraTraductora,
            icon: _pidiendoPermisoCamara
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.videocam, color: Colors.white),
            label: const Text('Abrir cámara y traducir señas',
                style: TextStyle(color: Colors.white)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'Texto traducido / respuesta escrita',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: _traducidoController,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              hintText: 'Aquí aparece la seña traducida, o escribe tu '
                  'respuesta...',
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.all(16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: Color(0xFFB388E8)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
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
        const Text(
          'Escribir directamente',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Color(0xFF1A1A2E),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Ninguno de los dos conoce Lengua de Señas Mexicana: '
          'escríbanse directamente.',
          style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
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
                borderSide: const BorderSide(color: Color(0xFFB388E8)),
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
              'Los dos conocen Lengua de Señas Mexicana',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Pueden comunicarse firmando directamente, sin necesidad '
              'de esta pantalla.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
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
              color: const Color(0xFFE85D5D),
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
              color: Color(0xFF6B6478),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAudioPlayerPlaceholder() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('00:00', style: TextStyle(fontSize: 12)),
              Text('00:00', style: TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 6),
          // TODO: reemplazar por una forma de onda real del audio recibido.
          Container(height: 30, color: const Color(0xFFEDE4FB)),
          const SizedBox(height: 8),
          CircleAvatar(
            radius: 20,
            backgroundColor: const Color(0xFF3A2A5C),
            child: const Icon(Icons.play_arrow, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Inserta [letter] en la posición actual del cursor (en vez de siempre
  /// al final), y mantiene el cursor justo después de la letra insertada.
  void _insertLetter(String letter) {
    final text = _controller.text;
    final selection = _controller.selection;
    final start = selection.start >= 0 ? selection.start : text.length;
    final end = selection.end >= 0 ? selection.end : text.length;
    final newText = text.replaceRange(start, end, letter);
    _controller.value = _controller.value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + letter.length),
      composing: TextRange.empty,
    );
  }

  Widget _buildSimpleKeyboard() {
    const rows = [
      'QWERTYUIOP',
      'ASDFGHJKL',
      'ZXCVBNM',
    ];
    return Column(
      children: rows
          .map(
            (row) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: row.split('').map((letter) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: Material(
                          color: const Color(0xFFEDE4FB),
                          borderRadius: BorderRadius.circular(6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => _insertLetter(letter),
                            child: Center(
                              child: Text(letter,
                                  style: const TextStyle(fontSize: 12)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _segmentButton({
    required String label,
    required bool selected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected ? color : color.withOpacity(0.25),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.white : const Color(0xFF1A1A2E),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
