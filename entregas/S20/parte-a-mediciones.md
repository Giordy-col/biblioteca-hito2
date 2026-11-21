# S20 · Parte A · Tabla de mediciones y respuestas

Grupo: Juan Esteban Mina (2518466), Cristian Camilo Criollo (2517199), Giordy Santiago Arcila (2242797), Jairo A. Tegüé Gómez (2416227).

Script: `entregas/S20/parte-a.sql` sobre el esquema `rendimiento` (`S20-rendimiento.sql`).
Cada consulta se corrió 3 veces con `EXPLAIN ANALYZE`; se anota el `Execution Time` típico (la mediana de las 3). Medido en PostgreSQL 16.

## Tabla de mediciones

| Consulta | Sin índices | Con índices (A2) | Desnormalizada (A3 o A4) |
|---|---|---|---|
| Catálogo (`Libro 12%`, 111 títulos) | 21,0 ms | 3,1 ms | 0,35 ms (columna `disponibles`) |
| Top 20 más prestados | 105,4 ms | (no aplica) | 0,005 ms (vista materializada) |

Mediciones individuales: catálogo sin índices 22,2 / 20,5 / 21,0 ms; con índices 3,2 / 3,1 / 3,0 ms; con la columna 0,35 / 0,34 / 0,35 ms. Top 20 directo 105,4 / 105,4 / 116,7 ms; vista materializada 0,012 / 0,005 / 0,005 ms.

## Respuestas

**A1.** (a) `LEFT JOIN` para no perder los ejemplares sin préstamo abierto, y `count(p.id)` porque cuenta solo los no nulos: un ejemplar sin préstamo suma 0. Con `count(*)` sumaría 1 y todos los libros saldrían con 0 disponibles. (c) El nodo más costoso es `Seq Scan on prestamo p` con `Filter: (fecha_devolucion IS NULL)`: recorre toda la tabla y descarta **300 000 filas** (`Rows Removed by Filter`) para quedarse con 3 750. Se lleva casi todo el tiempo.

**A2.** El `Seq Scan on prestamo` pasó a `Index Scan using prestamo_abierto_idx`, dentro de un `Nested Loop`: por cada ejemplar (333) busca en el índice su préstamo abierto. El tiempo bajó de 21,0 a 3,1 ms (cerca de 7 veces) y **no se agregó ninguna redundancia al modelo**. El índice lo mantiene el DBMS y no puede desincronizarse.

**A3.** (a) Predicción: 3 750 libros con 2 disponibles y 1 250 con 3. Entre 3i-2, 3i-1 y 3i hay a lo sumo un múltiplo de 4, y hay 3 750 múltiplos de 4. Así salió. (c) Después del `INSERT` del préstamo 400001, `descuadre` devuelve `9780000000001 | 3 | 2`. (d) Usaríamos un **trigger** sobre `prestamo`: insertar un préstamo abierto resta 1 y registrar la devolución suma 1. Así la copia queda al día sin depender de quien escriba. Hasta el Hito 4 la aplicación lo actualiza en la misma transacción, y `descuadre` queda como verificación. Una vista materializada no sirve, porque el catálogo debe estar al día en el momento de prestar.

**A4.** (c) Sin refrescar, `top_prestados` sigue mostrando a Libro 1 (3 881) de primero; la consulta directa ya muestra a Libro 5000 con 4 021. Después del `REFRESH`, Libro 5000 aparece de primero. (d) Refrescarla una vez al día (de noche) o cuando el bibliotecario abre el reporte. Nadie toma decisiones por un préstamo de diferencia, así que un atraso de horas es aceptable. Refrescarla en cada préstamo no tiene sentido: cuesta lo mismo que la consulta original.

**A5.** Si el plazo nunca cambia, `fecha_esperada = fecha_prestamo + 14` es un dato derivado y guardarla es redundante: podría ser una columna generada. Si la biblioteca puede cambiar el plazo o dar plazos especiales, la fecha esperada de cada préstamo es un **hecho histórico** del préstamo (depende de `id_prestamo`, no de la regla actual). Guardarla es correcto en 3FN, y recalcularla con una regla nueva cambiaría la mora de los préstamos viejos. En el proyecto aplica el segundo caso.

**Conclusión.** En el catálogo, el índice da casi toda la mejora sin redundancia. La columna desnormalizada gana otro orden de magnitud, pero sobre unos pocos milisegundos que nadie nota. El top 20 no se arregla con un índice, porque tiene que contar todos los préstamos; ahí la vista materializada sí se justifica.
