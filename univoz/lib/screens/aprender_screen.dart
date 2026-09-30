import 'package:flutter/material.dart';
import 'package:senas_core/avatar_bridge.dart';
import 'package:senas_core/avatar_view.dart';
import 'package:senas_core/muestras_locales.dart';
import 'univoz_shared_widgets.dart';

/// Pestaña "Aprender señas": diccionario visual de LSM con avatar 3D.
class AprenderScreen extends StatefulWidget {
  const AprenderScreen({super.key});

  @override
  State<AprenderScreen> createState() => _AprenderScreenState();
}

class _AprenderScreenState extends State<AprenderScreen> {
  final _avatarBridge = AvatarBridge();
  final _almacen = AlmacenMuestras.instancia;
  bool _playing = false;
  double _speed = 1.0;

  /// Categorías para filtrar el diccionario de señas (por ejemplo
  /// "Saludos", "Familia", "Números"). Antes había aquí una barra de
  /// búsqueda por texto; ahora se filtra eligiendo una categoría en vez
  /// de escribir. Se llenará con las categorías reales desde Supabase —
  /// mientras tanto queda vacía a propósito, en vez de mostrar nombres
  /// de categoría inventados que todavía no existen (ver
  /// [_buildCategoryFilter]).
  List<String> _categories = [];
  String? _selectedCategory;

  static const Color _bgColor = Color(0xFFF7F2FA);

  @override
  void initState() {
    super.initState();
    _prepararAvatar();
  }

  Future<void> _prepararAvatar() async {
    try {
      await _almacen.cargar();
      await _avatarBridge.configurarRig(_almacen.ajustes.rigCalibration);
    } catch (_) {
      // El visor muestra disponibilidad; no bloqueamos diccionario.
    }
  }

  @override
  void dispose() {
    _avatarBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: const UnivozHeader(),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCategoryFilter(),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: () {
                    // TODO: avanzar a la siguiente seña del diccionario
                    // (respetando _selectedCategory si hay una elegida).
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFB84FCE),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text('Siguiente',
                      style: TextStyle(color: Colors.white)),
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEDE4FB),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: AvatarViewport(bridge: _avatarBridge),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE85DA0),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Text(
                            'Nombre seña',
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
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _controlButton(
                    icon: _playing ? Icons.pause : Icons.play_arrow,
                    color: const Color(0xFF8B5CF6),
                    onTap: () => setState(() => _playing = !_playing),
                  ),
                  const SizedBox(width: 14),
                  _controlButton(
                    icon: Icons.replay,
                    color: const Color(0xFFE85D5D),
                    onTap: () {
                      // TODO: repetir animación de la seña desde el inicio.
                    },
                  ),
                  const SizedBox(width: 14),
                  _controlButton(
                    icon: Icons.camera_alt_outlined,
                    color: const Color(0xFF6C63FF),
                    onTap: () {
                      // TODO: abrir cámara para practicar la seña.
                    },
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text(
                'Velocidad',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A1A2E),
                ),
              ),
              Slider(
                value: _speed,
                min: 0.5,
                max: 2.0,
                activeColor: const Color(0xFF8B5CF6),
                onChanged: (v) => setState(() => _speed = v),
              ),
              const SizedBox(height: 12),
              const SosButton(),
            ],
          ),
        ),
      ),
    );
  }

  /// Fila de categorías (chips) para filtrar el diccionario de señas, en
  /// vez de la barra de búsqueda de texto que había antes. Mientras
  /// [_categories] esté vacía (todavía no se conecta Supabase) no
  /// mostramos nada aquí, en vez de inventar categorías de ejemplo que
  /// no existen — en cuanto [_categories] tenga datos reales, esta fila
  /// aparece sola con los chips y el filtrado por [_selectedCategory] ya
  /// queda listo para usarse.
  Widget _buildCategoryFilter() {
    if (_categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final category = _categories[i];
          final bool selected = _selectedCategory == category;
          return ChoiceChip(
            label: Text(category),
            selected: selected,
            onSelected: (_) => setState(() {
              _selectedCategory = selected ? null : category;
            }),
            selectedColor: const Color(0xFF8B5CF6),
            backgroundColor: Colors.white,
            labelStyle: TextStyle(
              color: selected ? Colors.white : const Color(0xFF1A1A2E),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: selected
                    ? const Color(0xFF8B5CF6)
                    : const Color(0xFFDDD3EE),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _controlButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: CircleAvatar(
        radius: 26,
        backgroundColor: color,
        child: Icon(icon, color: Colors.white, size: 26),
      ),
    );
  }
}
