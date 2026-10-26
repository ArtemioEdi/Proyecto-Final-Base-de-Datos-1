-- =====================================================================
-- AutoAudit - 03_configuracion.sql
-- Configuración de tablas, columnas y eventos a auditar
-- =====================================================================

-- ¿El usuario conectado tiene privilegios administrativos?
CREATE OR REPLACE FUNCTION auditoria.es_admin()
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = session_user)
        OR pg_catalog.pg_has_role(session_user, 'auditoria_admin', 'MEMBER');
$$;

CREATE OR REPLACE FUNCTION auditoria.validar_admin()
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF NOT auditoria.es_admin() THEN
        RAISE EXCEPTION 'El usuario % no tiene privilegios para configurar auditoría', session_user;
    END IF;
END $$;

-- Configura una columna de una tabla indicando qué operaciones se auditan.
-- Valida que la tabla y la columna existan antes de activarla.
CREATE OR REPLACE FUNCTION auditoria.configurar_columna(
    p_esquema name, p_tabla name, p_columna name,
    p_insert boolean, p_update boolean, p_delete boolean)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE
    v_tabla_id   int;
    v_columna_id int;
BEGIN
    PERFORM auditoria.validar_admin();

    IF NOT auditoria.existe_tabla(p_esquema, p_tabla) THEN
        RAISE EXCEPTION 'La tabla %.% no existe', p_esquema, p_tabla;
    END IF;
    IF NOT auditoria.existe_columna(p_esquema, p_tabla, p_columna) THEN
        RAISE EXCEPTION 'La columna % no existe en %.%', p_columna, p_esquema, p_tabla;
    END IF;

    INSERT INTO tabla_auditada (esquema, tabla) VALUES (p_esquema, p_tabla)
    ON CONFLICT (esquema, tabla) DO UPDATE SET activa = true
    RETURNING id INTO v_tabla_id;

    INSERT INTO columna_auditada (tabla_id, columna) VALUES (v_tabla_id, p_columna)
    ON CONFLICT (tabla_id, columna) DO UPDATE SET activa = true
    RETURNING id INTO v_columna_id;

    INSERT INTO configuracion (columna_id, evento_id, activa)
    VALUES (v_columna_id, 1, p_insert), (v_columna_id, 2, p_update), (v_columna_id, 3, p_delete)
    ON CONFLICT (columna_id, evento_id) DO UPDATE SET activa = EXCLUDED.activa;
END $$;

-- Desactiva la auditoría de una columna
CREATE OR REPLACE FUNCTION auditoria.desactivar_columna(p_esquema name, p_tabla name, p_columna name)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
BEGIN
    PERFORM auditoria.validar_admin();
    UPDATE columna_auditada c SET activa = false
    FROM tabla_auditada t
    WHERE t.id = c.tabla_id AND t.esquema = p_esquema AND t.tabla = p_tabla AND c.columna = p_columna;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La columna %.%.% no está configurada', p_esquema, p_tabla, p_columna;
    END IF;
END $$;

-- Desactiva la auditoría de una tabla completa
CREATE OR REPLACE FUNCTION auditoria.desactivar_tabla(p_esquema name, p_tabla name)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
BEGIN
    PERFORM auditoria.validar_admin();
    UPDATE tabla_auditada SET activa = false WHERE esquema = p_esquema AND tabla = p_tabla;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La tabla %.% no está configurada', p_esquema, p_tabla;
    END IF;
END $$;

-- Vista del estado actual de la configuración
CREATE OR REPLACE VIEW auditoria.v_configuracion AS
SELECT t.esquema, t.tabla, c.columna, e.nombre AS evento,
       (t.activa AND c.activa AND cf.activa) AS auditando,
       cf.id AS configuracion_id,
       t.trigger_nombre
FROM auditoria.configuracion cf
JOIN auditoria.columna_auditada c ON c.id = cf.columna_id
JOIN auditoria.tabla_auditada t   ON t.id = c.tabla_id
JOIN auditoria.evento e           ON e.id = cf.evento_id
ORDER BY t.esquema, t.tabla, c.columna, e.id;

REVOKE ALL ON FUNCTION auditoria.configurar_columna(name, name, name, boolean, boolean, boolean),
                       auditoria.desactivar_columna(name, name, name),
                       auditoria.desactivar_tabla(name, name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auditoria.configurar_columna(name, name, name, boolean, boolean, boolean),
                          auditoria.desactivar_columna(name, name, name),
                          auditoria.desactivar_tabla(name, name) TO auditoria_admin;
GRANT SELECT ON auditoria.v_configuracion TO auditoria_admin;
