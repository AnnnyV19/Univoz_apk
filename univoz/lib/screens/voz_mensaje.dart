import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/permiso_camara.dart';
import '../services/voz.dart';
import 'sos.dart' show aperturasSos;

/// Los dos botones de voz de "Comunicarse" (texto y voz): "Leer en voz
/// alta" lee el mensaje que hay en [controlador] y "Dictar con voz" lo
/// escribe a partir de lo que la persona dice.
///
/// [lector], [dictado] y [permisos] solo se pasan en pruebas; sin ellos se
/// usan los reales (flutter_tts, speech_to_text y permission_handler).
class ControlesVozMensaje extends StatefulWidget {
  final TextEditingController controlador;
  final LectorVoz? lector;
  final DictadoVoz? dictado;
  final AdaptadorPermiso? permisos;

  const ControlesVozMensaje({
    super.key,
    required this.controlador,
    this.lector,
    this.dictado,
    this.permisos,
  });

  @override
  State<ControlesVozMensaje> createState() => _ControlesVozMensajeState();
}

class _ControlesVozMensajeState extends State<ControlesVozMensaje> {
  late final LectorVoz _lector = widget.lector ?? LectorVozTts();
  late final DictadoVoz _dictado = widget.dictado ?? DictadoVozStt();

  bool _leyendo = false;
  bool _escuchando = false;
  bool _preparando = false;
  bool _pidiendoPermiso = false;
  bool _dictadoNoDisponible = false;

  /// Volumen reciente de la voz (0 a 1), el más nuevo al final.
  static const int _kMuestras = 28;
  final List<double> _niveles =
      List<double>.filled(_kMuestras, 0, growable: true);

  /// Texto que ya había antes de dictar: lo dictado se agrega después.
  String _base = '';

  // Cada sesión de lectura/dictado lleva un número; un aviso tardío de una
  // sesión anterior (por ejemplo, el "terminó" de la lectura que se acaba
  // de cortar) no debe apagar la sesión nueva.
  int _sesionLectura = 0;
  int _sesionDictado = 0;

  @override
  void initState() {
    super.initState();
    aperturasSos.addListener(_alAbrirSos);
  }

  /// Se abrió la pantalla de emergencia: callar lo que esté sonando.
  void _alAbrirSos() {
    if (_escuchando) _pararDictado();
    if (_leyendo) {
      _sesionLectura++;
      setState(() => _leyendo = false);
      _lector.detener();
    }
  }

  @override
  void dispose() {
    aperturasSos.removeListener(_alAbrirSos);
    _sesionLectura++;
    _sesionDictado++;
    _lector.detener();
    _dictado.detener();
    super.dispose();
  }

  void _aviso(String texto) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _alternarLectura() async {
    if (_leyendo) {
      _sesionLectura++;
      setState(() => _leyendo = false);
      await _lector.detener();
      return;
    }
    final texto = widget.controlador.text.trim();
    if (texto.isEmpty) return;
    if (_escuchando) await _pararDictado();
    final sesion = ++_sesionLectura;
    setState(() => _leyendo = true);
    try {
      await _lector.hablar(texto, alTerminar: () {
        if (mounted && sesion == _sesionLectura) {
          setState(() => _leyendo = false);
        }
      });
    } catch (_) {
      if (mounted && sesion == _sesionLectura) {
        setState(() => _leyendo = false);
        _aviso('No pude leer tu mensaje en voz alta. Inténtalo de nuevo.');
      }
    }
  }

  Future<void> _pararDictado() async {
    _sesionDictado++;
    if (mounted) setState(() => _escuchando = false);
    await _dictado.detener();
  }

  Future<void> _alternarDictado() async {
    if (_escuchando) {
      await _pararDictado();
      return;
    }
    if (_preparando || _pidiendoPermiso) return;
    _pidiendoPermiso = true;
    final permitido = await pedirPermiso(
      context,
      Permission.microphone,
      'Univoz usa el micrófono solo mientras dictas, para escribir lo que '
      'dices. El audio no se guarda.',
      titulo: 'Permiso de micrófono',
      icono: Icons.mic_none,
      mensajeNegado: 'Sin el micrófono no puedo escucharte. '
          'Puedes permitirlo cuando quieras.',
      tituloAjustes: 'El micrófono está desactivado',
      textoAjustes: 'Para dictar, permite el micrófono en los ajustes de tu '
          'teléfono.',
      adaptador: widget.permisos,
    );
    _pidiendoPermiso = false;
    if (!mounted || !permitido) return;
    setState(() => _preparando = true);
    final listo = await _dictado.preparar();
    if (!mounted) return;
    if (!listo) {
      setState(() {
        _preparando = false;
        _dictadoNoDisponible = true;
      });
      _aviso('Tu teléfono no puede dictar por voz.');
      return;
    }
    if (_leyendo) {
      _sesionLectura++;
      _leyendo = false;
      await _lector.detener();
      if (!mounted) return;
    }
    final sesion = ++_sesionDictado;
    _base = widget.controlador.text;
    _niveles.fillRange(0, _kMuestras, 0);
    setState(() {
      _preparando = false;
      _escuchando = true;
    });
    await _dictado.escuchar(
      alTexto: (texto, esFinal) {
        if (!mounted || sesion != _sesionDictado) return;
        _ponerTexto(texto);
      },
      alNivel: (nivel) {
        if (!mounted || sesion != _sesionDictado) return;
        setState(() {
          _niveles.removeAt(0);
          _niveles.add(nivel);
        });
      },
      alTerminar: (huboError) {
        if (!mounted || sesion != _sesionDictado) return;
        setState(() => _escuchando = false);
        if (huboError) _aviso('No pude escucharte. Inténtalo de nuevo.');
      },
    );
  }

  /// Escribe lo dictado después de lo que ya había, sin repetirlo cada vez
  /// que llega un resultado parcial nuevo.
  void _ponerTexto(String dictado) {
    if (dictado.isEmpty) return;
    final separador = _base.isEmpty || _base.endsWith(' ') ? '' : ' ';
    final nuevo = '$_base$separador$dictado';
    widget.controlador.value = TextEditingValue(
      text: nuevo,
      selection: TextSelection.collapsed(offset: nuevo.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: widget.controlador,
          builder: (context, valor, _) {
            final hayTexto = valor.text.trim().isNotEmpty;
            final puede = hayTexto || _leyendo;
            return Tooltip(
              message: puede
                  ? (_leyendo ? 'Detener la lectura' : 'Leer tu mensaje')
                  : 'Escribe o dicta un mensaje primero',
              child: SizedBox(
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: puede ? _alternarLectura : null,
                  icon: Icon(_leyendo ? Icons.stop : Icons.volume_up),
                  label: Text(_leyendo ? 'Detener' : 'Leer en voz alta'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colores.secondary,
                    foregroundColor: colores.onSecondary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        Tooltip(
          message: _dictadoNoDisponible
              ? 'Tu teléfono no puede dictar por voz'
              : (_escuchando
                  ? 'Toca para dejar de dictar'
                  : 'Dictar tu mensaje'),
          child: SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _dictadoNoDisponible ? null : _alternarDictado,
              icon: _preparando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_escuchando ? Icons.mic : Icons.mic_none,
                      color: _escuchando ? colores.error : null),
              label: Text(_escuchando ? 'Escuchando...' : 'Dictar con voz'),
              style: OutlinedButton.styleFrom(
                foregroundColor: colores.onSurface,
                side: BorderSide(
                    color: _escuchando ? colores.error : colores.outline),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ),
        if (_escuchando) ...[
          const SizedBox(height: 10),
          Semantics(
            label: 'Escuchando tu voz',
            liveRegion: true,
            child: ExcludeSemantics(
              child: _IndicadorNivel(niveles: _niveles, color: colores.error),
            ),
          ),
        ],
      ],
    );
  }
}

/// Barritas que suben y bajan con el volumen de la voz mientras se dicta.
class _IndicadorNivel extends StatelessWidget {
  final List<double> niveles;
  final Color color;

  const _IndicadorNivel({required this.niveles, required this.color});

  static const double _kAlto = 36;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('indicador-nivel'),
      height: _kAlto,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final n in niveles)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 90),
                width: 4,
                height: 4 + n * (_kAlto - 4),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
