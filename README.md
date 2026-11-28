# Biblioteca · Proyecto de Bases de Datos

Grupo: Juan Esteban Mina (2518466), Cristian Camilo Criollo (2517199), Giordy Santiago Arcila (2242797), Jairo A. Tegüé Gómez (2416227).

Base de datos de una biblioteca en PostgreSQL: catálogo de libros y ejemplares, lectores, préstamos y devoluciones.

## Cómo levantar la base

Desde la raíz de este repositorio, que trae su propio `docker-compose.yml`:

```bash
# Los scripts de postgres/init/ (01_esquema.sql y 02_programacion.sql) solo se
# ejecutan la primera vez, cuando postgres/data está vacía.
docker compose up -d

# Carga de datos y pruebas
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-libros.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/carga-lectores.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/datos-prueba.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/reportes.sql
docker compose exec postgres psql -U curso -d curso -f /scripts/pruebas-programacion.sql
```

## Estructura

| Carpeta / archivo | Qué es | Hito |
|---|---|---|
| `postgres/init/01_esquema.sql` | Esquema `biblioteca` (en FNBC) y la vista `ejemplares_descuadre` | 2 y 3 |
| `postgres/init/02_programacion.sql` | Funciones, procedimientos y triggers (copia de `programacion.sql`) | 4 |
| `postgres/scripts/carga-*.sql`, `datos/` | Carga de libros y lectores desde CSV, con bitácora de rechazos | 2 |
| `postgres/scripts/datos-prueba.sql`, `reportes.sql` | Datos de prueba y los 4 reportes | 2 |
| `postgres/scripts/programacion.sql`, `pruebas-programacion.sql` | Lógica en la base de datos y su batería de pruebas | 4 |
| `entregas/` | Entregas de los talleres (S16, S20) y documento de normalización | 2 y 3 |

## Lógica en la base de datos

Reglas del proyecto que implementa la base:

- **R1.** Solo presta un usuario con rol `lector` y estado `activo`.
- **R2.** Un lector en mora (préstamo abierto con `fecha_esperada < hoy`) no puede tomar préstamos.
- **R3.** Un lector tiene como máximo 3 préstamos abiertos.
- **R4.** Solo se presta un ejemplar `disponible` y sin préstamo abierto.
- **R5.** `ejemplares.estado = 'prestado'` se mantiene al día (desnormalización del Hito 3).

| Objeto | Tipo | Tabla | Evento | Regla que implementa |
|---|---|---|---|---|
| `lector_en_mora(integer)` | función | — | — | R2: mora = préstamo abierto con `fecha_esperada < hoy` |
| `prestamos_abiertos(integer)` | función | — | — | R3: cuenta los préstamos sin devolución |
| `ejemplar_disponible(integer)` | función | — | — | R4: ejemplar `disponible` y sin préstamo abierto |
| `registrar_prestamo(...)` | procedimiento | `prestamos` | — | Caso de uso "prestar": R1 a R4 con mensajes claros |
| `registrar_devolucion(...)` | procedimiento | `devoluciones` | — | Caso de uso "devolver": préstamo existente, abierto y fecha válida |
| `prestamo_validar` → `validar_prestamo()` | trigger | `prestamos` | BEFORE INSERT | Impide saltarse R1, R2 y R4 con un `INSERT` directo |
| `prestamo_estado` → `mantener_estado_ejemplar()` | trigger | `prestamos` | AFTER INSERT | R5: el ejemplar pasa a `prestado` |
| `devolucion_estado` → `mantener_estado_ejemplar()` | trigger | `devoluciones` | AFTER INSERT | R5: el ejemplar vuelve a `disponible` |
| `prestamo_auditar`, `devolucion_auditar` → `auditar_prestamo()` | trigger | `prestamos`, `devoluciones` | AFTER INSERT | Bitácora en `prestamo_auditoria` |

**Decisiones:**

- R3 queda solo en el procedimiento y no en el trigger: es una política de atención al lector, y un bibliotecario o una carga administrativa pueden necesitar registrar préstamos por fuera de ella.
- El trigger de validación es solo `BEFORE INSERT`: renovar un préstamo abierto (un `UPDATE` de `fecha_esperada`) no debe exigir que el ejemplar esté disponible.
- `datos-prueba.sql` desactiva los triggers mientras carga su historial (inserta los préstamos viejos antes que sus devoluciones) y calcula `ejemplares.estado` por su cuenta.
- Ningún trigger reacciona al paso del tiempo: la mora se calcula al consultar, con `lector_en_mora`.

**Verificación de la desnormalización:** `SELECT * FROM ejemplares_descuadre;` debe devolver **0 filas**. Las pruebas la consultan antes y después de prestar y devolver.
