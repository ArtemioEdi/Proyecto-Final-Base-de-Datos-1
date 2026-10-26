-- AutoAudit - instalación completa
-- psql -v ON_ERROR_STOP=1 -U postgres -d autoaudit -f instalar.sql
\set ON_ERROR_STOP 1
\ir sql/01_estructura.sql
\ir sql/02_diccionario.sql
\ir sql/03_configuracion.sql
\ir sql/04_generador.sql
\ir sql/05_consultas.sql
\echo '=== AutoAudit instalado ==='
