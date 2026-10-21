// Prueba de la frase: armarFrase del visor sobre señas reales.
const fs = require('fs'), vm = require('vm');
const [,, ruta, rutaSeg] = process.argv;
const html = fs.readFileSync(ruta, 'utf8');
const corte = (a, b) => html.slice(html.indexOf(a), html.indexOf(b));
const codigo = 'const kOffBody = 0, kOffLocL = 24, kOffLocR = 27, kOffPresL = 30, kOffPresR = 31, kOffShapeL = 32, kOffShapeR = 92, kFrameDim = 152, kTFrames = 32;\n' +
  corte('// <<ESTABLE_INICIO>>', '// <<ESTABLE_FIN>>') + '\n' +
  "const esFrameValido = (frame) => Array.isArray(frame) && frame.length === kFrameDim && frame.every((v) => Number.isFinite(Number(v)));\n" +
  corte('// <<FRASE_INICIO>>', '// <<FRASE_FIN>>') + '\nthis.armarFrase = armarFrase;';
const ctx = {Math, Number, Array, JSON, window: {}, avisar: (m) => console.log('AVISO', m)};
vm.createContext(ctx); vm.runInContext(codigo, ctx);
const segs = JSON.parse(fs.readFileSync(rutaSeg, 'utf8'));
const f = ctx.armarFrase(segs);
let falla = 0;
const malos = f.frames.filter((x) => x.length !== 152 || !x.every(Number.isFinite)).length;
if (malos) { falla++; console.log('FALLA: cuadros invalidos', malos); }
// salto maximo de muñeca entre cuadros consecutivos (mano presente en ambos)
let salto = 0;
for (let i = 1; i < f.frames.length; i++) {
  for (const [p, l] of [[30, 24], [31, 27]]) {
    if (f.frames[i][p] >= .5 && f.frames[i - 1][p] >= .5) {
      salto = Math.max(salto, Math.hypot(...[0, 1, 2].map((k) => f.frames[i][l + k] - f.frames[i - 1][l + k])));
    }
  }
}
const dur = f.frames.length / f.fps;
console.log('segmentos', segs.length, '| cuadros', f.frames.length, '| fps', f.fps, '| duracion', dur.toFixed(2), 's | salto max muñeca entre cuadros', salto.toFixed(3), 'anchos de hombro');
// llamada completa
ctx.colaFrames = null; ctx.arrancarReproduccion = (fr, fps) => { ctx.__ok = [fr.length, fps]; };
vm.runInContext('window.reproducirFrase = undefined;', ctx);

// saltos en las TRANSICIONES (los de dentro de una seña vienen de la grabacion)
const base = f.fps, nT = Math.max(2, Math.round(0.26 * base));
let idx = 0; const trans = new Set();
segs.forEach((sg, i) => {
  if (i > 0) { for (let j = 0; j <= nT; j++) trans.add(idx + j); idx += nT; }
  idx += Math.max(2, Math.round(32 * base / (sg.fps || 30)));
});
if (idx !== f.frames.length) { falla++; console.log('FALLA: largo inesperado', idx, f.frames.length); }
let saltoT = 0;
for (const i of trans) for (const [p, l] of [[30, 24], [31, 27]]) {
  if (i > 0 && i < f.frames.length && f.frames[i][p] >= .5 && f.frames[i - 1][p] >= .5) {
    saltoT = Math.max(saltoT, Math.hypot(...[0, 1, 2].map((k) => f.frames[i][l + k] - f.frames[i - 1][l + k])));
  }
}
console.log('salto max de muñeca en las transiciones:', saltoT.toFixed(3), 'anchos de hombro por cuadro');
if (saltoT > 0.2) { falla++; console.log('FALLA: transicion brusca'); }
process.exit(falla ? 1 : 0);
