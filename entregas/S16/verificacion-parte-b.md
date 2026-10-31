# S16 · Parte B · Tabla de verificación de los reportes

Esquema: `biblioteca` (`postgres/init/01_esquema.sql`).
Datos: libros y lectores semilla (S14) + `postgres/scripts/datos-prueba.sql`.
Consultas: `postgres/scripts/reportes.sql` (cada reporte queda como vista).
Salida completa de `psql`: `entregas/S16/salida-reportes.txt`.

## Cómo reproducir

```bash
# desde la carpeta del entorno Docker
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/datos-prueba.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
```

## Qué cambia en nuestro esquema respecto a `reportes_demo`

| Pregunta | Respuesta en nuestro esquema |
|---|---|
| ¿El préstamo apunta al libro o a un ejemplar? | A un **ejemplar** (`prestamos.ejemplar_id`). Para el reporte 1 hay un join más con `ejemplares` y se agrupa por libro. |
| ¿Nombre y correo del lector en `lector` o en `usuario`? | En **`usuarios`** (`nombre`, `correo`, `telefono`), con `rol = 'lector'`. |
| ¿Hay columna de estado o se calcula con fechas? | No hay estado en `prestamos`. Un préstamo está **devuelto** si tiene fila en `devoluciones`; si no, está abierto. |
| ¿Dónde está la fecha esperada? | En `prestamos.fecha_esperada` (los datos de prueba usan `fecha_prestamo + 14`). |

## Decisiones documentadas

- **Reporte 1:** se cuentan todos los préstamos (devueltos y abiertos) sumando todos los ejemplares del libro. Los empates en el puesto 20 se incluyen todos (`rank()`), así que el reporte puede tener más de 20 filas. Los libros sin préstamos cuentan 0 (`LEFT JOIN`), pero solo aparecerían si entraran en los 20 primeros puestos.
- **Reporte 2:** "leído" = préstamo devuelto. Se cuentan libros distintos. Salen todos los empatados en el máximo.
- **Reportes 3 y 4:** mora = sin devolución y `fecha_esperada < CURRENT_DATE`. Usamos `<`, así que el préstamo que vence hoy **no** está en mora.
- Todas las fechas de prueba son relativas a `CURRENT_DATE`.

## Verificación por caso

| # | Caso | Datos de prueba | Resultado esperado (escrito antes) | Resultado obtenido | ¿Coincide? |
|---|---|---|---|---|---|
| 1 | Libro que nadie ha prestado | Los libros 22 a 32 (p. ej. *Harry Potter y la piedra filosofal*) no tienen préstamos | No aparecen en el reporte 1, porque los 20 primeros puestos ya están ocupados por libros con al menos 1 préstamo | Los 11 libros sin préstamo no aparecen en el reporte 1; la comprobación extra los lista | Sí |
| 2 | Empate en el último puesto del top | 21 libros con préstamos; del puesto 5 al 21 todos tienen 1 préstamo | Salen los 21 libros (el puesto 20 empata con el 21) | 21 filas: puesto 1 (3 préstamos), puesto 2 ×3 (2 préstamos), puesto 5 ×17 (1 préstamo) | Sí |
| 3 | Dos lectores empatados en el 1er lugar de leídos | Mariana y Santiago devolvieron 4 libros distintos cada uno | Salen los dos con 4 | Mariana Gómez Rojas 4, Santiago Rodríguez Pérez 4 | Sí |
| 4 | Lector con varios abiertos y ninguno devuelto | Valentina tiene 5 préstamos abiertos (más que los ganadores), sin devolver y sin vencer | No sale en el reporte 2 | No sale en el reporte 2 ni en el 3 ni en el 4 | Sí |
| 5 | Devuelto después de la fecha esperada | Camila: esperada hace 46 días, devuelto hace 40 | No es mora: no sale en los reportes 3 ni 4 | No sale en 3 ni en 4 | Sí |
| 6 | Préstamo abierto que vence hoy | Sebastián: prestado hace 14 días, `fecha_esperada = CURRENT_DATE` | Con la regla `<` no está en mora: no sale en 3 ni 4 | No sale en 3 ni en 4; la comprobación extra muestra su préstamo con fecha esperada de hoy | Sí |
| 7 | Lector con dos préstamos en mora | Isabella: dos préstamos abiertos vencidos hace 26 y 16 días | Una vez en el reporte 3 (con 2 en mora) y dos veces en el 4 | Reporte 3: 1 fila con `prestamos_en_mora = 2`. Reporte 4: 2 filas (*El principito*, *Matilda*) | Sí |
| 8 | Lector sin ningún préstamo | Óscar Molina Restrepo (y otros lectores sin préstamos) | No aparece en ningún reporte ni rompe nada | No aparece en ninguno | Sí |
| extra | Otro moroso con un solo préstamo | Andrés Felipe: un préstamo vencido hace 6 días | Sale una vez en 3 y una vez en 4 | Reporte 3: 1 fila. Reporte 4: 1 fila (*Alicia en el país de las maravillas*) | Sí |

**Totales esperados y obtenidos:** reporte 1 → 21 filas; reporte 2 → 2; reporte 3 → 2; reporte 4 → 3. Todos coincidieron en la primera corrida, así que no hubo que corregir ni la consulta ni la expectativa.

`datos-prueba.sql` también se probó corriéndolo dos veces seguidas: la segunda vez deja exactamente los mismos 26 préstamos y 17 devoluciones (no duplica nada).
