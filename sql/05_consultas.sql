-- =====================================================================
-- AutoAudit - 05_consultas.sql
-- Consultas parametrizadas para consulta histórica de cambios
-- =====================================================================

-- Vista legible de la bitácora
CREATE OR REPLACE VIEW auditoria.v_bitacora AS
SELECT b.id,
       b.fecha_hora,
       u.nombre        AS usuario,
       e.ip            AS ip_origen,
       t.esquema,
       t.tabla,
       c.columna,
       ev.nombre       AS evento,
       b.registro_pk,
       b.valor_anterior,
       b.valor_nuevo
FROM auditoria.bitacora b
JOIN auditoria.configuracion cf    ON cf.id = b.configuracion_id
JOIN auditoria.columna_auditada c  ON c.id  = cf.columna_id
JOIN auditoria.tabla_auditada t    ON t.id  = c.tabla_id
JOIN auditoria.evento ev           ON ev.id = cf.evento_id
JOIN auditoria.usuario_auditado u  ON u.id  = b.usuario_id
JOIN auditoria.estacion_trabajo e  ON e.id  = b.estacion_id;

-- Historial de cambios por usuario (orden cronológico)
CREATE OR REPLACE FUNCTION auditoria.consultar_por_usuario(
    p_usuario name,
    p_desde timestamptz DEFAULT NULL,
    p_hasta timestamptz DEFAULT NULL)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE sql STABLE AS $$
    SELECT * FROM auditoria.v_bitacora
    WHERE usuario = p_usuario
      AND (p_desde IS NULL OR fecha_hora >= p_desde)
      AND (p_hasta IS NULL OR fecha_hora <= p_hasta)
    ORDER BY fecha_hora, id;
$$;

-- Historial de cambios de una columna específica (orden cronológico)
CREATE OR REPLACE FUNCTION auditoria.consultar_por_columna(
    p_esquema name, p_tabla name, p_columna name,
    p_desde timestamptz DEFAULT NULL,
    p_hasta timestamptz DEFAULT NULL)
RETURNS SETOF auditoria.v_bitacora
LANGUAGE sql STABLE AS $$
    SELECT * FROM auditoria.v_bitacora
    WHERE esquema = p_esquema AND tabla = p_tabla AND columna = p_columna
      AND (p_desde IS NULL OR fecha_hora >= p_desde)
      AND (p_hasta IS NULL OR fecha_hora <= p_hasta)
    ORDER BY fecha_hora, id;
$$;

GRANT SELECT ON auditoria.v_bitacora TO auditoria_admin;

-- Exportación de reportes (CSV) desde psql:
--   \copy (SELECT * FROM auditoria.consultar_por_usuario('ana')) TO 'reporte_usuario.csv' WITH (FORMAT csv, HEADER)
--   \copy (SELECT * FROM auditoria.consultar_por_columna('public','cliente','saldo')) TO 'reporte_columna.csv' WITH (FORMAT csv, HEADER)
