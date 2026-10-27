/// Sincronizacion con Supabase: subir las muestras grabadas en el telefono
/// y bajarse el diccionario aprobado del equipo.
///
/// Las dos operaciones son independientes a proposito. Subir manda tus
/// muestras a la cola de pendientes; bajar trae lo que YA fue aprobado. Una
/// muestra recien subida no aparece en el diccionario hasta que alguien la
/// apruebe -- esa es la idea, no un olvido.
library pantalla_sync;

import 'package:flutter/material.dart';

import 'config_supabase.dart';
import 'muestras_locales.dart';
import 'supabase_api.dart';

class PantallaSync extends StatefulWidget {
  const PantallaSync({Key? key}) : super(key: key);

  @override
  State<PantallaSync> createState() => _PantallaSyncState();
}

class _PantallaSyncState extends State<PantallaSync> {
  final _almacen = AlmacenMuestras.instancia;
  final _api = SupabaseApi();

  bool _subiendo = false;
  bool _bajando = false;
  bool _subiendoRaw = false;
  bool _probandoConexion = false;

  bool get _enProceso =>
      _subiendo || _bajando || _subiendoRaw || _probandoConexion;

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

  void _mostrar(String texto, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _resultado = texto;
      _resultadoEsError = error;
      _progreso = null;
      _subiendo = false;
      _bajando = false;
      _subiendoRaw = false;
      _probandoConexion = false;
    });
  }

  Future<void> _probar() async {
    if (_enProceso) return;
    setState(() {
      _probandoConexion = true;
      _resultado = null;
    });
    try {
      final msg = await _api.probar();
      _mostrar(msg);
    } catch (e) {
      _mostrar('$e', error: true);
    } finally {
      if (mounted) setState(() => _probandoConexion = false);
    }
  }

  Future<void> _subir() async {
    if (_enProceso) return;
    final pendientes = _almacen.sinSubir;
    if (pendientes.isEmpty) {
      _mostrar('No hay muestras nuevas para subir.');
      return;
    }

    setState(() {
      _subiendo = true;
      _resultado = null;
      _progreso = 'Subiendo 0 de ${pendientes.length}...';
    });

    var ok = 0;
    final errores = <String>[];

    try {
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
          await _almacen.marcarSubida(m.id);
          ok++;
        } catch (e) {
          errores.add('${m.gloss}: $e');
          if (errores.length >= 3) break;
        }
      }

      if (errores.isEmpty) {
        _mostrar(
            '$ok seña(s) enviada(s) correctamente. Serán revisadas para integrarse al vocabulario general.');
      } else {
        _mostrar(
          '$ok enviadas, ${errores.length} con error.\n\n${errores.join("\n\n")}',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  Future<void> _bajar() async {
    if (_enProceso) return;
    setState(() {
      _bajando = true;
      _resultado = null;
      _progreso = 'Descargando vocabulario actualizado...';
    });
    try {
      final plantillas = await _api.descargarPlantillas();
      if (plantillas.isEmpty) {
        _mostrar(
          'El servidor no tiene señas aprobadas disponibles para descargar en este momento.',
          error: true,
        );
        return;
      }
      await _almacen.guardarSincronizadas(plantillas);
      final senas = plantillas.map((p) => p.gloss).toSet().length;
      _mostrar(
          '$senas señas descargadas correctamente ($plantillas.length variantes). '
          'Ya puedes usarlas sin conexión a internet.');
    } catch (e) {
      _mostrar('$e', error: true);
    } finally {
      if (mounted) setState(() => _bajando = false);
    }
  }

  Future<void> _subirRaw() async {
    if (_enProceso) return;
    final pendientes = _almacen.muestras
        .where((m) => m.rawFramesPath != null && m.rawSubidaEn == null)
        .toList();
    if (pendientes.isEmpty) {
      _mostrar('No hay registros de movimiento pendientes para enviar.');
      return;
    }

    setState(() {
      _subiendoRaw = true;
      _resultado = null;
      _progreso = 'Enviando registros 0 de ${pendientes.length}...';
    });
    var ok = 0;
    final errores = <String>[];
    try {
      for (var i = 0; i < pendientes.length; i++) {
        final muestra = pendientes[i];
        if (mounted) {
          setState(() => _progreso =
              'Enviando registros ${i + 1} de ${pendientes.length} (${muestra.gloss})...');
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
          errores.add('${muestra.gloss}: $e');
          if (errores.length >= 3) break;
        }
      }
      if (errores.isEmpty) {
        _mostrar(
            '$ok registros de movimiento enviados correctamente. Por tu privacidad, no contienen video ni audio.');
      } else {
        _mostrar(
            '$ok enviados, ${errores.length} con error.\n\n${errores.join("\n\n")}',
            error: true);
      }
    } finally {
      if (mounted) setState(() => _subiendoRaw = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sinSubir = _almacen.sinSubir.length;
    final rawPendientes = _almacen.muestras
        .where((m) => m.rawFramesPath != null && m.rawSubidaEn == null)
        .length;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF29232F),
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Sincronizar',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF29232F),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          if (!haySupabaseConfigurado)
            _bannerAviso(
              'La conexión con la nube no está configurada aún en este dispositivo. '
              'Puedes usar la app con normalidad con las señas locales.',
              esInfo: true,
            ),

          // ── Tarjeta 1: Subir señas grabadas ──
          _tarjetaAccion(
            icono: Icons.cloud_upload_outlined,
            titulo: 'Compartir mis señas grabadas',
            detalle: sinSubir == 0
                ? 'Todas tus señas grabadas en este teléfono ya han sido enviadas.'
                : 'Tienes $sinSubir seña(s) nueva(s) en este teléfono. Al enviarlas, '
                    'serán revisadas por el equipo para integrarse al vocabulario de todos.',
            boton: sinSubir == 0 ? 'Sin señas pendientes' : 'Enviar $sinSubir seña(s)',
            habilitado: sinSubir > 0,
            cargando: _subiendo,
            onPressed: _subir,
          ),

          // ── Tarjeta 2: Descargar vocabulario / diccionario (Destacada) ──
          _tarjetaDiccionarioDestacada(),

          // ── Tarjeta 3: Puntos de articulación 3D (Avanzado) ──
          _tarjetaAccion(
            icono: Icons.gesture_outlined,
            titulo: 'Enviar puntos de movimiento (Opcional)',
            detalle: rawPendientes == 0
                ? 'No hay registros de movimiento pendientes por enviar.'
                : 'Envía únicamente las coordenadas numéricas de articulación para calibrar y mejorar el modelo de reconocimiento. '
                    'Por tu privacidad, nunca se sube ningún video ni imagen.',
            boton: rawPendientes == 0 ? 'Al día' : 'Enviar puntos de movimiento ($rawPendientes)',
            habilitado: rawPendientes > 0,
            cargando: _subiendoRaw,
            onPressed: _subirRaw,
          ),

          // ── Botón de comprobar conexión ──
          OutlinedButton(
            onPressed: () {
              if (!_enProceso) _probar();
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF791FC1),
              side: const BorderSide(color: Color(0xFFE2DEEC), width: 2),
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_probandoConexion) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFF791FC1),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Comprobando conexión...',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                ] else ...[
                  const Icon(Icons.wifi_rounded, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Comprobar conexión con el servidor',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Indicador de progreso ──
          if (_progreso != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F6FA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E0ED), width: 2),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFF791FC1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _progreso!,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF29232F),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Resultado (Éxito o Error) ──
          if (_resultado != null)
            _bannerAviso(_resultado!, esError: _resultadoEsError),

          const SizedBox(height: 4),

          // ── Tarjeta informativa: Seguridad y privacidad ──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFC),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE8E5EE), width: 2),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 20,
                  color: Color(0xFF791FC1),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Seguridad y privacidad',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF29232F),
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Tus señas compartidas son analizadas de forma anónima para verificar su precisión antes de integrarse al vocabulario oficial. La aplicación nunca comparte videos ni imágenes de tu cámara.',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF7D7588),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// Tarjeta destacada para descargar el diccionario con grid de estadísticas.
  Widget _tarjetaDiccionarioDestacada() {
    final cantidad = _almacen.sincronizadas.length;
    final fechaSync = _almacen.sincronizadoEn != null
        ? _fecha(_almacen.sincronizadoEn!)
        : 'Pendiente';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFDFBFE),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF791FC1), width: 2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF791FC1).withOpacity(0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF791FC1), Color(0xFF5B1493)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.cloud_download_rounded,
                    color: Colors.white, size: 21),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Actualizar diccionario de señas',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF29232F),
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3EDFA),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF791FC1),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Descarga el vocabulario más reciente aprobado por el equipo. '
            'Las señas quedan guardadas en tu teléfono para reconocer sin necesidad de internet.',
            style: TextStyle(
              fontSize: 12.5,
              color: Color(0xFF6E6679),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),

          // ── Mini-Grid de estadísticas informativas ──
          Row(
            children: [
              Expanded(
                child: _tileInfo(
                  icon: Icons.menu_book_rounded,
                  valor: cantidad == 0 ? 'Base' : '$cantidad',
                  label: 'Señas listas',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tileInfo(
                  icon: Icons.wifi_off_rounded,
                  valor: '100% Local',
                  label: 'Sin conexión',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _tileInfo(
                  icon: Icons.schedule_rounded,
                  valor: fechaSync,
                  label: 'Última descarga',
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Botón principal de descarga
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () {
                if (!_enProceso) _bajar();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF791FC1),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _bajando
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text(
                          'Descargando vocabulario...',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    )
                  : const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.download_rounded, size: 19),
                        SizedBox(width: 8),
                        Text(
                          'Descargar vocabulario más reciente',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tileInfo({
    required IconData icon,
    required String valor,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F5FA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFECE7F4), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: const Color(0xFF791FC1)),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  valor,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF29232F),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              color: Color(0xFF81798E),
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Tarjeta de acción con borde exterior de 2px estilo Fluent.
  Widget _tarjetaAccion({
    required IconData icono,
    required String titulo,
    required String detalle,
    required String boton,
    required bool habilitado,
    required VoidCallback onPressed,
    bool cargando = false,
  }) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8E5EE), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFF3EDFA),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icono, color: const Color(0xFF791FC1), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF29232F),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            detalle,
            style: const TextStyle(
              fontSize: 12.5,
              color: Color(0xFF6E6679),
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton(
              onPressed: habilitado
                  ? () {
                      if (!_enProceso) onPressed();
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF791FC1),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFEDEBF0),
                disabledForegroundColor: const Color(0xFFA69EB0),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: cargando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(
                      boton,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// Banner tipo Fluent InfoBar con borde exterior de 2px.
  Widget _bannerAviso(String texto, {bool esError = false, bool esInfo = false}) {
    final fondo = esError
        ? const Color(0xFFFEF2F2)
        : (esInfo ? const Color(0xFFFFFBEB) : const Color(0xFFF0FDF4));
    final borde = esError
        ? const Color(0xFFFECACA)
        : (esInfo ? const Color(0xFFFDE68A) : const Color(0xFFBBF7D0));
    final colorTexto = esError
        ? const Color(0xFF991B1B)
        : (esInfo ? const Color(0xFFB45309) : const Color(0xFF166534));
    final icono = esError
        ? Icons.error_outline_rounded
        : (esInfo ? Icons.info_outline_rounded : Icons.check_circle_outline_rounded);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: fondo,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borde, width: 2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, color: colorTexto, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              texto,
              style: TextStyle(
                color: colorTexto,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
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
