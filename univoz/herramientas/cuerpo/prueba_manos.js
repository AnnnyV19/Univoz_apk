// Prueba del separador de manos: extrae SeparadorCuerpo y SeparadorManos del
// visor (entre las marcas <<CUERPO_INICIO>>..<<MANOS_FIN>>) y los compara con
// la referencia en Python (casos_par.json).
const fs = require('fs');
const vm = require('vm');
const [,, ruta, rutaCasos] = process.argv;
const casos = JSON.parse(fs.readFileSync(rutaCasos, 'utf8'));
const html = fs.readFileSync(ruta, 'utf8');
const a = html.indexOf('// <<CUERPO_INICIO>>');
const b = html.indexOf('// <<MANOS_FIN>>');
if (a < 0 || b < 0) { console.log('FALLA: no se encontraron los modulos'); process.exit(1); }
const codigo = html.slice(a, b) + '\nthis.SeparadorManos = SeparadorManos;';
const ctx = {Math, Number, Object, Array}; vm.createContext(ctx); vm.runInContext(codigo, ctx);
const M = ctx.SeparadorManos;
const peor = {delta: 0, giro: 0, sh: 0, empuje: 0, psi: 0};
let falla = 0, conPases = 0;
for (const [i, c] of casos.entries()) {
  const r = M.resolverPar(c.es, c.previos, c.prevPar);
  const m = {delta: 0, giro: 0, sh: 0, empuje: 0, psi: 0};
  for (let l = 0; l < 2; l++) {
    m.delta = Math.max(m.delta, ...r.res[l].delta.map((v, j) => Math.abs(v - c.out.delta[l][j])));
    m.giro = Math.max(m.giro, Math.abs(r.res[l].giro - c.out.giro[l]));
    m.empuje = Math.max(m.empuje, Math.abs(r.res[l].empuje - c.out.empuje[l]));
    m.sh = Math.max(m.sh, ...r.sh[l].map((v, j) => Math.abs(v - c.out.sh[l][j])));
  }
  if (c.out.psi !== null && r.psi !== null) {
    const d = Math.abs(r.psi - c.out.psi); m.psi = Math.min(d, Math.abs(2 * Math.PI - d));
  } else if ((c.out.psi === null) !== (r.psi === null)) m.psi = 99;
  for (const k of Object.keys(m)) peor[k] = Math.max(peor[k], m[k]);
  if (r.pases > 0) conPases++;
  if (m.delta > 1e-6 || m.giro > 1e-6 || m.sh > 1e-6 || m.psi > 1e-9 || r.pases !== c.out.pases || r.limitado !== c.out.limitado) {
    falla++; if (falla <= 6) console.log('caso', i, m, 'pases', r.pases, c.out.pases, 'lim', r.limitado, c.out.limitado);
  }
}
console.log('casos', casos.length, '(con separacion:', conPases + ')', 'diferencias maximas', peor, 'fallas', falla);
process.exit(falla ? 1 : 0);
