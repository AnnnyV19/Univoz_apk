"""Inlinea los modulos rig_*.mjs dentro de avatar_viewer/index.html.

Android carga el visor como file:// (origen "null") y bloquea los import de
archivos locales por CORS, asi que cada modulo vive DOS veces: como .mjs
(fuente, probado con node --test) y como bloque inline en index.html. Este
script regenera los bloques desde los .mjs para que nunca deriven, y copia
el visor completo a univoz/assets/avatar_viewer.

  python3 tools/inline_viewer_modules.py          # regenera y copia
  python3 tools/inline_viewer_modules.py --check  # falla si hay deriva

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
           "rig_retarget", "rig_holistic", "rig_face"]
# Modulos nuevos: exponen todos sus exports. Los historicos conservan la
# lista de nombres de su bloque (algunos exports no se usan en la pagina).
EXPORT_ALL = {"rig_sign_space", "rig_mirror", "rig_body_profile",
              "rig_retarget", "rig_holistic", "rig_face"}
INDENT = "      "
FIN_MODULOS = "    // ---- fin modulos inline ----"


def inicio(mod):
    return "    // ---- inicio %s.mjs (antes importado por separado) ----" % mod


def fin(mod):
    return "    // ---- fin %s.mjs ----" % mod


def exports_de(src):
    return re.findall(r"^export (?:async )?(?:function\*? |const |let |class )"
                      r"([A-Za-z_$][\w$]*)", src, flags=re.M)


def bloque(mod, nombres):
    src = open(os.path.join(VIEWER, mod + ".mjs")).read().rstrip("\n")
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


def regenerar(html):
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
                nombres = exports_de(open(os.path.join(VIEWER, mod + ".mjs")).read())
            lineas[s:e + 1] = bloque(mod, nombres)
        except ValueError:
            src = open(os.path.join(VIEWER, mod + ".mjs")).read()
            nombres = exports_de(src)
            if FIN_MODULOS not in lineas:
                ultimo = max(i for i, l in enumerate(lineas)
                             if l.startswith("    // ---- fin rig_"))
                lineas.insert(ultimo + 1, FIN_MODULOS)
                lineas.insert(ultimo + 1, "")
            k = lineas.index(FIN_MODULOS)
            lineas[k:k] = bloque(mod, nombres) + [""]
    return "\n".join(lineas)


def archivos_visor():
    return sorted(f for f in os.listdir(VIEWER)
                  if not f.startswith(".") and
                  os.path.isfile(os.path.join(VIEWER, f)))


def main(check):
    actual = open(INDEX).read()
    nuevo = regenerar(actual)
    problemas = []
    if nuevo != actual:
        problemas.append("index.html no coincide con los .mjs")
    if os.path.isdir(UNIVOZ_VIEWER):
        for f in archivos_visor():
            otro = os.path.join(UNIVOZ_VIEWER, f)
            if f == "index.html":
                igual = os.path.exists(otro) and open(otro).read() == nuevo
            else:
                igual = os.path.exists(otro) and \
                    open(os.path.join(VIEWER, f), "rb").read() == \
                    open(otro, "rb").read()
            if not igual:
                problemas.append("univoz difiere: " + f)
    if check:
        for p in problemas:
            print("DERIVA:", p)
        return 1 if problemas else 0
    with open(INDEX, "w") as fh:
        fh.write(nuevo)
    if os.path.isdir(UNIVOZ_VIEWER):
        for f in archivos_visor():
            shutil.copy2(os.path.join(VIEWER, f), os.path.join(UNIVOZ_VIEWER, f))
    print("visor regenerado;", len(problemas), "diferencias corregidas")
    return 0


if __name__ == "__main__":
    sys.exit(main("--check" in sys.argv))
