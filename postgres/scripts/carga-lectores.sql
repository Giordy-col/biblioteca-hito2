-- Carga de lectores desde CSV al esquema biblioteca.
-- Adaptado de S14-carga-lectores.sql (referencia del profesor).
-- Requiere haber corrido 01_esquema.sql.
--
-- Uso (desde entorno-docker/, con los CSV en postgres/scripts/datos/):
--   docker compose exec postgres psql -U curso -d curso \
--     -v archivo=/scripts/datos/lectores_semilla_con_errores.csv \
--     -f /scripts/carga-lectores.sql
--
-- Sin "-v archivo=..." carga /scripts/datos/lectores_semilla.csv.
-- Los lectores son filas de "usuarios" con rol 'lector'. Lo que el CSV no trae:
--   nombre         = nombres || ' ' || apellidos
--   username       = documento
--   password_hash  = hash bcrypt del documento (pgcrypto); nunca texto plano
--   rol / estado   = 'lector' / 'activo'

\set ON_ERROR_STOP on
\if :{?archivo}
\else
    \set archivo /scripts/datos/lectores_semilla.csv
\endif

SET search_path TO biblioteca, public;

BEGIN;

TRUNCATE stg_linea, stg_lector RESTART IDENTITY;

-- 1. Leer el archivo tal cual: una fila por línea
COPY stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM stg_linea WHERE n = 1;          -- encabezado

-- 2. Partir cada línea en sus campos
INSERT INTO stg_lector (linea_csv, contenido, num_campos,
                        documento, nombres, apellidos, correo, telefono)
SELECT n, linea,
       array_length(string_to_array(linea, ','), 1),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       lower(trim(split_part(linea, ',', 4))),
       trim(split_part(linea, ',', 5))
FROM stg_linea;

-- 3. Validar (la primera regla que falla da el motivo)
UPDATE stg_lector SET motivo = CASE
    WHEN num_campos <> 5                          THEN 'tiene ' || num_campos || ' columnas, se esperaban 5'
    WHEN documento = ''                           THEN 'documento vacío'
    WHEN documento !~ '^[0-9]{6,15}$'             THEN 'documento no numérico o de longitud inválida'
    WHEN nombres = ''                             THEN 'nombres vacío'
    WHEN apellidos = ''                           THEN 'apellidos vacío'
    WHEN length(nombres || ' ' || apellidos) > 100
                                                  THEN 'nombre completo de más de 100 caracteres'
    WHEN correo = ''                              THEN 'correo vacío'
    WHEN correo !~ '^[^@ ]+@[^@ ]+\.[^@ ]+$'      THEN 'correo mal formado'
    WHEN length(correo) > 150                     THEN 'correo de más de 150 caracteres'
    WHEN telefono !~ '^[0-9]{7,15}$'              THEN 'teléfono no numérico o de longitud inválida'
    WHEN EXISTS (SELECT 1 FROM usuarios u WHERE u.documento = stg_lector.documento)
                                                  THEN 'documento ya existe'
    WHEN EXISTS (SELECT 1 FROM usuarios u WHERE u.username = stg_lector.documento)
                                                  THEN 'username (documento) ya está en uso'
    WHEN EXISTS (SELECT 1 FROM usuarios u WHERE lower(u.correo) = stg_lector.correo)
                                                  THEN 'correo ya registrado por otro usuario'
END;

-- 4. Duplicados dentro del mismo archivo (por documento o por correo)
UPDATE stg_lector SET motivo = 'documento o correo repetido en el archivo'
WHERE motivo IS NULL
  AND EXISTS (SELECT 1 FROM stg_lector s2
              WHERE (s2.documento = stg_lector.documento OR s2.correo = stg_lector.correo)
                AND s2.motivo IS NULL
                AND s2.linea_csv < stg_lector.linea_csv);

-- 5. Filas válidas a la tabla final
INSERT INTO usuarios (documento, nombre, correo, telefono,
                      username, password_hash, rol, estado)
SELECT documento, nombres || ' ' || apellidos, correo, telefono,
       documento, crypt(documento, gen_salt('bf')), 'lector', 'activo'
FROM stg_lector
WHERE motivo IS NULL;

-- 6. Rechazadas a la bitácora
INSERT INTO rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM stg_lector
WHERE motivo IS NOT NULL;

COMMIT;

-- Resumen de la carga
SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM stg_lector;

SELECT linea_csv AS linea, motivo, contenido
FROM stg_lector
WHERE motivo IS NOT NULL
ORDER BY linea_csv;
