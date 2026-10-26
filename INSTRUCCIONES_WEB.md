# Instrucciones para Claude Code: interfaz web de AutoAudit

Lee este archivo completo antes de empezar. Trabaja en español (código, comentarios, textos de la interfaz y mensajes).

## 1. Contexto

AutoAudit es un proyecto de curso (Base de Datos 1) que pide un sistema de auditoría configurable en PostgreSQL: el usuario elige tablas y columnas, el sistema genera triggers automáticamente y registra los cambios en una bitácora centralizada.

**Toda la lógica ya está hecha y probada** en SQL (carpeta `sql/`). Las pruebas de `pruebas/` pasan en esta PC. Tu trabajo es **solo la interfaz web**: una página que llama a las funciones SQL existentes.

### Regla principal

El proyecto debe ser **lo más simple posible y cumplir exactamente lo que pide el curso**. No agregues funciones, librerías, validaciones extra ni mejoras que no estén en este documento. Si algo no está aquí, no lo hagas.

**No modifiques nada en `sql/`, `pruebas/` ni `instalar.sql`.**

### Entorno

- Windows 11, Visual Studio Code.
- PostgreSQL 18 local: host `localhost`, puerto `5432`, base `autoaudit`, usuario `postgres`, contraseña `admin123`.
- `psql` está en `C:\Program Files\PostgreSQL\18\bin` (puede no estar en el PATH: agrégalo a la sesión si lo necesitas).
- Python se ejecuta con `py`. Ya está instalado `psycopg` 3.
- La base `autoaudit` ya existe y AutoAudit ya está instalado. Puede contener datos de pruebas anteriores (incluyendo ~805 000 filas de la prueba de rendimiento en la bitácora).
- Para psql en esta PC conviene: `PGCLIENTENCODING=UTF8` y `PAGER` vacío.

## 2. Qué hay que hacer (resumen)

1. Borrar la aplicación de consola: carpeta `app/` completa.
2. Crear la interfaz web en la carpeta `web/` con **Flask + HTML/CSS escritos a mano** (plantillas Jinja).
3. Probarla contra la base de datos real.
4. Actualizar el `README.md`.

## 3. Restricciones técnicas de la web

- **Flask** y **psycopg 3** (`psycopg[binary]`). Nada más.
- **Sin JavaScript** (ni propio ni librerías). Todo con formularios HTML normales (`GET`/`POST`), enlaces y redirecciones.
- **Sin frameworks de CSS** (nada de Bootstrap, Tailwind, etc.) ni fuentes externas. Un solo archivo `static/estilos.css`.
- Toda la lógica de auditoría se hace llamando a las funciones/vistas SQL de la sección 5. **No escribas SQL que inserte o modifique directamente las tablas del esquema `auditoria`**; solo llama a sus funciones o lee sus vistas/tablas.
- Usa siempre consultas parametrizadas (`%s`), nunca concatenes valores en el SQL.

## 4. Estructura de archivos

```
web/
├── app.py
├── requirements.txt        (flask, psycopg[binary])
├── templates/
│   ├── base.html           (encabezado, menú, mensajes flash; las demás heredan de esta)
│   ├── login.html
│   ├── inicio.html
│   ├── configurar.html
│   ├── trigger.html
│   └── historial.html
└── static/
    └── estilos.css
```

Se ejecuta con `py web\app.py` y queda en `http://localhost:5000`. En `app.py`, al inicio, constantes `DB_HOST = "localhost"`, `DB_PORT = 5432`, `DB_NAME = "autoaudit"`.

## 5. API SQL disponible (esquema `auditoria`)

Todas ya existen. Úsalas tal cual.

### Vistas y tablas de lectura

| Objeto | Columnas |
|---|---|
| `v_tablas_disponibles` | `esquema, tabla` (diccionario de datos; ya excluye el esquema `auditoria`) |
| `v_columnas_disponibles` | `esquema, tabla, columna, tipo, posicion, no_nulo` (ordenar por `posicion`) |
| `tabla_auditada` | `id, esquema, tabla, activa, trigger_nombre, funcion_nombre, fecha_generacion` (`trigger_nombre` NULL = sin trigger) |
| `columna_auditada` | `id, tabla_id, columna, activa` |
| `v_configuracion` | `esquema, tabla, columna, evento ('INSERT'/'UPDATE'/'DELETE'), auditando (bool), configuracion_id, trigger_nombre` |
| `usuario_auditado` | `id, nombre` |
| `v_bitacora` | `id, fecha_hora, usuario, ip_origen, esquema, tabla, columna, evento, registro_pk, valor_anterior, valor_nuevo` |

En `v_configuracion`, una casilla está marcada si `auditando = true` para esa columna y evento.

### Funciones

| Función | Qué hace |
|---|---|
| `auditoria.es_admin()` → boolean | Si el usuario conectado puede configurar (superusuario o miembro de `auditoria_admin`) |
| `auditoria.configurar_columna(esquema, tabla, columna, ins bool, upd bool, del bool)` | Registra/actualiza una columna con los eventos indicados; reactiva tabla y columna. Valida existencia y lanza excepción si no existe |
| `auditoria.desactivar_columna(esquema, tabla, columna)` | Desactiva una columna configurada |
| `auditoria.desactivar_tabla(esquema, tabla)` | Desactiva la tabla (después hay que llamar a `generar_trigger` para que se elimine el trigger) |
| `auditoria.generar_trigger(esquema, tabla)` → text | Genera/regenera el trigger según la configuración activa. Devuelve el código SQL generado, o NULL si no quedó nada activo (en ese caso elimina el trigger) |
| `auditoria.consultar_por_usuario(usuario, desde timestamptz, hasta timestamptz)` | Historial de un usuario, orden cronológico. `desde`/`hasta` pueden ser NULL |
| `auditoria.consultar_por_columna(esquema, tabla, columna, desde, hasta)` | Historial de una columna, orden cronológico |

Los errores de estas funciones llegan como excepciones de psycopg; el texto útil está en `e.diag.message_primary`.

Para **ver** el código de un trigger ya generado sin regenerarlo: `pg_get_functiondef(('auditoria.' || quote_ident(funcion_nombre))::regproc)` y `pg_get_triggerdef(oid)` del trigger `trigger_nombre` en la tabla (desde `pg_trigger`).

## 6. Funcionamiento de cada página

### Sesión e inicio de sesión (`/login`, `/salir`)

- Formulario con usuario y contraseña de PostgreSQL.
- Al enviar: intentar conectarse con esos datos y ejecutar `SELECT auditoria.es_admin()`. Si falla la conexión → mensaje "Usuario o contraseña incorrectos". Si `es_admin()` es falso → "El usuario no tiene privilegios para administrar la auditoría". En ambos casos no se entra.
- Si es correcto: generar un token aleatorio (`secrets.token_hex`), guardar `{token: (usuario, contraseña)}` en un diccionario en memoria del servidor y poner solo el token en `session` de Flask. **La contraseña no va en la cookie.** `app.secret_key = secrets.token_hex(32)`.
- Todas las demás páginas requieren sesión; si no hay, redirigir a `/login`.
- Una función auxiliar abre la conexión por petición con `psycopg.connect(host=..., port=..., dbname=..., user=..., password=..., autocommit=True)` y la cierra al terminar.
- `/salir` borra el token del diccionario y de la sesión.

### Inicio (`/`)

- Tabla con las tablas configuradas (`tabla_auditada`): esquema, tabla, activa (Sí/No), trigger (nombre o "Sin trigger"), fecha de generación (formato `dd/mm/aaaa hh:mm`).
- Por fila: enlaces/botones **Configurar**, **Ver trigger** (solo si tiene trigger) y **Desactivar** (solo si está activa; es un formulario POST a `/desactivar/<esquema>/<tabla>`).
- Debajo: formulario con un `<select>` de `v_tablas_disponibles` (texto `esquema.tabla`) y botón **Configurar tabla**, que lleva a la página de configuración.

### Configurar tabla (`/configurar/<esquema>/<tabla>`)

- GET: tabla con una fila por columna de `v_columnas_disponibles`: nombre, tipo, y tres casillas INSERT, UPDATE, DELETE, marcadas según `v_configuracion` (`auditando = true`). Botón **Guardar y generar trigger** y enlace **Cancelar**.
- POST, por cada columna de la tabla:
  - Si tiene al menos una casilla marcada → `configurar_columna(...)` con los tres valores.
  - Si no tiene ninguna marcada y estaba configurada (existe en `columna_auditada` activa) → `desactivar_columna(...)`.
  - Si no tiene ninguna y nunca estuvo configurada → no hacer nada.
- Después: `generar_trigger(esquema, tabla)`.
  - Si devuelve código → mensaje de éxito y redirigir a la página del trigger.
  - Si devuelve NULL → mensaje "No hay columnas activas: se eliminó el trigger" y redirigir al inicio.
- Si no se marcó ninguna casilla en una tabla que nunca estuvo configurada, mostrar el mensaje "Seleccione al menos una columna" y volver al formulario (no llamar a `generar_trigger`, porque fallaría al no estar configurada).

### Ver trigger (`/trigger/<esquema>/<tabla>`)

- Muestra en un bloque `<pre><code>` la definición de la función y la del trigger (ver sección 5). Si la tabla no tiene trigger, mensaje y redirigir al inicio.
- Enlace para volver al inicio.

### Desactivar (`POST /desactivar/<esquema>/<tabla>`)

- `desactivar_tabla(...)` y luego `generar_trigger(...)` (que elimina el trigger). Mensaje de éxito y redirigir al inicio.

### Historial (`/historial`)

- Formulario GET con:
  - Tipo de búsqueda: radio "Por usuario" / "Por columna".
  - `<select>` de usuarios (`usuario_auditado`).
  - `<select>` de columna con opciones `esquema.tabla.columna`, tomadas de las columnas configuradas (`columna_auditada` + `tabla_auditada`), sin importar si están activas.
  - Fecha desde y hasta (`<input type="date">`, opcionales). "Hasta" incluye todo ese día: enviar `hasta + ' 23:59:59.999999'`.
  - Botón **Buscar**.
- Resultado: tabla con fecha y hora (`dd/mm/aaaa hh:mm:ss`), usuario, IP origen, tabla (`esquema.tabla`), columna, evento, registro, valor anterior, valor nuevo. Orden cronológico (el que devuelve la función).
- Mostrar como máximo **500 filas** (`LIMIT 501` para saber si hay más). Si hay más, aviso: "Se muestran las primeras 500 filas. Exporte el CSV para ver todas."
- Si no hay resultados → "No hay cambios registrados para este filtro".
- Botón/enlace **Exportar CSV** a `/historial/csv` con los mismos parámetros: devuelve **todas** las filas, con encabezados, codificación `utf-8-sig` (para que Excel muestre bien los acentos), como descarga (`Content-Disposition: attachment; filename=reporte_auditoria.csv`).

### Todas las páginas

- Menú superior: AutoAudit (título), Inicio, Historial, usuario conectado y Salir.
- Mensajes con `flash()`: éxito en verde, error en rojo.
- Cualquier `psycopg.Error` dentro de una ruta se captura, se muestra como mensaje de error (`e.diag.message_primary`) y se redirige a una página válida; la aplicación nunca debe mostrar un error 500.
- Atributo `lang="es"` y `<meta charset="utf-8">` y `<meta name="viewport" content="width=device-width, initial-scale=1">`.

## 7. Diseño visual (CSS)

Sencillo y limpio:

- Fondo gris muy claro, contenido en tarjetas blancas con borde suave y esquinas redondeadas, ancho máximo ~1100 px centrado.
- Barra superior de color azul oscuro con texto blanco.
- Tablas con encabezado gris, filas alternadas y texto pequeño; en pantallas angostas, la tabla se desplaza horizontalmente dentro de su contenedor (`overflow-x: auto`), no la página.
- Botones: azul para acciones principales, gris para secundarias, rojo para desactivar.
- Tipografía del sistema (`system-ui, sans-serif`); `<pre>` con fuente monoespaciada, fondo oscuro y desplazamiento horizontal.
- Etiquetas de estado (Sí/No, eventos) como pequeñas "píldoras" de color.

## 8. Pruebas que debes hacer

1. Instalar dependencias: `py -m pip install -r web\requirements.txt`.
2. Dejar la base limpia: reinstalar AutoAudit (`psql -q -f instalar.sql` con las variables de la sección 1) para vaciar la bitácora. Crear una tabla de prueba:
   `CREATE TABLE public.producto (id serial PRIMARY KEY, nombre text, precio numeric(10,2));`
3. Probar con un script temporal usando `app.test_client()` de Flask (bórralo al terminar), verificando:
   - Login con contraseña incorrecta → rechazado.
   - Login con un usuario sin privilegios → rechazado (crea uno temporal con `CREATE ROLE prueba_web LOGIN PASSWORD 'x'` y elimínalo al final).
   - Login `postgres`/`admin123` → entra.
   - Configurar `public.producto`: `nombre` con los tres eventos, `precio` solo UPDATE → se genera el trigger y la página del trigger muestra el código.
   - Ejecutar con psql: `INSERT` de un producto, `UPDATE` del precio, `DELETE` → el historial por usuario `postgres` muestra 3 filas en orden; el historial por columna `public.producto.precio` muestra solo el UPDATE con valor anterior y nuevo.
   - El CSV se descarga con encabezados y las mismas filas.
   - Desmarcar todo en la configuración → se elimina el trigger. Desactivar desde el inicio también funciona.
   - Acceder a cualquier página sin sesión → redirige a `/login`.
4. Iniciar el servidor (`py web\app.py`) y pedirme que lo revise en el navegador.

Si alguna prueba falla, corrige el código de `web/` (no el SQL) y repite.

## 9. Al terminar

1. Borrar la carpeta `app/`.
2. Actualizar `README.md`:
   - Quitar la sección de la aplicación de consola.
   - Agregar sección "Interfaz web": instalación (`py -m pip install -r web\requirements.txt`), ejecución (`py web\app.py`), dirección `http://localhost:5000`, y que se entra con un usuario de PostgreSQL que sea superusuario o miembro de `auditoria_admin`.
   - Cambiar las instrucciones de instalación y pruebas para que sean de **Windows / PowerShell** (variables `PGUSER`, `PGPASSWORD`, `PGHOST`, `PGCLIENTENCODING`, `PAGER`, ruta de `psql`).
3. Darme un resumen corto de lo que hiciste y de cómo probarlo.
