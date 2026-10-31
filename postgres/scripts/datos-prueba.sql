-- =====================================================================
-- S16 · Parte B · Datos de prueba para los 4 reportes (esquema biblioteca)
--
-- Requiere: 01_esquema.sql y las cargas semilla de S14
--   docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
--   docker compose exec postgres psql -U curso -d curso -f /scripts/carga-lectores.sql
-- Uso:
--   docker compose exec postgres psql -U curso -d curso -f /scripts/datos-prueba.sql
--
-- Se puede correr cuantas veces se quiera: BORRA todos los préstamos y
-- devoluciones y los vuelve a crear. Libros, ejemplares y lectores no se tocan
-- (solo el estado de los ejemplares prestados).
--
-- Todas las fechas son relativas a CURRENT_DATE, así la mora sigue siendo
-- mora el día de la sustentación. En cada fila:
--   p = hace cuántos días se prestó   -> fecha_prestamo = CURRENT_DATE - p
--   fecha_esperada = fecha_prestamo + 14 (regla de la biblioteca)
--   d = hace cuántos días se devolvió -> fecha_devolucion = CURRENT_DATE - d
--       (d NULL = préstamo abierto, sin devolución)
--
-- Notas sobre nuestro esquema (respuestas a las 4 preguntas de S16):
--   1. El préstamo apunta a un EJEMPLAR (prestamos.ejemplar_id), no al libro:
--      hay que pasar por ejemplares para llegar a libros.
--   2. Nombre, correo y teléfono del lector están en USUARIOS (rol = 'lector').
--   3. No hay columna de estado en prestamos: un préstamo está devuelto si
--      tiene fila en DEVOLUCIONES; si no, está abierto.
--   4. La fecha esperada está en prestamos.fecha_esperada.
--   Cada préstamo necesita un bibliotecario_id, así que se crea uno de prueba.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

BEGIN;

-- 0. Comprobar que están cargados los datos semilla que usamos
DO $$
BEGIN
  IF (SELECT count(*) FROM libros WHERE isbn LIKE '97800000000%') < 32
     OR (SELECT count(*) FROM usuarios WHERE documento LIKE '10000000%') < 20 THEN
    RAISE EXCEPTION 'Faltan libros o lectores semilla: correr primero carga-libros.sql y carga-lectores.sql';
  END IF;
END $$;

-- 1. Limpiar préstamos anteriores (devoluciones primero por la FK)
DELETE FROM devoluciones;
DELETE FROM prestamos;
UPDATE ejemplares SET estado = 'disponible' WHERE estado = 'prestado';

-- 2. Bibliotecario que registra los préstamos (no es lector, no presta libros)
INSERT INTO usuarios (documento, nombre, correo, telefono, username,
                      password_hash, rol, estado)
VALUES ('9000000001', 'Bibliotecaria de Prueba', 'biblioteca.prueba@correo-ejemplo.edu.co',
        '3009000001', 'biblio_prueba', crypt('9000000001', gen_salt('bf')),
        'bibliotecario', 'activo')
ON CONFLICT (documento) DO NOTHING;

-- 3. Los préstamos de prueba
--    isbn: los 13 dígitos del libro semilla; copia: número del ejemplar
--    (codigo_inventario = isbn-001, isbn-002, ...); documento: el lector.
CREATE TEMP TABLE prueba (isbn text, copia int, documento text, p int, d int, caso text)
ON COMMIT DROP;

INSERT INTO prueba VALUES
  -- Caso 3: Mariana (…01) y Santiago (…02) empatan en el 1er lugar con 4 libros leídos
  ('9780000000001', 1, '1000000001', 120, 110, 'caso 3'),
  ('9780000000002', 1, '1000000001', 100,  95, 'caso 3'),
  ('9780000000003', 1, '1000000001',  90,  80, 'caso 3'),
  ('9780000000004', 1, '1000000001',  70,  60, 'caso 3'),
  ('9780000000001', 2, '1000000002', 115, 105, 'caso 3'),
  ('9780000000005', 1, '1000000002',  95,  85, 'caso 3'),
  ('9780000000006', 1, '1000000002',  85,  80, 'caso 3'),
  ('9780000000007', 1, '1000000002',  65,  55, 'caso 3'),
  -- Relleno: Juan David (…04) 3 leídos, Laura (…09) 2, Daniel (…10) 1
  ('9780000000001', 3, '1000000004', 110, 100, 'relleno'),
  ('9780000000008', 1, '1000000004',  80,  70, 'relleno'),
  ('9780000000009', 1, '1000000004',  75,  65, 'relleno'),
  ('9780000000002', 2, '1000000009',  60,  50, 'relleno'),
  ('9780000000010', 1, '1000000009',  50,  45, 'relleno'),
  ('9780000000014', 2, '1000000010',  45,  35, 'relleno'),
  ('9780000000020', 1, '1000000011',  40,  30, 'relleno'),
  ('9780000000021', 1, '1000000012',  35,  25, 'relleno'),
  -- Caso 4: Valentina (…03) tiene 5 préstamos abiertos (más que los ganadores)
  --         pero ninguno devuelto; vencen dentro de 12 días (no están en mora)
  ('9780000000011', 1, '1000000003',   2, NULL, 'caso 4'),
  ('9780000000012', 1, '1000000003',   2, NULL, 'caso 4'),
  ('9780000000013', 1, '1000000003',   2, NULL, 'caso 4'),
  ('9780000000014', 1, '1000000003',   2, NULL, 'caso 4'),
  ('9780000000015', 1, '1000000003',   2, NULL, 'caso 4'),
  -- Caso 5: Camila (…05) devolvió 6 días tarde (esperada hace 46, devuelto hace 40)
  ('9780000000009', 2, '1000000005',  60,  40, 'caso 5'),
  -- Caso 6: Sebastián (…06) tiene un préstamo abierto que vence HOY (p = 14)
  ('9780000000016', 1, '1000000006',  14, NULL, 'caso 6'),
  -- Caso 7: Isabella (…07) tiene DOS préstamos en mora (vencieron hace 26 y 16 días)
  ('9780000000017', 1, '1000000007',  40, NULL, 'caso 7'),
  ('9780000000018', 1, '1000000007',  30, NULL, 'caso 7'),
  -- Otro moroso con un solo préstamo en mora: Andrés Felipe (…08), vencido hace 6 días
  ('9780000000019', 1, '1000000008',  20, NULL, 'mora simple');
  -- Caso 1: los libros 22 a 32 (p. ej. Harry Potter) nadie los presta.
  -- Caso 2: hay 21 libros con préstamos; del puesto 5 al 21 todos tienen 1
  --         préstamo, así que el puesto 20 está empatado con el 21 (y más).
  -- Caso 8: Óscar (…20) y los demás lectores sin fila aquí no tienen préstamos.

INSERT INTO prestamos (fecha_prestamo, fecha_esperada, ejemplar_id, lector_id, bibliotecario_id)
SELECT CURRENT_DATE - t.p,
       CURRENT_DATE - t.p + 14,
       e.id_ejemplar,
       u.id_usuario,
       (SELECT id_usuario FROM usuarios WHERE documento = '9000000001')
FROM prueba t
JOIN ejemplares e ON e.codigo_inventario = t.isbn || '-' || lpad(t.copia::text, 3, '0')
JOIN usuarios   u ON u.documento = t.documento
ORDER BY t.p DESC;

-- Las devoluciones de los que tienen d (se ubica el préstamo por ejemplar,
-- lector y fecha, que en estos datos es único)
INSERT INTO devoluciones (fecha_devolucion, prestamo_id)
SELECT CURRENT_DATE - t.d, pr.id_prestamo
FROM prueba t
JOIN ejemplares e ON e.codigo_inventario = t.isbn || '-' || lpad(t.copia::text, 3, '0')
JOIN usuarios   u ON u.documento = t.documento
JOIN prestamos pr ON pr.ejemplar_id = e.id_ejemplar
                 AND pr.lector_id = u.id_usuario
                 AND pr.fecha_prestamo = CURRENT_DATE - t.p
WHERE t.d IS NOT NULL;

-- Los ejemplares de préstamos abiertos quedan como 'prestado'
UPDATE ejemplares e SET estado = 'prestado'
WHERE EXISTS (SELECT 1 FROM prestamos pr
              WHERE pr.ejemplar_id = e.id_ejemplar
                AND NOT EXISTS (SELECT 1 FROM devoluciones dv
                                WHERE dv.prestamo_id = pr.id_prestamo));

-- 4. Verificar que entró todo (si falla, ningún cambio queda hecho)
DO $$
BEGIN
  IF (SELECT count(*) FROM prestamos) <> 26 OR (SELECT count(*) FROM devoluciones) <> 17 THEN
    RAISE EXCEPTION 'Se esperaban 26 préstamos y 17 devoluciones';
  END IF;
END $$;

COMMIT;

SELECT (SELECT count(*) FROM prestamos)    AS prestamos,
       (SELECT count(*) FROM devoluciones) AS devoluciones,
       (SELECT count(*) FROM ejemplares WHERE estado = 'prestado') AS ejemplares_prestados;

-- =====================================================================
-- RESULTADOS ESPERADOS (escritos antes de correr reportes.sql)
--
-- Reporte 1 (top 20 libros más prestados, con empates):
--   21 filas. 1º Cien años de soledad (3); 2º empatados El amor en los
--   tiempos del cólera, Don Quijote y 1984 (2 cada uno); del 5º puesto al 21
--   empatan 17 libros con 1 préstamo. Ningún libro con 0 (Harry Potter, etc.).
-- Reporte 2 (el o los que más han leído):
--   2 filas: Mariana Gómez Rojas y Santiago Rodríguez Pérez, 4 libros cada uno.
--   Valentina López Díaz (5 préstamos abiertos, 0 devueltos) NO sale.
-- Reporte 3 (lectores morosos, una vez cada uno):
--   2 filas: Isabella Ramírez Castro y Andrés Felipe Vargas Ortiz.
--   No salen Camila (devolvió tarde, caso 5), Sebastián (vence hoy, caso 6),
--   Valentina (abiertos sin vencer) ni Óscar (sin préstamos).
-- Reporte 4 (préstamos en mora):
--   3 filas: Isabella dos veces (Matilda y El principito) y Andrés Felipe
--   una vez (Alicia en el país de las maravillas), con correo y teléfono.
-- =====================================================================
