#!/usr/bin/env python3
"""Comprueba que tu .env este bien antes de subir nada.

Revisa la base y, si los configuraste, tambien Storage y el bucket. Es la
forma barata de descubrir un .env mal puesto: si no, el primer aviso llega a
mitad de una ingesta de 29 senas, con MediaPipe ya cargado.

NO IMPRIME SECRETOS. De cada valor sensible muestra solo lo justo para
reconocerlo (los primeros caracteres, el largo), asi podes pegar la salida
en un chat o un issue sin filtrar nada.

Uso:
    python tools/probar_conexion.py
"""

import os
import re
import sys
from urllib.parse import urlparse, unquote

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dotenv import load_dotenv  # noqa: E402

OK, MAL, AVISO = "  [ok]  ", "  [MAL] ", "  [ojo] "


def tapar(valor, deja=4):
    """'sb_secret_abc123...' -> 'sb_s...(48 car.)'. Suficiente para saber si
    pusiste la clave que creias, sin mostrarla."""
    if not valor:
        return "(vacio)"
    return f"{valor[:deja]}...({len(valor)} car.)"


def revisar_database_url(problemas):
    url = os.environ.get("DATABASE_URL", "").strip()
    print("DATABASE_URL")
    if not url:
        print(MAL + "no esta definida en el .env")
        problemas.append("falta DATABASE_URL")
        return None

    # Los corchetes del placeholder, dejados por error. Es el fallo mas
    # comun y el que peor se diagnostica: el error que devuelve Postgres
    # habla de autenticacion y no menciona los corchetes por ningun lado.
    para_leer = url
    if re.search(r"[\[\]]", url):
        print(MAL + "tiene corchetes [ ] -- son del ejemplo, no de tu contrasena. Sacalos.")
        problemas.append("corchetes en DATABASE_URL")
        # Se los saco solo para poder seguir revisando el resto: con
        # corchetes, urlparse cree que es una direccion IPv6 y no lee nada
        # mas, asi que se perderian los otros problemas de la misma linea.
        para_leer = url.replace("[", "").replace("]", "")

    try:
        p = urlparse(para_leer)
    except ValueError:
        print(MAL + "no parece una URL valida")
        problemas.append("DATABASE_URL malformada")
        return None

    host = p.hostname or ""
    print(f"         host: {host}:{p.port or '(sin puerto)'}")
    print(f"         usuario: {p.username or '(sin usuario)'}")
    print(f"         contrasena: {tapar(unquote(p.password) if p.password else '', 2)}")

    if host.startswith("db.") and host.endswith(".supabase.co"):
        print(MAL + "es la 'Direct connection'. Ese host solo resuelve con el")
        print("         add-on de IPv4 (de pago); sin el no hay registro DNS y falla")
        print("         con 'could not translate host name'. Usa el Session pooler.")
        problemas.append("DATABASE_URL usa el host directo")
    elif "pooler.supabase.com" in host:
        if p.port == 6543:
            print(AVISO + "es el Transaction pooler (6543). Funciona, pero para estos")
            print("         scripts conviene el Session pooler (5432).")
        else:
            print(OK + "usa el pooler")

    if p.password and re.search(r"[^\w.~-]", unquote(p.password)):
        print(AVISO + "la contrasena tiene simbolos: si falla la autenticacion,")
        print("         puede que haya que escribirlos en %XX (por ej. @ -> %40).")

    return url


def probar_base(url, problemas):
    try:
        import psycopg2
    except ImportError:
        print(MAL + "falta psycopg2 (pip install -r tools/requirements.txt)")
        problemas.append("falta psycopg2")
        return
    try:
        conn = psycopg2.connect(url, connect_timeout=15)
    except Exception as e:
        msg = str(e).strip().splitlines()[0]
        print(MAL + f"no conecta: {msg}")
        if "could not translate host name" in msg:
            print("         -> el host no existe en el DNS. Casi siempre es haber")
            print("            usado la Direct connection en vez del pooler.")
        elif "password authentication failed" in msg:
            print("         -> usuario o contrasena mal. Revisa que no hayan quedado")
            print("            los corchetes, y que el usuario incluya .TU_REFERENCIA")
            print("            (el pooler lo pide: postgres.xxxxx, no solo postgres).")
        elif "timeout" in msg.lower() or "could not connect" in msg.lower():
            print("         -> el host resuelve pero no responde. Puede que el proyecto")
            print("            este PAUSADO: el plan gratis los pausa tras una semana")
            print("            sin uso. Se reactiva con un click desde el panel.")
        problemas.append("no conecta a la base")
        return

    try:
        with conn.cursor() as cur:
            cur.execute("select current_database(), current_user")
            base, usuario = cur.fetchone()
            print(OK + f"conecta ({usuario}@{base})")

            # Que existan las tablas del esquema, no solo que la conexion abra:
            # una base vacia conecta perfecto y falla despues.
            cur.execute("""
                select table_name from information_schema.tables
                where table_schema = 'public'
                  and table_name in ('signs','sign_samples','sample_landmarks')
            """)
            hay = {r[0] for r in cur.fetchall()}
            faltan = {"signs", "sign_samples", "sample_landmarks"} - hay
            if faltan:
                print(MAL + f"faltan tablas: {', '.join(sorted(faltan))}")
                print("         -> corre sql/001_schema.sql en el SQL Editor (INGESTA.md paso 2)")
                problemas.append("falta el esquema")
            else:
                print(OK + "el esquema esta (signs, sign_samples, sample_landmarks)")

                # Que este la fila de la version actual de normalizacion.
                # Sin ella la ingesta falla por clave foranea RECIEN al
                # guardar la primera muestra, o sea despues de cargar
                # MediaPipe y procesar un video entero. Comprobarlo aca
                # cuesta una consulta.
                import sign_norm as sn
                cur.execute("select frame_dim, t_frames from norm_versions where version = %s",
                            (sn.NORM_VERSION,))
                fila = cur.fetchone()
                if not fila:
                    print(MAL + f"falta la version '{sn.NORM_VERSION}' en norm_versions.")
                    print("         Esta base tiene un esquema anterior a la migracion.")
                    print("         -> volve a correr sql/001_schema.sql entero en el SQL")
                    print("            Editor: es idempotente, solo agrega lo que falta.")
                    cur.execute("select version, frame_dim from norm_versions order by version")
                    hay_v = cur.fetchall()
                    if hay_v:
                        print("         (tiene: " + ", ".join(f"{v} ({d} dim)" for v, d in hay_v) + ")")
                    problemas.append(f"falta norm_version {sn.NORM_VERSION}")
                elif fila[0] != sn.FRAME_DIM or fila[1] != sn.T_FRAMES:
                    print(MAL + f"la version '{sn.NORM_VERSION}' esta en la base como "
                          f"{fila[0]}x{fila[1]}, pero sign_norm.py usa {sn.FRAME_DIM}x{sn.T_FRAMES}")
                    problemas.append("norm_version no coincide con sign_norm.py")
                else:
                    print(OK + f"norm_version {sn.NORM_VERSION} ({sn.FRAME_DIM} dim x {sn.T_FRAMES} frames)")

                cur.execute("select count(*) from signs")
                n_signs = cur.fetchone()[0]
                cur.execute("select estado, count(*) from sign_samples group by estado")
                por_estado = dict(cur.fetchall())
                resumen = ", ".join(f"{k}: {v}" for k, v in sorted(por_estado.items())) or "ninguna"
                print(f"         {n_signs} sena(s), muestras -> {resumen}")
    finally:
        conn.close()


def probar_storage(problemas):
    url = (os.environ.get("SUPABASE_URL") or "").strip().strip('"').strip("'")
    key = (os.environ.get("SUPABASE_SERVICE_KEY") or "").strip().strip('"').strip("'")
    bucket = (os.environ.get("SUPABASE_BUCKET") or "videos").strip()

    print("\nSUPABASE_URL / SERVICE_KEY  (opcional: solo para subir los videos)")
    if not url and not key:
        print(AVISO + "sin configurar. Todo funciona igual, pero 'video_uri' en la")
        print("         base va a quedar como el nombre del archivo en vez de un link,")
        print("         asi que nadie va a poder abrir el video para revisar una")
        print("         muestra antes de aprobarla.")
        return

    ok_formato = True
    if url.startswith("postgres://") or url.startswith("postgresql://"):
        print(MAL + "SUPABASE_URL tiene una cadena de conexion de Postgres.")
        print("         Tiene que ser la URL del PROYECTO: https://xxxxx.supabase.co")
        print("         (Settings -> API -> Project URL). La de Postgres va en")
        print("         DATABASE_URL, no aca.")
        problemas.append("SUPABASE_URL mal")
        ok_formato = False
    elif not url.startswith("https://"):
        print(MAL + f"SUPABASE_URL no empieza con https:// ({url[:30]}...)")
        problemas.append("SUPABASE_URL mal")
        ok_formato = False
    else:
        print(OK + f"URL del proyecto: {url}")

    if not key:
        print(MAL + "SUPABASE_SERVICE_KEY esta vacia")
        problemas.append("falta SUPABASE_SERVICE_KEY")
        ok_formato = False
    elif key.startswith("sb_publishable_"):
        print(MAL + f"es la clave PUBLICA ({tapar(key)}). No puede escribir en")
        print("         Storage. Necesitas la secreta (sb_secret_... / service_role).")
        problemas.append("clave publica en SUPABASE_SERVICE_KEY")
        ok_formato = False
    else:
        print(OK + f"clave: {tapar(key)}")

    if not ok_formato:
        return

    try:
        import requests
    except ImportError:
        print(MAL + "falta requests (pip install -r tools/requirements.txt)")
        problemas.append("falta requests")
        return

    print(f"\nBucket '{bucket}'")
    try:
        r = requests.get(
            f"{url}/storage/v1/bucket/{bucket}",
            headers={"Authorization": f"Bearer {key}", "apikey": key},
            timeout=20,
        )
    except requests.RequestException as e:
        print(MAL + f"no responde: {e}")
        problemas.append("Storage no responde")
        return

    if r.status_code == 200:
        datos = r.json()
        publico = datos.get("public")
        print(OK + f"existe (publico: {publico})")
        if not publico:
            print(AVISO + "no es publico: los links quedan guardados pero no se van a")
            print("         poder abrir sin firmarlos. Para revisar muestras conviene")
            print("         marcarlo Public.")
    elif r.status_code in (400, 404):
        print(MAL + "no existe. Creala en Supabase -> Storage -> New bucket ->")
        print(f"         nombre '{bucket}' -> marcarlo Public.")
        problemas.append("falta el bucket")
    elif r.status_code in (401, 403):
        print(MAL + "la clave no tiene permiso. Revisa que sea la SECRETA.")
        problemas.append("clave sin permiso en Storage")
    else:
        print(MAL + f"respuesta inesperada ({r.status_code}): {r.text[:120]}")
        problemas.append("Storage devolvio un error")


def main():
    aca = os.path.dirname(os.path.abspath(__file__))
    ruta_env = os.path.join(aca, "..", ".env")
    if not os.path.exists(ruta_env):
        sys.exit(
            "no encuentro el .env en senas_core/\n"
            "Copia .env.example a .env y completa tus valores (INGESTA.md paso 5)."
        )
    load_dotenv(ruta_env)

    problemas = []
    url = revisar_database_url(problemas)
    if url:
        probar_base(url, problemas)
    probar_storage(problemas)

    print()
    if problemas:
        print(f"{len(problemas)} cosa(s) que arreglar:")
        for p in problemas:
            print(f"  - {p}")
        sys.exit(1)
    print("Todo bien. Ya podes subir senas.")


if __name__ == "__main__":
    main()
