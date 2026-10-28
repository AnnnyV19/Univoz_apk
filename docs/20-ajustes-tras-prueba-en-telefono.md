# 20. Ajustes después de la prueba en el teléfono (2026-10-28)

Rama `integracion-final`. Esto es lo que pidió la dueña después de probar la app en el teléfono.

## Avatar

- **Mezcla: movimiento de Karim + preparación de UNIVOZ.** El visor (`index.html` y los `rig_*.mjs`) vuelve a ser el de la integración (Karim = Javier Karim Andrade, `Xavier82h8`), con lo que hacía bien el de la dueña: suavizado, reparación de palmas volteadas, anticipación y frases unidas (`reproducirFrase` nativo).
- **Separadores apagados.** `separarCuerpo` y `separarManos` quedan en `false` en `cal`: eran los que empujaban las manos hacia el fondo.
- **Modelo:** `MODELO_UNIVOZ_v0.vrm` (el `univozM` se veía difícil).
- **Señas que se ven mal.** Medición de la mezcla en las 541 señas (`herramientas/auditoria_manos`): la muñeca casi no se separa de los datos (máximo por seña, mediana 0.9 cm; Karim solo 13.8 cm). La palma en las peores señas sigue como en Karim (p90 por seña: 62° en el 10 % peor; el visor anterior de UNIVOZ daba 26°) y hay 68 latigazos de palma. La lista de [senas_que_se_ven_mal.csv](senas_que_se_ven_mal.csv) (152) se hizo con el visor de Karim; muchas vienen de tomas con la palma volteada y hay que regrabarlas.

- **Dedos derechos que apuntaban hacia quien mira** (2026-10-28). El visor medía cada falange con el ángulo sin signo entre dos segmentos, así que la abertura lateral (el índice sale ~20° de la línea del metacarpo) y la punta un poco hacia atrás contaban como doblez hacia la palma. Ahora la flexión de los dedos largos va con signo sobre la normal de la palma (`rig_manos.mjs`, `flexionesConSigno`, interruptor `cal.flexionConSigno`). Si una toma viene espejada se detecta y se corrige. Medido en las 541 señas, en los dedos que el video muestra derechos: el avatar los doblaba más de 30° en el 73 % de los cuadros; ahora en el 5.8 %. Muñeca y palma, sin cambios.

## Reconocimiento

- **El detector no arrancaba en la vista previa.** La cámara del teléfono manda cuadros con manos alternados con cuadros de solo cuerpo, y el movimiento se medía contra el cuadro anterior, que muchas veces no tenía manos. Ahora cada mano se compara con la última vez que se vio (hasta 250 ms).
- **Estado visible.** Arriba de la cámara: "Haz tu seña" → "Leyendo la seña..." → "Reconociendo..." → la palabra, o "No la reconocí. Repite la seña".
- **Sin avatar, el automático no cortaba.** Antes el visor del avatar decidía cuándo había movimiento. Al quitar el avatar de Traducir y de la pantalla partida quedaba el detector por píxeles. Ahora `MovimientoTipoVisor` (en `controlador_captura.dart`) calcula en Dart lo mismo que el visor (`rig_math.mjs`), sobre los frames fusionados.
- **Cámara en espejo otra vez** con la frontal (imagen y esqueleto). Sin espejo, al mover el brazo derecho se movía uno del lado izquierdo.

## Comunicarse

Cuando una persona sabe LSM y la otra no (modos `avatar` y `camaraSenas`), la pantalla se parte en dos:

- **Arriba, el avatar** con sus controles encima: Deletreo/Palabra, "Escribe aquí", ▶ y micrófono. Firma lo que la otra persona escribe o dice.
- **Abajo, la cámara de fondo** (`PantallaDeTranslacion` embebida y sin avatar), con el SOS pequeño. La seña reconocida se vuelve texto; si del otro lado alguien oye, también se dice en voz alta.
- **Oyente con sordo que no sabe LSM:** solo escribir y leer.

Además:

- **Palabra.** Busca frases y palabras guardadas sin importar acentos ni mayúsculas ("hola, como estas" → HOLA + COMO_ESTAS) y deletrea lo que no tenga seña.
- **Deletreo.** Deletrea letra por letra (`deletrearTexto`).
- **Botón ▶ Señar.** Ya no hace falta dar Enter.
- **Teclado en pantalla.** Se quitó para que todo quepa sin desplazar; se usa el teclado del teléfono.
- **Voz.** La explicación larga se dice solo la primera vez; después solo "Habla ahora". Cuando el avatar termina de firmar, la app dice "Ahora responde con señas" y espera la seña en la cámara, en lugar de seguir escuchando.

## Navegación y perfiles

- **Menú de 3 opciones** con la tuerca de Configuración. "¿Cómo funciona?" → Comenzar lleva al menú.
- **"Atrás"** regresa a la pantalla anterior; antes saltaba al menú.
- **Preguntas que no cambian nada, ahora se saltan:**
  - si la otra persona es ciega, ya no se pregunta si usa lector de pantalla;
  - si tú eres sordo/a o mudo/a con LSM y la otra persona es sorda o muda, se asume que no sabe LSM.
- **Traducir una seña** ya no muestra el avatar (`AvatarBridge.apagado`, sin WebView).
- **Tutorial de primer uso** (`TutorialScreen`): 5 pasos con dibujo y dos o tres palabras. Se ve una sola vez (`TutorialVisto`).

## Diseño

- **Ilustraciones propias** en `herramientas/ilustraciones` → `assets/ilustraciones`. En pantalla va poco texto; la frase completa la lee TalkBack.
- **Sin desplazar:** menú, perfiles, ¿Cómo funciona?, Comunicarse, Aprender (una unidad a la vez, con flechas) y Lección.
- **Botones:** quedan como estaban, salvo los verdes, que ahora son morados. El botón SOS quedó centrado y dice solo "SOS".

## Bienvenida

- Degradado morado con la ilustración de la dueña en gris al 16 %, logo, "UNIVOZ" y un botón blanco "Comenzar". La primera vez lleva al tutorial.
- "Sabe LSM": las letras L, S, M con tres manos; "No sabe LSM": lo mismo con el símbolo de prohibido.

## Recolector nocturno

`senas_core/tools/recolector_nocturno.py` busca cada noche videos con licencia Creative Commons (YouTube) y de Wikisigns para las señas con menos de 10 muestras, saca los landmarks y los guarda como pendientes. Solo aprueba los que el reconocedor confirma como la misma seña con distancia, margen y calidad holgados; el resto queda para revisión. Reporte en `datasets_lsm/recolector/reporte_<fecha>.csv`. La tarea de Windows se registra a mano con `registrar_recolector.bat` (3:17 a. m.).

**Panel** (`panel_recolector.bat` → http://127.0.0.1:8731): en vivo (fase, seña, video, contadores, lo que va diciendo; correr y detener), revisar (video junto al esqueleto guardado; aprobar, aprobar suavizada, rechazar con motivo, recortar y volver a sacar) y lo que aprendió. `aprendizaje_recolector.py` aprende de esas revisiones: canales y señas que ya no se buscan en YouTube, calidad mínima, suavizado automático (mediana de 3 cuadros, no mueve alturas) y, desde 20 revisiones, una regresión logística que decide qué aprobar solo con un umbral que en sus revisiones da ≥ 95 % de acierto.

## Pendiente
- Probar en el teléfono la pantalla partida, cámara y avatar a la vez.
- Regrabar las tomas de `senas_que_se_ven_mal.csv`.
- Lucía: subir `immersive_navigation.dart`.
- Sacar `Model_Yuki_N.vrm` del repo público.
