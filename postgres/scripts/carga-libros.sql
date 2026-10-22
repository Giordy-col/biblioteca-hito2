-- Carga de libros desde CSV al esquema biblioteca.
-- Adaptado de S14-carga-libros.sql (referencia del profesor).
-- Requiere haber corrido 01_esquema.sql.
--
-- Uso (desde entorno-docker/, con los CSV en postgres/scripts/datos/):
--   docker compose exec postgres psql -U curso -d curso \
--     -v archivo=/scripts/datos/libros_semilla_con_errores.csv \
--     -f /scripts/carga-libros.sql
--
-- Sin "-v archivo=..." carga /scripts/datos/libros_semilla.csv.
-- Todo corre en una transacción: si algo falla, no queda nada a medias.
-- Repetir la misma carga no duplica nada: los ISBN ya cargados se rechazan.

\set ON_ERROR_STOP on
\if :{?archivo}
\else
    \set archivo /scripts/datos/libros_semilla.csv
\endif

SET search_path TO biblioteca, public;

BEGIN;

TRUNCATE stg_linea, stg_libro RESTART IDENTITY;

-- 1. Leer el archivo tal cual: una fila por línea (FORMAT text, separador
--    tabulador: la línea entera cae en una sola columna).
COPY stg_linea (linea) FROM :'archivo' WITH (FORMAT text);
DELETE FROM stg_linea WHERE n = 1;          -- la línea 1 es el encabezado

-- 2. Partir cada línea en sus campos (todavía como texto)
INSERT INTO stg_libro (linea_csv, contenido, num_campos, isbn, titulo, autor,
                       categoria, anio_publicacion, ejemplares_disponibles)
SELECT n, linea,
       array_length(string_to_array(linea, ','), 1),
       trim(split_part(linea, ',', 1)),
       trim(split_part(linea, ',', 2)),
       trim(split_part(linea, ',', 3)),
       trim(split_part(linea, ',', 4)),
       trim(split_part(linea, ',', 5)),
       trim(split_part(linea, ',', 6))
FROM stg_linea;

-- 3. Validar: la primera regla que falla da el motivo del rechazo.
--    El CASE se evalúa en orden: los ::integer solo se intentan cuando la
--    regla anterior ya comprobó que el texto es numérico.
UPDATE stg_libro SET motivo = CASE
    WHEN num_campos <> 6                          THEN 'tiene ' || num_campos || ' columnas, se esperaban 6'
    WHEN isbn = ''                                THEN 'isbn vacío'
    WHEN isbn !~ '^[0-9]{13}$'                    THEN 'isbn no tiene 13 dígitos'
    WHEN titulo = ''                              THEN 'título vacío'
    WHEN length(titulo) > 200                     THEN 'título de más de 200 caracteres'
    WHEN autor = ''                               THEN 'autor vacío'
    WHEN length(autor) > 150                      THEN 'autor de más de 150 caracteres'
    WHEN categoria = ''                           THEN 'categoría vacía'
    WHEN length(categoria) > 100                  THEN 'categoría de más de 100 caracteres'
    WHEN anio_publicacion !~ '^[0-9]{1,4}$'       THEN 'año no numérico'
    WHEN anio_publicacion::integer NOT BETWEEN 1450 AND 2100
                                                  THEN 'año fuera de rango' 
    WHEN ejemplares_disponibles !~ '^-?[0-9]{1,6}$'
                                                  THEN 'ejemplares no numérico'
    WHEN ejemplares_disponibles::integer < 0      THEN 'ejemplares negativo'
    WHEN EXISTS (SELECT 1 FROM libros l WHERE l.isbn = stg_libro.isbn)
                                                  THEN 'isbn ya existe en el catálogo'
END;

-- 4. Duplicados dentro del mismo archivo: se queda la primera aparición
UPDATE stg_libro SET motivo = 'isbn repetido en el archivo (línea '
       || (SELECT min(s2.linea_csv) FROM stg_libro s2
           WHERE s2.isbn = stg_libro.isbn AND s2.motivo IS NULL) || ')'
WHERE motivo IS NULL
  AND EXISTS (SELECT 1 FROM stg_libro s2
              WHERE s2.isbn = stg_libro.isbn
                AND s2.motivo IS NULL
                AND s2.linea_csv < stg_libro.linea_csv);

-- 5. Pasar las filas válidas a las tablas finales (cada libro se reparte en
--    categorias, autores, libros, libro_autor y ejemplares).

-- 5a. Categorías nuevas
INSERT INTO categorias (nombre)
SELECT DISTINCT categoria FROM stg_libro WHERE motivo IS NULL
ON CONFLICT (nombre) DO NOTHING;

-- 5b. Autores nuevos
INSERT INTO autores (nombre)
SELECT DISTINCT autor FROM stg_libro WHERE motivo IS NULL
ON CONFLICT (nombre) DO NOTHING;

-- 5c. Libros (estado inicial 'disponible'; el CSV no trae editorial)
INSERT INTO libros (titulo, isbn, anio_publicacion, estado, categoria_id)
SELECT s.titulo, s.isbn, s.anio_publicacion::integer, 'disponible', c.id_categoria
FROM stg_libro s
JOIN categorias c ON c.nombre = s.categoria
WHERE s.motivo IS NULL;

-- 5d. Relación libro-autor
INSERT INTO libro_autor (libro_id, autor_id)
SELECT l.id_libro, a.id_autor
FROM stg_libro s
JOIN libros  l ON l.isbn   = s.isbn
JOIN autores a ON a.nombre = s.autor
WHERE s.motivo IS NULL;

-- 5e. Una fila de ejemplares por cada copia (ISBN-001, ISBN-002, ...)
INSERT INTO ejemplares (codigo_inventario, estado, libro_id)
SELECT s.isbn || '-' || lpad(g.n::text, 3, '0'), 'disponible', l.id_libro
FROM stg_libro s
JOIN libros l ON l.isbn = s.isbn
CROSS JOIN LATERAL generate_series(1, s.ejemplares_disponibles::integer) AS g(n)
WHERE s.motivo IS NULL;

-- 6. Dejar constancia de las rechazadas
INSERT INTO rechazo_carga (archivo, linea, contenido, motivo)
SELECT :'archivo', linea_csv, contenido, motivo
FROM stg_libro
WHERE motivo IS NOT NULL;

COMMIT;

-- Resumen de la carga
SELECT count(*) FILTER (WHERE motivo IS NULL)     AS cargadas,
       count(*) FILTER (WHERE motivo IS NOT NULL) AS rechazadas
FROM stg_libro;

SELECT linea_csv AS linea, motivo, contenido
FROM stg_libro
WHERE motivo IS NOT NULL
ORDER BY linea_csv;
