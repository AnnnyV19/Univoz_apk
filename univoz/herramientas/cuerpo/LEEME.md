# Separadores del avatar: cuerpo (13-oct) y manos (14-oct-2026), y frases seguidas

Evita que muñecas, manos y antebrazos del avatar atraviesen su propio torso **sin cambiar nunca la altura de la muñeca**.
El código vive en `senas_core/assets/avatar_viewer/rig_cuerpo.mjs` (módulo `SeparadorCuerpo`, matemática pura, inlineado en
`index.html`) y se conecta en `resolverBrazo`. En la integración queda APAGADO por defecto (`cal.separarCuerpo = false`; se enciende
con `"separar_cuerpo": true` en `configurarRig`).

**Separador de manos (14-oct):** una mano no atraviesa a la otra ni al antebrazo de la otra. Vive en
`rig_manos.mjs` (módulo `SeparadorManos`); `aplicarFrame` lo calcula UNA vez por cuadro
para los dos brazos (`planificarManos`) y `resolverBrazo` usa el plan. Solo mueve muñecas en HORIZONTAL (la altura
no cambia nunca): la mano que queda delante se adelanta (máx. 4.5 cm por mano, cambio máx. 1 cm por cuadro).
APAGADO por defecto en la integración (`"separar_manos": true` en `configurarRig` lo enciende; necesita `separarCuerpo`).

**Frases (14-oct):** `window.reproducirFrase(json, '2.0.0')` recibe `[{frames: 32x152, fps}, ...]` y las hace
seguidas, con una transición de 0.26 s entre seña y seña (`rig_frase.mjs`; el puente de Dart es `AvatarBridge.reproducirFrase`).

## Pruebas (necesitan Node.js)
**Integración (docs/17):** el código del visor ya no vive dentro de `index.html`: se editan los módulos
`senas_core/assets/avatar_viewer/rig_cuerpo.mjs` (`SeparadorCuerpo`), `rig_manos.mjs` (`SeparadorManos`),
`rig_replay.mjs`, `rig_frase.mjs`, `rig_encuadre.mjs` y `rig_mano_ik.mjs` (ManoIK, sin conectar) y se regenera
`index.html` con `python3 senas_core/tools/inline_viewer_modules.py`. Las pruebas de la matemática pura son ahora
pruebas normales de `senas_core/tools/rig-tests/` (`npm test` o `./scripts/univoz.sh test`), con los casos de
referencia en `senas_core/tools/rig-tests/paridad_cuerpo/`:
1. `rig_cuerpo.test.mjs`: `SeparadorCuerpo` contra la referencia en Python (`casos_cuerpo.json`, 200 casos; coincide a 1e-6).
2. `rig_manos.test.mjs`: `SeparadorManos` contra la referencia en Python (`casos_par.json`, 150 pares).
3. `rig_frase.test.mjs`: arma una frase (HOLA, COMO_ESTAS, A, N, A) con `frase_prueba.json` y revisa las transiciones.

`prueba_visor.js` y `prueba_visor_manos.js` (con `mini_three.js`, `casos_visor*.json`) extraían `resolverBrazo` del
`index.html` de la dueña con sus marcas `<<CUERPO_INICIO>>`: **no funcionan con el visor integrado** (esas marcas ya no
existen y `resolverBrazo` cambió). Quedan como referencia; adaptarlas es un pendiente (docs/17).

## Simulación (Python, `simulacion/`)
Mide la penetración contra el torso de la malla del VRM (cascos convexos por altura). Se corre dentro de `simulacion/`:
- `python primeras.py ..\..\assets\plantillas.json primeras.npz`  (primera plantilla de cada glosa)
- `python validar4.py 1`  (todos los cuadros: penetración antes/después, altura, empuje, giro de codo)
- `python validar5.py`   (cuadros interpolados: suavidad del codo y de la muñeca)
- `python tabla_torso.py` regenera la tabla del torso (si cambia el modelo VRM; luego pegarla en `TABLA` del visor y en `separar4.py`)
- `python gen_casos.py` regenera `senas_core/tools/rig-tests/paridad_cuerpo/casos_cuerpo.json`
- Manos: `separar7.py` (referencia), `validar7.py` (cuadros sueltos), `validar8.py` (secuencias interpoladas: saltos y tasa),
  `gen_casos_par.py` (regenera `paridad_cuerpo/casos_par.json`), `medir_malla_mano.py` (grosor real de palma, dedos y antebrazo del VRM).
- Frases: `python espejo_frase.py "hola, ¿cómo estás?"` muestra qué señas saldrían con tu `plantillas.json`.
Requiere numpy y scipy. El VRM se busca en `..\..\assets\avatar\MODELO_UNIVOZ_v0.vrm` (o la variable `UNIVOZ_VRM`).

## Cómo funciona
1. Torso = tabla de cortes medida en la malla (superelipse N=2.4 por altura), escalada con el ancho de hombros del avatar
   y girada con la inclinación del pecho.
2. Empuje: si la muñeca o un punto de la mano (palma, nudillos, dedos) queda dentro del torso, el objetivo de la muñeca se corre
   HACIA ADELANTE (horizontal) lo justo para salir. Si el brazo ya está estirado y no puede avanzar, gira en horizontal (misma altura).
3. Giro del codo: alrededor del eje hombro-muñeca (±90°, afinado con sección áurea; máx. 12° por cuadro) hasta que codo y antebrazo salen.
4. Manos: esferas en muñeca, palma, nudillos, dedos y antebrazo (radios medidos en la malla). Se busca la traslación
   relativa horizontal mínima (48 direcciones; el costado cuesta 1.5× la profundidad, histéresis para no cambiar de
   lado) y se reparte: en profundidad se adelanta la mano de delante; de costado, mitad y mitad. Cada paso vuelve a
   pasar por el separador de cuerpo.
5. No hay colisión con la cabeza ni con la parte superior del brazo.
