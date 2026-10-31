-- =====================================================================
-- S16 · Parte B · Los 4 reportes del proyecto (esquema biblioteca)
--
-- Uso (después de datos-prueba.sql):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
--
-- Cada reporte queda guardado como VISTA (para la API de M7) y luego se
-- consulta con SELECT * FROM <vista>. Se puede correr cuantas veces se quiera.
--
-- Cómo se recorre nuestro esquema:
--   prestamos.ejemplar_id -> ejemplares.libro_id -> libros   (el préstamo es de un ejemplar)
--   prestamos.lector_id   -> usuarios (nombre, correo, telefono)
--   devuelto  = existe una fila en devoluciones con ese prestamo_id
--   abierto   = no existe esa fila
--   en mora   = abierto y fecha_esperada < CURRENT_DATE
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

-- ---------------------------------------------------------------------
-- Reporte 1. Los 20 libros más prestados.
--
-- Qué devuelve: título, ISBN, número de préstamos y puesto.
-- Decisiones del grupo:
--   * Se cuentan TODOS los préstamos del libro (devueltos y abiertos), sumando
--     los de todos sus ejemplares (por eso se agrupa por libro, no por ejemplar).
--   * Empates: se usa rank(); si el puesto 20 está empatado, salen todos los
--     empatados (el reporte puede tener más de 20 filas).
--   * Libros sin préstamos: el LEFT JOIN los cuenta con 0. Solo aparecen si
--     entran en los 20 primeros puestos (si hubiera menos de 20 libros
--     prestados); con nuestros datos no aparecen porque los puestos ya están
--     llenos de libros con al menos 1 préstamo.
-- Esperado con datos-prueba.sql: 21 filas. Cien años de soledad (3) en el
--   puesto 1; El amor en los tiempos del cólera, Don Quijote y 1984 (2) en el
--   puesto 2; 17 libros con 1 préstamo empatados en el puesto 5.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporte_top_libros AS
SELECT puesto, titulo, isbn, prestamos
FROM (
    SELECT l.titulo,
           l.isbn,
           count(p.id_prestamo)                              AS prestamos,
           rank() OVER (ORDER BY count(p.id_prestamo) DESC)  AS puesto
    FROM libros l
    LEFT JOIN ejemplares e ON e.libro_id    = l.id_libro
    LEFT JOIN prestamos  p ON p.ejemplar_id = e.id_ejemplar
    GROUP BY l.id_libro, l.titulo, l.isbn
) t
WHERE puesto <= 20
ORDER BY puesto, titulo;

\echo '== Reporte 1. Los 20 libros más prestados'
SELECT * FROM reporte_top_libros;

-- ---------------------------------------------------------------------
-- Reporte 2. El o los lectores que más libros han leído.
--
-- Qué devuelve: documento, nombre y número de libros leídos.
-- Decisiones del grupo:
--   * "Leído" = préstamo DEVUELTO (con fila en devoluciones). Los préstamos
--     abiertos no cuentan, así que un lector con muchos préstamos abiertos y
--     ninguno devuelto no sale.
--   * Se cuentan libros distintos (count DISTINCT libro_id): si un lector
--     devuelve dos veces el mismo libro, cuenta como un libro leído.
--   * Empates: se compara contra el máximo, así salen todos los empatados.
-- Esperado con datos-prueba.sql: 2 filas, Mariana Gómez Rojas y Santiago
--   Rodríguez Pérez con 4. Valentina López Díaz (5 abiertos) no sale.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporte_mas_lectores AS
WITH leidos AS (
    SELECT u.id_usuario, u.documento, u.nombre,
           count(DISTINCT e.libro_id) AS libros_leidos
    FROM usuarios u
    JOIN prestamos    p  ON p.lector_id    = u.id_usuario
    JOIN devoluciones dv ON dv.prestamo_id = p.id_prestamo
    JOIN ejemplares   e  ON e.id_ejemplar  = p.ejemplar_id
    GROUP BY u.id_usuario, u.documento, u.nombre
)
SELECT documento, nombre, libros_leidos
FROM leidos
WHERE libros_leidos = (SELECT max(libros_leidos) FROM leidos)
ORDER BY nombre;

\echo '== Reporte 2. El o los lectores que más libros han leído'
SELECT * FROM reporte_mas_lectores;

-- ---------------------------------------------------------------------
-- Reporte 3. Lectores morosos, cada uno una sola vez.
--
-- Qué devuelve: documento, nombre, correo, teléfono y cuántos préstamos
-- tiene en mora.
-- Decisiones del grupo:
--   * Mora = préstamo SIN devolución y fecha_esperada < CURRENT_DATE.
--     Usamos "<": el préstamo que vence HOY todavía no está en mora (el
--     lector tiene todo el día para devolverlo).
--   * Un préstamo devuelto tarde no es mora: ya se devolvió.
--   * Se agrupa por lector, así cada moroso sale una vez aunque tenga
--     varios préstamos en mora.
-- Esperado con datos-prueba.sql: 2 filas, Isabella Ramírez Castro (2 en mora)
--   y Andrés Felipe Vargas Ortiz (1). No salen Camila (devolvió tarde),
--   Sebastián (vence hoy), Valentina (abiertos sin vencer) ni Óscar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporte_morosos AS
SELECT u.documento, u.nombre, u.correo, u.telefono,
       count(*) AS prestamos_en_mora
FROM usuarios u
JOIN prestamos p ON p.lector_id = u.id_usuario
WHERE p.fecha_esperada < CURRENT_DATE
  AND NOT EXISTS (SELECT 1 FROM devoluciones dv
                  WHERE dv.prestamo_id = p.id_prestamo)
GROUP BY u.id_usuario, u.documento, u.nombre, u.correo, u.telefono
ORDER BY u.nombre;

\echo '== Reporte 3. Lectores morosos'
SELECT * FROM reporte_morosos;

-- ---------------------------------------------------------------------
-- Reporte 4. Préstamos en mora (la lista del botón "Enviar notificación").
--
-- Qué devuelve: una fila por PRÉSTAMO en mora, con nombre, correo y
-- teléfono del lector, el libro, el ejemplar, las fechas y los días de mora.
-- Decisiones del grupo: la misma regla de mora del reporte 3 ("<", sin
-- devolución). Un lector con dos préstamos en mora sale dos veces.
-- Esperado con datos-prueba.sql: 3 filas. Isabella Ramírez Castro dos veces
--   (El principito, 26 días; Matilda, 16 días) y Andrés Felipe Vargas Ortiz
--   una vez (Alicia en el país de las maravillas, 6 días).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW reporte_prestamos_mora AS
SELECT p.id_prestamo,
       u.nombre                         AS lector,
       u.correo,
       u.telefono,
       l.titulo,
       e.codigo_inventario,
       p.fecha_prestamo,
       p.fecha_esperada,
       CURRENT_DATE - p.fecha_esperada  AS dias_mora
FROM prestamos p
JOIN usuarios   u ON u.id_usuario  = p.lector_id
JOIN ejemplares e ON e.id_ejemplar = p.ejemplar_id
JOIN libros     l ON l.id_libro    = e.libro_id
WHERE p.fecha_esperada < CURRENT_DATE
  AND NOT EXISTS (SELECT 1 FROM devoluciones dv
                  WHERE dv.prestamo_id = p.id_prestamo)
ORDER BY dias_mora DESC, u.nombre;

\echo '== Reporte 4. Préstamos en mora'
SELECT * FROM reporte_prestamos_mora;

-- ---------------------------------------------------------------------
-- Comprobaciones extra de los casos de prueba (no son reportes)
-- ---------------------------------------------------------------------
\echo '== Caso 1. Libros sin ningún préstamo (no deben estar en el reporte 1)'
SELECT l.titulo
FROM libros l
WHERE NOT EXISTS (SELECT 1 FROM ejemplares e JOIN prestamos p ON p.ejemplar_id = e.id_ejemplar
                  WHERE e.libro_id = l.id_libro)
ORDER BY l.titulo;

\echo '== Caso 6. Préstamo abierto que vence hoy (no está en mora con la regla <)'
SELECT u.nombre, l.titulo, p.fecha_esperada
FROM prestamos p
JOIN usuarios u ON u.id_usuario = p.lector_id
JOIN ejemplares e ON e.id_ejemplar = p.ejemplar_id
JOIN libros l ON l.id_libro = e.libro_id
WHERE p.fecha_esperada = CURRENT_DATE
  AND NOT EXISTS (SELECT 1 FROM devoluciones dv WHERE dv.prestamo_id = p.id_prestamo);
