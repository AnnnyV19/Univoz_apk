// Ejecuta planificarManos + resolverBrazo REALES del visor (extraidos del HTML)
// con un THREE minimo, para las dos manos del mismo cuadro, con el separador
// de manos apagado y encendido.
const fs = require('fs'), vm = require('vm');
const THREE = require('./mini_three.js');
const [,, rutaHtml, rutaCasos, rutaSalida, inclinacionGrados = '0'] = process.argv;
const html = fs.readFileSync(rutaHtml, 'utf8');
const datos = JSON.parse(fs.readFileSync(rutaCasos, 'utf8'));
function funcion(nombre) {
  const a = html.indexOf('    function ' + nombre + '(');
  if (a < 0) throw new Error('no esta ' + nombre);
  const b = html.indexOf('\n    }\n', a);
  return html.slice(a, b + 7);
}
let modulo = '';
const ini = html.indexOf('    // <<CUERPO_INICIO>>');
const rb = html.indexOf('    function resolverBrazo(');
if (ini >= 0) modulo = html.slice(ini, rb);
const codigo = modulo + '\n' + funcion('vectorBaseAvatar') + '\n' + funcion('resolverBrazo');

const R = datos.rig, V = THREE.Vector3;
const aMundo = (p) => new V(-p[0], p[1], -p[2]);       // archivo -> mundo (escena girada pi)
const ctx = {THREE, Math, Number, Array, JSON, window: {}, console};
vm.createContext(ctx);
const capturas = [];
const hueso = (lado, tipo) => ({
  getWorldPosition(v) { return v.copy(aMundo(R[lado === 'left' ? 'L' : 'R'].sh)); },
  parent: {getWorldQuaternion(q) { return q; }},
  quaternion: new THREE.Quaternion(), tipo, lado,
});
const huesos = {};
for (const lado of ['left', 'right']) {
  huesos[lado] = {up: hueso(lado, 'up'), lo: hueso(lado, 'lo')};
}
ctx.VRMHumanBoneName = {LeftUpperArm: 'lu', RightUpperArm: 'ru', LeftLowerArm: 'll', RightLowerArm: 'rl'};
ctx.bone = (n) => ({lu: huesos.left.up, ru: huesos.right.up, ll: huesos.left.lo, rl: huesos.right.lo}[n]);
ctx.aplicarQuaternionSegura = (h, id, q) => { capturas.push({id, q: q.clone()}); };
const anchoHombros = R.W;
ctx.anchoHombrosAvatar = anchoHombros;
ctx.avDerecha = aMundo(R.R.sh).sub(aMundo(R.L.sh)).normalize();
ctx.avArriba = new V(0, 1, 0);
ctx.avFrente = new V(0, 0, 1);
ctx.kBase = {pDer: new V(1, 0, 0), pArr: new V(0, 1, 0), pFre: new V(0, 0, 1)};
ctx.cal = {leftArmGain: 1, rightArmGain: 1, ikMin: 0.05, ikMax: 2.60, invertZ: false, separarCuerpo: true};
ctx.refRig = {};
for (const [lado, k] of [['left', 'L'], ['right', 'R']]) {
  ctx.refRig[lado] = {
    dirUp: aMundo(R[k].dirUp).normalize(), dirLo: aMundo(R[k].dirLo).normalize(),
    lenUp: R[k].lenUp, lenLo: R[k].lenLo, palma: R[k].palma,
    qUp: new THREE.Quaternion(), qLo: new THREE.Quaternion(), qPadre: new THREE.Quaternion(),
  };
}
// Torso: matriz de mundo del pecho en reposo y "actual" (inclinada hacia adelante).
const p0 = aMundo(R.chest);
const restWorld = new THREE.Matrix4().makeRotationAxis(new V(0, 1, 0), Math.PI).setPosition(p0.x, p0.y, p0.z);
const pecho = {matrixWorld: restWorld.clone(), updateWorldMatrix() {}};
const orig = aMundo([(R.L.sh[0] + R.R.sh[0]) / 2, (R.L.sh[1] + R.R.sh[1]) / 2, (R.L.sh[2] + R.R.sh[2]) / 2]);
ctx.cuerpoRef = {bone: pecho, restWorld, origen: orig};
ctx.__capturas = capturas; ctx.__huesos = huesos; ctx.__plan = null;
vm.runInContext(codigo, ctx);


function reconstruir(lado) {
  const rr = ctx.refRig[lado];
  const sh = aMundo(R[lado === 'left' ? 'L' : 'R'].sh);
  const cU = capturas.find((c) => c.id === lado + ':upperArm').q;
  const cL = capturas.find((c) => c.id === lado + ':lowerArm').q;
  const mundoU = cU.clone();
  const mundoL = mundoU.clone().multiply(cL);
  const codo = sh.clone().addScaledVector(rr.dirUp.clone().applyQuaternion(mundoU), rr.lenUp);
  const muneca = codo.clone().addScaledVector(rr.dirLo.clone().applyQuaternion(mundoL), rr.lenLo);
  return {codo: [codo.x, codo.y, codo.z], muneca: [muneca.x, muneca.y, muneca.z]};
}
const porCuadro = new Map();
for (const c of datos.casos) {
  const k = c.g + '|' + c.fi;
  if (!porCuadro.has(k)) porCuadro.set(k, {});
  porCuadro.get(k)[c.lado] = c;
}
const pares = [...porCuadro.values()].filter((v) => v.L && v.R);
const limite = Number(process.env.PARES || pares.length);
const tiempos = [];
let falla = 0, maxDy = 0, maxLargo = 0, movidas = 0, maxMov = 0, maxPlan = 0, conPlan = 0, n = 0;
const d3 = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
const incl = Number(inclinacionGrados) * Math.PI / 180;
for (const par of pares.slice(0, limite)) {
  const ang = [0, incl, -incl][n++ % 3];
  const Rl = new THREE.Matrix4().makeRotationAxis(ctx.avDerecha, ang);
  const a = new THREE.Matrix4().setPosition(-p0.x, -p0.y, -p0.z);
  const b = new THREE.Matrix4().copy(Rl).multiply(a).premultiply(new THREE.Matrix4().setPosition(p0.x, p0.y, p0.z));
  pecho.matrixWorld = b.multiply(restWorld);
  const out = {};
  for (const modo of [false, true]) {
    ctx.cal.separarManos = modo;
    vm.runInContext('reiniciarSeparadorCuerpo();', ctx);
    capturas.length = 0;
    ctx.__p = {hombroI: new V(...par.L.hombro), codoI: new V(...par.L.codo), munI: new V(...par.L.muneca), manoI: par.L.mano,
      hombroD: new V(...par.R.hombro), codoD: new V(...par.R.codo), munD: new V(...par.R.muneca), manoD: par.R.mano};
    const __t0 = process.hrtime.bigint();
    vm.runInContext('planManos = null; planificarManos(__p, kBase);', ctx);
    if (modo) { const dt = Number(process.hrtime.bigint() - __t0) / 1e6; tiempos.push(dt); }
    vm.runInContext('' +
      'resolverBrazo("left", kBase, __p.hombroI, __p.codoI, __p.munI, {}, __p.manoI);' +
      'resolverBrazo("right", kBase, __p.hombroD, __p.codoD, __p.munD, {}, __p.manoD);' +
      '__plan = planManos; planManos = null;', ctx);
    out[modo] = {left: reconstruir('left'), right: reconstruir('right'), plan: ctx.__plan};
  }
  if (out[true].plan) conPlan++;
  if (out[false].plan) { falla++; console.log('FALLA: hubo plan con separarManos=false'); }
  for (const [lado, k] of [['left', 'L'], ['right', 'R']]) {
    const on = out[true][lado], off = out[false][lado];
    const sh = aMundo(R[k].sh); const shp = [sh.x, sh.y, sh.z];
    maxDy = Math.max(maxDy, Math.abs(on.muneca[1] - off.muneca[1]));
    maxLargo = Math.max(maxLargo, Math.abs(d3(shp, on.codo) - R[k].lenUp), Math.abs(d3(on.codo, on.muneca) - R[k].lenLo));
    const mv = d3(on.muneca, off.muneca);
    if (mv > 1e-3) movidas++;
    maxMov = Math.max(maxMov, mv);
    // la muñeca resuelta debe ser exactamente el objetivo del plan (recortado al alcance)
    const pl = out[true].plan && out[true].plan[lado];
    if (pl) {
      const dl = Math.hypot(...pl.delta);
      const rr = ctx.refRig[lado];
      const rpa = (g) => Math.sqrt(Math.max(0, rr.lenUp * rr.lenUp + rr.lenLo * rr.lenLo + 2 * rr.lenUp * rr.lenLo * Math.cos(g)));
      const rMin = Math.max(Math.abs(rr.lenUp - rr.lenLo) + 1e-5, rpa(ctx.cal.ikMax));
      const rMax = Math.min(rr.lenUp + rr.lenLo - 1e-5, rpa(ctx.cal.ikMin));
      const rad = Math.max(rMin, Math.min(rMax, dl));
      const esperado = shp.map((v, j) => v + pl.delta[j] * rad / dl);
      maxPlan = Math.max(maxPlan, d3(esperado, on.muneca));
    }
  }
}
if (maxDy > 1e-9) { falla++; console.log('FALLA: la altura de la muñeca cambio', maxDy); }
if (maxLargo > 1e-6) { falla++; console.log('FALLA: cambio el largo de un hueso', maxLargo); }
if (maxPlan > 1e-6) { falla++; console.log('FALLA: la muñeca no quedo donde dice el plan', maxPlan); }
if (conPlan === 0) { falla++; console.log('FALLA: el plan de manos nunca se calculo'); }
console.log('pares', Math.min(limite, pares.length), '| con plan', conPlan, '| muñeca movida >1 mm por las manos:', movidas,
  '| max movida (cm)', (100 * maxMov).toFixed(2), '| max cambio de altura', maxDy.toExponential(2),
  '| max error de largo', maxLargo.toExponential(2), '| plan vs muñeca', maxPlan.toExponential(2), '|', falla ? 'FALLA' : 'OK');
tiempos.sort((x, y) => x - y);
console.log('tiempo de planificarManos (ms): media', (tiempos.reduce((x, y) => x + y, 0) / tiempos.length).toFixed(2), 'p95', tiempos[Math.floor(tiempos.length * 0.95)].toFixed(2), 'max', tiempos[tiempos.length - 1].toFixed(2));
process.exit(falla ? 1 : 0);
