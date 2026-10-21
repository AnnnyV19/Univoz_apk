// Ejecuta resolverBrazo REAL del visor (extraido del HTML) con un THREE minimo
// y vuelca codo/muneca resultantes con el separador apagado y encendido.
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
ctx.__capturas = capturas; ctx.__huesos = huesos;
vm.runInContext(codigo, ctx);

function reconstruir(lado) {
  const rr = ctx.refRig[lado];
  const sh = aMundo(R[lado === 'left' ? 'L' : 'R'].sh);
  const cU = capturas.find((c) => c.id.endsWith('upperArm')).q;
  const cL = capturas.find((c) => c.id.endsWith('lowerArm')).q;
  const mundoU = cU.clone();
  const mundoL = mundoU.clone().multiply(cL);
  const codo = sh.clone().addScaledVector(rr.dirUp.clone().applyQuaternion(mundoU), rr.lenUp);
  const muneca = codo.clone().addScaledVector(rr.dirLo.clone().applyQuaternion(mundoL), rr.lenLo);
  return {codo: [codo.x, codo.y, codo.z], muneca: [muneca.x, muneca.y, muneca.z]};
}
const sal = [];
const incl = Number(inclinacionGrados) * Math.PI / 180;
let n = 0;
for (const c of datos.casos) {
  const lado = c.lado === 'L' ? 'left' : 'right';
  const reg = {g: c.g, fi: c.fi, lado: c.lado};
  // inclinacion del pecho (adelante/atras) segun el caso: 0, +incl, -incl
  const ang = [0, incl, -incl][n++ % 3];
  const Rl = new THREE.Matrix4().makeRotationAxis(ctx.avDerecha, ang);
  // actual = Tr(p0) R Tr(-p0) * rest
  const a = new THREE.Matrix4().makeRotationAxis(ctx.avDerecha, 0).setPosition(-p0.x, -p0.y, -p0.z);
  const b = new THREE.Matrix4().copy(Rl).multiply(a).premultiply(new THREE.Matrix4().setPosition(p0.x, p0.y, p0.z));
  pecho.matrixWorld = b.multiply(restWorld);
  reg.inclinacion = ang;
  for (const modo of [false, true]) {
    ctx.cal.separarCuerpo = modo;
    vm.runInContext('if (typeof reiniciarSeparadorCuerpo === "function") reiniciarSeparadorCuerpo();', ctx);
    capturas.length = 0;
    ctx.__args = [lado, ctx.kBase, new V(...c.hombro), new V(...c.codo), new V(...c.muneca), {}, c.mano];
    vm.runInContext('resolverBrazo(...__args)', ctx);
    const r = reconstruir(lado);
    reg[modo ? 'on' : 'off'] = r;
    if (modo) reg.diag = vm.runInContext('(typeof estadoCuerpo !== "undefined") ? estadoCuerpo["' + lado + '"].ultimo : null', ctx);
  }
  // matriz T (mundo actual -> mundo reposo) para el chequeo de colision en Python
  const T = new THREE.Matrix4().copy(pecho.matrixWorld).invert().premultiply(restWorld).elements;
  reg.T = [T[0], T[4], T[8], T[12], T[1], T[5], T[9], T[13], T[2], T[6], T[10], T[14]];
  sal.push(reg);
}
if (rutaSalida !== '-') fs.writeFileSync(rutaSalida, JSON.stringify(sal));
// Comprobaciones: la corrección no puede cambiar la altura de la muñeca ni el largo de los huesos.
let falla = 0, maxDy = 0, maxLargo = 0, movidas = 0;
const d3 = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
for (const [i, r] of sal.entries()) {
  const lado = r.lado === 'L' ? 'left' : 'right';
  const sh = aMundo(R[r.lado].sh);
  const shp = [sh.x, sh.y, sh.z];
  maxDy = Math.max(maxDy, Math.abs(r.on.muneca[1] - r.off.muneca[1]));
  maxLargo = Math.max(maxLargo,
    Math.abs(d3(shp, r.on.codo) - R[r.lado].lenUp), Math.abs(d3(r.on.codo, r.on.muneca) - R[r.lado].lenLo));
  if (d3(r.on.muneca, r.off.muneca) > 1e-3) movidas++;
}
if (maxDy > 1e-9) { falla++; console.log('FALLA: la altura de la muñeca cambio', maxDy); }
if (maxLargo > 1e-6) { falla++; console.log('FALLA: cambio el largo de un hueso', maxLargo); }
console.log('casos', sal.length, '| muñeca movida >1 mm:', movidas, '| max cambio de altura', maxDy.toExponential(2),
  '| max error de largo de hueso', maxLargo.toExponential(2), '|', falla ? 'FALLA' : 'OK');
process.exit(falla ? 1 : 0);
