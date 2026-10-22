-- Biblioteca: esquema del proyecto (script de arranque de postgres/init/)
-- Basado en el modelo E-R del grupo (lab2BS.sql), con estos ajustes:
--   * claves primarias autogeneradas (GENERATED ALWAYS AS IDENTITY) para poder
--     cargar desde CSV, que no trae ids
--   * llave foránea devoluciones -> prestamos en el sentido correcto
--   * autores.nombre UNIQUE (para no duplicar autores al cargar)
--   * CHECKs de estado/rol/año, y tablas de paso + bitácora para la carga S14

\set ON_ERROR_STOP on

-- pgcrypto se instala en public para que no lo borre el DROP SCHEMA de abajo
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public;

DROP SCHEMA IF EXISTS biblioteca CASCADE;
CREATE SCHEMA biblioteca;
SET search_path TO biblioteca, public;

-- ---------------------------------------------------------------
-- Tablas del modelo
-- ---------------------------------------------------------------

CREATE TABLE categorias (
  id_categoria  integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre        varchar(100) NOT NULL UNIQUE
);

CREATE TABLE autores (
  id_autor  integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre    varchar(150) NOT NULL UNIQUE
);

CREATE TABLE usuarios (
  id_usuario     integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  documento      varchar(20)  NOT NULL UNIQUE,
  nombre         varchar(100) NOT NULL,
  correo         varchar(150) NOT NULL UNIQUE,
  telefono       varchar(20),
  username       varchar(50)  NOT NULL UNIQUE,
  password_hash  varchar(255) NOT NULL,
  rol            varchar(20)  NOT NULL CHECK (rol IN ('lector', 'bibliotecario')),
  estado         varchar(20)  NOT NULL CHECK (estado IN ('activo', 'inactivo', 'suspendido'))
);

CREATE TABLE libros (
  id_libro          integer      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  titulo            varchar(200) NOT NULL CHECK (titulo <> ''),
  isbn              varchar(20)  UNIQUE,
  anio_publicacion  integer      CHECK (anio_publicacion BETWEEN 1450 AND 2100),
  editorial         varchar(150),
  estado            varchar(20)  NOT NULL CHECK (estado IN ('disponible', 'baja')),
  categoria_id      integer      NOT NULL REFERENCES categorias (id_categoria)
);

CREATE TABLE libro_autor (
  libro_id  integer NOT NULL REFERENCES libros (id_libro),
  autor_id  integer NOT NULL REFERENCES autores (id_autor),
  PRIMARY KEY (libro_id, autor_id)
);

CREATE TABLE ejemplares (
  id_ejemplar        integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo_inventario  varchar(50) NOT NULL UNIQUE,
  estado             varchar(30) NOT NULL CHECK (estado IN ('disponible', 'prestado', 'perdido', 'baja')),
  libro_id           integer     NOT NULL REFERENCES libros (id_libro)
);

CREATE TABLE prestamos (
  id_prestamo       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fecha_prestamo    date    NOT NULL,
  fecha_esperada    date    NOT NULL CHECK (fecha_esperada >= fecha_prestamo),
  ejemplar_id       integer NOT NULL REFERENCES ejemplares (id_ejemplar),
  lector_id         integer NOT NULL REFERENCES usuarios (id_usuario),
  bibliotecario_id  integer NOT NULL REFERENCES usuarios (id_usuario)
);

CREATE TABLE devoluciones (
  id_devolucion     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  fecha_devolucion  date    NOT NULL,
  prestamo_id       integer NOT NULL UNIQUE REFERENCES prestamos (id_prestamo)
);

-- ---------------------------------------------------------------
-- Carga desde CSV (S14): bitácora y tablas de paso
-- ---------------------------------------------------------------

-- Bitácora de filas rechazadas: persiste entre cargas.
CREATE TABLE rechazo_carga (
  id         integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  archivo    text        NOT NULL,
  linea      integer     NOT NULL,
  contenido  text        NOT NULL,
  motivo     text        NOT NULL,
  fecha      timestamptz NOT NULL DEFAULT now()
);

-- Tablas de paso: todo texto, sin restricciones. Cada carga las vacía.
CREATE TABLE stg_linea (
  n      integer GENERATED ALWAYS AS IDENTITY,
  linea  text
);

CREATE TABLE stg_libro (
  linea_csv               integer,
  contenido               text,
  num_campos              integer,
  isbn                    text,
  titulo                  text,
  autor                   text,
  categoria               text,
  anio_publicacion        text,
  ejemplares_disponibles  text,
  motivo                  text     -- NULL = la fila pasó la validación
);

CREATE TABLE stg_lector (
  linea_csv   integer,
  contenido   text,
  num_campos  integer,
  documento   text,
  nombres     text,
  apellidos   text,
  correo      text,
  telefono    text,
  motivo      text
);
