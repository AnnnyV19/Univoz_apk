// Genera assets/avatar_viewer/vendor/univoz_vendor.min.js (iife, minificado).
// El archivo generado se versiona: compilar la app no necesita red ni npm.
//   cd senas_core/tools/viewer_vendor && npm ci && npm run build
import { build } from 'esbuild';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const salida = new URL('../../assets/avatar_viewer/vendor/univoz_vendor.min.js', import.meta.url);
mkdirSync(new URL('./', salida), { recursive: true });

const version = (paquete) =>
  JSON.parse(readFileSync(new URL(`./node_modules/${paquete}/package.json`, import.meta.url), 'utf8')).version;

const banner =
  '/*! Univoz viewer vendor: three@' + version('three') + ' (MIT, (c) three.js authors) + ' +
  '@pixiv/three-vrm@' + version('@pixiv/three-vrm') + ' (MIT, (c) pixiv Inc.). ' +
  'Generado por senas_core/tools/viewer_vendor/build.mjs; no editar a mano. */';

await build({
  entryPoints: [new URL('./entry.mjs', import.meta.url).pathname],
  bundle: true,
  minify: true,
  format: 'iife',
  globalName: 'UnivozVendor',
  target: 'es2020',
  legalComments: 'none',
  banner: { js: banner },
  outfile: salida.pathname,
  logLevel: 'info',
});

// Los shaders GLSL de three.js (template strings) traen espacios al final de
// linea: no cambian nada en GLSL y hacen fallar 'git diff --check'.
const codigo = readFileSync(salida, 'utf8').replace(/[ \t]+$/gm, '');
writeFileSync(salida, codigo);
