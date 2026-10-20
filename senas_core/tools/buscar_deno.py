"""Imprime la carpeta donde esta deno.exe (instalado con 'pip install deno'), o nada."""
import os
import sys
import sysconfig

candidatas = [sysconfig.get_path("scripts"), sysconfig.get_path("scripts", "nt_user")]
try:
    import deno  # el paquete de PyPI trae el binario
    candidatas.append(os.path.dirname(deno.__file__))
except Exception:
    pass
for base in candidatas:
    if not base or not os.path.isdir(base):
        continue
    for raiz, _d, archivos in os.walk(base):
        if "deno.exe" in archivos or "deno" in archivos and sys.platform != "win32":
            print(raiz)
            sys.exit(0)
sys.exit(1)
