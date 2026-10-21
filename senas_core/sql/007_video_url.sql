-- 007: sign_samples.video_url y la vista v_muestras_revision.
--
-- Hasta ahora los crea sola senas_core/tools/subir_videos_dataset.py (rama
-- app-limpia) con la clave de SERVICIO; este archivo deja el esquema escrito
-- aqui para que no dependa de un script. Es idempotente: aplicarlo con la
-- columna ya creada no hace nada. Ver docs/17-integracion-app-limpia.md.
--
-- video_url guarda el LINK del video de origen de una muestra importada de un
-- dataset (CICESE, ITESO, UAEMex, Wikisigns...) para poder revisarla en el
-- Table Editor. La app NO lo lee ni lo sube: es solo de curaduria.

BEGIN;

ALTER TABLE sign_samples ADD COLUMN IF NOT EXISTS video_url TEXT;

-- security_invoker: la vista respeta las politicas RLS de quien la consulta
-- (sin eso, cualquiera con la clave publishable veria todo lo que ve el
-- dueno).
CREATE OR REPLACE VIEW v_muestras_revision WITH (security_invoker = true) AS
SELECT ss.id, s.gloss, s.espanol, s.categoria, ss.estado, ss.origen,
       ss.duracion_ms, ss.quality_score, ss.video_url, ss.video_uri,
       ss.creado_en
FROM sign_samples ss
JOIN signs s ON s.id = ss.sign_id;

COMMIT;

-- Nota de seguridad (decision pendiente de la dueña): la politica de INSERT
-- para anon/authenticated de 006_beta_limites.sql exige video_uri IS NULL y
-- origen = 'camara', pero NO dice nada de video_url. Una muestra subida desde
-- la app podria traer un video_url arbitrario (texto que solo se ve en la
-- vista de revision). Para cerrarlo, agregar "AND video_url IS NULL" al
-- WITH CHECK de esa politica.
