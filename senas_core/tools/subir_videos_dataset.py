#!/usr/bin/env python3
"""Sube a Supabase Storage los videos del dataset de LSM que ya importaste,
y deja el link en la base para poder VERLOS desde el panel de Supabase.

Que hace, en orden:
  1. busca en la base las muestras que importo importar_dataset_lsm.py (las
     que tienen video_uri 'zenodo:18330565/...') y encuentra su video en tu
     carpeta datasets_lsm/zenodo_18330565/videos
  2. comprime cada video a 480 px de alto, H.264, sin audio (los originales
     suman ~980 MB y el plan gratis de Supabase Storage da 1 GB en total; ya
     comprimidos quedan en pocos MB). Los originales NO se tocan. Las copias
     quedan en datasets_lsm/zenodo_18330565/videos_480p/ para no recomprimir
     si lo vuelves a correr.
  3. los sube al bucket (por defecto 'videos') en zenodo_18330565/<GLOSA>/...
  4. guarda el link en sign_samples.video_url (columna nueva; se crea sola) y
     crea la vista v_muestras_revision: en Supabase -> Table Editor ->
     v_muestras_revision ves glosa, espanol, estado y el link de cada video.

NO cambia video_uri (ese campo es la huella con la que el importador sabe que
una muestra ya existe; si lo tocara, --rehacer y --deshacer dejarian de
encontrarla). Tampoco toca los landmarks ni plantillas.json: las muestras y
la app siguen exactamente igual. Los videos son solo para que tu equipo los
vea al revisar.

Uso:
    python tools/subir_videos_dataset.py --seco       # solo cuenta, no sube nada
    python tools/subir_videos_dataset.py --probar 3   # sube 3 de prueba
    python tools/subir_videos_dataset.py              # todos

Requiere en el .env: DATABASE_URL (ya lo tienes) y SUPABASE_SERVICE_KEY (la
clave SECRETA: Supabase -> Settings -> API Keys -> Secret keys, sb_secret_...).
SUPABASE_URL es opcional: si esta vacio se saca de DATABASE_URL.
Para comprimir hace falta ffmpeg; si no lo tienes:  pip install imageio-ffmpeg

El dataset es CC BY 4.0: se puede redistribuir dando el credito (ver
datasets_lsm/CREDITOS.md). Ojo: un bucket Public deja los videos abiertos a
cualquiera que tenga el link; son personas reales firmando.
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.parse

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(HERE)

PREFIJO_DEFECTO = "zenodo:18330565/"
CARPETA_DEFECTO = os.path.join(RAIZ, "datasets_lsm", "zenodo_18330565", "videos")
LIMITE_ARCHIVO_MB = 50          # tope por archivo del plan gratis de Supabase
LIMITE_TOTAL_MB = 900           # del GB gratis; se deja margen para el resto

SQL_COLUMNA = "ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS video_url TEXT"
# security_invoker: la vista respeta las politicas RLS de quien la consulta
# (sin eso, cualquiera con la clave publishable veria todo lo que ve el dueno).
SQL_VISTA = """
CREATE OR REPLACE VIEW v_muestras_revision WITH (security_invoker = true) AS
SELECT ss.id, s.gloss, s.espanol, s.categoria, ss.estado, ss.origen,
       ss.duracion_ms, ss.quality_score, ss.video_url, ss.video_uri, ss.creado_en
FROM sign_samples ss
JOIN signs s ON s.id = ss.sign_id
"""
SQL_MUESTRAS = """
SELECT ss.id, s.gloss, ss.video_uri, ss.video_url
FROM sign_samples ss
JOIN signs s ON s.id = ss.sign_id
WHERE ss.video_uri LIKE %s
ORDER BY s.gloss, ss.video_uri
"""


# ---------------------------------------------------------------------------
# utilidades
# ---------------------------------------------------------------------------
def nfc(s):
    return unicodedata.normalize("NFC", s)


def nombre_seguro(nombre):
    """Storage solo acepta claves ASCII sencillas: BANO_0.mp4 si el archivo es BA(enie)O_0.mp4."""
    s = unicodedata.normalize("NFKD", nombre).encode("ascii", "ignore").decode("ascii")
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


def mb(n):
    return n / 1e6


def url_supabase():
    url = (os.environ.get("SUPABASE_URL") or "").strip().rstrip("/")
    if url:
        return url
    # Se deduce del connection string: db.<ref>.supabase.co  o  postgres.<ref>@...pooler
    db = os.environ.get("DATABASE_URL") or ""
    m = re.search(r"@db\.([a-z0-9]+)\.supabase\.co", db) or re.search(r"//postgres\.([a-z0-9]+):", db)
    return f"https://{m.group(1)}.supabase.co" if m else ""


def buscar_ffmpeg():
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return None


def comprimir(ffmpeg, origen, destino, alto, crf):
    """H.264, alto maximo 'alto' (nunca agranda), sin audio, listo para verse en el navegador."""
    tmp = destino + ".parcial.mp4"
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-i", origen,
           "-vf", f"scale=-2:min({alto}\\,ih)",
           "-c:v", "libx264", "-preset", "veryfast", "-crf", str(crf),
           "-pix_fmt", "yuv420p", "-an", "-movflags", "+faststart", tmp]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(tmp) or os.path.getsize(tmp) == 0:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise RuntimeError((r.stderr or "ffmpeg fallo").strip().splitlines()[-1][:200])
    os.replace(tmp, destino)


# ---------------------------------------------------------------------------
# Supabase Storage
# ---------------------------------------------------------------------------
class Storage:
    def __init__(self, base, key, bucket):
        self.base, self.bucket = base, bucket
        self.h = {"Authorization": f"Bearer {key}", "apikey": key}

    def estado_bucket(self):
        """None si no existe, True/False segun sea publico."""
        r = requests.get(f"{self.base}/storage/v1/bucket/{self.bucket}", headers=self.h, timeout=30)
        if r.status_code == 200:
            return bool(r.json().get("public"))
        # Supabase contesta 400 (con statusCode 404 adentro) cuando el bucket no existe.
        if r.status_code == 404 or (r.status_code == 400 and "not found" in r.text.lower()):
            return None
        if r.status_code in (400, 401, 403):
            raise RuntimeError(f"Supabase rechazo la clave ({r.status_code}: {r.text[:150]}). "
                               "En SUPABASE_SERVICE_KEY va la clave SECRETA (sb_secret_... o service_role), "
                               "no la publishable/anon.")
        raise RuntimeError(f"no pude consultar el bucket ({r.status_code}: {r.text[:200]})")

    def crear_bucket(self):
        r = requests.post(f"{self.base}/storage/v1/bucket", headers=self.h, timeout=30,
                          json={"id": self.bucket, "name": self.bucket, "public": True,
                                "file_size_limit": LIMITE_ARCHIVO_MB * 1024 * 1024})
        if r.status_code not in (200, 201):
            raise RuntimeError(f"no pude crear el bucket ({r.status_code}: {r.text[:200]})")

    def subir(self, ruta_local, ruta_remota):
        """Devuelve el link publico. Reintenta 3 veces."""
        with open(ruta_local, "rb") as f:
            datos = f.read()
        ep = f"{self.base}/storage/v1/object/{self.bucket}/{urllib.parse.quote(ruta_remota, safe='/')}"
        ultimo = ""
        for intento in range(3):
            try:
                r = requests.put(ep, data=datos, timeout=120,
                                 headers={**self.h, "Content-Type": "video/mp4", "x-upsert": "true"})
                if r.status_code in (200, 201):
                    return (f"{self.base}/storage/v1/object/public/{self.bucket}/"
                            f"{urllib.parse.quote(ruta_remota, safe='/')}")
                ultimo = f"{r.status_code}: {r.text[:200]}"
                if r.status_code < 500 and r.status_code != 429:
                    break
            except requests.RequestException as e:
                ultimo = str(e)
            time.sleep(2 * (intento + 1))
        raise RuntimeError(ultimo)


# ---------------------------------------------------------------------------
# principal
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--carpeta", default=CARPETA_DEFECTO, help="carpeta con los videos descomprimidos")
    ap.add_argument("--prefijo", default=PREFIJO_DEFECTO, help="prefijo del video_uri de las muestras")
    ap.add_argument("--bucket", help="bucket de Storage (por defecto SUPABASE_BUCKET o 'videos')")
    ap.add_argument("--seco", action="store_true", help="solo cuenta y calcula, no comprime ni sube")
    ap.add_argument("--probar", type=int, metavar="N", help="solo las primeras N muestras")
    ap.add_argument("--rehacer", action="store_true", help="vuelve a subir aunque ya tengan video_url")
    ap.add_argument("--alto", type=int, default=480, help="alto maximo en px (480)")
    ap.add_argument("--crf", type=int, default=28, help="calidad H.264: mas alto = mas chico (28)")
    ap.add_argument("--sin-comprimir", action="store_true", help="sube los originales tal cual")
    ap.add_argument("--max-mb", type=float, default=LIMITE_TOTAL_MB, help="tope del total a subir")
    ap.add_argument("--crear-bucket", action="store_true", help="crea el bucket (publico) si no existe")
    args = ap.parse_args()

    try:
        from dotenv import load_dotenv
        load_dotenv(os.path.join(RAIZ, ".env"))
    except ImportError:
        pass
    sys.path.insert(0, HERE)
    import db

    bucket = args.bucket or os.environ.get("SUPABASE_BUCKET") or "videos"
    base = url_supabase()
    key = (os.environ.get("SUPABASE_SERVICE_KEY") or "").strip()

    if not args.seco:
        faltan = []
        if not base:
            faltan.append("SUPABASE_URL (o un DATABASE_URL del tipo db.<proyecto>.supabase.co)")
        if not key:
            faltan.append("SUPABASE_SERVICE_KEY")
        if faltan:
            print("Falta en tu .env: " + ", ".join(faltan))
            print("  La clave secreta (sb_secret_...) esta en Supabase -> Settings -> API Keys -> Secret keys.")
            print("  NO uses la publishable (sb_publishable_...): no puede escribir en Storage.")
            return 2

    # --- 1. muestras en la base ---------------------------------------------
    conn = db.conectar()
    conn.autocommit = True
    with conn.cursor() as cur:
        if not args.seco:
            cur.execute(SQL_COLUMNA)
        try:
            cur.execute(SQL_MUESTRAS, (args.prefijo + "%",))
        except Exception as e:
            if args.seco and "video_url" in str(e):
                cur.execute(SQL_MUESTRAS.replace(", ss.video_url", ", NULL"), (args.prefijo + "%",))
            else:
                raise
        filas = cur.fetchall()
    if not filas:
        print(f"No hay muestras con video_uri '{args.prefijo}...' en la base. "
              "Corre antes tools/importar_dataset_lsm.py.")
        return 1

    # --- 2. videos en tu disco ----------------------------------------------
    indice = {}
    for d, _, fs in os.walk(args.carpeta):
        for f in fs:
            if f.lower().endswith(".mp4"):
                indice.setdefault(nfc(f).lower(), os.path.join(d, f))
    if not indice:
        print(f"No encontre videos .mp4 en {args.carpeta}\n"
              "  (usa --carpeta RUTA si los descomprimiste en otro lado)")
        return 1

    trabajo, sin_video, ya = [], [], 0
    for sid, gloss, uri, url in filas:
        archivo = re.sub(r"#t\d+$", "", uri[len(args.prefijo):])
        ruta = indice.get(nfc(archivo).lower())
        if not ruta:
            sin_video.append(archivo)
            continue
        if url and not args.rehacer:
            ya += 1
            continue
        trabajo.append({"id": sid, "gloss": gloss, "archivo": archivo, "origen": ruta,
                        "seguro": nombre_seguro(archivo)})
    if args.probar:
        trabajo = trabajo[:args.probar]

    peso_orig = sum(os.path.getsize(t["origen"]) for t in trabajo)
    print(f"Muestras del dataset en la base: {len(filas)}")
    print(f"  ya tienen video_url:   {ya}")
    print(f"  por subir ahora:       {len(trabajo)}   ({mb(peso_orig):.0f} MB originales)")
    if sin_video:
        print(f"  sin video en tu disco: {len(sin_video)}  (ej: {', '.join(sin_video[:3])})")
    if not trabajo:
        print("Nada que subir.")
        return 0

    ffmpeg = None
    if not args.sin_comprimir:
        ffmpeg = buscar_ffmpeg()
        if not ffmpeg:
            print("\nNo encontre ffmpeg para comprimir. Instala uno de estos dos:")
            print("    pip install imageio-ffmpeg")
            print("    winget install ffmpeg")
            print("o usa --sin-comprimir (suben ~980 MB: no caben con holgura en el GB gratis).")
            return 2
    elif any(os.path.getsize(t["origen"]) > LIMITE_ARCHIVO_MB * 1e6 for t in trabajo):
        print(f"Hay videos de mas de {LIMITE_ARCHIVO_MB} MB (tope de Supabase gratis): comprime.")
        return 2

    if args.seco:
        est = peso_orig * (1 if args.sin_comprimir else 0.1)
        print(f"\n[seco] estimado a subir: ~{mb(est):.0f} MB "
              f"({'originales' if args.sin_comprimir else 'comprimidos a ' + str(args.alto) + 'p'}).")
        print("[seco] no se comprimio ni subio nada.")
        return 0

    # --- 3. bucket -----------------------------------------------------------
    st = Storage(base, key, bucket)
    try:
        publico = st.estado_bucket()
    except (RuntimeError, requests.RequestException) as e:
        print(f"\n{e}")
        return 2
    if publico is None:
        if not args.crear_bucket:
            print(f"\nEl bucket '{bucket}' no existe. Crealo en Supabase -> Storage -> New bucket "
                  f"(nombre '{bucket}', marcado Public), o corre otra vez con --crear-bucket.")
            return 2
        st.crear_bucket()
        publico = True
        print(f"Bucket '{bucket}' creado (publico).")
    elif not publico:
        print(f"\nOJO: el bucket '{bucket}' es PRIVADO: se suben bien pero los links no abren. "
              "Para verlos: Supabase -> Storage -> el bucket -> Edit -> Public.")

    # --- 4. comprimir --------------------------------------------------------
    dest_dir = os.path.join(os.path.dirname(args.carpeta), "videos_" + str(args.alto) + "p")
    os.makedirs(dest_dir, exist_ok=True)
    fallos = []
    t0 = time.time()
    if ffmpeg:
        print(f"\nComprimiendo a {args.alto}p (crf {args.crf})...")
    for i, t in enumerate(trabajo, 1):
        if not ffmpeg:
            t["subir"] = t["origen"]
            continue
        t["subir"] = os.path.join(dest_dir, t["seguro"])
        if os.path.exists(t["subir"]) and os.path.getsize(t["subir"]) > 0:
            continue
        try:
            comprimir(ffmpeg, t["origen"], t["subir"], args.alto, args.crf)
        except Exception as e:
            fallos.append((t["archivo"], f"compresion: {e}"))
            t["subir"] = None
        if i % 10 == 0 or i == len(trabajo):
            print(f"  {i}/{len(trabajo)}  ({time.time() - t0:.0f} s)")
    trabajo = [t for t in trabajo if t.get("subir")]
    peso_sub = sum(os.path.getsize(t["subir"]) for t in trabajo)
    print(f"A subir: {len(trabajo)} videos, {mb(peso_sub):.1f} MB "
          f"(de {mb(peso_orig):.0f} MB originales)")
    if mb(peso_sub) > args.max_mb:
        print(f"Eso pasa de {args.max_mb:.0f} MB (el plan gratis da 1 GB en total). "
              f"Prueba --alto 360 o --crf 32, o sube el tope con --max-mb si tienes plan de pago.")
        return 2

    # --- 5. subir y guardar el link -------------------------------------------
    ok = 0
    aviso_publico = False
    for i, t in enumerate(trabajo, 1):
        ruta_remota = f"{nombre_seguro(args.prefijo.rstrip('/').replace(':', '_'))}/{t['gloss']}/{t['seguro']}"
        try:
            url = st.subir(t["subir"], ruta_remota)
            with conn.cursor() as cur:
                cur.execute("UPDATE sign_samples SET video_url = %s WHERE id = %s", (url, t["id"]))
            ok += 1
            if not aviso_publico:
                aviso_publico = True
                if requests.head(url, timeout=30).status_code != 200:
                    print("  OJO: el primer link no abre desde afuera: revisa que el bucket sea Public.")
        except Exception as e:
            fallos.append((t["archivo"], str(e)))
        if i % 20 == 0 or i == len(trabajo):
            print(f"  subidos {ok}/{len(trabajo)}")

    with conn.cursor() as cur:
        cur.execute("SELECT s.gloss, ss.video_uri, ss.id, ss.video_url FROM sign_samples ss "
                    "JOIN signs s ON s.id = ss.sign_id WHERE ss.video_uri LIKE %s "
                    "AND ss.video_url IS NOT NULL ORDER BY s.gloss, ss.video_uri", (args.prefijo + "%",))
        con_url = cur.fetchall()
    if con_url:
        sal = os.path.join(os.path.dirname(os.path.dirname(args.carpeta)), "videos_subidos.csv")
        with open(sal, "w", newline="", encoding="utf-8-sig") as f:
            w = csv.writer(f)
            w.writerow(["gloss", "archivo", "sample_id", "url"])
            for g, uri, sid, url in con_url:
                w.writerow([g, re.sub(r"#t\d+$", "", uri[len(args.prefijo):]), sid, url])
        print(f"Lista de links ({len(con_url)}): {sal}")

    with conn.cursor() as cur:
        try:
            cur.execute(SQL_VISTA)
            print("Vista v_muestras_revision lista (Supabase -> Table Editor).")
        except Exception as e:
            print(f"No pude crear la vista v_muestras_revision ({str(e).splitlines()[0]}); "
                  "los links igual estan en sign_samples.video_url.")

    print(f"\nListo: {ok} videos subidos, {len(fallos)} con problemas.")
    for a, m in fallos[:10]:
        print(f"  {a}: {m}")
    return 0 if not fallos else 1


if __name__ == "__main__":
    sys.exit(main())
