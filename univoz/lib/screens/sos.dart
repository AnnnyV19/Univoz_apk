import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/contacto_emergencia.dart';
import '../services/conversation_profile.dart';
import '../services/perfil_guardado.dart';
import '../services/perfiles.dart';
import '../services/voz.dart';

/// Lo que se le muestra y se le lee en voz alta a quien pueda ayudar.
///
/// Dice cómo ayudar a esta persona (cómo comunicarse con ella), no lo que
/// "le falta". Depende del perfil ([tipo]); para oyente, "prestar
/// celular", sin perfil o con [mencionarCondicion] apagado sale el texto
/// neutro. [nombre] va justo después de "Necesito ayuda." y
/// [sabeLsm] solo cuenta para el perfil sordo.
String mensajeSos({
  ProfileType? tipo,
  String? nombre,
  bool sabeLsm = false,
  bool mencionarCondicion = true,
}) {
  final n = (nombre ?? '').trim();
  final quien = n.isEmpty ? '' : ' Me llamo $n.';
  final guia = switch (mencionarCondicion ? tipo : null) {
    ProfileType.sordo => ' Soy una persona sorda. Por favor, escríbeme o '
        'háblame de frente y despacio.${sabeLsm ? ' Me comunico en Lengua '
            'de Señas Mexicana.' : ''}',
    ProfileType.mudo => ' Te escucho bien, pero me comunico por escrito. '
        'Por favor, lee mi pantalla.',
    ProfileType.ciego => ' Soy una persona ciega. Por favor, dime quién '
        'eres y qué está pasando, y avísame antes de tocarme.',
    _ => ' Por favor, llama a emergencias o a mi contacto.',
  };
  return 'Necesito ayuda.$quien$guia';
}

/// El SMS al contacto de emergencia: corto, no explica nada de la
/// condición porque el contacto ya conoce a la persona.
String mensajeSmsContacto(String? nombre) {
  final n = (nombre ?? '').trim();
  return n.isEmpty
      ? 'Necesito ayuda. Te escribo desde Univoz.'
      : 'Soy $n, necesito ayuda. Te escribo desde Univoz.';
}

/// El SMS cuando el teléfono está prestado: lo recibe el contacto de la
/// dueña, así que tiene que decir que escribe quien lo está usando y no ella.
/// [nombreDueno] es el de la dueña (puede no saberse).
String mensajeSmsPrestado(String? nombreDueno) {
  final n = (nombreDueno ?? '').trim();
  return n.isEmpty
      ? 'Te escribo con Univoz desde un teléfono prestado: la persona que lo '
          'está usando necesita ayuda.'
      : 'Te escribo desde el teléfono de $n con Univoz: la persona que lo '
          'está usando necesita ayuda.';
}

/// Lo que la app sabe de quien está usando el teléfono ahorita, para armar
/// los mensajes de SOS.
///
/// Con el teléfono prestado ([ConversationProfile.prestado]) quien lo usa
/// no es su dueña: el nombre guardado no debe salir en la ayuda de otra
/// persona, y tampoco su mensaje personalizado ni su preferencia de
/// mencionar la condición (son de la dueña).
class _QuienPideAyuda {
  final ProfileType? tipo;
  final bool sabeLsm;
  final bool esLaDuena;

  _QuienPideAyuda._(this.tipo, this.sabeLsm, this.esLaDuena);

  factory _QuienPideAyuda() {
    final enUso = ConversationProfile.mine;
    final guardado = PerfilGuardado.tipo;
    // Además de la señal explícita, un perfil en uso distinto del guardado
    // también delata que no es su dueña (sin perfil guardado no hay con
    // quién comparar).
    final esLaDuena = !ConversationProfile.prestado &&
        (guardado == null || enUso == null || enUso == guardado);
    return _QuienPideAyuda._(
      enUso ?? guardado,
      enUso != null ? ConversationProfile.mineKnowsLsm : PerfilGuardado.sabeLsm,
      esLaDuena,
    );
  }

  String? get nombre => esLaDuena ? PerfilGuardado.nombre : null;
}

/// El texto final de pantalla y voz. Es el único lugar que lo arma.
///
/// [mencionarCondicion] y [personalizado] solo los pasa la vista previa
/// del formulario (para mostrar lo que quedaría antes de guardar); si no,
/// se usa lo guardado.
String mensajeSosActual({bool? mencionarCondicion, String? personalizado}) {
  final q = _QuienPideAyuda();
  final propio = q.esLaDuena
      ? (personalizado ?? PerfilGuardado.mensajeSosPersonalizado)?.trim()
      : null;
  if (propio != null && propio.isNotEmpty) return propio;
  return mensajeSos(
    tipo: q.tipo,
    nombre: q.nombre,
    sabeLsm: q.sabeLsm,
    mencionarCondicion: q.esLaDuena
        ? (mencionarCondicion ?? PerfilGuardado.mencionarCondicion)
        : true,
  );
}

/// El SMS que se manda al contacto de emergencia: con el nombre de quien
/// pide ayuda si es su dueña; con el teléfono prestado, avisa que quien
/// escribe no es ella.
String mensajeSmsActual() {
  final q = _QuienPideAyuda();
  return q.esLaDuena
      ? mensajeSmsContacto(q.nombre)
      : mensajeSmsPrestado(PerfilGuardado.nombre);
}

/// Sube cada vez que se abre [PantallaSos]. Lo que esté usando el
/// micrófono o la bocina por debajo (dictado, lectura) lo escucha para
/// callarse y no encimarse con la pantalla de emergencia.
final ValueNotifier<int> aperturasSos = ValueNotifier<int>(0);

/// Número de emergencias en México.
const String kNumeroEmergencias = '911';

/// Pantalla completa de emergencia: un mensaje enorme y de mucho contraste
/// para enseñárselo a quien esté cerca, y los atajos para pedir ayuda sin
/// buscar nada (llamar o escribir al contacto, llamar al 911, leer el
/// mensaje en voz alta).
///
/// [lanzador] y [lector] solo se pasan en pruebas.
class PantallaSos extends StatefulWidget {
  final LanzadorUrl? lanzador;
  final LectorVoz? lector;

  const PantallaSos({super.key, this.lanzador, this.lector});

  @override
  State<PantallaSos> createState() => _PantallaSosState();
}

class _PantallaSosState extends State<PantallaSos> {
  late final LanzadorUrl _lanzador = widget.lanzador ?? const LanzadorUrlReal();
  late final LectorVoz _lector = widget.lector ?? LectorVozTts();

  ContactoEmergencia? _contacto = PerfilGuardado.contactoEmergencia;
  bool _leyendo = false;
  int _sesionLectura = 0;

  String get _mensaje => mensajeSosActual();

  @override
  void dispose() {
    _sesionLectura++;
    _lector.detener();
    super.dispose();
  }

  void _aviso(String texto) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _llamar(String telefono) async {
    final ok = await _lanzador.abrir(Uri(scheme: 'tel', path: telefono));
    if (!ok) _aviso('No pude abrir el teléfono. Marca el $telefono tú mismo.');
  }

  Future<void> _enviarSms(String telefono) async {
    // El texto se codifica a mano: Uri.queryParameters pone "+" en vez de
    // %20 y varias apps de mensajes lo muestran tal cual.
    final uri = Uri.parse(
        'sms:$telefono?body=${Uri.encodeComponent(mensajeSmsActual())}');
    final ok = await _lanzador.abrir(uri);
    if (!ok) _aviso('No pude abrir los mensajes en este teléfono.');
  }

  Future<void> _llamar911() async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (dialogo) => AlertDialog(
        title: const Text('¿Llamar al 911?'),
        content: const Text(
            'Se abrirá el teléfono con el $kNumeroEmergencias listo para '
            'marcar.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogo).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogo).pop(true),
            child: const Text('Llamar'),
          ),
        ],
      ),
    );
    if (confirmado == true) await _llamar(kNumeroEmergencias);
  }

  Future<void> _alternarLectura() async {
    if (_leyendo) {
      _sesionLectura++;
      setState(() => _leyendo = false);
      await _lector.detener();
      return;
    }
    final sesion = ++_sesionLectura;
    setState(() => _leyendo = true);
    try {
      await _lector.hablar(_mensaje, alTerminar: () {
        if (mounted && sesion == _sesionLectura) {
          setState(() => _leyendo = false);
        }
      });
    } catch (_) {
      if (mounted && sesion == _sesionLectura) {
        setState(() => _leyendo = false);
        _aviso('No pude leer el mensaje en voz alta.');
      }
    }
  }

  Future<void> _configurarContacto() async {
    final guardado = await Navigator.of(context).push<ContactoEmergencia?>(
      MaterialPageRoute(
        builder: (_) => const PantallaContactoEmergencia(),
      ),
    );
    if (!mounted) return;
    // El formulario ya guardó (o quitó) el contacto: se relee de ahí.
    setState(() => _contacto = guardado ?? PerfilGuardado.contactoEmergencia);
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final contacto = _contacto;
    return Scaffold(
      backgroundColor: colores.errorContainer,
      appBar: AppBar(
        backgroundColor: colores.error,
        foregroundColor: colores.onError,
        title: const Text('Emergencia'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cerrar',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                container: true,
                label: 'Mensaje de emergencia para mostrar',
                child: Card(
                  color: colores.surfaceContainerLowest,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(color: colores.error, width: 4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _mensaje,
                      key: const ValueKey('mensaje-sos'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        // Un mensaje largo (el sugerido o uno propio) tiene
                        // que seguir cabiendo sin esconderse.
                        fontSize: _mensaje.length > 140 ? 26 : 32,
                        height: 1.25,
                        fontWeight: FontWeight.w900,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              if (contacto != null) ...[
                _boton(
                  icono: Icons.call,
                  texto: 'Llamar a ${contacto.nombre}',
                  onPressed: () => _llamar(contacto.telefono),
                ),
                const SizedBox(height: 12),
                _boton(
                  icono: Icons.sms_outlined,
                  texto: 'Enviar SMS a ${contacto.nombre}',
                  onPressed: () => _enviarSms(contacto.telefono),
                  tonal: true,
                ),
              ] else
                _boton(
                  icono: Icons.person_add_alt_1,
                  texto: 'Configurar contacto de emergencia',
                  onPressed: _configurarContacto,
                ),
              const SizedBox(height: 12),
              _boton(
                icono: Icons.local_hospital_outlined,
                texto: 'Llamar al $kNumeroEmergencias',
                onPressed: _llamar911,
                peligro: true,
              ),
              const SizedBox(height: 12),
              _boton(
                icono: _leyendo ? Icons.stop : Icons.volume_up,
                texto: _leyendo ? 'Detener' : 'Leer en voz alta',
                onPressed: _alternarLectura,
                tonal: true,
              ),
              if (contacto != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _configurarContacto,
                  style: TextButton.styleFrom(
                    foregroundColor: colores.onErrorContainer,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  child: const Text('Cambiar contacto de emergencia'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _boton({
    required IconData icono,
    required String texto,
    required VoidCallback onPressed,
    bool tonal = false,
    bool peligro = false,
  }) {
    final colores = Theme.of(context).colorScheme;
    final contenido = Text(
      texto,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
    );
    const tamano = Size.fromHeight(64);
    if (tonal) {
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: Icon(icono, size: 28),
        label: contenido,
        style: FilledButton.styleFrom(minimumSize: tamano),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(icono, size: 28),
      label: contenido,
      style: FilledButton.styleFrom(
        minimumSize: tamano,
        backgroundColor: peligro ? colores.error : null,
        foregroundColor: peligro ? colores.onError : null,
      ),
    );
  }
}

/// Formulario del contacto de emergencia (nombre y teléfono). Se guarda en
/// [PerfilGuardado] y se devuelve con `Navigator.pop`.
class PantallaContactoEmergencia extends StatefulWidget {
  const PantallaContactoEmergencia({super.key});

  @override
  State<PantallaContactoEmergencia> createState() =>
      _PantallaContactoEmergenciaState();
}

class _PantallaContactoEmergenciaState
    extends State<PantallaContactoEmergencia> {
  final _formulario = GlobalKey<FormState>();
  late final TextEditingController _nombre = TextEditingController(
      text: PerfilGuardado.contactoEmergencia?.nombre ?? '');
  late final TextEditingController _telefono = TextEditingController(
      text: PerfilGuardado.contactoEmergencia?.telefono ?? '');
  late final TextEditingController _mensajeSos =
      TextEditingController(text: PerfilGuardado.mensajeSosPersonalizado ?? '');
  late bool _mencionarCondicion = PerfilGuardado.mencionarCondicion;
  bool _guardando = false;

  /// Aviso en línea de "Mensaje guardado." (no un SnackBar: ése tapaba
  /// "Restaurar mensaje sugerido", el último botón de la pantalla).
  bool _mensajeGuardado = false;

  /// Hay texto propio que todavía no se guardó.
  bool get _mensajeSinGuardar =>
      _mensajeSos.text.trim() !=
      (PerfilGuardado.mensajeSosPersonalizado ?? '').trim();

  @override
  void dispose() {
    _nombre.dispose();
    _telefono.dispose();
    _mensajeSos.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!(_formulario.currentState?.validate() ?? false)) return;
    final contacto = ContactoEmergencia.crear(_nombre.text, _telefono.text);
    if (contacto == null) return;
    setState(() => _guardando = true);
    await PerfilGuardado.guardarContacto(contacto);
    // El mensaje que se escribió va con el contacto: no se pierde en
    // silencio al salir.
    await _guardarMensaje(avisar: false);
    if (!mounted) return;
    Navigator.of(context).pop(contacto);
  }

  /// Guarda cómo se dice el mensaje de SOS (sin tocar el contacto).
  Future<void> _guardarMensaje({bool avisar = true}) async {
    await PerfilGuardado.guardarMensajeSos(
      mencionarCondicion: _mencionarCondicion,
      personalizado: _mensajeSos.text,
    );
    if (!mounted) return;
    setState(() => _mensajeGuardado = avisar);
  }

  /// Atrás con un mensaje sin guardar: se pregunta en vez de perderlo.
  Future<void> _alIntentarSalir(bool salio, Object? _) async {
    if (salio) return;
    final decision = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Guardar tu mensaje?'),
        content: const Text(
            'Escribiste un mensaje de emergencia y todavía no lo guardas.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No guardar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    // Tocar fuera del aviso (null) es seguir editando.
    if (decision == null) return;
    if (decision) await _guardarMensaje(avisar: false);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _restaurarMensaje() async {
    setState(() => _mensajeSos.clear());
    await _guardarMensaje(avisar: false);
  }

  Future<void> _cambiarCondicion(bool valor) async {
    setState(() => _mencionarCondicion = valor);
    await _guardarMensaje(avisar: false);
  }

  Future<void> _quitar() async {
    setState(() => _guardando = true);
    await PerfilGuardado.guardarContacto(null);
    await _guardarMensaje(avisar: false);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;
    final hayContacto = PerfilGuardado.contactoEmergencia != null;
    return PopScope(
      canPop: !_mensajeSinGuardar,
      onPopInvokedWithResult: _alIntentarSalir,
      child: Scaffold(
        appBar: AppBar(title: const Text('Contacto de emergencia')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formulario,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Es la persona a quien llamará o escribirá el botón SOS. '
                    'Se queda solo en tu teléfono.',
                    style: TextStyle(color: colores.onSurfaceVariant),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('campo-nombre-contacto'),
                    controller: _nombre,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    maxLength: ContactoEmergencia.kMaxNombre,
                    decoration: const InputDecoration(
                      labelText: 'Nombre',
                      hintText: 'Por ejemplo, Mamá',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: ContactoEmergencia.validarNombre,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('campo-telefono-contacto'),
                    controller: _telefono,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9+\s\-().]')),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Teléfono',
                      hintText: 'Por ejemplo, 55 1234 5678',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    validator: ContactoEmergencia.validarTelefono,
                    onFieldSubmitted: (_) => _guardar(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _guardando ? null : _guardar,
                    child: const Text('Guardar contacto'),
                  ),
                  if (hayContacto) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _guardando ? null : _quitar,
                      child: const Text('Quitar contacto'),
                    ),
                  ],
                  const Divider(height: 40),
                  Text('Mensaje de emergencia',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Es lo que se muestra y se lee en voz alta cuando pides '
                    'ayuda. Tú decides cómo se dice.',
                    style: TextStyle(color: colores.onSurfaceVariant),
                  ),
                  SwitchListTile(
                    key: const ValueKey('interruptor-condicion'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Mencionar mi condición en el mensaje'),
                    value: _mencionarCondicion,
                    onChanged: _cambiarCondicion,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const ValueKey('campo-mensaje-sos'),
                    controller: _mensajeSos,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: PerfilGuardado.kMaxMensajeSos,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() => _mensajeGuardado = false),
                    decoration: const InputDecoration(
                      labelText: 'Mensaje propio (opcional)',
                      hintText: 'Si lo dejas vacío se usa el mensaje sugerido.',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('Así se verá:',
                      style: TextStyle(color: colores.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Semantics(
                    container: true,
                    label: 'Vista previa del mensaje de emergencia',
                    child: Card(
                      key: const ValueKey('vista-previa-sos'),
                      color: colores.errorContainer,
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          mensajeSosActual(
                            mencionarCondicion: _mencionarCondicion,
                            personalizado: _mensajeSos.text,
                          ),
                          key: const ValueKey('texto-vista-previa'),
                          style: TextStyle(
                              color: colores.onErrorContainer,
                              fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: _guardarMensaje,
                    child: const Text('Guardar mensaje'),
                  ),
                  if (_mensajeGuardado)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('Mensaje guardado.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colores.onSurfaceVariant)),
                      ),
                    ),
                  TextButton(
                    onPressed: _restaurarMensaje,
                    child: const Text('Restaurar mensaje sugerido'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
