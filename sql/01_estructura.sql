-- =====================================================================
-- AutoAudit - 01_estructura.sql
-- Scripts de creación de estructura de tablas del sistema
-- PostgreSQL 18 (ejecutar como superusuario)
-- =====================================================================

DROP SCHEMA IF EXISTS auditoria CASCADE;
CREATE SCHEMA auditoria;

-- Rol de administradores: solo sus miembros pueden configurar auditoría
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'auditoria_admin') THEN
        CREATE ROLE auditoria_admin NOLOGIN;
    END IF;
END $$;

-- Tablas auditadas
CREATE TABLE auditoria.tabla_auditada (
    id               serial PRIMARY KEY,
    esquema          name        NOT NULL,
    tabla            name        NOT NULL,
    activa           boolean     NOT NULL DEFAULT true,
    trigger_nombre   name,                 -- trigger generado actualmente (NULL = sin trigger)
    funcion_nombre   name,                 -- función del trigger generado
    fecha_generacion timestamptz,
    UNIQUE (esquema, tabla)
);

-- Columnas auditadas
CREATE TABLE auditoria.columna_auditada (
    id        serial PRIMARY KEY,
    tabla_id  int     NOT NULL REFERENCES auditoria.tabla_auditada(id),
    columna   name    NOT NULL,
    activa    boolean NOT NULL DEFAULT true,
    UNIQUE (tabla_id, columna)
);

-- Eventos (operaciones) auditables
CREATE TABLE auditoria.evento (
    id     smallint   PRIMARY KEY,
    nombre varchar(6) NOT NULL UNIQUE CHECK (nombre IN ('INSERT', 'UPDATE', 'DELETE'))
);
INSERT INTO auditoria.evento (id, nombre) VALUES (1, 'INSERT'), (2, 'UPDATE'), (3, 'DELETE');

-- Configuración: eventos que se deben auditar por cada columna de cada tabla
CREATE TABLE auditoria.configuracion (
    id         serial   PRIMARY KEY,
    columna_id int      NOT NULL REFERENCES auditoria.columna_auditada(id),
    evento_id  smallint NOT NULL REFERENCES auditoria.evento(id),
    activa     boolean  NOT NULL DEFAULT true,
    UNIQUE (columna_id, evento_id)
);

-- Usuarios auditados
CREATE TABLE auditoria.usuario_auditado (
    id     serial PRIMARY KEY,
    nombre name   NOT NULL UNIQUE
);

-- Estaciones de trabajo auditadas (IP origen; NULL = conexión local por socket)
CREATE TABLE auditoria.estacion_trabajo (
    id serial PRIMARY KEY,
    ip inet,
    CONSTRAINT estacion_trabajo_ip_uk UNIQUE NULLS NOT DISTINCT (ip)
);

-- Bitácora centralizada de cambios
-- No tiene llave foránea hacia las tablas origen: así conserva los datos
-- aunque el registro fuente sea eliminado.
CREATE TABLE auditoria.bitacora (
    id               bigserial   PRIMARY KEY,
    configuracion_id int         NOT NULL REFERENCES auditoria.configuracion(id),
    usuario_id       int         NOT NULL REFERENCES auditoria.usuario_auditado(id),
    estacion_id      int         NOT NULL REFERENCES auditoria.estacion_trabajo(id),
    fecha_hora       timestamptz NOT NULL DEFAULT now(),
    registro_pk      text,       -- valor de la llave primaria del registro afectado
    valor_anterior   text,
    valor_nuevo      text
);

CREATE INDEX bitacora_usuario_idx       ON auditoria.bitacora (usuario_id, fecha_hora);
CREATE INDEX bitacora_configuracion_idx ON auditoria.bitacora (configuracion_id, fecha_hora);
CREATE INDEX bitacora_fecha_idx         ON auditoria.bitacora (fecha_hora);

-- ---------------------------------------------------------------------
-- Seguridad
-- Nadie (salvo el dueño) puede escribir directamente en las tablas del
-- sistema. Los administradores solo pueden leerlas; la configuración se
-- hace mediante funciones y la bitácora solo la escriben los triggers.
-- ---------------------------------------------------------------------
REVOKE ALL ON ALL TABLES    IN SCHEMA auditoria FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA auditoria FROM PUBLIC;
GRANT USAGE  ON SCHEMA auditoria TO auditoria_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA auditoria TO auditoria_admin;
