# Ilustraciones de UNIVOZ

Dibujos planos con la paleta de Lucía (morado #791FC1, sin verde, sin emojis). Las pantallas usan menos texto y estas imágenes en su lugar.

- `generar.py` escribe los `.svg` de esta carpeta. Cada dibujo es una entrada de `ilus`.
- `a_png.js` los pasa a PNG en 1x, 2x y 3x (240×180 lógicos), dentro de `univoz/assets/ilustraciones/`. Necesita Node y Playwright con Chromium.

```
python generar.py
node a_png.js . ../../assets/ilustraciones
```
