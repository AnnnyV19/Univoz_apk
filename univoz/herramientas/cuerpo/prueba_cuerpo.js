// Prueba del separador de cuerpo: extrae el modulo del visor (entre
// <<CUERPO_INICIO>> y <<CUERPO_FIN>>), lo ejecuta y lo compara con la
// referencia en Python (casos.json).
const fs = require('fs');
const vm = require('vm');
const ruta = process.argv[2];
const casos = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
const html = fs.readFileSync(ruta, 'utf8');
const a = html.indexOf('// <<CUERPO_INICIO>>');
const b = html.indexOf('// <<CUERPO_FIN>>');
if (a < 0 || b < 0) { console.log('FALLA: no se encontro el modulo'); process.exit(1); }
const codigo = html.slice(a, b) + '\nthis.SeparadorCuerpo = SeparadorCuerpo;';
const ctx = {Math, Number}; vm.createContext(ctx); vm.runInContext(codigo, ctx);
const S = ctx.SeparadorCuerpo;
let peor = {empuje: 0, delta: 0, giro: 0, giroObj: 0, costo: 0}, falla = 0;
for (const [i, c] of casos.entries()) {
  const r = S.resolver(c.e, c.previo);
  const dd = Math.max(...r.delta.map((v, j) => Math.abs(v - c.out.delta[j])));
  const m = {empuje: Math.abs(r.empuje - c.out.empuje), delta: dd,
    giro: Math.abs(r.giro - c.out.giro), giroObj: Math.abs(r.giroObjetivo - c.out.giroObjetivo),
    costo: Math.abs(r.costo - c.out.costo)};
  for (const k of Object.keys(m)) peor[k] = Math.max(peor[k], m[k]);
  if (m.empuje > 1e-6 || m.delta > 1e-6 || m.giro > 1e-6 || r.iter !== c.out.iter) {
    falla++; if (falla <= 5) console.log('caso', i, m, 'iter', r.iter, c.out.iter);
  }
}
console.log('casos', casos.length, 'diferencias maximas', peor, 'fallas', falla);
process.exit(falla ? 1 : 0);
