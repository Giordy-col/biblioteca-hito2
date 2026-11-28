-- =====================================================================
-- S22 · Laboratorio · Parte A: reservas de salas de estudio
--
-- Grupo: Juan Esteban Mina (2518466), Cristian Camilo Criollo (2517199),
--        Giordy Santiago Arcila (2242797), Jairo A. Tegüé Gómez (2416227).
--
-- Uso (desde entorno-docker/, con los dos archivos en postgres/scripts/):
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S22-reservas.sql
--   docker compose exec postgres psql -U curso -d curso -f /scripts/S22-grupo.sql
--
-- Se corre SIEMPRE después de S22-reservas.sql (que borra y recrea todo).
-- Las baterías incluyen sentencias que DEBEN fallar, así que el archivo
-- no se detiene con los errores (ON_ERROR_STOP off): cada error esperado
-- está anotado en un comentario "-- debe fallar".
-- Las respuestas a las preguntas están en S22-respuestas.pdf.
-- =====================================================================

\set ON_ERROR_STOP off
SET search_path TO reservas;

-- =====================================================================
-- A1. Restricciones y acciones referenciales
-- =====================================================================

-- (a) Regla 1 y asistentes positivos, como CHECK de varias columnas
ALTER TABLE reserva
    ADD CONSTRAINT reserva_orden      CHECK (fin > inicio),
    ADD CONSTRAINT reserva_duracion   CHECK (fin - inicio <= interval '3 hours'),
    ADD CONSTRAINT reserva_horario    CHECK (inicio::date = fin::date
                                             AND inicio::time >= time '07:00'
                                             AND fin::time    <= time '21:00'),
    ADD CONSTRAINT reserva_asistentes CHECK (asistentes > 0);

-- (b) Acciones ON DELETE de las tres FK
-- sala_recurso -> sala: CASCADE. Los recursos son parte de la sala; si la
--   sala desaparece, sus recursos no tienen sentido solos.
ALTER TABLE sala_recurso
    DROP CONSTRAINT sala_recurso_id_sala_fkey,
    ADD  CONSTRAINT sala_recurso_id_sala_fkey
         FOREIGN KEY (id_sala) REFERENCES sala ON DELETE CASCADE;

-- reserva -> sala: RESTRICT. Las reservas son historial (asistencia,
--   sanciones); una sala con reservas no se borra, se marca activa = false.
ALTER TABLE reserva
    DROP CONSTRAINT reserva_id_sala_fkey,
    ADD  CONSTRAINT reserva_id_sala_fkey
         FOREIGN KEY (id_sala) REFERENCES sala ON DELETE RESTRICT;

-- reserva -> estudiante: RESTRICT. Borrar al estudiante borraría (CASCADE)
--   o dejaría sin dueño (SET NULL, y codigo es NOT NULL) su historial y la
--   evidencia de sus inasistencias.
ALTER TABLE reserva
    DROP CONSTRAINT reserva_codigo_fkey,
    ADD  CONSTRAINT reserva_codigo_fkey
         FOREIGN KEY (codigo) REFERENCES estudiante ON DELETE RESTRICT;

-- (c) Batería A1
\echo '== A1 (c) batería'
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '10:00', dia(4) + time '09:00', 2);   -- debe fallar: reserva_orden
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '08:00', dia(4) + time '12:00', 2);   -- debe fallar: reserva_duracion
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '20:00', dia(4) + time '22:00', 2);   -- debe fallar: reserva_horario
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(4) + time '10:00', dia(4) + time '11:00', 0);   -- debe fallar: reserva_asistentes

BEGIN;
DELETE FROM sala WHERE id_sala = 4;                  -- pasa: la sala D no tiene reservas
SELECT count(*) AS recursos_sala_4 FROM sala_recurso WHERE id_sala = 4;   -- 0: se borraron en cascada
ROLLBACK;
DELETE FROM sala WHERE id_sala = 1;                  -- debe fallar: tiene reservas (RESTRICT)

BEGIN;
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610006', dia(1) + time '09:00', dia(1) + time '10:00', 9);   -- pasa (ver A1 d)
ROLLBACK;

-- (d) Ver S22-respuestas.pdf: viola las reglas 2 (9 personas en una sala de
--     4) y 3 (se cruza con la reserva 1 de Ana). Un CHECK solo ve la fila que
--     se inserta: no puede leer la capacidad en sala ni las otras reservas.

-- =====================================================================
-- A2. Funciones
-- =====================================================================

-- Horas reservadas (sin canceladas) por el estudiante en la semana de p_dia
CREATE OR REPLACE FUNCTION horas_semana(p_codigo varchar, p_dia date)
RETURNS numeric
LANGUAGE sql STABLE
AS $$
    SELECT round(coalesce(sum(extract(epoch FROM r.fin - r.inicio)) / 3600, 0), 1)
    FROM   reserva r
    WHERE  r.codigo = p_codigo
      AND  r.estado <> 'cancelada'
      AND  date_trunc('week', r.inicio) = date_trunc('week', p_dia::timestamp);
$$;

-- Regla 3: la sala no tiene reservas activas que se crucen con [p_inicio, p_fin),
-- sin contar la reserva p_excluir (la que se está modificando)
CREATE OR REPLACE FUNCTION sala_libre(p_sala integer, p_inicio timestamp, p_fin timestamp,
                                      p_excluir integer DEFAULT NULL)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT NOT EXISTS (
        SELECT 1
        FROM   reserva r
        WHERE  r.id_sala = p_sala
          AND  r.estado  = 'activa'
          AND  r.inicio  < p_fin
          AND  p_inicio  < r.fin
          AND  (p_excluir IS NULL OR r.id <> p_excluir));
$$;

\echo '== A2 batería'
SELECT codigo, horas_semana(codigo, dia(1))   AS proxima,
               horas_semana(codigo, dia(-13)) AS pasada
FROM   estudiante ORDER BY codigo;
-- próxima: Ana 5.0, Bruno 2.0, Carla 3.0, Diego 2.0, Elena 0.0, Felipe 0.0
-- pasada:  Bruno 2.0, Carla 2.0, Felipe 2.0, los demás 0.0

SELECT sala_libre(1, dia(1) + time '09:00', dia(1) + time '11:00')    AS a,   -- f
       sala_libre(1, dia(1) + time '12:00', dia(1) + time '14:00')    AS b,   -- t
       sala_libre(2, dia(3) + time '08:00', dia(3) + time '10:00')    AS c,   -- t
       sala_libre(1, dia(1) + time '08:00', dia(1) + time '10:00', 1) AS d;   -- t

-- =====================================================================
-- A3. Procedimientos
-- =====================================================================

-- (a) Caso de uso "reservar": reglas 5, 2, 3 y 4, en ese orden.
--     La regla 1 la imponen los CHECK de A1.
CREATE OR REPLACE PROCEDURE reservar(p_codigo varchar, p_sala integer,
                                     p_inicio timestamp, p_fin timestamp,
                                     p_asistentes integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sancion   date;
    v_capacidad integer;
    v_activa    boolean;
    v_horas     numeric;
    v_nuevas    numeric;
    v_id        integer;
BEGIN
    -- Regla 5: el estudiante existe y no está sancionado
    SELECT sancionado_hasta INTO v_sancion FROM estudiante WHERE codigo = p_codigo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El estudiante % no existe', p_codigo;
    END IF;
    IF v_sancion IS NOT NULL AND v_sancion >= CURRENT_DATE THEN
        RAISE EXCEPTION 'El estudiante % está sancionado hasta el %', p_codigo, v_sancion;
    END IF;

    -- Regla 2: la sala existe, no está en mantenimiento y le caben los asistentes
    SELECT capacidad, activa INTO v_capacidad, v_activa FROM sala WHERE id_sala = p_sala;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La sala % no existe', p_sala;
    END IF;
    IF NOT v_activa THEN
        RAISE EXCEPTION 'La sala % está en mantenimiento', p_sala;
    END IF;
    IF p_asistentes > v_capacidad THEN
        RAISE EXCEPTION 'La sala % tiene capacidad para %, no para % asistentes',
              p_sala, v_capacidad, p_asistentes;
    END IF;

    -- Regla 3: la sala está libre en ese horario
    IF NOT sala_libre(p_sala, p_inicio, p_fin) THEN
        RAISE EXCEPTION 'La sala % ya está ocupada entre % y %', p_sala, p_inicio, p_fin;
    END IF;

    -- Regla 4: máximo 6 horas por semana
    v_horas  := horas_semana(p_codigo, p_inicio::date);
    v_nuevas := round(extract(epoch FROM p_fin - p_inicio) / 3600, 1);
    IF v_horas + v_nuevas > 6 THEN
        RAISE EXCEPTION 'El estudiante % lleva % horas esa semana: con % más superaría el máximo de 6',
              p_codigo, v_horas, v_nuevas;
    END IF;

    INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
    VALUES (p_sala, p_codigo, p_inicio, p_fin, p_asistentes)
    RETURNING id INTO v_id;

    RAISE NOTICE 'Reserva % creada', v_id;
END;
$$;

-- (b) Regla 6: cancelar solo si está activa y no ha empezado
CREATE OR REPLACE PROCEDURE cancelar(p_id integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_estado varchar;
    v_inicio timestamp;
BEGIN
    SELECT estado, inicio INTO v_estado, v_inicio FROM reserva WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La reserva % no existe', p_id;
    END IF;
    IF v_estado <> 'activa' THEN
        RAISE EXCEPTION 'La reserva % no está activa (estado: %)', p_id, v_estado;
    END IF;
    IF v_inicio <= localtimestamp THEN
        RAISE EXCEPTION 'La reserva % ya empezó (%): no se puede cancelar', p_id, v_inicio;
    END IF;

    UPDATE reserva SET estado = 'cancelada' WHERE id = p_id;
    RAISE NOTICE 'Reserva % cancelada', p_id;
END;
$$;

-- (c) Batería A3
\echo '== A3 batería'
CALL reservar('2610005', 1, dia(4) + time '08:00', dia(4) + time '10:00', 2);   -- 1. debe fallar: Elena sancionada
CALL reservar('2610006', 4, dia(4) + time '08:00', dia(4) + time '10:00', 2);   -- 2. debe fallar: sala en mantenimiento
CALL reservar('2610006', 1, dia(4) + time '08:00', dia(4) + time '10:00', 5);   -- 3. debe fallar: capacidad 4
CALL reservar('2610006', 1, dia(1) + time '09:00', dia(1) + time '11:00', 2);   -- 4. debe fallar: sala ocupada
CALL reservar('2610001', 2, dia(4) + time '08:00', dia(4) + time '10:00', 3);   -- 5. debe fallar: Ana lleva 5.0
CALL reservar('2610006', 1, dia(1) + time '12:00', dia(1) + time '14:00', 3);   -- 6. pasa
CALL reservar('2610004', 2, dia(3) + time '08:00', dia(3) + time '10:00', 4);   -- 7. pasa (la anterior estaba cancelada)
CALL reservar('2610001', 2, dia(4) + time '08:00', dia(4) + time '09:00', 3);   -- 8. pasa (Ana llega justo a 6)
CALL reservar('2610099', 2, dia(4) + time '08:00', dia(4) + time '09:00', 3);   -- 9. debe fallar: no existe
CALL cancelar(7);                                                                -- 10. debe fallar: no está activa
CALL cancelar(2);                                                                -- 11. pasa: cancela la de Bruno

SELECT * FROM agenda;

-- =====================================================================
-- A4. Trigger de validación
-- =====================================================================

-- (a) Sin trigger, un INSERT directo se salta las reglas 2 y 3
\echo '== A4 (a) sin trigger'
BEGIN;
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 12);   -- pasa (¡mal!): 12 en sala de 10, cruzada con Ana
ROLLBACK;

-- (b) Reglas 2 y 3 para TODA reserva activa, venga de donde venga
CREATE OR REPLACE FUNCTION validar_reserva()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacidad integer;
    v_activa    boolean;
BEGIN
    IF NEW.estado <> 'activa' THEN
        RETURN NEW;                       -- canceladas, cumplidas, etc. no ocupan la sala
    END IF;

    SELECT capacidad, activa INTO v_capacidad, v_activa FROM sala WHERE id_sala = NEW.id_sala;
    IF NOT v_activa THEN
        RAISE EXCEPTION 'La sala % está en mantenimiento', NEW.id_sala;
    END IF;
    IF NEW.asistentes > v_capacidad THEN
        RAISE EXCEPTION 'La sala % tiene capacidad para %, no para % asistentes',
              NEW.id_sala, v_capacidad, NEW.asistentes;
    END IF;

    -- se excluye a sí misma: al modificar una reserva no debe chocar consigo
    IF NOT sala_libre(NEW.id_sala, NEW.inicio, NEW.fin, NEW.id) THEN
        RAISE EXCEPTION 'La sala % ya está ocupada entre % y %',
              NEW.id_sala, NEW.inicio, NEW.fin;
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS reserva_validar ON reserva;
CREATE TRIGGER reserva_validar
    BEFORE INSERT OR UPDATE ON reserva
    FOR EACH ROW
    EXECUTE FUNCTION validar_reserva();

-- (c) Batería A4
\echo '== A4 (c) batería'
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 12);   -- debe fallar: capacidad
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (3, '2610005', dia(2) + time '10:00', dia(2) + time '11:00', 6);    -- debe fallar: sala ocupada
UPDATE reserva SET inicio = dia(3) + time '09:00' WHERE id = 6;            -- debe fallar: cruce con Diego 8:00
UPDATE reserva SET asistentes = 5 WHERE id = 6;                            -- pasa
UPDATE reserva SET estado = 'activa' WHERE id = 5;                         -- debe fallar: reactivarla la cruza

-- =====================================================================
-- A5. Trigger que reacciona a un cambio de estado
-- =====================================================================

-- Regla 5: quien no se presenta queda sancionado 7 días. greatest() evita
-- acortar una sanción más larga que ya tuviera.
CREATE OR REPLACE FUNCTION sancionar_inasistencia()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE estudiante
    SET    sancionado_hasta = greatest(coalesce(sancionado_hasta, CURRENT_DATE), CURRENT_DATE + 7)
    WHERE  codigo = NEW.codigo;
    RETURN NULL;                          -- AFTER: el valor de retorno se ignora
END;
$$;

DROP TRIGGER IF EXISTS reserva_sancionar ON reserva;
CREATE TRIGGER reserva_sancionar
    AFTER UPDATE OF estado ON reserva
    FOR EACH ROW
    WHEN (NEW.estado = 'no_asistio' AND OLD.estado <> 'no_asistio')
    EXECUTE FUNCTION sancionar_inasistencia();

\echo '== A5 batería'
UPDATE reserva SET estado = 'no_asistio' WHERE id = 7;    -- Felipe no se presentó
SELECT codigo, nombre, sancionado_hasta - CURRENT_DATE AS dias
FROM   estudiante WHERE sancionado_hasta IS NOT NULL;     -- Elena 30, Felipe 7
CALL reservar('2610006', 3, dia(5) + time '08:00', dia(5) + time '10:00', 2);   -- debe fallar: Felipe sancionado
UPDATE reserva SET asistentes = 2 WHERE id = 8;           -- Bruno: no queda sancionado
SELECT codigo, nombre, sancionado_hasta - CURRENT_DATE AS dias
FROM   estudiante WHERE sancionado_hasta IS NOT NULL;     -- sigue: Elena 30, Felipe 7

-- =====================================================================
-- A6. Ciclo o conjunto
-- =====================================================================

-- Versión del compañero (fila por fila), solo para comparar
CREATE OR REPLACE PROCEDURE cerrar_vencidas_ciclo()
LANGUAGE plpgsql
AS $$
DECLARE
    r  record;
BEGIN
    FOR r IN SELECT id FROM reserva WHERE estado = 'activa' AND fin < now() LOOP
        UPDATE reserva SET estado = 'cumplida' WHERE id = r.id;
        RAISE NOTICE 'Reserva % cerrada', r.id;
    END LOOP;
END;
$$;

-- (a) Una sola sentencia sobre el conjunto
CREATE OR REPLACE PROCEDURE cerrar_vencidas()
LANGUAGE sql
AS $$
    UPDATE reserva
    SET    estado = 'cumplida'
    WHERE  estado = 'activa'
      AND  fin < now();
$$;

\echo '== A6 (a)'
SELECT id, estado FROM reserva WHERE id = 9;      -- activa
CALL cerrar_vencidas();
SELECT id, estado FROM reserva WHERE id = 9;      -- cumplida

-- =====================================================================
-- Reto: la regla 3 como restricción EXCLUDE
-- =====================================================================
-- btree_gist se instala en public para que no lo borre el DROP SCHEMA de
-- S22-reservas.sql (igual que pgcrypto en nuestro esquema del proyecto).
CREATE EXTENSION IF NOT EXISTS btree_gist SCHEMA public;
SET search_path TO reservas, public;

ALTER TABLE reserva DROP CONSTRAINT IF EXISTS reserva_sin_cruce;
ALTER TABLE reserva ADD CONSTRAINT reserva_sin_cruce
    EXCLUDE USING gist (id_sala WITH =, tsrange(inicio, fin) WITH &&)
    WHERE (estado = 'activa');

\echo '== Reto: con el trigger desactivado'
ALTER TABLE reserva DISABLE TRIGGER reserva_validar;

INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610004', dia(1) + time '09:00', dia(1) + time '10:00', 2);   -- debe fallar: reserva_sin_cruce (Ana 8-10)
BEGIN;
INSERT INTO reserva (id_sala, codigo, inicio, fin, asistentes)
VALUES (1, '2610004', dia(1) + time '15:00', dia(1) + time '16:00', 2);   -- pasa: la sala A está libre
ROLLBACK;

ALTER TABLE reserva ENABLE TRIGGER reserva_validar;

\echo '== Estado final'
SELECT * FROM agenda;
