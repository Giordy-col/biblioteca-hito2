-- =====================================================================
-- S16. Taller de consultas complejas · Parte A (esquema tienda)
-- Uso:
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S16-tienda.sql
--   docker compose exec postgres psql -U curso -d curso -f /entregas/S16/consultas.sql
--   (o copiar este archivo a postgres/scripts/ y correrlo desde /scripts/)
-- "Sin cancelados" = se excluyen los pedidos con estado = 'cancelado'.
-- Valor de una línea = cantidad * precio_unitario (no producto.precio).
-- =====================================================================

SET search_path TO tienda;

-- ---------------------------------------------------------------------
-- Ejercicio 1. Pedido 1003: cliente, producto, cantidad y subtotal.
-- Join de 4 tablas. Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT c.nombre                         AS cliente,
       pr.nombre                        AS producto,
       d.cantidad,
       d.cantidad * d.precio_unitario   AS subtotal
FROM pedido p
JOIN cliente  c  ON c.id_cliente   = p.id_cliente
JOIN detalle  d  ON d.id_pedido    = p.id_pedido
JOIN producto pr ON pr.id_producto = d.id_producto
WHERE p.id_pedido = 1003;

-- ---------------------------------------------------------------------
-- Ejercicio 2. Cada cliente con el nombre de quien lo refirió.
-- Self-join externo: LEFT JOIN para que salgan los que llegaron solos
-- (su columna referido_por sale vacía). Filas esperadas: 8
-- ---------------------------------------------------------------------
SELECT c.id_cliente,
       c.nombre       AS cliente,
       r.nombre       AS referido_por
FROM cliente c
LEFT JOIN cliente r ON r.id_cliente = c.referido_por
ORDER BY c.id_cliente;

-- ---------------------------------------------------------------------
-- Ejercicio 3. Productos que nunca se han vendido (ni en cancelados).
-- Anti-join con NOT EXISTS. Filas esperadas: 1 (Taza de cerámica)
-- ---------------------------------------------------------------------
SELECT pr.id_producto, pr.nombre
FROM producto pr
WHERE NOT EXISTS (SELECT 1
                  FROM detalle d
                  WHERE d.id_producto = pr.id_producto);

-- ---------------------------------------------------------------------
-- Ejercicio 4. Número de pedidos por cliente (todos, incluso cancelados),
-- con 0 para quien no tiene. count(p.id_pedido) y no count(*): con
-- count(*) el cliente sin pedidos contaría 1 (la fila del LEFT JOIN).
-- Filas esperadas: 8 (Jorge Salazar con 0)
-- ---------------------------------------------------------------------
SELECT c.id_cliente, c.nombre, count(p.id_pedido) AS num_pedidos
FROM cliente c
LEFT JOIN pedido p ON p.id_cliente = c.id_cliente
GROUP BY c.id_cliente, c.nombre
ORDER BY num_pedidos DESC, c.nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 5. Total vendido por categoría, sin cancelados, de mayor a menor.
-- Filas esperadas: 3 (Grano 480000, Accesorio 376000, Molido 184000)
-- ---------------------------------------------------------------------
SELECT pr.categoria, sum(d.cantidad * d.precio_unitario) AS total
FROM detalle d
JOIN pedido   p  ON p.id_pedido    = d.id_pedido
JOIN producto pr ON pr.id_producto = d.id_producto
WHERE p.estado <> 'cancelado'
GROUP BY pr.categoria
ORDER BY total DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 6. Meses de 2026 con ventas (sin cancelados) > $200 000.
-- WHERE filtra filas (año, cancelados); HAVING filtra grupos (el total).
-- Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT extract(month FROM p.fecha)          AS mes,
       sum(d.cantidad * d.precio_unitario)  AS total
FROM pedido p
JOIN detalle d ON d.id_pedido = p.id_pedido
WHERE p.estado <> 'cancelado'
  AND extract(year FROM p.fecha) = 2026
GROUP BY extract(month FROM p.fecha)
HAVING sum(d.cantidad * d.precio_unitario) > 200000
ORDER BY mes;

-- ---------------------------------------------------------------------
-- Ejercicio 7. Productos con precio mayor que el promedio de SU categoría.
-- Subconsulta correlacionada. Filas esperadas: 4
-- ---------------------------------------------------------------------
SELECT pr.nombre, pr.categoria, pr.precio
FROM producto pr
WHERE pr.precio > (SELECT avg(p2.precio)
                   FROM producto p2
                   WHERE p2.categoria = pr.categoria)
ORDER BY pr.categoria, pr.precio DESC;

-- ---------------------------------------------------------------------
-- Ejercicio 8. Clientes de Cali que compraron al menos un accesorio,
-- sin cancelados. EXISTS garantiza que cada cliente sale una sola vez
-- (un join daría una fila por cada línea de accesorio). Filas esperadas: 2
-- ---------------------------------------------------------------------
SELECT c.id_cliente, c.nombre
FROM cliente c
WHERE c.ciudad = 'Cali'
  AND EXISTS (SELECT 1
              FROM pedido p
              JOIN detalle  d  ON d.id_pedido    = p.id_pedido
              JOIN producto pr ON pr.id_producto = d.id_producto
              WHERE p.id_cliente = c.id_cliente
                AND p.estado <> 'cancelado'
                AND pr.categoria = 'Accesorio');

-- ---------------------------------------------------------------------
-- Ejercicio 9. La trampa de NOT IN.
--
-- Consulta original (devuelve 0 filas):
--   SELECT nombre FROM cliente
--   WHERE id_cliente NOT IN (SELECT referido_por FROM cliente);
--
-- Por qué: la subconsulta devuelve {NULL, NULL, NULL, NULL, 1, 1, 4, 3},
-- porque los 4 clientes que llegaron solos tienen referido_por = NULL.
-- "x NOT IN (a, b, NULL)" equivale a "x <> a AND x <> b AND x <> NULL".
-- x <> NULL es UNKNOWN (no TRUE ni FALSE) en la lógica de tres valores
-- de SQL, así que el AND completo nunca puede ser TRUE: es FALSE (si x
-- está en la lista) o UNKNOWN (si no está). El WHERE solo deja pasar
-- filas TRUE, por eso no sale ningún cliente.
--
-- Corrección (a): NOT EXISTS, que no se afecta por los NULL porque solo
-- pregunta si existe alguna fila que cumpla la igualdad.
-- Filas esperadas: 5 (clientes 2, 5, 6, 7, 8)
-- ---------------------------------------------------------------------
SELECT c.nombre
FROM cliente c
WHERE NOT EXISTS (SELECT 1
                  FROM cliente r
                  WHERE r.referido_por = c.id_cliente)
ORDER BY c.nombre;

-- Corrección (b), equivalente: filtrar el NULL dentro del NOT IN.
SELECT nombre
FROM cliente
WHERE id_cliente NOT IN (SELECT referido_por
                         FROM cliente
                         WHERE referido_por IS NOT NULL)
ORDER BY nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 10. El o los clientes que más han gastado (sin cancelados).
-- Se compara contra el máximo de los totales, así salen todos los
-- empatados (LIMIT 1 dejaría uno por fuera). Filas esperadas: 2
-- ---------------------------------------------------------------------
WITH gasto AS (
    SELECT c.id_cliente, c.nombre,
           sum(d.cantidad * d.precio_unitario) AS total
    FROM cliente c
    JOIN pedido  p ON p.id_cliente = c.id_cliente
    JOIN detalle d ON d.id_pedido  = p.id_pedido
    WHERE p.estado <> 'cancelado'
    GROUP BY c.id_cliente, c.nombre
)
SELECT id_cliente, nombre, total
FROM gasto
WHERE total = (SELECT max(total) FROM gasto)
ORDER BY nombre;

-- ---------------------------------------------------------------------
-- Ejercicio 11. Clientes que compraron TODOS los productos de Grano,
-- sin cancelados. División con NOT EXISTS doble:
-- "no existe un producto de Grano que el cliente no haya comprado".
-- Filas esperadas: 2 (Laura Ortiz y Felipe Cárdenas).
-- Andrés compró Nariño y Cauca solo en el pedido 1013, que está
-- cancelado, así que no completa la categoría.
-- ---------------------------------------------------------------------
SELECT c.id_cliente, c.nombre
FROM cliente c
WHERE NOT EXISTS (
        SELECT 1
        FROM producto pr
        WHERE pr.categoria = 'Grano'
          AND NOT EXISTS (
                SELECT 1
                FROM pedido p
                JOIN detalle d ON d.id_pedido = p.id_pedido
                WHERE p.id_cliente  = c.id_cliente
                  AND d.id_producto = pr.id_producto
                  AND p.estado <> 'cancelado'))
ORDER BY c.nombre;


-- =====================================================================
-- RETOS (opcionales)
-- =====================================================================

-- R1. Ejercicio 11 con conteo.
-- Hay que usar count(DISTINCT d.id_producto): Felipe compró el Huila (101)
-- en dos pedidos (1005 y 1014). Con count(*) un cliente que haya comprado
-- 3 líneas de Grano repitiendo un producto contaría 3 sin tener los 3
-- productos distintos. Además el JOIN interno con producto en Grano
-- excluye a clientes que no compraron nada de Grano.
SELECT c.id_cliente, c.nombre
FROM cliente c
JOIN pedido   p  ON p.id_cliente   = c.id_cliente
JOIN detalle  d  ON d.id_pedido    = p.id_pedido
JOIN producto pr ON pr.id_producto = d.id_producto
WHERE p.estado <> 'cancelado'
  AND pr.categoria = 'Grano'
GROUP BY c.id_cliente, c.nombre
HAVING count(DISTINCT d.id_producto) = (SELECT count(*)
                                        FROM producto
                                        WHERE categoria = 'Grano')
ORDER BY c.nombre;

-- Con count(*) en lugar de count(DISTINCT ...): Felipe tiene 4 líneas de
-- Grano (101, 102, 103 en 1005 y 101 otra vez en 1014) -> 4 <> 3, y
-- desaparece del resultado aunque sí compró los tres. Laura tiene
-- 101, 102 (1001) y 103 (1003) = 3, sale. Resultado: solo 1 fila (mal).
SELECT c.id_cliente, c.nombre, count(*) AS lineas_grano
FROM cliente c
JOIN pedido   p  ON p.id_cliente   = c.id_cliente
JOIN detalle  d  ON d.id_pedido    = p.id_pedido
JOIN producto pr ON pr.id_producto = d.id_producto
WHERE p.estado <> 'cancelado'
  AND pr.categoria = 'Grano'
GROUP BY c.id_cliente, c.nombre
HAVING count(*) = (SELECT count(*) FROM producto WHERE categoria = 'Grano');

-- R2. Con una categoría sin productos (p. ej. 'Té'):
--  * NOT EXISTS doble: el "para todo" sobre un conjunto vacío es
--    verdadero, así que devuelve LOS 8 CLIENTES (verdad vacía).
--  * Conteo: el JOIN con producto en esa categoría no deja ninguna fila,
--    no se forma ningún grupo y devuelve 0 filas (aunque 0 = 0).
-- Las dos formulaciones solo coinciden cuando el divisor no es vacío.
SELECT count(*) AS r2_not_exists   -- 8
FROM cliente c
WHERE NOT EXISTS (
        SELECT 1 FROM producto pr
        WHERE pr.categoria = 'Té'
          AND NOT EXISTS (
                SELECT 1 FROM pedido p
                JOIN detalle d ON d.id_pedido = p.id_pedido
                WHERE p.id_cliente = c.id_cliente
                  AND d.id_producto = pr.id_producto
                  AND p.estado <> 'cancelado'));

SELECT c.id_cliente, c.nombre       -- 0 filas
FROM cliente c
JOIN pedido   p  ON p.id_cliente   = c.id_cliente
JOIN detalle  d  ON d.id_pedido    = p.id_pedido
JOIN producto pr ON pr.id_producto = d.id_producto
WHERE p.estado <> 'cancelado' AND pr.categoria = 'Té'
GROUP BY c.id_cliente, c.nombre
HAVING count(DISTINCT d.id_producto) = (SELECT count(*) FROM producto WHERE categoria = 'Té');

-- R3. Cada cliente referido: ¿gastó más o menos que quien lo refirió?
-- LEFT JOIN + coalesce para que quien no ha comprado nada cuente 0.
WITH gasto AS (
    SELECT c.id_cliente,
           coalesce(sum(d.cantidad * d.precio_unitario), 0) AS total
    FROM cliente c
    LEFT JOIN pedido  p ON p.id_cliente = c.id_cliente AND p.estado <> 'cancelado'
    LEFT JOIN detalle d ON d.id_pedido  = p.id_pedido
    GROUP BY c.id_cliente
)
SELECT c.nombre  AS referido,   gc.total AS total_referido,
       r.nombre  AS referidor,  gr.total AS total_referidor,
       CASE WHEN gc.total > gr.total THEN 'más'
            WHEN gc.total < gr.total THEN 'menos'
            ELSE 'igual' END AS comparacion
FROM cliente c
JOIN cliente r  ON r.id_cliente  = c.referido_por
JOIN gasto   gc ON gc.id_cliente = c.id_cliente
JOIN gasto   gr ON gr.id_cliente = r.id_cliente
ORDER BY c.id_cliente;
