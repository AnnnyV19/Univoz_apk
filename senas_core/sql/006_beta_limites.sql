-- Aplicar manualmente en Supabase SQL editor; revisar antes.
--
-- Limites para la beta publica: endurece lo que la clave PUBLISHABLE (rol
-- anon) puede insertar en signs, sign_samples y sample_landmarks. Se corre
-- DESPUES de 001_schema.sql, 002_app_acceso.sql y 004_motion_v2.sql (usa las
-- columnas raw_landmarks_uri / checksum_sha256 de esa ultima). NO lo ejecuta
-- nadie por ti: copialo al SQL Editor, leelo y correlo una vez. Es
-- idempotente (se puede repetir).
--
-- Se corre DESPUES de 005_storage_raw.sql; es independiente de
-- 003_categorizar_senas.sql.
--
-- Que cambia, en una linea cada cosa:
--   * La app solo puede dar de alta senas "normales": glosa en MAYUSCULAS
--     sin simbolos, textos cortos y sin los campos que son de curaduria.
--   * Solo puede subir muestras en 'pendiente', de origen 'camara', sin
--     revisora, sin video y sin derivar de otra muestra.
--   * Los landmarks tienen que ser EXACTAMENTE un MotionSequenceV2
--     (2.0.0, 32 x 152, float16 = 9728 bytes). Nada de payloads gigantes.
--   * Rangos sanos para fps, duracion, visibilidad y calidad.
--   * Se quitan explicitamente UPDATE/DELETE al rol anon.
--
-- Las restricciones de columna van NOT VALID: se aplican a TODA fila nueva o
-- modificada (tambien las de tus scripts con la clave secreta), pero NO
-- revisan las filas que ya estan. Cuando limpies lo viejo puedes correr
-- ALTER TABLE ... VALIDATE CONSTRAINT <nombre>.
--
-- Lo que esto NO resuelve (RLS no tiene estado): limitar CUANTAS filas sube
-- una misma persona. Para eso usa el rate limiting de la API de Supabase
-- (Dashboard -> Auth/API settings) o pon una Edge Function delante.
-- Tampoco se puede exigir en RLS que sample_landmarks apunte a una muestra
-- 'pendiente': el rol anon no puede LEER las pendientes (samples_lectura),
-- asi que ese EXISTS siempre daria falso. La clave foranea y la PK (un solo
-- payload por muestra) ya cubren lo importante.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. signs
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    ALTER TABLE signs ADD CONSTRAINT signs_largos_check CHECK (
        char_length(gloss) BETWEEN 1 AND 64
        AND char_length(espanol) BETWEEN 1 AND 120
        AND (categoria IS NULL OR char_length(categoria) <= 60)
        AND (notas IS NULL OR char_length(notas) <= 500)
    ) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DROP POLICY IF EXISTS signs_alta ON signs;
CREATE POLICY signs_alta ON signs
    FOR INSERT TO anon, authenticated
    WITH CHECK (
        -- Misma forma que produce aGlosa() en la app: A-Z, 0-9 y "_".
        gloss ~ '^[A-Z0-9_]{1,64}$'
        AND char_length(btrim(espanol)) BETWEEN 1 AND 120
        AND (categoria IS NULL OR char_length(categoria) <= 60)
        -- Campos de curaduria: los pone el equipo, no la app.
        AND notas IS NULL
        AND variante_de IS NULL
        AND es_estatica = false
        AND manos = 1
        AND usa_no_manuales = false
    );

-- ---------------------------------------------------------------------------
-- 2. sign_samples
-- ---------------------------------------------------------------------------
DO $$ BEGIN
    ALTER TABLE sign_samples ADD CONSTRAINT sign_samples_rangos_check CHECK (
        (fps IS NULL OR (fps > 0 AND fps <= 240))
        AND (duracion_ms IS NULL OR duracion_ms BETWEEN 0 AND 60000)
        AND (n_frames_orig IS NULL OR n_frames_orig BETWEEN 0 AND 10000)
        AND frames_invalidos BETWEEN 0 AND 10000
        AND (visibilidad_min IS NULL OR visibilidad_min BETWEEN 0 AND 1)
        AND (quality_score IS NULL OR quality_score BETWEEN 0 AND 1)
        AND (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-f]{64}$')
    ) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DROP POLICY IF EXISTS samples_alta ON sign_samples;
CREATE POLICY samples_alta ON sign_samples
    FOR INSERT TO anon, authenticated
    WITH CHECK (
        estado = 'pendiente'
        AND origen = 'camara'
        AND derivada_de IS NULL
        AND revisada_por IS NULL
        AND video_uri IS NULL
        AND raw_landmarks_uri IS NULL
        AND raw_landmarks_format IS NULL
        -- La app siempre manda cuantos frames tenia la captura original.
        AND n_frames_orig IS NOT NULL
        AND n_frames_orig BETWEEN 0 AND 10000
        AND (fps IS NULL OR (fps > 0 AND fps <= 240))
        AND (duracion_ms IS NULL OR duracion_ms BETWEEN 0 AND 60000)
        AND frames_invalidos BETWEEN 0 AND 10000
        AND (visibilidad_min IS NULL OR visibilidad_min BETWEEN 0 AND 1)
        AND (quality_score IS NULL OR quality_score BETWEEN 0 AND 1)
        AND (checksum_sha256 IS NULL OR checksum_sha256 ~ '^[0-9a-f]{64}$')
    );

-- ---------------------------------------------------------------------------
-- 3. sample_landmarks
-- ---------------------------------------------------------------------------
-- Tope generoso a nivel de tabla (cualquier rol): un MotionSequenceV2 pesa
-- 9728 bytes; 64 KB deja margen para versiones futuras sin permitir basura.
DO $$ BEGIN
    ALTER TABLE sample_landmarks ADD CONSTRAINT sample_landmarks_tamano_check CHECK (
        t_frames BETWEEN 1 AND 512
        AND frame_dim BETWEEN 1 AND 1024
        AND octet_length(data) BETWEEN 1 AND 65536
    ) NOT VALID;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DROP POLICY IF EXISTS landmarks_alta ON sample_landmarks;
CREATE POLICY landmarks_alta ON sample_landmarks
    FOR INSERT TO anon, authenticated
    -- La app solo sube MotionSequenceV2: 2.0.0, 32 frames x 152 valores en
    -- float16 (2 bytes) = 9728 bytes exactos. La FK ata la fila a una
    -- muestra real y la PK impide un segundo payload para la misma muestra.
    WITH CHECK (
        norm_version = '2.0.0'
        AND t_frames = 32
        AND frame_dim = 152
        AND octet_length(data) = 32 * 152 * 2
    );

-- ---------------------------------------------------------------------------
-- 4. Nada de modificar ni borrar desde la app (defensa en profundidad: ya
--    estaba prohibido por falta de politicas).
-- ---------------------------------------------------------------------------
REVOKE UPDATE, DELETE, TRUNCATE ON signs            FROM anon, authenticated;
REVOKE UPDATE, DELETE, TRUNCATE ON sign_samples     FROM anon, authenticated;
REVOKE UPDATE, DELETE, TRUNCATE ON sample_landmarks FROM anon, authenticated;

COMMIT;

-- Ojo: la app inserta sign_samples con Prefer: return=minimal y el id
-- generado en el cliente. Con return=representation el INSERT...RETURNING
-- exigiria poder LEER la fila 'pendiente' y fallaria con 42501.
--
-- Comprobacion rapida despues de aplicar (como anon, desde la app o con
-- curl): subir una muestra desde la app debe seguir funcionando; esto debe
-- FALLAR por la politica:
--   POST /rest/v1/sign_samples  {"sign_id": "...", "origen": "camara",
--                                "estado": "aprobada", "n_frames_orig": 40}
