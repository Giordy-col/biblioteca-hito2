# `postgres/scripts/`

Scripts SQL sueltos que **no se ejecutan automáticamente** — quedan
disponibles dentro del contenedor en `/scripts` para correrlos a mano,
cuantas veces se quiera, sin perder los datos existentes. Útil para
consultas de una práctica, un `ALTER TABLE`, o probar algo sin tocar el
esquema inicial.

```bash
docker compose exec postgres psql -U curso -d curso -f /scripts/mi_consulta.sql
```

O entrar a una sesión interactiva de `psql` y ejecutar el `\i` desde ahí:

```bash
docker compose exec postgres psql -U curso -d curso
curso=# \i /scripts/mi_consulta.sql
```
