# 20. Ajustes después de la prueba en el teléfono (2026-10-28)

Rama `integracion-final`. Esto es lo que pidió la dueña después de probar la app en el teléfono.

## Avatar

- **Ahora es 100% el de Karim** (Javier Karim Andrade, `Xavier82h8`). El visor (`index.html` y los `rig_*.mjs`) y sus pruebas son los de la rama `karim`, y el modelo es `univozM.vrm`.
- **Lo que se quitó.** Las piezas de app-limpia y de la auditoría del 20-oct (`rig_cuerpo`, `rig_manos`, `rig_mano_ik`, `rig_replay`, `rig_frase`, `rig_encuadre`) daban problemas de profundidad.
  - `MODELO_UNIVOZ_v0.vrm` sigue en `univoz/assets/avatar/` pero no se empaqueta.
- **Frases.** El visor de Karim no une señas, así que `AvatarBridge.reproducirFrase` las manda una por una: cada seña espera el `fin` de la anterior.
- **Cámara de Traducir.** Ya no voltea la imagen ni los puntos, igual que la versión de Karim.
- **Señas que se ven mal.** Se midieron las 541 señas en el visor de Karim con `herramientas/auditoria_manos`. 152 tienen un error alto de muñeca o de palma, o un latigazo; la lista está en [senas_que_se_ven_mal.csv](senas_que_se_ven_mal.csv). Muchas vienen de tomas con la palma volteada en los datos y hay que regrabarlas.

## Comunicarse

Cuando una persona sabe LSM y la otra no (modos `avatar` y `camaraSenas`), la pantalla se parte en dos:

- **Arriba, la cámara** (`PantallaDeTranslacion` embebida y sin avatar). La seña reconocida se vuelve texto. Si del otro lado alguien oye, también se dice en voz alta.
- **Abajo, el avatar.** Firma lo que la otra persona escribe o dice.

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

## Pendiente

- Fondo de la bienvenida: la imagen la va a dar la dueña.
- Probar en el teléfono la pantalla partida, cámara y avatar a la vez.
- Regrabar las tomas de `senas_que_se_ven_mal.csv`.
- Lucía: subir `immersive_navigation.dart`.
- Sacar `Model_Yuki_N.vrm` del repo público.
