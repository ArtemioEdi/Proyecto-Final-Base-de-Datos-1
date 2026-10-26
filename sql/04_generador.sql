-- =====================================================================
-- AutoAudit - 04_generador.sql
-- Módulo de generación dinámica de triggers según configuración
-- =====================================================================

-- Obtiene (o registra) el usuario que realiza el cambio
CREATE OR REPLACE FUNCTION auditoria.obtener_usuario()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE v_id int;
BEGIN
    SELECT id INTO v_id FROM usuario_auditado WHERE nombre = session_user;
    IF v_id IS NULL THEN
        INSERT INTO usuario_auditado (nombre) VALUES (session_user)
        ON CONFLICT (nombre) DO UPDATE SET nombre = EXCLUDED.nombre
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $$;

-- Obtiene (o registra) la estación de trabajo (IP origen) del cambio
CREATE OR REPLACE FUNCTION auditoria.obtener_estacion()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE v_id int;
BEGIN
    SELECT id INTO v_id FROM estacion_trabajo WHERE ip IS NOT DISTINCT FROM inet_client_addr();
    IF v_id IS NULL THEN
        INSERT INTO estacion_trabajo (ip) VALUES (inet_client_addr())
        ON CONFLICT ON CONSTRAINT estacion_trabajo_ip_uk DO UPDATE SET ip = EXCLUDED.ip
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END $$;

-- Elimina el trigger y la función generados para una tabla (si existen)
CREATE OR REPLACE FUNCTION auditoria.eliminar_trigger(p_esquema name, p_tabla name)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE r record;
BEGIN
    PERFORM auditoria.validar_admin();
    SELECT * INTO r FROM tabla_auditada WHERE esquema = p_esquema AND tabla = p_tabla;
    IF r.trigger_nombre IS NOT NULL THEN
        IF auditoria.existe_tabla(p_esquema, p_tabla) THEN
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.trigger_nombre, p_esquema, p_tabla);
        END IF;
        EXECUTE format('DROP FUNCTION IF EXISTS auditoria.%I()', r.funcion_nombre);
        UPDATE tabla_auditada
           SET trigger_nombre = NULL, funcion_nombre = NULL, fecha_generacion = now()
         WHERE id = r.id;
    END IF;
END $$;

-- Genera (o regenera) el trigger AFTER de una tabla a partir de su configuración.
-- Devuelve el código SQL generado.
CREATE OR REPLACE FUNCTION auditoria.generar_trigger(p_esquema name, p_tabla name)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE
    v_tabla      tabla_auditada%ROWTYPE;
    v_funcion    name := left('aud_' || p_esquema || '_' || p_tabla, 63);
    v_trigger    name := 'autoaudit_trg';
    v_pk_new     text;
    v_pk_old     text;
    v_ins        text := '';
    v_upd        text := '';
    v_del        text := '';
    v_eventos    text[] := '{}';
    v_codigo     text;
    r            record;
BEGIN
    PERFORM auditoria.validar_admin();

    SELECT * INTO v_tabla FROM tabla_auditada WHERE esquema = p_esquema AND tabla = p_tabla;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La tabla %.% no está configurada para auditoría', p_esquema, p_tabla;
    END IF;
    IF NOT auditoria.existe_tabla(p_esquema, p_tabla) THEN
        RAISE EXCEPTION 'La tabla %.% ya no existe en la base de datos', p_esquema, p_tabla;
    END IF;

    -- Expresión de llave primaria del registro afectado (NULL si la tabla no tiene PK)
    SELECT string_agg(format('NEW.%I::text', columna), ', ' ORDER BY orden),
           string_agg(format('OLD.%I::text', columna), ', ' ORDER BY orden)
      INTO v_pk_new, v_pk_old
      FROM v_llaves_primarias WHERE esquema = p_esquema AND tabla = p_tabla;
    v_pk_new := coalesce('concat_ws('','', ' || v_pk_new || ')', 'NULL');
    v_pk_old := coalesce('concat_ws('','', ' || v_pk_old || ')', 'NULL');

    -- Recorre la configuración activa y arma una instrucción por columna/evento
    FOR r IN
        SELECT c.columna, cf.id AS cfg_id, cf.evento_id
        FROM configuracion cf
        JOIN columna_auditada c ON c.id = cf.columna_id
        WHERE c.tabla_id = v_tabla.id AND v_tabla.activa AND c.activa AND cf.activa
        ORDER BY c.columna, cf.evento_id
    LOOP
        IF NOT auditoria.existe_columna(p_esquema, p_tabla, r.columna) THEN
            RAISE EXCEPTION 'La columna % ya no existe en %.%', r.columna, p_esquema, p_tabla;
        END IF;

        IF r.evento_id = 1 THEN
            v_ins := v_ins || format(E'        INSERT INTO auditoria.bitacora (configuracion_id, usuario_id, estacion_id, registro_pk, valor_anterior, valor_nuevo)\n'
                                    '        VALUES (%s, v_usr, v_est, %s, NULL, NEW.%I::text);\n',
                                    r.cfg_id, v_pk_new, r.columna);
        ELSIF r.evento_id = 2 THEN
            v_upd := v_upd || format(E'        IF NEW.%I IS DISTINCT FROM OLD.%I THEN\n'
                                    '            INSERT INTO auditoria.bitacora (configuracion_id, usuario_id, estacion_id, registro_pk, valor_anterior, valor_nuevo)\n'
                                    '            VALUES (%s, v_usr, v_est, %s, OLD.%I::text, NEW.%I::text);\n'
                                    '        END IF;\n',
                                    r.columna, r.columna, r.cfg_id, v_pk_new, r.columna, r.columna);
        ELSE
            v_del := v_del || format(E'        INSERT INTO auditoria.bitacora (configuracion_id, usuario_id, estacion_id, registro_pk, valor_anterior, valor_nuevo)\n'
                                    '        VALUES (%s, v_usr, v_est, %s, OLD.%I::text, NULL);\n',
                                    r.cfg_id, v_pk_old, r.columna);
        END IF;
    END LOOP;

    IF v_ins <> '' THEN v_eventos := array_append(v_eventos, 'INSERT'); END IF;
    IF v_upd <> '' THEN v_eventos := array_append(v_eventos, 'UPDATE'); END IF;
    IF v_del <> '' THEN v_eventos := array_append(v_eventos, 'DELETE'); END IF;

    -- Se elimina el trigger anterior (si lo hay) antes de generar el nuevo
    PERFORM auditoria.eliminar_trigger(p_esquema, p_tabla);

    IF cardinality(v_eventos) = 0 THEN
        RAISE NOTICE 'La tabla %.% no tiene columnas/eventos activos: no se genera trigger', p_esquema, p_tabla;
        RETURN NULL;
    END IF;

    v_codigo := format(E'CREATE FUNCTION auditoria.%I() RETURNS trigger\n'
                        'LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $trg$\n'
                        'DECLARE\n'
                        '    v_usr int := auditoria.obtener_usuario();\n'
                        '    v_est int := auditoria.obtener_estacion();\n'
                        'BEGIN\n'
                        '    IF TG_OP = ''INSERT'' THEN\n%s'
                        '    ELSIF TG_OP = ''UPDATE'' THEN\n%s'
                        '    ELSIF TG_OP = ''DELETE'' THEN\n%s'
                        '    END IF;\n'
                        '    RETURN NULL;\n'
                        'END $trg$;\n\n'
                        'CREATE TRIGGER %I AFTER %s ON %I.%I\n'
                        'FOR EACH ROW EXECUTE FUNCTION auditoria.%I();\n',
                        v_funcion,
                        coalesce(nullif(v_ins, ''), E'        NULL;\n'),
                        coalesce(nullif(v_upd, ''), E'        NULL;\n'),
                        coalesce(nullif(v_del, ''), E'        NULL;\n'),
                        v_trigger, array_to_string(v_eventos, ' OR '), p_esquema, p_tabla,
                        v_funcion);

    BEGIN
        EXECUTE v_codigo;
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'Error al generar el trigger de %.%: % (SQLSTATE %)',
                        p_esquema, p_tabla, SQLERRM, SQLSTATE;
    END;

    EXECUTE format('REVOKE ALL ON FUNCTION auditoria.%I() FROM PUBLIC', v_funcion);

    UPDATE tabla_auditada
       SET trigger_nombre = v_trigger, funcion_nombre = v_funcion, fecha_generacion = now()
     WHERE id = v_tabla.id;

    RETURN v_codigo;
END $$;

-- Genera los triggers de todas las tablas configuradas
CREATE OR REPLACE FUNCTION auditoria.generar_todos()
RETURNS TABLE (esquema name, tabla name, generado boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, auditoria AS $$
DECLARE r record;
BEGIN
    PERFORM auditoria.validar_admin();
    FOR r IN SELECT t.esquema, t.tabla FROM tabla_auditada t ORDER BY 1, 2 LOOP
        esquema := r.esquema;
        tabla   := r.tabla;
        generado := auditoria.generar_trigger(r.esquema, r.tabla) IS NOT NULL;
        RETURN NEXT;
    END LOOP;
END $$;

REVOKE ALL ON FUNCTION auditoria.generar_trigger(name, name), auditoria.generar_todos(),
                       auditoria.eliminar_trigger(name, name) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION auditoria.generar_trigger(name, name), auditoria.generar_todos(),
                          auditoria.eliminar_trigger(name, name) TO auditoria_admin;
