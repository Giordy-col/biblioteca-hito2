# Hito 3 · Documento de normalización · Biblioteca

Grupo: Juan Esteban Mina (2518466), Cristian Camilo Criollo (2517199), Giordy Santiago Arcila (2242797), Jairo A. Tegüé Gómez (2416227).

Esquema `biblioteca` (`postgres/init/01_esquema.sql`). Evidencia con los datos semilla (S14) y `datos-prueba.sql` (S16). Las tablas de carga (`rechazo_carga`, `stg_*`) no son del modelo y quedan fuera.

## 1. Esquema antes

- `categorias` (**id_categoria**, nombre UNIQUE)
- `autores` (**id_autor**, nombre UNIQUE)
- `usuarios` (**id_usuario**, documento UNIQUE, nombre, correo UNIQUE, telefono, username UNIQUE, password_hash, rol, estado)
- `libros` (**id_libro**, titulo, isbn UNIQUE NULL, anio_publicacion, editorial, estado, categoria_id → categorias)
- `libro_autor` (**libro_id → libros, autor_id → autores**)
- `ejemplares` (**id_ejemplar**, codigo_inventario UNIQUE, estado, libro_id → libros)
- `prestamos` (**id_prestamo**, fecha_prestamo, fecha_esperada, ejemplar_id → ejemplares, lector_id → usuarios, bibliotecario_id → usuarios)
- `devoluciones` (**id_devolucion**, fecha_devolucion, prestamo_id UNIQUE → prestamos)

## 2. Dependencias funcionales y claves candidatas

| Tabla | Dependencias (y la regla que las justifica) | Claves candidatas |
|---|---|---|
| categorias, autores | id → nombre y nombre → id: no hay dos con el mismo nombre (la carga identifica al autor por su nombre) | {id}, {nombre} |
| usuarios | Cada clave → todo lo demás: un documento es una persona; un correo y un username pertenecen a un solo usuario. `nombre` no determina nada (homónimos) | {id_usuario}, {documento}, {correo}, {username} |
| libros | id_libro → resto; isbn → resto (un ISBN es una edición). Cada libro tiene una categoría. `estado` = si sigue en catálogo, hecho del libro | {id_libro}; `isbn` es superclave cuando no es NULL |
| libro_autor | Solo la trivial (relación N:M) | {libro_id, autor_id} |
| ejemplares | id_ejemplar → resto; codigo_inventario → resto (etiqueta física de la copia) | {id_ejemplar}, {codigo_inventario} |
| prestamos | id_prestamo → resto. `fecha_esperada` **no** depende de `fecha_prestamo`: la biblioteca puede cambiar el plazo o dar plazos especiales, así que es un hecho histórico del préstamo | {id_prestamo} |
| devoluciones | Cada clave → todo: un préstamo se devuelve una sola vez | {id_devolucion}, {prestamo_id} |

## 3. Forma normal y problemas encontrados

**Las 8 tablas están en FNBC**: todo determinante es clave candidata, no hay valores múltiples y la única PK compuesta (`libro_autor`) no tiene columnas extra. El estado del préstamo no se guarda (se deduce de `devoluciones`), y `ejemplares_disponibles` del CSV se convierte en filas, no en una columna.

Consultas de evidencia (los datos no contradicen las reglas):

```sql
SELECT count(*) FROM usuarios WHERE telefono ~ '[^0-9]';                     -- 0: un solo teléfono (1FN)
SELECT fecha_esperada - fecha_prestamo, count(*) FROM prestamos GROUP BY 1;   -- 14 | 26 (hoy, no por regla)
SELECT ejemplar_id FROM prestamos p                                            -- 0: ningún ejemplar con
WHERE NOT EXISTS (SELECT 1 FROM devoluciones d WHERE d.prestamo_id = p.id_prestamo)
GROUP BY ejemplar_id HAVING count(*) > 1;                                      --    dos préstamos abiertos
```

**Hallazgos de S19 (parte B) y decisión final:**

| Hallazgo de S19 | Propuesta en S19 | Decisión en el Hito 3 |
|---|---|---|
| `telefono` podría tener varios valores | Tabla `usuario_telefono` | No hace falta: evidencia = 0 y la carga solo acepta 7 a 15 dígitos |
| `editorial` es texto libre ("Planeta" / "Editorial Planeta") | Ninguna obligatoria | Se deja: no determina nada, no viola 3FN; es un riesgo de calidad de datos |
| `libros.estado` podría derivarse de los ejemplares | Revisar | No es derivado: significa "sigue en catálogo"; un libro puede seguir en catálogo con todo prestado |
| `ejemplares.estado = 'prestado'` duplica a `prestamos` y `devoluciones` | Calcularlo con una vista | **Cambió**: se mantiene como desnormalización deliberada (sección 5); el Hito 4 ya pide el trigger que lo mantiene |
| `fecha_esperada` derivada si el plazo es fijo | Quitarla | Se guarda: el plazo no es fijo (sección 2) |
| `prestamos` sin UNIQUE natural | `UNIQUE (ejemplar_id, fecha_prestamo)` | Se descarta: un ejemplar puede prestarse, devolverse y volver a prestarse el mismo día. La regla real es "no hay dos préstamos abiertos del mismo ejemplar"; hoy se cumple (evidencia = 0) y no cabe en un UNIQUE porque "abierto" depende de `devoluciones`, así que va al trigger del Hito 4 |

**Único problema real:** 'perdido' y 'baja' son la condición física del ejemplar, pero 'prestado' se deduce de otras tablas (prestado si y solo si tiene un préstamo sin devolución). No viola la FNBC de `ejemplares`, porque es una dependencia entre tablas, pero es el mismo hecho guardado dos veces. Hoy lo actualiza a mano `datos-prueba.sql`.

## 4. Cambios aplicados y migración

No hubo cambios estructurales, así que **no hay `normalizacion.sql`**. Cambios:

- `postgres/init/01_esquema.sql`: se agregó la vista `ejemplares_descuadre` (sección 5). Probado en una base vacía aparte (`prueba_init`): corre limpio.
- `postgres/scripts/verificacion-ejemplares.sql`: crea la vista en la base del grupo sin borrar datos y prueba que detecta el descuadre (con `ROLLBACK`).

Conteos antes = después (no se migraron datos): categorías 9, autores 29, usuarios 21, libros 32, libro_autor 32, ejemplares 94, préstamos 26, devoluciones 17. Los reportes de S16 dan lo esperado: 21, 2, 2 y 3 filas (`entregas/S20/salida-reportes.txt`).

## 5. Desnormalización deliberada: `ejemplares.estado = 'prestado'`

- **Por qué:** la columna ya existe por 'perdido' y 'baja', y la GUI muestra el estado de cada copia sin juntar tres tablas. **No es por rendimiento**: con 94 ejemplares no hay diferencia medible. Si el catálogo creciera, lo primero sería un índice, como en la parte A (catálogo de 21,0 ms a 3,1 ms sin redundancia).
- **Cómo se mantiene:** hasta el Hito 4, quien registra el préstamo o la devolución actualiza el ejemplar en la misma transacción. Riesgo: un `INSERT` desde `psql` o una carga masiva se lo salta. En el Hito 4 (S22) lo reemplaza un **trigger** sobre `prestamos` (pasa a 'prestado') y sobre `devoluciones` (vuelve a 'disponible').
- **Verificación:** la vista `ejemplares_descuadre` lista los ejemplares cuyo estado guardado no coincide con los préstamos; **0 filas = consistente**. Con los datos de prueba da 0. Un préstamo registrado sin actualizar el ejemplar da 1 fila ('disponible' vs 'prestado'), y una devolución igual ('prestado' vs 'no prestado'). También detecta un ejemplar 'perdido' o 'baja' con préstamo abierto: la regla es cerrar el préstamo antes de cambiar la condición física.

## 6. Esquema después

Las mismas 8 tablas, más la vista `ejemplares_descuadre`. **Todas en FNBC**: ninguna queda solo en 3FN. La única redundancia es la de la sección 5, documentada y con su verificación.
