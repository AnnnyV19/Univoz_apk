// Mini THREE solo con lo que usan resolverBrazo y el separador de cuerpo.
class Vector3 {
  constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
  get isVector3() { return true; }
  set(x, y, z) { this.x = x; this.y = y; this.z = z; return this; }
  copy(v) { this.x = v.x; this.y = v.y; this.z = v.z; return this; }
  clone() { return new Vector3(this.x, this.y, this.z); }
  add(v) { this.x += v.x; this.y += v.y; this.z += v.z; return this; }
  sub(v) { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
  subVectors(a, b) { this.x = a.x - b.x; this.y = a.y - b.y; this.z = a.z - b.z; return this; }
  multiplyScalar(s) { this.x *= s; this.y *= s; this.z *= s; return this; }
  addScaledVector(v, s) { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
  dot(v) { return this.x * v.x + this.y * v.y + this.z * v.z; }
  lengthSq() { return this.dot(this); }
  length() { return Math.sqrt(this.lengthSq()); }
  distanceTo(v) { return Math.sqrt((this.x - v.x) ** 2 + (this.y - v.y) ** 2 + (this.z - v.z) ** 2); }
  normalize() { const l = this.length() || 1; return this.multiplyScalar(1 / l); }
  crossVectors(a, b) { const x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x; return this.set(x, y, z); }
  applyQuaternion(q) {
    const x = this.x, y = this.y, z = this.z, qx = q.x, qy = q.y, qz = q.z, qw = q.w;
    const tx = 2 * (qy * z - qz * y), ty = 2 * (qz * x - qx * z), tz = 2 * (qx * y - qy * x);
    this.x = x + qw * tx + qy * tz - qz * ty;
    this.y = y + qw * ty + qz * tx - qx * tz;
    this.z = z + qw * tz + qx * ty - qy * tx;
    return this;
  }
  applyAxisAngle(axis, angle) { return this.applyQuaternion(new Quaternion().setFromAxisAngle(axis, angle)); }
}
class Quaternion {
  constructor(x = 0, y = 0, z = 0, w = 1) { this.x = x; this.y = y; this.z = z; this.w = w; }
  copy(q) { this.x = q.x; this.y = q.y; this.z = q.z; this.w = q.w; return this; }
  clone() { return new Quaternion(this.x, this.y, this.z, this.w); }
  normalize() { const l = Math.hypot(this.x, this.y, this.z, this.w) || 1; this.x /= l; this.y /= l; this.z /= l; this.w /= l; return this; }
  invert() { this.x = -this.x; this.y = -this.y; this.z = -this.z; return this; }
  multiply(q) { return this.multiplyQuaternions(this, q); }
  multiplyQuaternions(a, b) {
    const x = a.x * b.w + a.w * b.x + a.y * b.z - a.z * b.y;
    const y = a.y * b.w + a.w * b.y + a.z * b.x - a.x * b.z;
    const z = a.z * b.w + a.w * b.z + a.x * b.y - a.y * b.x;
    const w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z;
    this.x = x; this.y = y; this.z = z; this.w = w; return this;
  }
  setFromAxisAngle(axis, angle) {
    const h = angle / 2, s = Math.sin(h);
    this.x = axis.x * s; this.y = axis.y * s; this.z = axis.z * s; this.w = Math.cos(h); return this;
  }
  setFromUnitVectors(a, b) {
    let r = a.dot(b) + 1;
    if (r < Number.EPSILON) {
      r = 0;
      if (Math.abs(a.x) > Math.abs(a.z)) { this.x = -a.y; this.y = a.x; this.z = 0; this.w = r; }
      else { this.x = 0; this.y = -a.z; this.z = a.y; this.w = r; }
    } else { this.x = a.y * b.z - a.z * b.y; this.y = a.z * b.x - a.x * b.z; this.z = a.x * b.y - a.y * b.x; this.w = r; }
    return this.normalize();
  }
}
class Matrix4 {
  constructor() { this.elements = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; }
  copy(m) { this.elements = m.elements.slice(); return this; }
  clone() { return new Matrix4().copy(this); }
  multiplyMatrices(a, b) {
    const ae = a.elements, be = b.elements, te = new Array(16).fill(0);
    for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) {
      let s = 0; for (let k = 0; k < 4; k++) s += ae[r + 4 * k] * be[k + 4 * c];
      te[r + 4 * c] = s;
    }
    this.elements = te; return this;
  }
  premultiply(m) { return this.multiplyMatrices(m, this); }
  multiply(m) { return this.multiplyMatrices(this, m); }
  invert() {
    // inversa de una transformacion rigida (rotacion + traslacion) -- suficiente aqui
    const e = this.elements;
    const r = [[e[0], e[4], e[8]], [e[1], e[5], e[9]], [e[2], e[6], e[10]]];
    const t = [e[12], e[13], e[14]];
    const rt = [[r[0][0], r[1][0], r[2][0]], [r[0][1], r[1][1], r[2][1]], [r[0][2], r[1][2], r[2][2]]];
    const ti = rt.map((row) => -(row[0] * t[0] + row[1] * t[1] + row[2] * t[2]));
    this.elements = [rt[0][0], rt[1][0], rt[2][0], 0, rt[0][1], rt[1][1], rt[2][1], 0, rt[0][2], rt[1][2], rt[2][2], 0, ti[0], ti[1], ti[2], 1];
    return this;
  }
  makeRotationAxis(axis, angle) {
    const c = Math.cos(angle), s = Math.sin(angle), t = 1 - c, x = axis.x, y = axis.y, z = axis.z;
    this.elements = [t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0, t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0, t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0, 0, 0, 0, 1];
    return this;
  }
  setPosition(x, y, z) { this.elements[12] = x; this.elements[13] = y; this.elements[14] = z; return this; }
}
module.exports = {Vector3, Quaternion, Matrix4};
