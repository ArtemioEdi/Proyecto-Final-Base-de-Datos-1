# AutoAudit

Sistema de auditoría automatizado para PostgreSQL 18 (Windows 11).

## Estructura

| Archivo | Contenido |
|---|---|
| `sql/01_estructura.sql` | Tablas del sistema (esquema `auditoria`) y permisos |
| `sql/02_diccionario.sql` | Consultas al diccionario de datos (tablas, columnas, llaves primarias) |
| `sql/03_configuracion.sql` | Configuración de tablas, columnas y eventos a auditar |
| `sql/04_generador.sql` | Generación dinámica de triggers según configuración |
| `sql/05_consultas.sql` | Consultas parametrizadas de historial (por usuario y por columna) |
| `instalar.sql` | Ejecuta los cinco scripts en orden |
| `pruebas/01_pruebas_funcionales.sql` | Casos de prueba INSERT, UPDATE, DELETE, consultas y seguridad |
| `pruebas/02_pruebas_rendimiento.sql` | Prueba de rendimiento con volumen creciente |
| `web/` | Interfaz web (Flask) |

## Preparar la consola (PowerShell)

```powershell
$env:Path += ";C:\Program Files\PostgreSQL\18\bin"
$env:PGHOST = "localhost"
$env:PGUSER = "postgres"
$env:PGPASSWORD = "admin123"
$env:PGCLIENTENCODING = "UTF8"
$env:PAGER = ""
```

## Instalación

```powershell
createdb autoaudit
psql -v ON_ERROR_STOP=1 -d autoaudit -f instalar.sql
```

## Uso

```sql
-- 1. Ver tablas y columnas disponibles
SELECT * FROM auditoria.v_tablas_disponibles;
SELECT * FROM auditoria.v_columnas_disponibles WHERE tabla = 'cliente';

-- 2. Configurar columnas (esquema, tabla, columna, insert, update, delete)
SELECT auditoria.configurar_columna('ventas', 'cliente', 'saldo', true, true, true);

-- 3. Generar el trigger
SELECT auditoria.generar_trigger('ventas', 'cliente');

-- 4. Consultar historial
SELECT * FROM auditoria.consultar_por_usuario('luis');
SELECT * FROM auditoria.consultar_por_columna('ventas', 'cliente', 'saldo');

-- 5. Exportar a CSV (psql)
\copy (SELECT * FROM auditoria.consultar_por_usuario('luis')) TO 'reporte.csv' WITH (FORMAT csv, HEADER)
```

Solo superusuarios o miembros del rol `auditoria_admin` pueden configurar y consultar.
Después de cambiar la configuración se debe volver a ejecutar `generar_trigger`.

## Pruebas

```powershell
cd pruebas
psql -v ON_ERROR_STOP=1 -d autoaudit -f 01_pruebas_funcionales.sql
psql -v ON_ERROR_STOP=1 -d autoaudit -f 02_pruebas_rendimiento.sql
```

## Interfaz web

Página web (Flask) para elegir tablas y columnas, generar y ver triggers, consultar el historial y exportarlo a CSV.

```powershell
py -m pip install -r web\requirements.txt
py web\app.py
```

Abrir `http://localhost:5000` e ingresar con un usuario de PostgreSQL que sea superusuario o miembro del rol `auditoria_admin`.
La conexión a la base se configura con las constantes `DB_HOST`, `DB_PORT` y `DB_NAME` al inicio de `web\app.py`.
