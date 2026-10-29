import 'package:flutter/material.dart';
import 'package:senas_core/tema_univoz.dart';

/// Una fuente de datos que se usa en UNIVOZ y cuya licencia obliga a dar
/// crédito. Los textos salen de `senas_core/datasets_lsm/CREDITOS.md`.
class FuenteDeDatos {
  final String nombre;
  final String licencia;
  final String cita;
  final String enlace;

  const FuenteDeDatos({
    required this.nombre,
    required this.licencia,
    required this.cita,
    required this.enlace,
  });
}

/// Fuentes de las que sale (o saldrá) el vocabulario de la app. Si se
/// agrega un dataset nuevo, se agrega aquí y en CREDITOS.md.
const List<FuenteDeDatos> fuentesDeDatos = [
  FuenteDeDatos(
    nombre: 'Mexican Sign Language Glosses (Dynamic Signs) — CICESE',
    licencia: 'CC BY 4.0',
    cita: 'Navarrete López, J. A., Sainos-Vizuett, M., & López-Nava, I. H. '
        '(2026). Zenodo.',
    enlace: 'https://doi.org/10.5281/zenodo.18330565',
  ),
  FuenteDeDatos(
    nombre: 'Alfabeto LSM, letras dinámicas y estáticas — CICESE',
    licencia: 'CC BY 4.0',
    cita: "Datos del artículo 'A comprehensive dataset of static and dynamic "
        "signs for the Mexican Sign Language alphabet' (CICESE, Data in "
        'Brief 66:112887, 2026). Zenodo.',
    enlace: 'https://doi.org/10.5281/zenodo.14689869 y '
        'https://doi.org/10.5281/zenodo.10067509',
  ),
  FuenteDeDatos(
    nombre: 'Wikisigns — Lengua de Señas Mexicana',
    licencia: 'CC BY-SA 4.0',
    cita: 'Wikisigns, Lengua de Señas Mexicana. Videos de sus autores.',
    enlace: 'https://www.wikisigns.org/list/es/lsm',
  ),
  FuenteDeDatos(
    nombre: 'ITESO-MX-100',
    licencia: 'CC BY 4.0',
    cita: 'Martínez Sánchez, V. H. (2026). ITESO-MX-100 [Data set]. '
        'Mendeley Data, V1.',
    enlace: 'https://doi.org/10.17632/g45jkzys4f.1',
  ),
  FuenteDeDatos(
    nombre: 'Mexican sign language dataset — UAEMex (249 palabras)',
    licencia: 'CC BY 4.0',
    cita: 'Espejel, J., Dominguez, L. Y., Cervantes, J., & Cervantes, J. '
        '(2023). Universidad Autónoma del Estado de México. Mendeley Data, V1.',
    enlace: 'https://doi.org/10.17632/6rj76z6y3n.1',
  ),
  FuenteDeDatos(
    nombre: 'Glosario Digital de Lengua de Señas Mexicana — INDISCAPACIDAD CDMX',
    licencia: 'Uso autorizado por INDISCAPACIDAD CDMX',
    cita: 'Instituto de las Personas con Discapacidad de la Ciudad de México, '
        'con organizaciones de personas Sordas. Su reproducción requiere '
        'autorización del Instituto. En UNIVOZ: solo Diccionario y avatar.',
    enlace: 'https://lsm.indiscapacidad.cdmx.gob.mx/',
  ),
];

/// Pantalla "Acerca de y créditos": qué es UNIVOZ y de dónde salen los datos
/// de las señas, con la licencia de cada fuente (las licencias CC BY y
/// CC BY-SA obligan a dar crédito y a decir si se hicieron cambios).
class AcercaScreen extends StatelessWidget {
  const AcercaScreen({super.key});

  static const Color _bgColor = ColoresUnivoz.fondoSuave;
  static const Color _ink = ColoresUnivoz.tinta;
  static const Color _gray = ColoresUnivoz.tintaSuave;
  static const Color _accent = ColoresUnivoz.morado;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _bgColor,
        foregroundColor: _ink,
        elevation: 0,
        title: const Text(
          'Acerca de y créditos',
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'UNIVOZ',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Aplicación para aprender y comunicarse en lengua de señas '
                'mexicana (LSM), con un avatar 3D y reconocimiento de señas '
                'con la cámara.',
                style: TextStyle(fontSize: 14, color: _gray, height: 1.4),
              ),
              const SizedBox(height: 24),
              const Text(
                'Datos de las señas',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: _ink,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Parte del vocabulario viene de estos conjuntos de datos '
                'abiertos. UNIVOZ no distribuye sus videos ni fotos: de '
                'ellos se extrajeron puntos de referencia del cuerpo y de las '
                'manos, que se normalizaron y se usan como plantillas. '
                'Gracias a las personas y a los equipos que los hicieron.',
                style: TextStyle(fontSize: 14, color: _gray, height: 1.4),
              ),
              const SizedBox(height: 16),
              for (final f in fuentesDeDatos) _TarjetaFuente(fuente: f),
              const SizedBox(height: 8),
              const Text(
                'Las descripciones de cómo se hace cada letra se basan en '
                'videos de referencia del abecedario de la LSM (SEP e '
                '"Incluyéndome").',
                style: TextStyle(fontSize: 12, color: _gray, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TarjetaFuente extends StatelessWidget {
  final FuenteDeDatos fuente;
  const _TarjetaFuente({required this.fuente});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fuente.nombre,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AcercaScreen._ink,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Licencia ${fuente.licencia}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AcercaScreen._accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            fuente.cita,
            style: const TextStyle(
              fontSize: 13,
              color: AcercaScreen._gray,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            fuente.enlace,
            style: const TextStyle(fontSize: 12, color: AcercaScreen._ink),
          ),
        ],
      ),
    );
  }
}
