"""Inlinea los modulos rig_*.mjs dentro de avatar_viewer/index.html.

Android carga el visor como file:// (origen "null") y bloquea los import de
archivos locales por CORS, asi que cada modulo vive DOS veces: como .mjs
(fuente, probado con node --test) y como bloque inline en index.html. Este
script regenera los bloques desde los .mjs para que nunca deriven, y copia
a univoz/assets/avatar_viewer SOLO index.html: en Android el WebView lo carga
con loadFlutterAsset, el VRM llega en base64 desde Dart y los .task los lee
Kotlin de android/app/src/main/assets. Los .mjs (ya inline) y los .task (13 MB
c/u para la web) no se empaquetan en la app; la web standalone de senas_core
sigue teniendo todo en senas_core/assets/avatar_viewer.

  python3 tools/inline_viewer_modules.py          # regenera y copia
  python3 tools/inline_viewer_modules.py --check  # falla si hay deriva

Ademas inlinea vendor/univoz_vendor.min.js (three.js + three-vrm, generado
por tools/viewer_vendor) como <script> clasico antes del script de modulo, para
que el visor no dependa de ningun CDN. El archivo vive en una subcarpeta que
Flutter no empaqueta (solo toma los archivos directos de assets/avatar_viewer/)
y por eso tampoco se copia a univoz: ya va dentro de index.html.

Cada bloque expone solo los nombres que la pagina usa. Para un modulo que
todavia no tiene bloque, se agrega antes del marcador FIN_MODULOS con todos
sus exports.
"""

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.normpath(os.path.join(HERE, "..", "assets", "avatar_viewer"))
UNIVOZ_VIEWER = os.path.normpath(
    os.path.join(HERE, "..", "..", "univoz", "assets", "avatar_viewer"))
INDEX = os.path.join(VIEWER, "index.html")

MODULES = ["rig_math", "rig_metrics", "rig_diagnostics", "rig_safety",
           "rig_tracking", "rig_sign_space", "rig_mirror", "rig_body_profile",
           "rig_retarget", "rig_holistic", "rig_holistic_worker", "rig_face",
           "rig_hand_gate", "rig_session", "rig_avatar_state",
           "rig_device_tier", "rig_embedded_perf", "rig_latency_diag",
           "rig_motion_frame", "rig_hand_capture",
           # Aportados por la rama app-limpia (docs/17). rig_mano_ik.mjs (ManoIK)
           # NO se inlinea: no esta conectado a este visor.
           "rig_cuerpo", "rig_manos", "rig_replay", "rig_frase",
           "rig_encuadre"]
# Modulos nuevos: exponen todos sus exports. Los historicos conservan la
# lista de nombres de su bloque (algunos exports no se usan en la pagina).
EXPORT_ALL = {"rig_sign_space", "rig_mirror", "rig_body_profile",
              "rig_retarget", "rig_holistic", "rig_holistic_worker", "rig_face",
              "rig_hand_gate", "rig_session", "rig_avatar_state",
              "rig_device_tier", "rig_embedded_perf", "rig_latency_diag",
              "rig_motion_frame", "rig_hand_capture", "rig_cuerpo", "rig_manos", "rig_replay",
              "rig_frase", "rig_encuadre"}
INDENT = "      "
VENDOR = os.path.join(VIEWER, "vendor", "univoz_vendor.min.js")
VENDOR_INICIO = "  <!-- inicio univoz_vendor.min.js -->"
VENDOR_FIN = "  <!-- fin univoz_vendor.min.js -->"
VENDOR_NOMBRES = ("THREE, GLTFLoader, OrbitControls, VRMLoaderPlugin, "
                  "VRMUtils, VRMHumanBoneName")
VENDOR_CONST = "    const { %s } = window.UnivozVendor;" % VENDOR_NOMBRES
# Imports por CDN que reemplaza el vendor (solo la primera vez).
IMPORTS_CDN = re.compile(
    r"    import \* as THREE from 'three';\n"
    r"    import \{ GLTFLoader \} from 'three/addons/loaders/GLTFLoader\.js';\n"
    r"    import \{ OrbitControls \} from 'three/addons/controls/OrbitControls\.js';\n"
    r"    import \{ VRMLoaderPlugin, VRMUtils, VRMHumanBoneName \} "
    r"from '@pixiv/three-vrm';")
IMPORTMAP = re.compile(r'  <script type="importmap">.*?</script>', re.S)
FIN_MODULOS = "    // ---- fin modulos inline ----"


def leer(ruta):
    # UTF-8 y LF en cualquier sistema: en Windows open() usaria cp1252 y CRLF.
    with open(ruta, encoding="utf-8", newline="") as fh:
        return fh.read()


def escribir(ruta, texto):
    with open(ruta, "w", encoding="utf-8", newline="") as fh:
        fh.write(texto)


def inicio(mod):
    return "    // ---- inicio %s.mjs (antes importado por separado) ----" % mod


def fin(mod):
    return "    // ---- fin %s.mjs ----" % mod


def exports_de(src):
    return re.findall(r"^export (?:async )?(?:function\*? |const |let |class )"
                      r"([A-Za-z_$][\w$]*)", src, flags=re.M)


def bloque(mod, nombres):
    src = leer(os.path.join(VIEWER, mod + ".mjs")).rstrip("\n")
    lineas = [inicio(mod),
              "    const {%s} = (() => {" % ", ".join(nombres)]
    for linea in src.split("\n"):
        # Los import entre modulos locales sobran: el bloque del modulo
        # importado ya expuso esos nombres en el ambito de la pagina.
        if re.match(r"^import \{[^}]*\} from '\./rig_\w+\.mjs';$", linea):
            linea = "// " + linea + " (nombres ya en ambito)"
        linea = re.sub(r"^export ", "", linea)
        lineas.append(INDENT + linea if linea else "")
    lineas.append(INDENT + "return {%s};" % ", ".join(nombres))
    lineas.append("    })();")
    lineas.append(fin(mod))
    return lineas


def bloque_vendor():
    if not os.path.isfile(VENDOR):
        sys.exit("FALTA %s: genera el vendor con 'cd senas_core/tools/"
                 "viewer_vendor && npm ci && npm run build'" % VENDOR)
    src = leer(VENDOR).strip("\n")
    # Un </script o <!-- dentro del JS cortaria el bloque inline.
    src = src.replace("</script", "<\\/script").replace("<!--", "<\\!--")
    return "\n".join([VENDOR_INICIO, "  <script>", src, "  </script>",
                       VENDOR_FIN])


def inyectar_vendor(html):
    bloque_v = bloque_vendor()
    if VENDOR_INICIO in html:
        s = html.index(VENDOR_INICIO)
        e = html.index(VENDOR_FIN) + len(VENDOR_FIN)
        html = html[:s] + bloque_v + html[e:]
    elif IMPORTMAP.search(html):
        html = IMPORTMAP.sub(lambda _: bloque_v, html, count=1)
    else:
        sys.exit("index.html no tiene importmap ni bloque vendor")
    return IMPORTS_CDN.sub(lambda _: VENDOR_CONST, html)


def regenerar(html):
    html = inyectar_vendor(html)
    lineas = html.split("\n")
    for mod in MODULES:
        if not os.path.exists(os.path.join(VIEWER, mod + ".mjs")):
            continue
        try:
            s = lineas.index(inicio(mod))
            e = lineas.index(fin(mod))
            m = re.match(r"\s*const \{(.*)\} = \(\(\) => \{", lineas[s + 1])
            nombres = [n.strip() for n in m.group(1).split(",")]
            if mod in EXPORT_ALL:
                nombres = exports_de(leer(os.path.join(VIEWER, mod + ".mjs")))
            lineas[s:e + 1] = bloque(mod, nombres)
        except ValueError:
            src = leer(os.path.join(VIEWER, mod + ".mjs"))
            nombres = exports_de(src)
            if FIN_MODULOS not in lineas:
                ultimo = max(i for i, l in enumerate(lineas)
                             if l.startswith("    // ---- fin rig_"))
                lineas.insert(ultimo + 1, FIN_MODULOS)
                lineas.insert(ultimo + 1, "")
            k = lineas.index(FIN_MODULOS)
            lineas[k:k] = bloque(mod, nombres) + [""]
    return "\n".join(lineas)


def sobrantes_univoz():
    """Archivos de univoz/assets/avatar_viewer que ya no deben empaquetarse."""
    if not os.path.isdir(UNIVOZ_VIEWER):
        return []
    return sorted(f for f in os.listdir(UNIVOZ_VIEWER)
                  if f != "index.html" and not f.startswith(".") and
                  os.path.isfile(os.path.join(UNIVOZ_VIEWER, f)))


def main(check):
    actual = leer(INDEX)
    nuevo = regenerar(actual)
    problemas = []
    if nuevo != actual:
        problemas.append("index.html no coincide con los .mjs")
    if os.path.isdir(UNIVOZ_VIEWER):
        otro = os.path.join(UNIVOZ_VIEWER, "index.html")
        if not os.path.exists(otro) or leer(otro) != nuevo:
            problemas.append("univoz difiere: index.html")
        for f in sobrantes_univoz():
            problemas.append("univoz sobra (no se empaqueta): " + f)
    if check:
        for p in problemas:
            print("DERIVA:", p)
        return 1 if problemas else 0
    escribir(INDEX, nuevo)
    if os.path.isdir(UNIVOZ_VIEWER):
        shutil.copy2(INDEX, os.path.join(UNIVOZ_VIEWER, "index.html"))
        for f in sobrantes_univoz():
            os.remove(os.path.join(UNIVOZ_VIEWER, f))
    print("visor regenerado;", len(problemas), "diferencias corregidas")
    return 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv))
