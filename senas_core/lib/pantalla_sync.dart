/// Sincronizacion con Supabase: subir las muestras grabadas en el telefono
/// y bajarse el diccionario aprobado del equipo.
///
/// Las dos operaciones son independientes a proposito. Subir manda tus
/// muestras a la cola de pendientes; bajar trae lo que YA fue aprobado. Una
/// muestra recien subida no aparece en el diccionario hasta que alguien la
/// apruebe -- esa es la idea, no un olvido.
library pantalla_sync;

import 'package:flutter/material.dart';

import 'componentes_univoz.dart';
import 'config_supabase.dart';
import 'modo_desarrollador.dart';
import 'muestras_locales.dart';
import 'red.dart';
import 'sincronizador_plantillas.dart' show kFraccionMinimaSync;
import 'supabase_api.dart';

class PantallaSync extends StatefulWidget {
  const PantallaSync({Key? key}) : super(key: key);

  @override
  State<PantallaSync> createState() => _PantallaSyncState();
}

class _PantallaSyncState extends State<PantallaSync> {
  final _almacen = AlmacenMuestras.instancia;
  final _api = SupabaseApi();

  bool _trabajando = false;
  String? _progreso;
  String? _resultado;
  bool _resultadoEsError = false;

  @override
  void initState() {
    super.initState();
    _almacen.addListener(_alCambiar);
    _almacen.cargar();
  }

  void _alCambiar() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _almacen.removeListener(_alCambiar);
    _api.cerrar();
    super.dispose();
  }

  /// Nunca el error crudo: una persona normal ve un mensaje humano; el
  /// detalle tecnico solo con el modo desarrollador.
  String _textoError(Object e) =>
      mensajeHumano(e, dev: ModoDesarrollador.activo);

  void _mostrar(String texto, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _resultado = texto;
      _resultadoEsError = error;
      _progreso = null;
      _trabajando = false;
    });
  }

  Future<void> _probar() async {
    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Probando conexión...';
    });
    try {
      final msg = await _api.probar();
      _mostrar(msg);
    } catch (e) {
      _mostrar(_textoError(e), error: true);
    }
  }

  Future<void> _subir() async {
    final pendientes = _almacen.sinSubir;
    if (pendientes.isEmpty) {
      _mostrar('No hay muestras nuevas para subir.');
      return;
    }

    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Subiendo 0 de ${pendientes.length}...';
    });

    var ok = 0;
    final errores = <String>[];

    for (var i = 0; i < pendientes.length; i++) {
      final m = pendientes[i];
      if (mounted) {
        setState(() => _progreso =
            'Subiendo ${i + 1} de ${pendientes.length} (${m.gloss})...');
      }
      try {
        await _api.subirMuestra(
          gloss: m.gloss,
          espanol: m.espanol.isEmpty ? m.gloss.toLowerCase() : m.espanol,
          seq: m.seq,
          categoria: m.categoria,
          signer: m.signer,
          nFramesOrig: m.nFramesOrig,
          fps: m.fps,
          duracionMs: m.duracionMs,
          framesInvalidos: m.framesInvalidos,
          visibilidadMin: m.visibilidadMin,
          qualityScore: m.qualityScore,
          checksumSha256: m.checksumSha256,
        );
        // Se marca una por una: si se corta la red a mitad, lo que ya subio
        // no se vuelve a subir la proxima vez.
        await _almacen.marcarSubida(m.id);
        ok++;
      } catch (e) {
        errores.add('${m.gloss}: ${_textoError(e)}');
        // Un error de politica o de red se repite en todas: no tiene sentido
        // seguir intentando 40 veces.
        if (errores.length >= 3) break;
      }
    }

    if (errores.isEmpty) {
      _mostrar('$ok muestras subidas. Quedaron como "pendiente" — hay que '
          'aprobarlas en Supabase para que entren al diccionario.');
    } else {
      _mostrar(
        '$ok subidas, ${errores.length} con error.\n\n${errores.join("\n\n")}',
        error: true,
      );
    }
  }

  Future<void> _bajar() async {
    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Descargando diccionario...';
    });
    try {
      final plantillas = await _api.descargarPlantillas();
      if (plantillas.isEmpty) {
        _mostrar(
          ModoDesarrollador.activo
              ? 'La base no tiene ninguna muestra aprobada todavía. En el SQL '
                  'Editor de Supabase:\n\nUPDATE sign_samples SET '
                  'estado=\'aprobada\' WHERE estado=\'pendiente\';'
              : 'Todavía no hay señas nuevas para descargar. Inténtalo más '
                  'tarde.',
          error: true,
        );
        return;
      }
      // Misma regla que la sincronizacion en segundo plano: una descarga
      // mucho mas chica que la anterior puede ser un corte del servidor. Aqui
      // la persona decide. Sin descarga anterior no hay con que comparar: el
      // paquete de la app manda y esto solo le suma glosas.
      final actual = _almacen.sincronizadas.length;
      if (actual > 0 &&
          plantillas.length < actual * kFraccionMinimaSync &&
          !await _confirmarDiccionarioMasChico(plantillas.length, actual)) {
        _mostrar('Se conservó tu última descarga.');
        return;
      }
      await _almacen.guardarSincronizadas(plantillas);
      final senas = plantillas.map((p) => p.gloss).toSet().length;
      _mostrar('Se guardaron ${plantillas.length} plantillas ($senas señas). '
          'Solo se suman las señas que la app no trae.');
    } catch (e) {
      _mostrar(_textoError(e), error: true);
    }
  }

  Future<bool> _confirmarDiccionarioMasChico(int nuevas, int actuales) async {
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Reemplazar tu última descarga?'),
        content: Text(
          'El servidor mandó solo $nuevas plantillas y tu última descarga '
          'tenía $actuales. Puede ser un error del servidor. Si reemplazas, '
          'podrías perder las señas nuevas que ya habías descargado hasta la '
          'próxima descarga. Las que vienen con la app no se tocan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Conservar la anterior'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reemplazar'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _subirRaw() async {
    final pendientes = _almacen.muestras
        .where((m) => m.rawFramesPath != null && m.rawSubidaEn == null)
        .toList();
    if (pendientes.isEmpty) {
      _mostrar('No hay landmarks crudos pendientes.');
      return;
    }

    setState(() {
      _trabajando = true;
      _resultado = null;
      _progreso = 'Subiendo landmarks 0 de ${pendientes.length}...';
    });
    var ok = 0;
    final errores = <String>[];
    for (var i = 0; i < pendientes.length; i++) {
      final muestra = pendientes[i];
      if (mounted) {
        setState(() => _progreso =
            'Subiendo landmarks ${i + 1} de ${pendientes.length} (${muestra.gloss})...');
      }
      try {
        final bytes = await _almacen.cargarRawComprimido(muestra);
        if (bytes == null) throw StateError('no existe sidecar local');
        final uri = await _api.subirLandmarksCrudos(
          bucket: 'motion-raw',
          objectPath: 'raw/${muestra.id}.json.gz',
          gzipBytes: bytes,
        );
        await _almacen.marcarRawSubida(muestra.id, uri);
        ok++;
      } catch (e) {
        errores.add('${muestra.gloss}: ${_textoError(e)}');
        if (errores.length >= 3) break;
      }
    }
    if (errores.isEmpty) {
      _mostrar('$ok archivos de landmarks subidos. No contienen video.');
    } else {
      _mostrar(
          '$ok subidos, ${errores.length} con error.\n\n${errores.join("\n\n")}',
          error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sinSubir = _almacen.sinSubir.length;
    final rawPendientes = _almacen.muestras
        .where((m) => m.rawFramesPath != null && m.rawSubidaEn == null)
        .length;
    final colores = Theme.of(context).colorScheme;
    // Subir muestras y probar la conexión son herramientas del equipo: solo
    // con el modo desarrollador. Bajar el diccionario lo ve cualquiera.
    final dev = ModoDesarrollador.activo;

    return Scaffold(
      appBar: AppBar(title: const Text('Sincronizar')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (!haySupabaseConfigurado)
            AvisoUnivoz(
              dev
                  ? 'Falta cargar la URL y la clave del proyecto en config_supabase.dart. '
                      'Sin eso, la app funciona igual pero solo con las muestras de este teléfono.'
                  : 'La descarga del diccionario no está disponible en esta versión.',
              tipo: TipoAviso.info,
            ),
          _tarjetaDiccionario(),
          if (dev)
            _tarjetaAccion(
              icono: Icons.cloud_upload_outlined,
              titulo: 'Subir mis muestras',
              detalle: sinSubir == 0
                  ? 'Todas las muestras de este teléfono ya están en la base.'
                  : '$sinSubir muestra(s) sin subir. Van a quedar como "pendiente" '
                      'hasta que alguien las apruebe.',
              boton: 'Subir $sinSubir muestra(s)',
              habilitado: !_trabajando && sinSubir > 0,
              onPressed: _subir,
            ),
          if (dev)
            _tarjetaAccion(
              icono: Icons.data_object,
              titulo: 'Subir landmarks crudos (opcional)',
              detalle: rawPendientes == 0
                  ? 'No hay archivos crudos pendientes.'
                  : 'Solo sube coordenadas comprimidas para auditoría o re-normalización. '
                      'Nunca sube video.',
              boton: 'Subir landmarks',
              habilitado: !_trabajando && rawPendientes > 0,
              onPressed: _subirRaw,
            ),
          if (dev) ...[
            OutlinedButton.icon(
              onPressed: _trabajando ? null : _probar,
              icon: const Icon(Icons.wifi_rounded, size: 18),
              label: const Text('Probar conexión'),
            ),
            const SizedBox(height: 12),
          ],
          if (_progreso != null) ProgresoUnivoz(_progreso!),
          if (_resultado != null)
            AvisoUnivoz(
              _resultado!,
              tipo: _resultadoEsError ? TipoAviso.error : TipoAviso.exito,
              seleccionable: true,
            ),
          if (dev)
            TarjetaUnivoz(
              relleno: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined, size: 20, color: colores.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Por qué las muestras entran como "pendiente": la app usa la clave '
                      'publishable, que es pública por diseño. Las reglas de la base '
                      '(sql/002_app_acceso.sql) le permiten agregar, pero no aprobar, '
                      'modificar ni borrar. Así, aunque alguien saque la clave del APK, '
                      'no puede tocar el diccionario aprobado.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: colores.onSurfaceVariant,
                        height: 1.35,
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

  /// Tarjeta destacada: bajar el diccionario, con fichas de estado.
  Widget _tarjetaDiccionario() {
    final colores = Theme.of(context).colorScheme;
    final cantidad = _almacen.sincronizadas.length;
    final fecha = _almacen.sincronizadoEn != null
        ? _fecha(_almacen.sincronizadoEn!)
        : 'Nunca';
    return TarjetaUnivoz(
      destacada: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconoCaja(Icons.cloud_download_rounded,
                  tamano: 38, relleno: true),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Bajar el diccionario',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: colores.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            cantidad == 0
                ? 'Todavía no se descargó nada. Se está usando el paquete que vino '
                    'con la app más tus muestras locales.'
                : '$cantidad plantillas guardadas. '
                    'Quedan en el teléfono: no hace falta internet para reconocer. '
                    'Solo se suman las señas que la app no trae.',
            style: TextStyle(
              fontSize: 12.5,
              color: colores.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FichaDato(
                  icono: Icons.menu_book_rounded,
                  valor: cantidad == 0 ? 'Solo la app' : '$cantidad',
                  etiqueta: 'Descargadas',
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: FichaDato(
                  icono: Icons.wifi_off_rounded,
                  valor: 'Sin internet',
                  etiqueta: 'Para reconocer',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FichaDato(
                  icono: Icons.schedule_rounded,
                  valor: fecha,
                  etiqueta: 'Tu última descarga',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _trabajando ? null : _bajar,
              icon: const Icon(Icons.download_rounded, size: 19),
              label: const Text('Descargar ahora'),
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta de una acción: icono en caja, título, detalle y botón.
  Widget _tarjetaAccion({
    required IconData icono,
    required String titulo,
    required String detalle,
    required String boton,
    required bool habilitado,
    required VoidCallback onPressed,
  }) {
    final colores = Theme.of(context).colorScheme;
    return TarjetaUnivoz(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconoCaja(icono),
              const SizedBox(width: 12),
              // Expanded, no Text suelto: dentro de un Row el texto pide su
              // ancho natural y se sale del cuadro en cuanto el titulo es
              // largo o la pantalla angosta.
              Expanded(
                child: Text(
                  titulo,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colores.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            detalle,
            style: TextStyle(
              fontSize: 12.5,
              color: colores.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: habilitado ? onPressed : null,
              child: Text(boton),
            ),
          ),
        ],
      ),
    );
  }

  String _fecha(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    String dos(int n) => n.toString().padLeft(2, '0');
    return '${dos(t.day)}/${dos(t.month)} ${dos(t.hour)}:${dos(t.minute)}';
  }
}
