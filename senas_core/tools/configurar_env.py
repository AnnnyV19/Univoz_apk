#!/usr/bin/env python3
"""Arma el .env preguntando lo que falta, en vez de editarlo a mano.

Existe porque escribir esa cadena a mano sale mal de formas que el error no
explica: quedan los corchetes del ejemplo, se usa la "Direct connection" que
no resuelve sin el add-on de IPv4, el usuario va sin la referencia del
proyecto, o la contrasena tiene simbolos que hay que escribir en %XX.

La contrasena y la clave se piden SIN QUE SE VEAN al escribirlas, y no
quedan en el historial de la terminal.

Uso:
    python tools/configurar_env.py
"""

import os
import re
import socket
import sys
from getpass import getpass
from urllib.parse import urlparse, quote, unquote

AQUI = os.path.dirname(os.path.abspath(__file__))
RUTA_ENV = os.path.normpath(os.path.join(AQUI, "..", ".env"))


def preguntar(texto, defecto=None):
    sufijo = f" [{defecto}]" if defecto else ""
    r = input(f"{texto}{sufijo}: ").strip()
    return r or (defecto or "")


def leer_env():
    """Lo que ya hay en el .env, para poder ofrecerlo como default."""
    valores = {}
    if not os.path.exists(RUTA_ENV):
        return valores
    with open(RUTA_ENV, encoding="utf-8-sig") as f:
        for linea in f:
            linea = linea.strip()
            if not linea or linea.startswith("#") or "=" not in linea:
                continue
            k, v = linea.split("=", 1)
            valores[k.strip()] = v.strip().strip('"').strip("'")
    return valores


def resuelve(host):
    try:
        socket.getaddrinfo(host, None)
        return True
    except socket.gaierror:
        return False


def main():
    print("Configurador del .env de UNIVOZ")
    print("=" * 60)
    print("Abri Supabase -> tu proyecto -> boton Connect -> Session pooler,")
    print("y pega aca esa cadena entera. No importa si trae [YOUR-PASSWORD] o")
    print("tu contrasena: la contrasena se pide aparte, en el paso siguiente.")
    print()

    actual = leer_env()
    cadena = ""
    while not cadena:
        cadena = input("Cadena del Session pooler: ").strip().strip('"').strip("'")
        if not cadena:
            print("  (hace falta para poder seguir)")
            continue
        # Los corchetes del placeholder rompen urlparse (los lee como IPv6).
        limpia = cadena.replace("[", "").replace("]", "")
        try:
            p = urlparse(limpia)
        except ValueError:
            print("  no parece una URL de conexion, probá de nuevo")
            cadena = ""
            continue
        if not p.hostname or not p.username:
            print("  a esa cadena le falta el host o el usuario, probá de nuevo")
            cadena = ""
            continue
        if p.hostname.startswith("db.") and p.hostname.endswith(".supabase.co"):
            print("  esa es la 'Direct connection', no el pooler. Ese host solo")
            print("  resuelve con el add-on de IPv4 (de pago). En el panel, bajá")
            print("  hasta 'Session pooler' y copiá esa.")
            cadena = ""
            continue

    host = p.hostname
    puerto = p.port or 5432
    usuario = p.username
    base = (p.path or "/postgres").lstrip("/") or "postgres"

    if puerto == 6543:
        print("\n  ojo: el puerto 6543 es el Transaction pooler. Para estos scripts")
        print("  conviene el Session pooler (5432): el de transacciones no admite")
        print("  prepared statements.")
        if preguntar("  ¿lo cambio a 5432? (s/n)", "s").lower().startswith("s"):
            puerto = 5432

    # La referencia del proyecto viene en el usuario del pooler
    # (postgres.xxxxxxxx). Si falta, el pooler no sabe a que proyecto ir.
    m = re.match(r"^postgres\.([a-z0-9]+)$", usuario)
    if m:
        referencia = m.group(1)
    else:
        print(f"\n  ojo: el usuario '{usuario}' no trae la referencia del proyecto.")
        print("  El pooler la necesita: tiene que ser postgres.TU_REFERENCIA")
        referencia = preguntar("  referencia del proyecto (las letras de tu URL)")
        if not referencia:
            sys.exit("sin la referencia no se puede armar la cadena")
        usuario = f"postgres.{referencia}"

    print(f"\n  proyecto:  {referencia}")
    print(f"  host:      {host}:{puerto}")
    print(f"  usuario:   {usuario}")

    # Comprobar que el proyecto exista ANTES de escribir nada: un proyecto
    # borrado se ve igual que un problema de red en el error de psycopg2.
    api = f"{referencia}.supabase.co"
    if resuelve(api):
        print(f"  {api} responde en el DNS: el proyecto existe")
    else:
        print(f"\n  CUIDADO: {api} no existe en el DNS.")
        print("  Un proyecto pausado SI conserva su DNS, asi que esto suele")
        print("  querer decir que el proyecto fue borrado, o que la referencia")
        print("  esta mal escrita. Revisala en la URL de tu panel de Supabase.")
        if not preguntar("  ¿seguir igual? (s/n)", "n").lower().startswith("s"):
            sys.exit("cancelado, no se escribio nada")

    print("\nContrasena de la base (la que pusiste al crear el proyecto).")
    print("No se va a ver mientras la escribis.")
    contrasena = ""
    while not contrasena:
        contrasena = getpass("  contrasena: ")
        if not contrasena:
            print("  (hace falta)")
            continue
        if contrasena.startswith("[") and contrasena.endswith("]"):
            print("  sacale los corchetes: son del ejemplo, no son parte de la contrasena")
            contrasena = ""
            continue
        # Un espacio pegado al copiar es invisible aca (getpass no muestra
        # nada) y despues sale como "password authentication failed", que no
        # dice nada de espacios. Por eso se avisa con el largo a la vista:
        # es lo unico comprobable sin mostrar la contrasena.
        if contrasena != contrasena.strip():
            limpia = contrasena.strip()
            print(f"  ojo: empieza o termina con espacios ({len(contrasena)} caracteres;")
            print(f"  sin ellos serian {len(limpia)}). Suele ser del copiar y pegar.")
            if preguntar("  ¿se los saco? (s/n)", "s").lower().startswith("s"):
                contrasena = limpia
        print(f"  ({len(contrasena)} caracteres)")

    # Escapar simbolos: una contrasena con @ o / parte la URL en dos y el
    # error que sale habla de autenticacion, no de eso.
    escapada = quote(contrasena, safe="")
    if escapada != contrasena:
        print("  (tiene simbolos: los escribo en %XX para que la URL no se rompa)")

    database_url = f"postgresql://{usuario}:{escapada}@{host}:{puerto}/{base}"

    print("\nStorage (opcional): para poder abrir el video de una muestra y")
    print("revisarla antes de aprobarla. Si lo saltas, todo lo demas funciona.")
    supabase_url = f"https://{referencia}.supabase.co"
    clave = ""
    if preguntar("  ¿configurar Storage ahora? (s/n)", "s").lower().startswith("s"):
        print("\n  Settings -> API -> la clave SECRETA (sb_secret_... o service_role).")
        print("  NO la publica (sb_publishable_... / anon): esa no puede escribir.")
        clave = getpass("  clave secreta: ").strip()
        if clave.startswith("sb_publishable_"):
            print("  esa es la PUBLICA. La dejo vacia para que no falle despues.")
            clave = ""
    bucket = actual.get("SUPABASE_BUCKET") or "videos"

    if os.path.exists(RUTA_ENV):
        respaldo = RUTA_ENV + ".anterior"
        with open(RUTA_ENV, encoding="utf-8-sig") as f:
            previo = f.read()
        with open(respaldo, "w", encoding="utf-8") as f:
            f.write(previo)
        print(f"\n  (copia de lo que habia: {os.path.basename(respaldo)})")

    with open(RUTA_ENV, "w", encoding="utf-8") as f:
        f.write(
            "# Secretos de esta maquina. NUNCA se sube a git (esta en .gitignore).\n"
            "# Escrito por tools/configurar_env.py\n"
            "# Para comprobar que quedo bien:  python tools/probar_conexion.py\n"
            "\n"
            "# Session pooler. NO uses la 'Direct connection' (db.xxx.supabase.co):\n"
            "# ese host solo resuelve con el add-on de IPv4, que es de pago.\n"
            f"DATABASE_URL={database_url}\n"
            "\n"
            "# URL del PROYECTO, no una cadena de Postgres.\n"
            f"SUPABASE_URL={supabase_url}\n"
            "\n"
            "# Clave SECRETA. Nunca en la app de Flutter ni en git.\n"
            f"SUPABASE_SERVICE_KEY={clave}\n"
            "\n"
            f"SUPABASE_BUCKET={bucket}\n"
        )

    print(f"\nListo: {RUTA_ENV}")
    print("\nAhora comproba que funcione:")
    print("    python tools/probar_conexion.py")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\ncancelado, no se escribio nada")
