-- =====================================================================
-- AutoAudit - Pruebas funcionales (insert, update, delete, consultas, seguridad)
-- Ejecutar con:  psql -v ON_ERROR_STOP=1 -d autoaudit -f pruebas/01_pruebas_funcionales.sql
-- =====================================================================
\set ON_ERROR_STOP 1

-- ---------- Datos de ejemplo ----------
DROP SCHEMA IF EXISTS ventas CASCADE;
CREATE SCHEMA ventas;
CREATE TABLE ventas.cliente (
    id     serial PRIMARY KEY,
    nombre text NOT NULL,
    email  text,
    saldo  numeric(12,2) NOT NULL DEFAULT 0
);

DROP ROLE IF EXISTS ana;
DROP ROLE IF EXISTS luis;
CREATE ROLE ana  LOGIN IN ROLE auditoria_admin;   -- administradora de auditoría
CREATE ROLE luis LOGIN;                           -- usuario normal de la aplicación
GRANT USAGE ON SCHEMA ventas TO luis;
GRANT SELECT, INSERT, UPDATE, DELETE ON ventas.cliente TO luis;
GRANT USAGE ON SEQUENCE ventas.cliente_id_seq TO luis;

-- ---------- Diccionario de datos ----------
SELECT * FROM auditoria.v_tablas_disponibles WHERE esquema = 'ventas';
SELECT * FROM auditoria.v_columnas_disponibles WHERE esquema = 'ventas';

-- ---------- Configuración (como administradora) ----------
SET SESSION AUTHORIZATION ana;
SELECT auditoria.configurar_columna('ventas', 'cliente', 'nombre', true,  true,  true);
SELECT auditoria.configurar_columna('ventas', 'cliente', 'saldo',  true,  true,  true);
SELECT auditoria.configurar_columna('ventas', 'cliente', 'email',  false, true,  false);

-- Validación de existencia: debe fallar
DO $$
BEGIN
    PERFORM auditoria.configurar_columna('ventas', 'no_existe', 'x', true, true, true);
    RAISE EXCEPTION 'FALLO: aceptó una tabla inexistente';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLO%' THEN RAISE; END IF;
    RAISE NOTICE 'OK validación tabla: %', SQLERRM;
END $$;
DO $$
BEGIN
    PERFORM auditoria.configurar_columna('ventas', 'cliente', 'no_existe', true, true, true);
    RAISE EXCEPTION 'FALLO: aceptó una columna inexistente';
EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FALLO%' THEN RAISE; END IF;
    RAISE NOTICE 'OK validación columna: %', SQLERRM;
END $$;

-- Generación del trigger (muestra el código generado)
SELECT auditoria.generar_trigger('ventas', 'cliente');
SELECT * FROM auditoria.v_configuracion;
RESET SESSION AUTHORIZATION;

-- ---------- Seguridad ----------
SET SESSION AUTHORIZATION luis;
DO $$
BEGIN
    PERFORM auditoria.configurar_columna('ventas', 'cliente', 'email', true, true, true);
    RAISE EXCEPTION 'FALLO: un usuario normal pudo configurar';
EXCEPTION WHEN insufficient_privilege OR raise_exception THEN
    IF SQLERRM LIKE 'FALLO%' THEN RAISE; END IF;
    RAISE NOTICE 'OK sin privilegios para configurar: %', SQLERRM;
END $$;
DO $$
BEGIN
    INSERT INTO auditoria.bitacora (configuracion_id, usuario_id, estacion_id) VALUES (1, 1, 1);
    RAISE EXCEPTION 'FALLO: un usuario escribió directamente en la bitácora';
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'OK escritura directa en bitácora bloqueada: %', SQLERRM;
END $$;

-- ---------- Caso 1: INSERT ----------
INSERT INTO ventas.cliente (nombre, email, saldo) VALUES ('Juan Pérez', 'juan@correo.com', 100);
RESET SESSION AUTHORIZATION;

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM auditoria.v_bitacora
    WHERE tabla = 'cliente' AND evento = 'INSERT' AND registro_pk = '1' AND usuario = 'luis';
    ASSERT n = 2, format('INSERT: se esperaban 2 registros (nombre, saldo), hay %s', n);
    ASSERT (SELECT valor_nuevo FROM auditoria.v_bitacora
            WHERE evento = 'INSERT' AND columna = 'nombre' AND registro_pk = '1') = 'Juan Pérez';
    ASSERT NOT EXISTS (SELECT 1 FROM auditoria.v_bitacora WHERE evento = 'INSERT' AND columna = 'email'),
           'INSERT: email no debía auditarse en INSERT';
    RAISE NOTICE 'OK caso INSERT';
END $$;

-- ---------- Caso 2: UPDATE (valor antiguo y nuevo) ----------
SET SESSION AUTHORIZATION luis;
UPDATE ventas.cliente SET saldo = 250, email = 'jp@correo.com' WHERE id = 1;
UPDATE ventas.cliente SET saldo = 250 WHERE id = 1;   -- sin cambio real: no debe registrar
RESET SESSION AUTHORIZATION;

DO $$
DECLARE r record; n int;
BEGIN
    SELECT * INTO r FROM auditoria.v_bitacora WHERE evento = 'UPDATE' AND columna = 'saldo';
    ASSERT r.valor_anterior = '100.00' AND r.valor_nuevo = '250.00',
           format('UPDATE saldo: %s -> %s', r.valor_anterior, r.valor_nuevo);
    SELECT * INTO r FROM auditoria.v_bitacora WHERE evento = 'UPDATE' AND columna = 'email';
    ASSERT r.valor_anterior = 'juan@correo.com' AND r.valor_nuevo = 'jp@correo.com';
    SELECT count(*) INTO n FROM auditoria.v_bitacora WHERE evento = 'UPDATE';
    ASSERT n = 2, format('UPDATE: se esperaban 2 registros, hay %s', n);
    RAISE NOTICE 'OK caso UPDATE';
END $$;

-- ---------- Caso 3: DELETE (preservación de datos) ----------
SET SESSION AUTHORIZATION luis;
DELETE FROM ventas.cliente WHERE id = 1;
RESET SESSION AUTHORIZATION;

DO $$
DECLARE n int;
BEGIN
    ASSERT NOT EXISTS (SELECT 1 FROM ventas.cliente WHERE id = 1);
    SELECT count(*) INTO n FROM auditoria.v_bitacora
    WHERE evento = 'DELETE' AND registro_pk = '1'
      AND ((columna = 'nombre' AND valor_anterior = 'Juan Pérez')
        OR (columna = 'saldo'  AND valor_anterior = '250.00'));
    ASSERT n = 2, format('DELETE: se esperaban 2 registros con datos originales, hay %s', n);
    RAISE NOTICE 'OK caso DELETE (datos preservados tras eliminar el registro)';
END $$;

-- ---------- Consultas históricas ----------
SELECT * FROM auditoria.consultar_por_usuario('luis');
SELECT * FROM auditoria.consultar_por_columna('ventas', 'cliente', 'saldo');

DO $$
BEGIN
    ASSERT (SELECT count(*) FROM auditoria.consultar_por_usuario('luis')) = 6;
    ASSERT (SELECT count(*) FROM auditoria.consultar_por_columna('ventas', 'cliente', 'saldo')) = 3;
    RAISE NOTICE 'OK consultas por usuario y por columna';
END $$;

-- Exportación de reportes a CSV
\copy (SELECT * FROM auditoria.consultar_por_usuario('luis')) TO 'reporte_usuario.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM auditoria.consultar_por_columna('ventas','cliente','saldo')) TO 'reporte_columna.csv' WITH (FORMAT csv, HEADER)

-- ---------- Desactivación ----------
SET SESSION AUTHORIZATION ana;
SELECT auditoria.desactivar_columna('ventas', 'cliente', 'email');
SELECT auditoria.generar_trigger('ventas', 'cliente');
RESET SESSION AUTHORIZATION;
UPDATE ventas.cliente SET email = 'x' WHERE false;  -- (sin filas)
INSERT INTO ventas.cliente (nombre, email) VALUES ('Ana', 'a@a.com');
UPDATE ventas.cliente SET email = 'b@b.com' WHERE nombre = 'Ana';
DO $$
BEGIN
    ASSERT (SELECT count(*) FROM auditoria.v_bitacora WHERE columna = 'email') = 1,
           'Desactivación: email no debía registrar más cambios';
    RAISE NOTICE 'OK desactivación de columna';
END $$;

\echo '=== TODAS LAS PRUEBAS FUNCIONALES PASARON ==='
