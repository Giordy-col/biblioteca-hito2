# `postgres/init/`

Scripts SQL (o `.sh`) que Postgres ejecuta **una sola vez**, en orden
alfabético, **solo si `postgres/data/` está vacía** (es decir, la primera vez
que se crea la base, o después de borrarla para empezar de cero).

Convención de nombres: prefijo numérico de dos dígitos para controlar el
orden.

```
01_esquema.sql   -- CREATE TABLE, constraints, etc.
02_datos.sql     -- INSERT de datos semilla
```

## Cómo cambiar de práctica

Como estos scripts solo corren con la base vacía, para pasar de una práctica
a otra (nuevo esquema) hay que reiniciar los datos:

```bash
docker compose down
rm -rf ../data/*      # o: sudo rm -rf ../data/* si da permiso denegado
# reemplaza aquí los .sql por los de la nueva práctica
docker compose up -d postgres
```

Si en cambio solo quieres **agregar** tablas o datos sin perder lo que ya
hay, no uses esta carpeta — corre el script a mano contra la base ya viva
(ver `../scripts/README.md`).
