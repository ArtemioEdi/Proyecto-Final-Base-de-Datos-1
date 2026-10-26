-- =====================================================================
-- AutoAudit - 02_diccionario.sql
-- Consultas para obtener datos del diccionario de datos del DBMS
-- =====================================================================

-- Tablas existentes que pueden auditarse
CREATE OR REPLACE VIEW auditoria.v_tablas_disponibles AS
SELECT n.nspname AS esquema,
       c.relname AS tabla
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'auditoria')
ORDER BY 1, 2;

-- Columnas existentes de cada tabla
CREATE OR REPLACE VIEW auditoria.v_columnas_disponibles AS
SELECT n.nspname                                   AS esquema,
       c.relname                                   AS tabla,
       a.attname                                   AS columna,
       pg_catalog.format_type(a.atttypid, a.atttypmod) AS tipo,
       a.attnum                                    AS posicion,
       a.attnotnull                                AS no_nulo
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c     ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND a.attnum > 0
  AND NOT a.attisdropped
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast', 'auditoria')
ORDER BY 1, 2, 5;

-- Columnas de llave primaria de cada tabla
CREATE OR REPLACE VIEW auditoria.v_llaves_primarias AS
SELECT n.nspname AS esquema,
       c.relname AS tabla,
       a.attname AS columna,
       k.ord     AS orden
FROM pg_catalog.pg_index i
JOIN pg_catalog.pg_class c     ON c.oid = i.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum = k.attnum
WHERE i.indisprimary
ORDER BY 1, 2, 4;

-- Funciones de validación de existencia
CREATE OR REPLACE FUNCTION auditoria.existe_tabla(p_esquema name, p_tabla name)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM auditoria.v_tablas_disponibles
                   WHERE esquema = p_esquema AND tabla = p_tabla);
$$;

CREATE OR REPLACE FUNCTION auditoria.existe_columna(p_esquema name, p_tabla name, p_columna name)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM auditoria.v_columnas_disponibles
                   WHERE esquema = p_esquema AND tabla = p_tabla AND columna = p_columna);
$$;

GRANT SELECT ON auditoria.v_tablas_disponibles, auditoria.v_columnas_disponibles,
                auditoria.v_llaves_primarias TO auditoria_admin;
