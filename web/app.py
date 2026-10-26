# AutoAudit - interfaz web (Flask + psycopg 3)
# Ejecutar: py web\app.py  ->  http://localhost:5000

import csv
import io
import secrets

import psycopg
from flask import (Flask, Response, flash, g, redirect, render_template,
                   request, session, url_for)

DB_HOST = "localhost"
DB_PORT = 5432
DB_NAME = "autoaudit"

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)

# Credenciales en memoria del servidor: {token: (usuario, contraseña)}
SESIONES = {}

COLUMNAS_HISTORIAL = ("fecha_hora, usuario, ip_origen, esquema, tabla, columna, "
                      "evento, registro_pk, valor_anterior, valor_nuevo")


def conectar(usuario=None, contrasena=None):
    """Abre una conexión con los datos indicados o con los de la sesión."""
    if usuario is None:
        usuario, contrasena = g.credenciales
    return psycopg.connect(host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
                           user=usuario, password=contrasena, autocommit=True)


def mensaje_error(e):
    diag = getattr(e, "diag", None)
    return (diag.message_primary if diag else None) or str(e)


@app.template_filter("fecha")
def formato_fecha(valor, segundos=False):
    if valor is None:
        return ""
    return valor.strftime("%d/%m/%Y %H:%M:%S" if segundos else "%d/%m/%Y %H:%M")


@app.before_request
def requerir_sesion():
    g.usuario = None
    if request.endpoint in ("login", "static"):
        return None
    credenciales = SESIONES.get(session.get("token"))
    if credenciales is None:
        return redirect(url_for("login"))
    g.credenciales = credenciales
    g.usuario = credenciales[0]
    return None


@app.errorhandler(psycopg.Error)
def error_bd(e):
    flash(mensaje_error(e), "error")
    if request.endpoint == "inicio":
        # Si falla la propia página de inicio, se cierra la sesión para no entrar en un ciclo
        SESIONES.pop(session.pop("token", None), None)
        return redirect(url_for("login"))
    return redirect(url_for("inicio"))


# ---------------------------------------------------------------------
# Sesión
# ---------------------------------------------------------------------

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        usuario = request.form.get("usuario", "")
        contrasena = request.form.get("contrasena", "")
        try:
            with conectar(usuario, contrasena) as con:
                es_admin = con.execute("SELECT auditoria.es_admin()").fetchone()[0]
        except psycopg.OperationalError:
            flash("Usuario o contraseña incorrectos", "error")
            return redirect(url_for("login"))
        except psycopg.errors.InsufficientPrivilege:
            # Sin acceso al esquema auditoria: tampoco es administrador
            es_admin = False
        if not es_admin:
            flash("El usuario no tiene privilegios para administrar la auditoría", "error")
            return redirect(url_for("login"))
        token = secrets.token_hex(32)
        SESIONES[token] = (usuario, contrasena)
        session["token"] = token
        return redirect(url_for("inicio"))
    return render_template("login.html")


@app.route("/salir")
def salir():
    SESIONES.pop(session.pop("token", None), None)
    return redirect(url_for("login"))


# ---------------------------------------------------------------------
# Inicio
# ---------------------------------------------------------------------

@app.route("/")
def inicio():
    with conectar() as con:
        tablas = con.execute(
            "SELECT esquema, tabla, activa, trigger_nombre, fecha_generacion "
            "FROM auditoria.tabla_auditada ORDER BY esquema, tabla").fetchall()
        disponibles = con.execute(
            "SELECT esquema, tabla FROM auditoria.v_tablas_disponibles").fetchall()
    return render_template("inicio.html", tablas=tablas, disponibles=disponibles)


@app.route("/elegir")
def elegir_tabla():
    esquema, _, tabla = request.args.get("tabla", "").partition(".")
    return redirect(url_for("configurar", esquema=esquema, tabla=tabla))


@app.route("/desactivar/<esquema>/<tabla>", methods=["POST"])
def desactivar(esquema, tabla):
    with conectar() as con:
        con.execute("SELECT auditoria.desactivar_tabla(%s, %s)", (esquema, tabla))
        con.execute("SELECT auditoria.generar_trigger(%s, %s)", (esquema, tabla))
    flash(f"Se desactivó la auditoría de {esquema}.{tabla}", "exito")
    return redirect(url_for("inicio"))


# ---------------------------------------------------------------------
# Configuración y trigger
# ---------------------------------------------------------------------

@app.route("/configurar/<esquema>/<tabla>", methods=["GET", "POST"])
def configurar(esquema, tabla):
    with conectar() as con:
        columnas = con.execute(
            "SELECT columna, tipo, posicion FROM auditoria.v_columnas_disponibles "
            "WHERE esquema = %s AND tabla = %s ORDER BY posicion", (esquema, tabla)).fetchall()

        if request.method == "GET":
            marcadas = {(c, ev) for c, ev in con.execute(
                "SELECT columna, evento FROM auditoria.v_configuracion "
                "WHERE esquema = %s AND tabla = %s AND auditando", (esquema, tabla))}
            return render_template("configurar.html", esquema=esquema, tabla=tabla,
                                   columnas=columnas, marcadas=marcadas)

        configurada = con.execute(
            "SELECT 1 FROM auditoria.tabla_auditada WHERE esquema = %s AND tabla = %s",
            (esquema, tabla)).fetchone() is not None
        activas = {c for (c,) in con.execute(
            "SELECT c.columna FROM auditoria.columna_auditada c "
            "JOIN auditoria.tabla_auditada t ON t.id = c.tabla_id "
            "WHERE t.esquema = %s AND t.tabla = %s AND c.activa", (esquema, tabla))}

        elegidas = {}
        for columna, _, posicion in columnas:
            eventos = [f"{ev}_{posicion}" in request.form for ev in ("INSERT", "UPDATE", "DELETE")]
            elegidas[columna] = eventos

        if not configurada and not any(any(ev) for ev in elegidas.values()):
            flash("Seleccione al menos una columna", "error")
            return redirect(url_for("configurar", esquema=esquema, tabla=tabla))

        for columna, (ins, upd, dele) in elegidas.items():
            if ins or upd or dele:
                con.execute("SELECT auditoria.configurar_columna(%s, %s, %s, %s, %s, %s)",
                            (esquema, tabla, columna, ins, upd, dele))
            elif columna in activas:
                con.execute("SELECT auditoria.desactivar_columna(%s, %s, %s)",
                            (esquema, tabla, columna))

        codigo = con.execute("SELECT auditoria.generar_trigger(%s, %s)",
                             (esquema, tabla)).fetchone()[0]

    if codigo is None:
        flash("No hay columnas activas: se eliminó el trigger", "exito")
        return redirect(url_for("inicio"))
    flash(f"Se generó el trigger de {esquema}.{tabla}", "exito")
    return redirect(url_for("ver_trigger", esquema=esquema, tabla=tabla))


@app.route("/trigger/<esquema>/<tabla>")
def ver_trigger(esquema, tabla):
    with conectar() as con:
        fila = con.execute(
            "SELECT pg_get_functiondef(('auditoria.' || quote_ident(t.funcion_nombre))::regproc), "
            "       (SELECT pg_get_triggerdef(tg.oid) FROM pg_trigger tg "
            "         WHERE tg.tgrelid = format('%%I.%%I', t.esquema, t.tabla)::regclass "
            "           AND tg.tgname = t.trigger_nombre) "
            "FROM auditoria.tabla_auditada t "
            "WHERE t.esquema = %s AND t.tabla = %s AND t.trigger_nombre IS NOT NULL",
            (esquema, tabla)).fetchone()
    if fila is None:
        flash(f"La tabla {esquema}.{tabla} no tiene trigger", "error")
        return redirect(url_for("inicio"))
    return render_template("trigger.html", esquema=esquema, tabla=tabla,
                           funcion=fila[0], trigger=fila[1])


# ---------------------------------------------------------------------
# Historial
# ---------------------------------------------------------------------

def consulta_historial(args):
    """Arma la consulta de historial según los parámetros del formulario."""
    desde = args.get("desde") or None
    hasta = args.get("hasta")
    hasta = hasta + " 23:59:59.999999" if hasta else None
    if args.get("tipo") == "columna":
        esquema, tabla, columna = (args.get("columna", "").split(".", 2) + ["", ""])[:3]
        return (f"SELECT {COLUMNAS_HISTORIAL} FROM auditoria.consultar_por_columna("
                "%s, %s, %s, %s::timestamptz, %s::timestamptz)",
                (esquema, tabla, columna, desde, hasta))
    return (f"SELECT {COLUMNAS_HISTORIAL} FROM auditoria.consultar_por_usuario("
            "%s, %s::timestamptz, %s::timestamptz)",
            (args.get("usuario", ""), desde, hasta))


@app.route("/historial")
def historial():
    with conectar() as con:
        usuarios = [u for (u,) in con.execute(
            "SELECT nombre FROM auditoria.usuario_auditado ORDER BY nombre")]
        columnas = [f"{e}.{t}.{c}" for e, t, c in con.execute(
            "SELECT t.esquema, t.tabla, c.columna FROM auditoria.columna_auditada c "
            "JOIN auditoria.tabla_auditada t ON t.id = c.tabla_id "
            "ORDER BY t.esquema, t.tabla, c.columna")]
        filas = None
        if "tipo" in request.args:
            sql, parametros = consulta_historial(request.args)
            filas = con.execute(sql + " LIMIT 501", parametros).fetchall()
    hay_mas = filas is not None and len(filas) > 500
    return render_template("historial.html", usuarios=usuarios, columnas=columnas,
                           filas=filas[:500] if filas else filas, hay_mas=hay_mas,
                           args=request.args)


@app.route("/historial/csv")
def historial_csv():
    sql, parametros = consulta_historial(request.args)
    with conectar() as con:
        filas = con.execute(sql, parametros).fetchall()
    salida = io.StringIO()
    escritor = csv.writer(salida)
    escritor.writerow(["fecha_hora", "usuario", "ip_origen", "tabla", "columna", "evento",
                       "registro", "valor_anterior", "valor_nuevo"])
    for f in filas:
        escritor.writerow([formato_fecha(f[0], True), f[1], f[2] or "", f"{f[3]}.{f[4]}",
                           f[5], f[6], f[7], f[8], f[9]])
    return Response(salida.getvalue().encode("utf-8-sig"), mimetype="text/csv",
                    headers={"Content-Disposition":
                             "attachment; filename=reporte_auditoria.csv"})


if __name__ == "__main__":
    app.run(host="localhost", port=5000)
