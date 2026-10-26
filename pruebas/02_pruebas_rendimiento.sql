-- =====================================================================
-- AutoAudit - Pruebas de rendimiento con volumen creciente
-- Compara el tiempo de INSERT/UPDATE/DELETE en una tabla sin auditoría
-- contra la misma tabla con auditoría (2 columnas, 3 eventos).
-- Ejecutar con:  psql -v ON_ERROR_STOP=1 -d autoaudit -f pruebas/02_pruebas_rendimiento.sql
-- =====================================================================
\set ON_ERROR_STOP 1

DROP SCHEMA IF EXISTS rendimiento CASCADE;
CREATE SCHEMA rendimiento;
CREATE TABLE rendimiento.sin_auditoria (id int PRIMARY KEY, nombre text, monto numeric);
CREATE TABLE rendimiento.con_auditoria (id int PRIMARY KEY, nombre text, monto numeric);

SELECT auditoria.configurar_columna('rendimiento', 'con_auditoria', 'nombre', true, true, true);
SELECT auditoria.configurar_columna('rendimiento', 'con_auditoria', 'monto',  true, true, true);
SELECT auditoria.generar_trigger('rendimiento', 'con_auditoria') IS NOT NULL AS trigger_generado;

CREATE TEMP TABLE resultado (registros int, tabla text, insert_ms numeric, update_ms numeric, delete_ms numeric);

DO $$
DECLARE
    n   int;
    t   text;
    t0  timestamptz;
    ti  numeric; tu numeric; td numeric;
BEGIN
    FOREACH n IN ARRAY ARRAY[1000, 10000, 50000, 100000] LOOP
        FOREACH t IN ARRAY ARRAY['sin_auditoria', 'con_auditoria'] LOOP
            t0 := clock_timestamp();
            EXECUTE format('INSERT INTO rendimiento.%I SELECT g, ''nombre '' || g, g FROM generate_series(1, %s) g', t, n);
            ti := extract(epoch FROM clock_timestamp() - t0) * 1000;

            t0 := clock_timestamp();
            EXECUTE format('UPDATE rendimiento.%I SET monto = monto + 1', t);
            tu := extract(epoch FROM clock_timestamp() - t0) * 1000;

            t0 := clock_timestamp();
            EXECUTE format('DELETE FROM rendimiento.%I', t);
            td := extract(epoch FROM clock_timestamp() - t0) * 1000;

            INSERT INTO resultado VALUES (n, t, round(ti, 1), round(tu, 1), round(td, 1));
        END LOOP;
    END LOOP;
END $$;

SELECT r.registros, r.tabla, r.insert_ms, r.update_ms, r.delete_ms,
       round((r.insert_ms + r.update_ms + r.delete_ms) * 1000 / r.registros / 3, 2) AS microseg_por_fila
FROM resultado r ORDER BY registros, tabla DESC;

SELECT count(*) AS filas_en_bitacora FROM auditoria.v_bitacora WHERE esquema = 'rendimiento';
