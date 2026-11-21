-- =====================================================================
-- S20 · Hito 3 · Verificación de ejemplares.estado = 'prestado'
--
-- Crea (o reemplaza) la vista ejemplares_descuadre en la base del grupo SIN
-- borrar datos (01_esquema.sql ya la crea en una base nueva), la consulta y
-- luego simula a alguien que registra un préstamo y olvida actualizar el
-- estado del ejemplar, para mostrar que la vista lo detecta. La simulación
-- se deshace con ROLLBACK: la base queda igual que antes.
--
-- Uso (después de datos-prueba.sql):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/verificacion-ejemplares.sql
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

CREATE OR REPLACE VIEW ejemplares_descuadre AS
SELECT e.id_ejemplar,
       e.codigo_inventario,
       e.estado                                   AS estado_guardado,
       CASE WHEN a.abierto THEN 'prestado'
            ELSE 'no prestado' END                AS segun_prestamos
FROM   ejemplares e
CROSS JOIN LATERAL (
       SELECT EXISTS (SELECT 1
                      FROM   prestamos p
                      WHERE  p.ejemplar_id = e.id_ejemplar
                        AND  NOT EXISTS (SELECT 1 FROM devoluciones d
                                         WHERE d.prestamo_id = p.id_prestamo)) AS abierto
) a
WHERE  (e.estado = 'prestado') <> a.abierto;

\echo '== 1. Estado actual (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;

\echo '== 2. Simulación: préstamo registrado sin actualizar el ejemplar (esperado: 1 fila)'
BEGIN;

INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE, CURRENT_DATE + 14,
       (SELECT id_ejemplar FROM ejemplares WHERE codigo_inventario = '9780000000032-001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '1000000020'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001');

SELECT * FROM ejemplares_descuadre;

\echo '== 3. Simulación: devolución registrada sin actualizar el ejemplar (esperado: 2 filas)'
INSERT INTO devoluciones (fecha_devolucion, prestamo_id)
SELECT CURRENT_DATE, p.id_prestamo
FROM   prestamos p
JOIN   ejemplares e ON e.id_ejemplar = p.ejemplar_id
WHERE  e.codigo_inventario = '9780000000017-001'
  AND  NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.prestamo_id = p.id_prestamo);

SELECT * FROM ejemplares_descuadre ORDER BY id_ejemplar;

ROLLBACK;

\echo '== 4. Después del ROLLBACK (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;
