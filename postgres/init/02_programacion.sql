-- =====================================================================
-- Hito 4 · programacion.sql · Biblioteca
-- Procedimientos, funciones y triggers del proyecto.
--
-- Reglas del documento del proyecto que se implementan aquí:
--   R1  Un lector solo puede tener préstamos si está 'activo'.
--   R2  Un lector en mora (préstamo abierto con fecha_esperada < hoy)
--       no puede tomar nuevos préstamos.
--   R3  Un lector no puede tener más de 3 préstamos abiertos a la vez.
--   R4  Un ejemplar solo se presta si está 'disponible' y no tiene
--       préstamo abierto (según devoluciones).
--   R5  (Hito 3, desnormalización) ejemplares.estado = 'prestado'
--       se mantiene con triggers sobre prestamos y devoluciones.
--
-- Uso:
--   docker compose exec postgres psql -U curso -d curso -f /scripts/programacion.sql
-- Se puede correr varias veces: usa CREATE OR REPLACE y DROP TRIGGER IF EXISTS.
-- Una copia idéntica está en postgres/init/02_programacion.sql, para que una
-- base vacía quede creada con todo (después de 01_esquema.sql).
--
-- Nota: datos-prueba.sql desactiva estos triggers mientras carga su historial
-- (préstamos viejos que se insertan todos antes que sus devoluciones) y
-- deja ejemplares.estado calculado por su cuenta.
-- =====================================================================

\set ON_ERROR_STOP on
SET search_path TO biblioteca, public;

-- ---------------------------------------------------------------------
-- Funciones de apoyo (reutilizables desde procedimientos y triggers)
-- ---------------------------------------------------------------------

-- ¿El lector está en mora? (préstamo abierto con fecha_esperada vencida)
CREATE OR REPLACE FUNCTION lector_en_mora(p_id_lector integer)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM   prestamos p
        WHERE  p.lector_id = p_id_lector
          AND  p.fecha_esperada < CURRENT_DATE
          AND  NOT EXISTS (SELECT 1 FROM devoluciones d
                           WHERE d.prestamo_id = p.id_prestamo)
    );
$$;

-- Préstamos abiertos del lector
CREATE OR REPLACE FUNCTION prestamos_abiertos(p_id_lector integer)
RETURNS integer
LANGUAGE sql STABLE
AS $$
    SELECT count(*)::integer
    FROM   prestamos p
    WHERE  p.lector_id = p_id_lector
      AND  NOT EXISTS (SELECT 1 FROM devoluciones d
                       WHERE d.prestamo_id = p.id_prestamo);
$$;

-- ¿El ejemplar está disponible para prestar?
-- Disponible = estado 'disponible' y sin préstamo abierto.
CREATE OR REPLACE FUNCTION ejemplar_disponible(p_id_ejemplar integer)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM   ejemplares e
        WHERE  e.id_ejemplar = p_id_ejemplar
          AND  e.estado = 'disponible'
          AND  NOT EXISTS (
                 SELECT 1 FROM prestamos p
                 WHERE  p.ejemplar_id = e.id_ejemplar
                   AND  NOT EXISTS (SELECT 1 FROM devoluciones d
                                    WHERE d.prestamo_id = p.id_prestamo)
               )
    );
$$;

-- ---------------------------------------------------------------------
-- Procedimiento: registrar un préstamo (caso de uso completo)
-- Reglas: R1 (activo), R2 (no en mora), R3 (máx. 3 abiertos),
--         R4 (ejemplar disponible), y valida existencia de lector,
--         bibliotecario y ejemplar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE registrar_prestamo(
    p_documento_lector  varchar,
    p_codigo_ejemplar   varchar,
    p_documento_biblio  varchar,
    p_dias              integer DEFAULT 14
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_lector        usuarios%ROWTYPE;
    v_biblio        usuarios%ROWTYPE;
    v_ejemplar      ejemplares%ROWTYPE;
    v_abiertos      integer;
    v_id            integer;
BEGIN
    IF p_dias IS NULL OR p_dias <= 0 THEN
        RAISE EXCEPTION 'El plazo debe ser positivo (recibido: %)', p_dias;
    END IF;

    -- Lector
    SELECT * INTO v_lector FROM usuarios WHERE documento = p_documento_lector;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El lector con documento % no existe', p_documento_lector;
    END IF;
    IF v_lector.rol <> 'lector' THEN
        RAISE EXCEPTION 'El usuario % no es un lector (rol: %)',
                        p_documento_lector, v_lector.rol;
    END IF;
    IF v_lector.estado <> 'activo' THEN
        RAISE EXCEPTION 'El lector % no está activo (estado: %)',
                        p_documento_lector, v_lector.estado;
    END IF;

    -- R2: mora
    IF lector_en_mora(v_lector.id_usuario) THEN
        RAISE EXCEPTION 'El lector % está en mora; no puede tomar préstamos',
                        p_documento_lector;
    END IF;

    -- R3: máximo de abiertos
    v_abiertos := prestamos_abiertos(v_lector.id_usuario);
    IF v_abiertos >= 3 THEN
        RAISE EXCEPTION 'El lector % ya tiene % préstamos abiertos (máx. 3)',
                        p_documento_lector, v_abiertos;
    END IF;

    -- Bibliotecario
    SELECT * INTO v_biblio FROM usuarios WHERE documento = p_documento_biblio;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El bibliotecario con documento % no existe', p_documento_biblio;
    END IF;
    IF v_biblio.rol <> 'bibliotecario' THEN
        RAISE EXCEPTION 'El usuario % no es un bibliotecario (rol: %)',
                        p_documento_biblio, v_biblio.rol;
    END IF;
    IF v_biblio.estado <> 'activo' THEN
        RAISE EXCEPTION 'El bibliotecario % no está activo (estado: %)',
                        p_documento_biblio, v_biblio.estado;
    END IF;

    -- Ejemplar
    SELECT * INTO v_ejemplar FROM ejemplares WHERE codigo_inventario = p_codigo_ejemplar;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El ejemplar % no existe', p_codigo_ejemplar;
    END IF;
    IF v_ejemplar.estado IN ('perdido', 'baja') THEN
        RAISE EXCEPTION 'El ejemplar % está en estado %; no se puede prestar',
                        p_codigo_ejemplar, v_ejemplar.estado;
    END IF;

    -- R4: disponible
    IF NOT ejemplar_disponible(v_ejemplar.id_ejemplar) THEN
        RAISE EXCEPTION 'El ejemplar % no está disponible (estado: %, con préstamo abierto: %)',
                        p_codigo_ejemplar, v_ejemplar.estado,
                        CASE WHEN v_ejemplar.estado = 'prestado' THEN 'sí' ELSE 'no' END;
    END IF;

    INSERT INTO prestamos (fecha_prestamo, fecha_esperada,
                           ejemplar_id, lector_id, bibliotecario_id)
    VALUES (CURRENT_DATE, CURRENT_DATE + p_dias,
            v_ejemplar.id_ejemplar, v_lector.id_usuario, v_biblio.id_usuario)
    RETURNING id_prestamo INTO v_id;

    RAISE NOTICE 'Préstamo % registrado: lector %, ejemplar %, hasta %',
                 v_id, p_documento_lector, p_codigo_ejemplar, CURRENT_DATE + p_dias;
END;
$$;

-- ---------------------------------------------------------------------
-- Procedimiento: registrar una devolución
-- Reglas: el préstamo existe y está abierto; se registra la devolución.
-- El trigger AFTER sobre devoluciones libera el ejemplar.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE registrar_devolucion(
    p_id_prestamo     integer,
    p_fecha           date DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prestamo prestamos%ROWTYPE;
BEGIN
    SELECT * INTO v_prestamo FROM prestamos WHERE id_prestamo = p_id_prestamo;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El préstamo % no existe', p_id_prestamo;
    END IF;
    IF EXISTS (SELECT 1 FROM devoluciones WHERE prestamo_id = p_id_prestamo) THEN
        RAISE EXCEPTION 'El préstamo % ya fue devuelto', p_id_prestamo;
    END IF;
    IF p_fecha < v_prestamo.fecha_prestamo THEN
        RAISE EXCEPTION 'La fecha de devolución (%) es anterior a la del préstamo (%)',
                        p_fecha, v_prestamo.fecha_prestamo;
    END IF;

    INSERT INTO devoluciones (fecha_devolucion, prestamo_id)
    VALUES (p_fecha, p_id_prestamo);

    RAISE NOTICE 'Devolución registrada para el préstamo %', p_id_prestamo;
END;
$$;

-- ---------------------------------------------------------------------
-- Trigger BEFORE de validación (defensa en profundidad)
-- Impide que un INSERT directo sobre prestamos (desde psql u otro
-- programa) se salte R1, R2 y R4. Reutiliza las funciones de apoyo.
-- Es solo BEFORE INSERT: un UPDATE de un préstamo abierto (por ejemplo,
-- renovar la fecha_esperada) no debe exigir que el ejemplar esté
-- 'disponible', porque está prestado justamente por ese préstamo.
-- No valida R3 (máximo de abiertos): es una política de atención al
-- lector que queda en el procedimiento (como las reglas 4 y 5 de S22).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION validar_prestamo() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- R1: el lector existe, es lector y está activo
    IF NOT EXISTS (SELECT 1 FROM usuarios u
                   WHERE u.id_usuario = NEW.lector_id
                     AND u.rol = 'lector' AND u.estado = 'activo') THEN
        RAISE EXCEPTION 'El usuario % no es un lector activo; no puede registrar el préstamo',
                        NEW.lector_id;
    END IF;
    -- R2: mora
    IF lector_en_mora(NEW.lector_id) THEN
        RAISE EXCEPTION 'El lector % está en mora; no puede registrar el préstamo',
                        NEW.lector_id;
    END IF;
    -- R4: ejemplar disponible y sin préstamo abierto
    IF NOT ejemplar_disponible(NEW.ejemplar_id) THEN
        RAISE EXCEPTION 'El ejemplar % no está disponible para préstamo', NEW.ejemplar_id;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS prestamo_validar ON prestamos;
CREATE TRIGGER prestamo_validar
BEFORE INSERT ON prestamos
FOR EACH ROW
EXECUTE FUNCTION validar_prestamo();

-- ---------------------------------------------------------------------
-- Trigger AFTER: mantener ejemplares.estado = 'prestado'
-- (desnormalización del Hito 3, sección 5 del documento)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mantener_estado_ejemplar() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'prestamos' THEN
        -- Al prestar: si el ejemplar está disponible, pasa a 'prestado'
        UPDATE ejemplares
           SET estado = 'prestado'
         WHERE id_ejemplar = NEW.ejemplar_id
           AND estado = 'disponible';
    ELSIF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'devoluciones' THEN
        -- Al devolver: si el ejemplar está prestado, vuelve a 'disponible'
        UPDATE ejemplares e
           SET estado = 'disponible'
         WHERE e.id_ejemplar = (
                 SELECT p.ejemplar_id FROM prestamos p
                  WHERE p.id_prestamo = NEW.prestamo_id
               )
           AND e.estado = 'prestado';
    END IF;
    RETURN NULL;  -- AFTER: el valor de retorno se ignora
END;
$$;

DROP TRIGGER IF EXISTS prestamo_estado ON prestamos;
CREATE TRIGGER prestamo_estado
AFTER INSERT ON prestamos
FOR EACH ROW
EXECUTE FUNCTION mantener_estado_ejemplar();

DROP TRIGGER IF EXISTS devolucion_estado ON devoluciones;
CREATE TRIGGER devolucion_estado
AFTER INSERT ON devoluciones
FOR EACH ROW
EXECUTE FUNCTION mantener_estado_ejemplar();

-- ---------------------------------------------------------------------
-- Trigger AFTER de auditoría (opcional, evidencia extra)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prestamo_auditoria (
    id_auditoria    integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_prestamo     integer     NOT NULL,
    accion          varchar(20) NOT NULL,   -- 'prestamo' | 'devolucion'
    fecha_registro  timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION auditar_prestamo() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'prestamos' THEN
        INSERT INTO prestamo_auditoria (id_prestamo, accion)
        VALUES (NEW.id_prestamo, 'prestamo');
    ELSIF TG_OP = 'INSERT' AND TG_TABLE_NAME = 'devoluciones' THEN
        INSERT INTO prestamo_auditoria (id_prestamo, accion)
        VALUES (NEW.prestamo_id, 'devolucion');
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS prestamo_auditar ON prestamos;
CREATE TRIGGER prestamo_auditar
AFTER INSERT ON prestamos
FOR EACH ROW
EXECUTE FUNCTION auditar_prestamo();

DROP TRIGGER IF EXISTS devolucion_auditar ON devoluciones;
CREATE TRIGGER devolucion_auditar
AFTER INSERT ON devoluciones
FOR EACH ROW
EXECUTE FUNCTION auditar_prestamo();