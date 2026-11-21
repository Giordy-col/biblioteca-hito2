-- =====================================================================
-- S20 · Parte A · Medir, indexar, desnormalizar (esquema rendimiento)
--
-- Requiere haber corrido antes S20-rendimiento.sql (borra y recrea el
-- esquema, así que se puede volver a empezar cuando se quiera).
--
-- Uso: abrir psql y pegar bloque por bloque, o correr todo de una:
--   docker compose exec postgres psql -U curso -d curso -f /scripts/parte-a.sql
-- Cada EXPLAIN ANALYZE está 3 veces: anotar el Execution Time típico.
-- =====================================================================

SET search_path TO rendimiento;

-- ---------------------------------------------------------------------
-- A1. Consulta del catálogo, sin índices
-- ---------------------------------------------------------------------
\echo '== A1. Catálogo sin índices (x3)'
EXPLAIN ANALYZE
SELECT l.isbn, l.titulo, count(e.id_ejemplar) - count(p.id) AS disponibles
FROM   libro l
JOIN   ejemplar e      ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar
                      AND p.fecha_devolucion IS NULL
WHERE  l.titulo LIKE 'Libro 12%'
GROUP BY l.isbn, l.titulo;
\g
\g

-- ---------------------------------------------------------------------
-- A4 (a). Top 20 más prestados, sin vista materializada
--   (se mide aquí, antes de A3/A4, sobre los datos originales)
-- ---------------------------------------------------------------------
\echo '== A4 (a). Top 20 directo (x3)'
EXPLAIN ANALYZE
SELECT   l.isbn, l.titulo, count(*) AS prestamos
FROM     prestamo p
JOIN     ejemplar e ON e.id_ejemplar = p.id_ejemplar
JOIN     libro    l ON l.isbn = e.isbn
GROUP BY l.isbn, l.titulo
ORDER BY prestamos DESC
FETCH FIRST 20 ROWS WITH TIES;
\g
\g

-- ---------------------------------------------------------------------
-- A2. Índices (los dos de la sección 4) y repetir A1
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ejemplar_isbn_idx    ON ejemplar (isbn);
CREATE INDEX IF NOT EXISTS prestamo_abierto_idx ON prestamo (id_ejemplar)
       WHERE fecha_devolucion IS NULL;
ANALYZE;

\echo '== A2. Catálogo con índices (x3)'
EXPLAIN ANALYZE
SELECT l.isbn, l.titulo, count(e.id_ejemplar) - count(p.id) AS disponibles
FROM   libro l
JOIN   ejemplar e      ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar
                      AND p.fecha_devolucion IS NULL
WHERE  l.titulo LIKE 'Libro 12%'
GROUP BY l.isbn, l.titulo;
\g
\g

-- ---------------------------------------------------------------------
-- A3. Desnormalizar libro.disponibles
-- Predicción: 3 750 libros con 2 disponibles y 1 250 con 3
-- (en 3i-2, 3i-1, 3i hay a lo sumo un múltiplo de 4).
-- ---------------------------------------------------------------------
ALTER TABLE libro ADD COLUMN disponibles smallint;   -- sin NOT NULL todavía: hay filas

UPDATE libro l
SET    disponibles =
         (SELECT count(*) FROM ejemplar e WHERE e.isbn = l.isbn)
       - (SELECT count(*) FROM prestamo p JOIN ejemplar e ON e.id_ejemplar = p.id_ejemplar
          WHERE  e.isbn = l.isbn AND p.fecha_devolucion IS NULL);

ALTER TABLE libro ALTER COLUMN disponibles SET NOT NULL,
                  ADD CONSTRAINT libro_disponibles_check CHECK (disponibles >= 0);

\echo '== A3 (a). Comprobar la predicción (esperado 2: 3750, 3: 1250)'
SELECT disponibles, count(*) FROM libro GROUP BY 1 ORDER BY 1;

\echo '== A3 (b). Catálogo con la columna (x3)'
EXPLAIN ANALYZE
SELECT isbn, titulo, disponibles FROM libro WHERE titulo LIKE 'Libro 12%';
\g
\g

-- A3 (c). Vista que detecta la copia desincronizada
CREATE VIEW descuadre AS
SELECT   l.isbn, l.disponibles AS guardado,
         count(e.id_ejemplar) - count(p.id) AS calculado
FROM     libro l
JOIN     ejemplar e    ON e.isbn = l.isbn
LEFT JOIN prestamo p   ON p.id_ejemplar = e.id_ejemplar AND p.fecha_devolucion IS NULL
GROUP BY l.isbn, l.disponibles
HAVING   l.disponibles <> count(e.id_ejemplar) - count(p.id);

\echo '== A3 (c). descuadre antes del préstamo olvidado (esperado: 0 filas)'
SELECT * FROM descuadre;

-- alguien registra un préstamo y olvida actualizar libro.disponibles
INSERT INTO prestamo VALUES (400001, 1, '1000000001', CURRENT_DATE, CURRENT_DATE + 14, NULL);

\echo '== A3 (c). descuadre después (esperado: 9780000000001 | 3 | 2)'
SELECT * FROM descuadre;

-- ---------------------------------------------------------------------
-- A4. Top 20 como vista materializada
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW top_prestados AS
SELECT   l.isbn, l.titulo, count(*) AS prestamos
FROM     prestamo p
JOIN     ejemplar e ON e.id_ejemplar = p.id_ejemplar
JOIN     libro    l ON l.isbn = e.isbn
GROUP BY l.isbn, l.titulo
ORDER BY prestamos DESC
FETCH FIRST 20 ROWS WITH TIES;

\echo '== A4 (b). Leer la vista materializada (x3)'
EXPLAIN ANALYZE SELECT * FROM top_prestados;
\g
\g

-- A4 (c). Un mes de mucho movimiento del Libro 5000 (ejemplar 15000)
INSERT INTO prestamo
SELECT 500000 + g, 15000, (1000000001 + g % 2000)::text,
       DATE '2025-06-01', DATE '2025-06-15', DATE '2025-06-10'
FROM   generate_series(1, 4000) AS g;

\echo '== A4 (c). Vista SIN refrescar (Libro 1 sigue de primero)'
SELECT * FROM top_prestados LIMIT 3;

\echo '== A4 (c). Consulta directa (Libro 5000 ya va de primero con 4021)'
SELECT   l.isbn, l.titulo, count(*) AS prestamos
FROM     prestamo p
JOIN     ejemplar e ON e.id_ejemplar = p.id_ejemplar
JOIN     libro    l ON l.isbn = e.isbn
GROUP BY l.isbn, l.titulo
ORDER BY prestamos DESC
LIMIT 3;

REFRESH MATERIALIZED VIEW top_prestados;

\echo '== A4 (c). Vista DESPUÉS del REFRESH (Libro 5000 de primero)'
SELECT * FROM top_prestados LIMIT 3;
