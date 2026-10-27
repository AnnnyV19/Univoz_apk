/// Calibracion del reconocedor, sin recompilar.
///
/// Los umbrales por defecto (0.55 / 0.12) estan calibrados contra datos
/// sinteticos, no contra grabaciones reales -- el README ya avisaba que hay
/// que ajustarlos con las primeras señas grabadas. Esta pantalla es para
/// hacerlo probando, que es la unica forma honesta de calibrarlos.
library pantalla_ajustes;

import 'package:flutter/material.dart';

import 'motion_contract.dart';
import 'muestras_locales.dart';
import 'pantalla_espejo.dart';
import 'voz.dart';

class PantallaAjustes extends StatefulWidget {
  const PantallaAjustes({Key? key}) : super(key: key);

  @override
  State<PantallaAjustes> createState() => _PantallaAjustesState();
}

class _PantallaAjustesState extends State<PantallaAjustes> {
  final _almacen = AlmacenMuestras.instancia;
  late Ajustes _a;
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    await _almacen.cargar();
    if (!mounted) return;
    setState(() {
      _a = _almacen.ajustes.copiar();
      _listo = true;
    });
  }

  Future<void> _guardar() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Ajustes guardados. Vuelve a entrar a Reconocer para aplicarlos.',
        ),
      ),
    );
  }

  Future<void> _calibrarPulgares() async {
    await _almacen.guardarAjustes(_a);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const PantallaEspejo(iniciarCalibracion: true),
    ));
    if (!mounted) return;
    setState(() => _a = _almacen.ajustes.copiar());
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) {
      return const Scaffold(
        backgroundColor: Colors.white,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF29232F),
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Text(
          'Ajustes',
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
          // ── Sección 1: Precisión del reconocimiento ──
          _tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _encabezado(
                  icon: Icons.tune_rounded,
                  title: 'Precisión al detectar señas',
                  description:
                      'Ajusta qué tan estricta es la aplicación para reconocer una seña. '
                      'Si reconoce cosas por error, aumenta la exigencia; si le cuesta detectar, hazla más flexible.',
                ),
                _slider(
                  etiqueta: 'Tolerancia al movimiento',
                  valor: _a.maxDistance,
                  min: 0.10,
                  max: 1.50,
                  divisiones: 28,
                  ayuda:
                      'Permite pequeñas variaciones al hacer la seña (Menor = más estricto)',
                  onChanged: (v) => setState(() => _a.maxDistance = v),
                ),
                const SizedBox(height: 6),
                _slider(
                  etiqueta: 'Claridad entre palabras',
                  valor: _a.minMargin,
                  min: 0.0,
                  max: 0.50,
                  divisiones: 25,
                  ayuda:
                      'Diferencia exigida frente a otras señas parecidas (Mayor = más estricto)',
                  onChanged: (v) => setState(() => _a.minMargin = v),
                ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF791FC1),
                      padding: EdgeInsets.zero,
                    ),
                    icon: const Icon(Icons.restart_alt_rounded, size: 16),
                    label: const Text(
                      'Restablecer valores recomendados (0.55 / 0.12)',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    onPressed: () => setState(() {
                      _a.maxDistance = 0.55;
                      _a.minMargin = 0.12;
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección 2: Cámara y Preferencias ──
          _tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _encabezado(
                  icon: Icons.camera_alt_outlined,
                  title: 'Cámara',
                  description:
                      'Configura cómo capturar tus señas de forma cómoda.',
                ),
                _switch(
                  title: 'Usar cámara frontal',
                  subtitle:
                      'Usa la cámara delantera para verte en la pantalla. Desactívala si otra persona sostiene el teléfono.',
                  value: _a.camaraFrontal,
                  onChanged: (v) => setState(() => _a.camaraFrontal = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección 3: Voz y Accesibilidad auditiva ──
          _tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _encabezado(
                  icon: Icons.volume_up_outlined,
                  title: 'Pronunciación por voz',
                  description:
                      'Permite que el teléfono hable en voz alta al entender la seña.',
                ),
                _switch(
                  title: 'Decir el resultado en voz alta',
                  subtitle:
                      'Pronuncia la palabra automáticamente al reconocerla. Desactívalo para ver solo el texto.',
                  value: _a.hablarResultado,
                  onChanged: (v) => setState(() => _a.hablarResultado = v),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF791FC1),
                    side: const BorderSide(color: Color(0xFFE2DEEC), width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Probar sonido de voz ("Hola, gracias")'),
                  onPressed: () async {
                    final err =
                        await LectorVoz.instancia.decir('Hola, gracias');
                    if (!mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Error de voz: $err')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección 4: Diccionario y zurdos ──
          _tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _encabezado(
                  icon: Icons.front_hand_outlined,
                  title: 'Compatibilidad con ambas manos',
                  description:
                      'Facilita la comunicación sin importar con qué mano se señe.',
                ),
                _switch(
                  title: 'Modo para zurdos y diestros',
                  subtitle:
                      'Reconoce la misma seña hecha con la mano izquierda o derecha sin tener que grabarla de nuevo.',
                  value: _a.espejoAutomatico,
                  onChanged: (v) => setState(() => _a.espejoAutomatico = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── Sección 5: Movimiento del avatar 3D ──
          _tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _encabezado(
                  icon: Icons.accessibility_new_rounded,
                  title: 'Movimiento del avatar 3D',
                  description:
                      'Personaliza cómo se mueve el avatar visual al reproducir las señas.',
                ),
                _switch(
                  title: 'Invertir dirección de movimiento',
                  subtitle:
                      'Actívalo si notas que el avatar mueve las manos hacia atrás en lugar de hacia el frente.',
                  value: _a.rigCalibration.invertZ,
                  onChanged: (v) => setState(() =>
                      _a.rigCalibration = _a.rigCalibration.copyWith(invertZ: v)),
                ),
                const SizedBox(height: 4),
                _switch(
                  title: 'Reposo automático de manos',
                  subtitle:
                      'Regresa las manos a una postura natural si la cámara deja de verlas temporalmente.',
                  value: _a.rigCalibration.resetHandOnLoss,
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(resetHandOnLoss: v)),
                ),
                const SizedBox(height: 8),
                _slider(
                  etiqueta: 'Tamaño del avatar',
                  valor: _a.rigCalibration.avatarScale,
                  min: 0.70,
                  max: 1.30,
                  divisiones: 60,
                  ayuda: 'Ajusta el tamaño visible en pantalla',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(avatarScale: v)),
                ),
                _slider(
                  etiqueta: 'Alcance del brazo izquierdo',
                  valor: _a.rigCalibration.leftArmGain,
                  min: 0.50,
                  max: 1.50,
                  divisiones: 50,
                  ayuda: 'Amplitud de movimiento del brazo izquierdo',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(leftArmGain: v)),
                ),
                _slider(
                  etiqueta: 'Alcance del brazo derecho',
                  valor: _a.rigCalibration.rightArmGain,
                  min: 0.50,
                  max: 1.50,
                  divisiones: 50,
                  ayuda: 'Amplitud de movimiento del brazo derecho',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(rightArmGain: v)),
                ),
                _slider(
                  etiqueta: 'Flexión de los dedos',
                  valor: _a.rigCalibration.fingerSensitivity,
                  min: 0.50,
                  max: 1.50,
                  divisiones: 50,
                  ayuda: 'Qué tanto se doblan los dedos al hacer la seña',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(fingerSensitivity: v)),
                ),
                _slider(
                  etiqueta: 'Apertura mínima del codo',
                  valor: _a.rigCalibration.ikMin,
                  min: 0.0,
                  max: 1.50,
                  divisiones: 30,
                  ayuda: 'Evita que el brazo se cierre de más',
                  onChanged: (v) => setState(() {
                    final max = _a.rigCalibration.ikMax < v
                        ? v
                        : _a.rigCalibration.ikMax;
                    _a.rigCalibration =
                        _a.rigCalibration.copyWith(ikMin: v, ikMax: max);
                  }),
                ),
                _slider(
                  etiqueta: 'Apertura máxima del codo',
                  valor: _a.rigCalibration.ikMax,
                  min: _a.rigCalibration.ikMin,
                  max: 3.14,
                  divisiones: 62,
                  ayuda: 'Evita posturas forzadas en los brazos',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(ikMax: v)),
                ),
                _slider(
                  etiqueta: 'Orientación de la muñeca',
                  valor: _a.rigCalibration.wristCompensation,
                  min: -1.0,
                  max: 1.0,
                  divisiones: 40,
                  ayuda: 'Alineación de la palma de la mano',
                  onChanged: (v) => setState(() => _a.rigCalibration =
                      _a.rigCalibration.copyWith(wristCompensation: v)),
                ),
                const SizedBox(height: 8),
                _switch(
                  title: 'Modo técnico de diagnóstico',
                  subtitle:
                      'Muestra datos avanzados en pantalla (cuadros por segundo y puntos capturados). Solo para pruebas.',
                  value: _a.rigDiagnosticMode,
                  onChanged: (v) => setState(() => _a.rigDiagnosticMode = v),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF791FC1),
                        side: const BorderSide(
                            color: Color(0xFFE2DEEC), width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      icon: const Icon(Icons.pan_tool_alt_outlined, size: 16),
                      label: const Text('Calibrar pulgares',
                          style: TextStyle(fontSize: 12.5)),
                      onPressed: _calibrarPulgares,
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF791FC1),
                      ),
                      onPressed: () => setState(
                          () => _a.rigCalibration = const RigCalibration()),
                      child: const Text('Restablecer animación',
                          style: TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Botón Guardar ajustes ──
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _guardar,
              icon: const Icon(Icons.check_rounded, size: 20),
              label: const Text(
                'Guardar ajustes',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF791FC1),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  /// Tarjeta Fluent con borde exterior de 2px sobrio y medido.
  Widget _tarjeta({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8E5EE), width: 2),
      ),
      child: child,
    );
  }

  Widget _encabezado({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: const Color(0xFF791FC1)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF29232F),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: const TextStyle(
            fontSize: 12.5,
            color: Color(0xFF6E6679),
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        const Divider(color: Color(0xFFF0EDF5), height: 1),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _slider({
    required String etiqueta,
    required double valor,
    required double min,
    required double max,
    required int divisiones,
    required String ayuda,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  etiqueta,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF29232F),
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3EDFA),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  valor.toStringAsFixed(2),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF791FC1),
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: const Color(0xFF791FC1),
              inactiveTrackColor: const Color(0xFFEDE9F4),
              thumbColor: const Color(0xFF791FC1),
              overlayColor: const Color(0xFF791FC1).withOpacity(0.12),
              trackHeight: 3.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.5),
            ),
            child: Slider(
              value: valor.clamp(min, max),
              min: min,
              max: max,
              divisions: divisiones,
              onChanged: onChanged,
            ),
          ),
          Text(
            ayuda,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF7E7688)),
          ),
        ],
      ),
    );
  }

  Widget _switch({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF29232F),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF7E7688),
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(
            value: value,
            activeColor: const Color(0xFF791FC1),
            activeTrackColor: const Color(0xFFDCC8F5),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
