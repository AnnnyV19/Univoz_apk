"""Arma la copia de AUDITORIA del visor (nunca va a la app) en ./www.
uso: python armar.py [ruta\\index.html] [nombre.html]
Toma el index.html de la app (todo inline, sin CDN) y le agrega:
- un reloj manual: requestAnimationFrame y performance.now los maneja el
  arnes, asi cada cuadro dura exactamente 1/60 s aunque la PC sea lenta;
- el registro de congelamientos de la compuerta de seguridad;
- el arnes (hook.js)."""
import os, sys, shutil
AQUI = os.path.dirname(os.path.abspath(__file__))
args = [a for a in sys.argv[1:] if not a.startswith('--')]
ent = args[0] if args else os.path.join(AQUI, '..', '..', 'assets', 'avatar_viewer', 'index.html')
nombre = args[1] if len(args) > 1 else 'auditoria.html'
src = open(ent, encoding='utf-8').read()
reloj = ("<script>(function(){var pn=performance.now.bind(performance);window.__tsim=null;"
         "performance.now=function(){return window.__tsim!=null?window.__tsim:pn();};})();"
         "window.__rafq=[];window.__anom=[];window.requestAnimationFrame=function(f){"
         "window.__rafq.push(f);return window.__rafq.length;};window.cancelAnimationFrame=function(){};</script>\n")
i = src.index('<script')
src = src[:i] + reloj + src[i:]
a = '''    function reportSafetyAnomaly(result, jointId) {
      if (!result?.code) return;'''
assert src.count(a) == 1, 'no encontre reportSafetyAnomaly'
src = src.replace(a, a + "\n      window.__anom.push([jointId, result.code, result.timestampMs]);")
fin = '    requestAnimationFrame(animar);\n'
k = src.rfind(fin)
assert k > 0, 'no encontre el arranque del render'
src = src[:k] + open(os.path.join(AQUI, 'hook.js'), encoding='utf-8').read() + '\n' + src[k:]
www = os.path.join(AQUI, 'www')
os.makedirs(os.path.join(www, 'avatar_viewer'), exist_ok=True)
os.makedirs(os.path.join(www, 'avatar'), exist_ok=True)
for vrm in ('MODELO_UNIVOZ_v0.vrm', 'univozM.vrm'):
    o = os.path.join(AQUI, '..', '..', 'assets', 'avatar', vrm)
    d = os.path.join(www, 'avatar', vrm)
    if os.path.exists(o) and not os.path.exists(d): shutil.copyfile(o, d)
open(os.path.join(www, 'avatar_viewer', nombre), 'w', encoding='utf-8').write(src)
print('armado', nombre, len(src))
