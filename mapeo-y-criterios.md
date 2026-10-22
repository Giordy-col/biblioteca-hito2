# Mapeo CSV → esquema y criterios por tipo de error

Esquema destino: `biblioteca` (ver `postgres/init/01_esquema.sql`).
Criterio general: **rechazar** y registrar en `rechazo_carga` todo lo que no se pueda normalizar con `trim` o `lower`. Las filas válidas del mismo archivo sí entran.

## 1. Mapeo CSV → esquema

### libros_semilla.csv (6 columnas)

| Columna del CSV | Tabla.columna destino | Transformación | Regla de validación (motivo) |
|---|---|---|---|
| `isbn` | `libros.isbn` | `trim` | no vacío ("isbn vacío"); 13 dígitos ("isbn no tiene 13 dígitos"); no existe en `libros` ("isbn ya existe en el catálogo"); no repetido en el archivo ("isbn repetido en el archivo") |
| `titulo` | `libros.titulo` | `trim` | no vacío ("título vacío"); máx. 200 caracteres |
| `autor` | `autores.nombre` + `libro_autor` | se da de alta el autor si no existe (`ON CONFLICT DO NOTHING`) y se enlaza con el libro | no vacío ("autor vacío"); máx. 150 caracteres |
| `categoria` | `categorias.nombre` → `libros.categoria_id` | se da de alta la categoría si no existe y se busca su id | no vacía ("categoría vacía"); máx. 100 caracteres |
| `anio_publicacion` | `libros.anio_publicacion` | `::integer` | solo dígitos ("año no numérico"); entre 1450 y 2100 ("año fuera de rango") |
| `ejemplares_disponibles` | `ejemplares` (n filas) | `generate_series(1, n)`; `codigo_inventario = isbn-001, isbn-002…`; `estado = 'disponible'` | entero ("ejemplares no numérico"); ≥ 0 ("ejemplares negativo") |
| *(no viene en el CSV)* | `libros.estado` | valor fijo `'disponible'` | — |
| *(no viene en el CSV)* | `libros.editorial` | queda `NULL` | — |

Además: una fila con número de columnas distinto de 6 se rechaza ("tiene N columnas, se esperaban 6").

### lectores_semilla.csv (5 columnas)

| Columna del CSV | Tabla.columna destino | Transformación | Regla de validación (motivo) |
|---|---|---|---|
| `documento` | `usuarios.documento` y `usuarios.username` | `trim` | no vacío; 6 a 15 dígitos ("documento no numérico o de longitud inválida"); no existe en `usuarios` ("documento ya existe"); no está en uso como username |
| `nombres` + `apellidos` | `usuarios.nombre` | `nombres \|\| ' ' \|\| apellidos` | ninguno vacío; nombre completo ≤ 100 caracteres |
| `correo` | `usuarios.correo` | `lower(trim(...))` | no vacío; formato `x@y.z` ("correo mal formado"); no registrado por otro usuario; no repetido en el archivo |
| `telefono` | `usuarios.telefono` | `trim` | 7 a 15 dígitos ("teléfono no numérico o de longitud inválida") |
| *(no viene en el CSV)* | `usuarios.password_hash` | `crypt(documento, gen_salt('bf'))` con `pgcrypto`: el documento es la clave inicial, guardada con hash, nunca en texto plano | — |
| *(no viene en el CSV)* | `usuarios.rol` / `usuarios.estado` | valores fijos `'lector'` / `'activo'` | — |

Además: una fila con número de columnas distinto de 5 se rechaza ("tiene N columnas, se esperaban 5").

## 2. Criterios por tipo de error

### Libros (8 errores del archivo con errores)

| Línea | Problema | Qué se hace | Por qué |
|---|---|---|---|
| 2 | ISBN ya existe en el catálogo (duplicado de un libro cargado) | Rechazar | Evita duplicar libros y ejemplares; así repetir una carga no duplica nada. Si se quisiera sumar copias habría que decidirlo como regla nueva. |
| 3 | Título vacío | Rechazar | No se puede adivinar el título. |
| 4 | Ejemplares no numérico (`dos`) | Rechazar | No se convierte texto a número por suposición. 
| 4 | Año no numérico (`dos` en la columna del año) | Rechazar | Un texto no se convierte a número por suposición, y aquí además parece que las columnas están corridas. |
| 5 | Año no numérico (`MCMXLIX`) | Rechazar | No se convierten números romanos; el dato queda en la bitácora para corregirlo a mano. |
| 6 | Columna de más (7 en lugar de 6) | Rechazar | No se sabe qué campo sobra ni si hay una coma dentro de un campo. |
| 7 | Autor vacío | Rechazar | Cada libro necesita al menos un autor en `libro_autor`. |
| 8 | ISBN vacío | Rechazar | El ISBN es el identificador con el que se detectan duplicados. |
| 9 | Ejemplares negativo | Rechazar | No existe un número negativo de copias; no se corrige a 0 porque cambia el significado. |

### Lectores (completar con la salida real del archivo con errores)

| Línea | Problema | Qué se hace | Por qué |
|---|---|---|---|
| 2 | Documento ya existe (duplicado de Mariana) | Rechazar | No se duplica a la persona; actualizar sus datos sería otro proceso. |
| 3 | Correo vacío | Rechazar | El correo es obligatorio y único; no se puede inventar. |
| 4 | Correo mal formado (sin @) | Rechazar | No se adivina el correo correcto. |
| 5 | Teléfono no numérico (`tres-cero-cero`) | Rechazar | No se convierte texto a número por suposición. |
| 6 | Documento vacío | Rechazar | Es el identificador del lector. |
| 7 | Nombres vacío | Rechazar | `usuarios.nombre` es obligatorio. |

### Errores propios del grupo (CSV propio)

| Problema | Qué se hace | Por qué |
|---|---|---|
| ISBN repetido dentro del mismo archivo (`9789580000013`) | Cargar la primera aparición y rechazar la repetida | Se conserva un solo registro por ISBN; la repetida queda en la bitácora para revisarla. |
| Año fuera de rango (`1200`) | Rechazar | Un año anterior a 1450 no es plausible para un libro impreso, y no se corrige por suposición. |
| Categoría vacía | Rechazar | Cada libro necesita una categoría (`categoria_id` es obligatorio) y no se puede inventar. |


## 3. Respuesta a la prueba de la última línea de defensa

Al comentar la regla del `CASE` que valida el rango del año y cargar un archivo con un año `3000`, la fila mala llega a `INSERT INTO libros` y choca con `CHECK (anio_publicacion BETWEEN 1450 AND 2100)`. Como todo corre dentro de `BEGIN … COMMIT`, el error deshace **toda** la carga: no entra ninguna fila, ni siquiera las buenas del mismo archivo, y tampoco se escribe nada en `rechazo_carga` (se pierde también la constancia de las filas que sí habían sido rechazadas). Con `ON_ERROR_STOP` el script se detiene en ese punto.

Nota: comentar la regla de "ejemplares negativo" **no** provoca ese choque en este esquema, porque `ejemplares_disponibles` no es una columna sino el argumento de `generate_series`, y `generate_series(1, -3)` simplemente no genera filas. El resultado sería un libro cargado con cero ejemplares y sin ningún error. Por eso la regla del `CASE` es necesaria y no es redundante con el esquema.

Al comentar la regla del año y cargar un archivo con un año 3000, la fila mala llegó al INSERT en `libros` y el CHECK del esquema la rechazó con el error `violates check constraint "libros_anio_publicacion_check"`. Como la carga corre dentro de una transacción (BEGIN … COMMIT), el error deshizo toda la carga: no entró ninguna fila, ni siquiera la buena, y la bitácora `rechazo_carga` quedó vacía. Esto muestra que el esquema sirve como última línea de defensa, pero que la validación del script es mejor porque rechaza solo la fila mala y explica el motivo.
