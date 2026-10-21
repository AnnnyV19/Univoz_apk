// El visor debe funcionar sin internet: three.js y three-vrm van inline.
import { readFileSync, existsSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const visor = new URL('../../assets/avatar_viewer/', import.meta.url);
const html = readFileSync(new URL('index.html', visor), 'utf8');
const rutaVendor = new URL('vendor/univoz_vendor.min.js', visor);

test('index.html no importa three ni three-vrm desde un CDN', () => {
  assert.doesNotMatch(html, /cdn\.jsdelivr\.net\/npm\/three/);
  assert.doesNotMatch(html, /cdn\.jsdelivr\.net\/npm\/@pixiv\/three-vrm/);
  assert.doesNotMatch(html, /type="importmap"/);
  assert.doesNotMatch(html, /from 'three/);
  assert.doesNotMatch(html, /from '@pixiv\/three-vrm'/);
});

test('index.html inlina el vendor antes del script de modulo', () => {
  const ini = html.indexOf('<!-- inicio univoz_vendor.min.js -->');
  const fin = html.indexOf('<!-- fin univoz_vendor.min.js -->');
  assert.ok(ini > 0 && fin > ini, 'faltan los marcadores del vendor');
  assert.ok(ini < html.indexOf('<script type="module">'));
  const bloque = html.slice(ini, fin);
  const cierre = bloque.lastIndexOf('</script>');
  assert.ok(cierre > 0, 'el bloque no cierra su <script>');
  assert.doesNotMatch(bloque.slice(0, cierre), /<\/script/i,
    'un </script> dentro del vendor rompe el parseo');
  assert.match(html,
    /const \{ THREE, GLTFLoader, OrbitControls, VRMLoaderPlugin, VRMUtils, VRMHumanBoneName \} = window\.UnivozVendor;/);
});

test('el vendor existe, nombra versiones y expone lo que usa la pagina', () => {
  assert.ok(existsSync(rutaVendor), 'falta vendor/univoz_vendor.min.js');
  const src = readFileSync(rutaVendor, 'utf8');
  assert.match(src.slice(0, 600), /three@0\.160\.0/);
  assert.match(src.slice(0, 600), /three-vrm@2\.1\.3/);
  const ctx = { console };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(src + '\n;globalThis.__v = UnivozVendor;', ctx);
  const v = ctx.__v;
  for (const n of ['THREE', 'GLTFLoader', 'OrbitControls', 'VRMLoaderPlugin',
                   'VRMUtils', 'VRMHumanBoneName']) {
    assert.ok(v[n], 'falta ' + n);
  }
  assert.equal(typeof v.THREE.Scene, 'function');
});

test('el script inline del vendor es identico al archivo (con </script escapado)', () => {
  const src = readFileSync(rutaVendor, 'utf8').replaceAll('</script', '<\\/script');
  assert.ok(html.includes(src), 'index.html difiere del vendor; corre inline_viewer_modules.py');
});
