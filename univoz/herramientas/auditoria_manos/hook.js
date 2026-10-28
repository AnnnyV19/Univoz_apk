    // ===== ARNES DE AUDITORIA (solo copia de pruebas, no va a la app) =====
    (function () {
      const LADOS = ['Left', 'Right'];
      const DEDOS = ['Index', 'Middle', 'Ring', 'Little'];
      function nodosLado(L) {
        const raw = (n) => vrm.humanoid.getRawBoneNode(VRMHumanBoneName[L + n]);
        const lista = [raw('UpperArm'), raw('LowerArm'), raw('Hand'),
          raw('ThumbMetacarpal'), raw('ThumbProximal'), raw('ThumbDistal')];
        const punta = (d) => (d && d.children && d.children.length) ? d.children[0] : null;
        lista.push(punta(raw('ThumbDistal')));
        for (const D of DEDOS) {
          lista.push(raw(D + 'Proximal'), raw(D + 'Intermediate'), raw(D + 'Distal'));
          lista.push(punta(raw(D + 'Distal')));
        }
        return lista; // 23 nodos
      }
      let NODOS = null;
      const tmp = new THREE.Vector3();
      function capturar(out) {
        vrm.scene.updateMatrixWorld(true);
        for (const n of NODOS) {
          if (n) { n.getWorldPosition(tmp); out.push(tmp.x, tmp.y, tmp.z); }
          else out.push(NaN, NaN, NaN);
        }
      }
      let t = 1000;
      function paso(dt) {
        t += dt;
        window.__tsim = t;
        const q = window.__rafq; window.__rafq = [];
        for (const f of q) f(t);
      }
      window.__aud = {
        listo: () => !!vrm && !!window.parlanteVrmListo,
        preparar() {
          // Puntas virtuales: el VRM no trae hueso de yema. En T-pose se cuelga
          // de cada falange distal un punto que sigue su misma direccion.
          vrm.humanoid.resetNormalizedPose();
          vrm.update(0);
          vrm.scene.updateMatrixWorld(true);
          for (const L of LADOS) {
            const raw = (n) => vrm.humanoid.getRawBoneNode(VRMHumanBoneName[L + n]);
            const cadenas = [['ThumbProximal', 'ThumbDistal'],
              ...DEDOS.map((D) => [D + 'Intermediate', D + 'Distal'])];
            for (const [a, b] of cadenas) {
              const na = raw(a), nb = raw(b);
              if (!na || !nb || (nb.children && nb.children.length)) continue;
              const pa = new THREE.Vector3(), pb = new THREE.Vector3();
              na.getWorldPosition(pa); nb.getWorldPosition(pb);
              const largo = pa.distanceTo(pb) * (a.startsWith('Thumb') ? 0.9 : 0.85);
              const punta = pb.clone().add(pb.clone().sub(pa).normalize().multiplyScalar(largo));
              const o = new THREE.Object3D(); o.name = 'punta_auditoria';
              nb.add(o); o.position.copy(nb.worldToLocal(punta));
            }
          }
          vrm.scene.updateMatrixWorld(true);
          posarReposo();
          NODOS = [...nodosLado('Left'), ...nodosLado('Right')];
          renderer.render = () => {};
          return {
            faltan: NODOS.map((n, i) => n ? null : i).filter((x) => x !== null),
            ancho: anchoHombrosAvatar,
            der: avDerecha.toArray(), arr: avArriba.toArray(), fre: avFrente.toArray(),
            invertZ: !!cal.invertZ,
          };
        },
        config(c) { Object.assign(cal, c); return true; },
        reposo(n = 60) { posarReposo(); for (let i = 0; i < n; i++) paso(1000 / 60); },
        // Reproduce una seña por el camino real y devuelve, por cada cuadro de
        // pantalla (60 Hz), la posicion de reproduccion, el frame que se le
        // dio al rig y los 46 nodos del avatar en el mundo.
        senar(frames, fps, extra = 20, segmentos = null) {
          window.__anom = [];
          if (segmentos) window.reproducirFrase(JSON.stringify(segmentos), '2.0.0');
          else window.reproducirSecuencia(JSON.stringify(frames), fps, '2.0.0');
          const pos = [], alim = [], nodos = [];
          let guard = 0;
          while (reproduciendo && guard++ < 4000) {
            paso(1000 / 60);
            if (!reproduciendo) break;
            const posicion = acumMs * kFps / 1000;
            const pp = Math.max(0, posicion);
            const ult = colaFrames.length - 1;
            const i = Math.min(ult, Math.floor(pp));
            const f = i < ult ? pp - i : 0;
            pos.push(posicion);
            alim.push(...interpolarFramePlantilla(colaFrames[i], colaFrames[Math.min(ult, i + 1)], f));
            capturar(nodos);
          }
          const post = [];
          for (let i = 0; i < extra; i++) { paso(1000 / 60); capturar(post); }
          return {pos, alim, nodos, post, fps: kFps, prep: colaFrames.map((f) => Array.from(f)), anom: window.__anom.slice(0, 2000)};
        },
      };
    })();
