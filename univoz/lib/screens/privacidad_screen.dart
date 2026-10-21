import 'package:flutter/material.dart';

/// Texto de privacidad de la app. Es el MISMO texto de docs/PRIVACIDAD.md
/// (la prueba privacidad_test.dart falla si se separan): si cambias uno,
/// cambia el otro. Vive en Dart y no como asset para no sumar un lector de
/// markdown.
class SeccionPrivacidad {
  final String titulo;
  final List<String> puntos;
  const SeccionPrivacidad(this.titulo, this.puntos);
}

const String kTituloPrivacidad = 'Privacidad de Univoz';

const String kIntroPrivacidad =
    'Univoz es una app para comunicarte con señas. Aquí te contamos, '
    'sin letra chiquita, qué pasa con tus datos. Versión 0.9.0 beta, '
    'actualizada el 20 de octubre de 2026.';

const List<SeccionPrivacidad> kSeccionesPrivacidad = [
  SeccionPrivacidad('Tu cámara', [
    'La cámara se usa solo para ver tus manos, tu cuerpo y tu cara y '
        'así reconocer tus señas.',
    'Las imágenes se procesan en tu teléfono, al instante. El video y'
        ' las fotos no se guardan ni salen de tu teléfono.',
    'Lo único que la app maneja son puntos (la posición de tus manos, '
        'tu cuerpo y unos cuantos puntos de tu cara), no tu imagen.',
  ]),
  SeccionPrivacidad('Sesiones para mejorar el reconocimiento', [
    'Solo si lo permites, la app guarda en tu teléfono sesiones con '
        'esos puntos (nunca video) para mejorar el reconocimiento.',
    'Si dices que no, no se guarda nada, y tu respuesta se recuerda '
        'para no volver a preguntarte a cada rato. Puedes cambiarla '
        'cuando quieras en Configuración, Ajustes de reconocimiento.',
    'Las sesiones se quedan en tu teléfono y no se envían solas. Para'
        ' no llenar tu almacenamiento, las más viejas se borran solas '
        'y, en total, las sesiones guardadas ocupan unos 50 MB como máximo.',
  ]),
  SeccionPrivacidad('Diccionario y muestras (Sincronizar)', [
    'Al abrir la app, como máximo una vez al día, se descarga en '
        'segundo plano el diccionario de señas aprobado desde nuestro '
        'servidor (Supabase). Para eso no envía nada tuyo, aunque, como '
        'en cualquier conexión a internet, el servidor ve tu dirección '
        'IP.',
    'Si grabas muestras de señas, solo se suben a nuestro servidor '
        'cuando tú eliges subirlas desde Sincronizar. Lo que se sube son '
        'los puntos de la seña y su palabra, nunca video ni fotos.',
    'Nada se sube en automático.',
  ]),
  SeccionPrivacidad('Micrófono', [
    'El micrófono se usa solo para dictar mensajes y para los '
        'comandos de voz del modo para personas ciegas, y solo se abre '
        'cuando tú lo activas o justo después de que la app te hace una '
        'pregunta en voz alta, y se cierra al terminar.',
    'Univoz no graba ni guarda tu voz. El reconocimiento de voz lo '
        'hace el servicio de voz de tu teléfono Android; según tu '
        'teléfono y los idiomas que tengas descargados, puede procesarse '
        'en el teléfono o por el servicio de voz de tu sistema (por '
        'ejemplo, Google).',
  ]),
  SeccionPrivacidad('Contacto de emergencia y SOS', [
    'El nombre y el número de tu contacto de emergencia se guardan '
        'solo en tu teléfono. Univoz no los recibe ni los sube.',
    'El botón SOS abre el marcador o la app de mensajes de tu '
        'teléfono con ese número ya puesto. Nada se llama ni se envía '
        'solo: tú confirmas en esa app.',
  ]),
  SeccionPrivacidad('Registro de errores', [
    'Si la app falla, anota el error en un archivo dentro de tu '
        'teléfono para poder arreglarlo. No usa servicios externos y solo'
        ' sale de tu teléfono si tú lo compartes a mano.',
  ]),
  SeccionPrivacidad('Lo que no hacemos', [
    'No hay anuncios, no hay analítica ni rastreadores y no necesitas'
        ' crear una cuenta.',
    'No vendemos ni compartimos tus datos con terceros.',
  ]),
  SeccionPrivacidad('Cómo borrar tus datos', [
    'Sesiones, consentimiento y perfil corporal: Configuración, '
        'Ajustes de reconocimiento, Borrar mis datos.',
    'Contacto de emergencia: Configuración, Contacto de emergencia, '
        'Quitar contacto.',
    'Muestras que grabaste: bórralas desde la lista de muestras de la'
        ' app.',
    'Todo de una vez: en los ajustes de Android, Apps, Univoz, '
        'Almacenamiento, Borrar datos; o desinstala la app.',
    'Si ya subiste muestras a nuestro servidor y quieres que las '
        'borremos, escríbenos al correo de contacto de la ficha de la app'
        ' y las quitamos.',
  ]),
];

/// El mismo texto en markdown, tal como está en docs/PRIVACIDAD.md.
String privacidadMarkdown() {
  final b = StringBuffer('# $kTituloPrivacidad\n\n$kIntroPrivacidad\n');
  for (final s in kSeccionesPrivacidad) {
    b.write('\n## ${s.titulo}\n\n');
    for (final p in s.puntos) {
      b.write('- $p\n');
    }
  }
  return b.toString();
}

/// Pantalla "Privacidad" de Configuración: el texto de [kSeccionesPrivacidad]
/// con el tema de la app, sin nada que cargar ni conectar.
class PrivacidadScreen extends StatelessWidget {
  const PrivacidadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final colores = tema.colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacidad')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              kTituloPrivacidad,
              style: tema.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(kIntroPrivacidad,
                style: TextStyle(color: colores.onSurfaceVariant)),
            for (final s in kSeccionesPrivacidad) ...[
              const SizedBox(height: 20),
              Semantics(
                header: true,
                child: Text(
                  s.titulo,
                  style: tema.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold, color: colores.primary),
                ),
              ),
              const SizedBox(height: 6),
              for (final p in s.puntos)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(p)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
