-- =====================================================================
-- Hito 4 · pruebas-programacion.sql · Biblioteca
-- Batería de pruebas de programacion.sql, al estilo de S22 parte A:
-- para cada regla, al menos un caso que pasa y uno que falla, con el
-- resultado esperado en un comentario.
--
-- Uso (después de datos-prueba.sql y programacion.sql):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/pruebas-programacion.sql
--
-- Los casos usan los lectores de datos-prueba.sql (S16):
--   1000000001 Mariana    4 libros devueltos, sin préstamos abiertos
--   1000000003 Valentina  5 préstamos abiertos, ninguno vencido   -> R3
--   1000000006 Sebastián  1 préstamo abierto que vence HOY        -> no es mora
--   1000000007 Isabella   2 préstamos en mora                     -> R2
--   1000000020 Óscar      sin préstamos                           -> caso feliz
--   9000000001            la bibliotecaria de prueba
--   Ejemplares: 9780000000017-001 prestado a Isabella; 9780000000032-001
--   (Harry Potter) disponible.
--
-- Todo lo que cambia datos se hace dentro de BEGIN ... ROLLBACK: al terminar
-- la base queda igual y el archivo se puede correr las veces que se quiera.
-- Las sentencias marcadas "debe fallar" dan ERROR a propósito, así que el
-- archivo no se detiene con los errores (ON_ERROR_STOP off).
-- =====================================================================

\set ON_ERROR_STOP off
SET search_path TO biblioteca, public;

\echo '== 0. Verificación inicial: ejemplares_descuadre (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;

-- ---------------------------------------------------------------------
-- R1. El lector existe, es lector y está activo (procedimiento)
-- ---------------------------------------------------------------------
\echo '== R1a. Lector que no existe (esperado: ERROR "no existe")'
CALL registrar_prestamo('1000000099', '9780000000032-001', '9000000001');      -- debe fallar

\echo '== R1b. Un bibliotecario como lector (esperado: ERROR "no es un lector")'
CALL registrar_prestamo('9000000001', '9780000000032-001', '9000000001');      -- debe fallar

\echo '== R1c. Lector inactivo (esperado: ERROR "no está activo")'
BEGIN;
UPDATE usuarios SET estado = 'inactivo' WHERE documento = '1000000020';
CALL registrar_prestamo('1000000020', '9780000000032-001', '9000000001');      -- debe fallar
ROLLBACK;

-- ---------------------------------------------------------------------
-- R2. Un lector en mora no puede tomar préstamos (procedimiento)
-- ---------------------------------------------------------------------
\echo '== R2a. Isabella, con 2 préstamos en mora (esperado: ERROR "está en mora")'
CALL registrar_prestamo('1000000007', '9780000000032-001', '9000000001');      -- debe fallar

\echo '== R2b. Sebastián, su préstamo vence HOY: no es mora (esperado: préstamo registrado)'
BEGIN;
CALL registrar_prestamo('1000000006', '9780000000032-001', '9000000001');      -- pasa
ROLLBACK;

-- ---------------------------------------------------------------------
-- R3. Máximo 3 préstamos abiertos (procedimiento)
-- ---------------------------------------------------------------------
\echo '== R3a. Valentina, con 5 abiertos (esperado: ERROR "ya tiene 5 préstamos abiertos")'
CALL registrar_prestamo('1000000003', '9780000000032-001', '9000000001');      -- debe fallar

\echo '== R3b. Óscar llega a 3 abiertos y el 4º se rechaza (esperado: 3 registrados y ERROR)'
BEGIN;
CALL registrar_prestamo('1000000020', '9780000000032-001', '9000000001');      -- pasa (1)
CALL registrar_prestamo('1000000020', '9780000000031-001', '9000000001');      -- pasa (2)
CALL registrar_prestamo('1000000020', '9780000000030-001', '9000000001');      -- pasa (3)
CALL registrar_prestamo('1000000020', '9780000000029-001', '9000000001');      -- debe fallar (4)
ROLLBACK;

-- ---------------------------------------------------------------------
-- R4. El ejemplar existe, no está perdido/de baja y no está prestado
-- ---------------------------------------------------------------------
\echo '== R4a. Ejemplar que no existe (esperado: ERROR "no existe")'
CALL registrar_prestamo('1000000020', '9780000000032-999', '9000000001');      -- debe fallar

\echo '== R4b. Ejemplar prestado a Isabella (esperado: ERROR "no está disponible")'
CALL registrar_prestamo('1000000020', '9780000000017-001', '9000000001');      -- debe fallar

\echo '== R4c. Ejemplar perdido (esperado: ERROR "está en estado perdido")'
BEGIN;
UPDATE ejemplares SET estado = 'perdido' WHERE codigo_inventario = '9780000000032-002';
CALL registrar_prestamo('1000000020', '9780000000032-002', '9000000001');      -- debe fallar
ROLLBACK;

\echo '== Plazo inválido (esperado: ERROR "El plazo debe ser positivo")'
CALL registrar_prestamo('1000000020', '9780000000032-001', '9000000001', 0);   -- debe fallar

-- ---------------------------------------------------------------------
-- Caso feliz completo: préstamo y devolución con los procedimientos.
-- El trigger AFTER mantiene ejemplares.estado (desnormalización del
-- Hito 3): consulta antes, operación, consulta después.
-- ---------------------------------------------------------------------
\echo '== 5. Préstamo y devolución de Óscar (esperado: disponible -> prestado -> disponible, descuadre 0)'
BEGIN;

\echo '-- 5a. Antes del préstamo: el ejemplar está disponible'
SELECT codigo_inventario, estado FROM ejemplares WHERE codigo_inventario = '9780000000032-001';

CALL registrar_prestamo('1000000020', '9780000000032-001', '9000000001');      -- pasa

\echo '-- 5b. Después del préstamo: el trigger lo pasó a prestado'
SELECT codigo_inventario, estado FROM ejemplares WHERE codigo_inventario = '9780000000032-001';
\echo '-- 5c. Descuadre (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;

SELECT max(id_prestamo) AS id_nuevo FROM prestamos \gset
CALL registrar_devolucion(:id_nuevo);                                          -- pasa

\echo '-- 5d. Después de la devolución: el trigger lo volvió a poner disponible'
SELECT codigo_inventario, estado FROM ejemplares WHERE codigo_inventario = '9780000000032-001';
\echo '-- 5e. Descuadre (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;
\echo '-- 5f. Auditoría: un registro del préstamo y uno de la devolución'
SELECT id_prestamo, accion FROM prestamo_auditoria WHERE id_prestamo = :id_nuevo ORDER BY id_auditoria;

\echo '-- 5g. Devolver otra vez el mismo préstamo (esperado: ERROR "ya fue devuelto")'
CALL registrar_devolucion(:id_nuevo);                                          -- debe fallar
ROLLBACK;

-- ---------------------------------------------------------------------
-- Devoluciones inválidas
-- ---------------------------------------------------------------------
\echo '== 6a. Préstamo que no existe (esperado: ERROR "no existe")'
CALL registrar_devolucion(99999);                                              -- debe fallar

\echo '== 6b. Fecha de devolución anterior al préstamo (esperado: ERROR "es anterior")'
SELECT p.id_prestamo AS id_isabella
FROM   prestamos p JOIN ejemplares e ON e.id_ejemplar = p.ejemplar_id
WHERE  e.codigo_inventario = '9780000000017-001'
  AND  NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.prestamo_id = p.id_prestamo) \gset
CALL registrar_devolucion(:id_isabella, CURRENT_DATE - 100);                   -- debe fallar

-- ---------------------------------------------------------------------
-- Trigger BEFORE: un INSERT directo (como si viniera de psql u otro
-- programa, sin pasar por el procedimiento) no se salta las reglas.
-- ---------------------------------------------------------------------
\echo '== 7a. INSERT directo para Isabella, en mora (esperado: ERROR del trigger "está en mora")'
INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE, CURRENT_DATE + 14,
       (SELECT id_ejemplar FROM ejemplares WHERE codigo_inventario = '9780000000032-001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '1000000007'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001');      -- debe fallar

\echo '== 7b. INSERT directo de un ejemplar ya prestado (esperado: ERROR del trigger "no está disponible")'
INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE, CURRENT_DATE + 14,
       (SELECT id_ejemplar FROM ejemplares WHERE codigo_inventario = '9780000000017-001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '1000000020'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001');      -- debe fallar

\echo '== 7c. INSERT directo con la bibliotecaria como lectora (esperado: ERROR del trigger "no es un lector activo")'
INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE, CURRENT_DATE + 14,
       (SELECT id_ejemplar FROM ejemplares WHERE codigo_inventario = '9780000000032-001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001');      -- debe fallar

\echo '== 7d. INSERT directo válido (esperado: pasa, y el trigger AFTER marca el ejemplar como prestado)'
BEGIN;
INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE, CURRENT_DATE + 14,
       (SELECT id_ejemplar FROM ejemplares WHERE codigo_inventario = '9780000000032-001'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '1000000020'),
       (SELECT id_usuario  FROM usuarios   WHERE documento = '9000000001');      -- pasa
SELECT codigo_inventario, estado FROM ejemplares WHERE codigo_inventario = '9780000000032-001';  -- prestado
SELECT * FROM ejemplares_descuadre;                                                              -- 0 filas
ROLLBACK;

\echo '== 7e. UPDATE de un préstamo abierto: renovar el de Sebastián 7 días (esperado: pasa)'
BEGIN;
UPDATE prestamos p SET fecha_esperada = fecha_esperada + 7
FROM   usuarios u
WHERE  u.id_usuario = p.lector_id AND u.documento = '1000000006'
  AND  NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.prestamo_id = p.id_prestamo);           -- pasa
ROLLBACK;

-- ---------------------------------------------------------------------
\echo '== 8. Verificación final: ejemplares_descuadre (esperado: 0 filas)'
SELECT * FROM ejemplares_descuadre;
