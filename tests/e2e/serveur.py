"""Petit serveur de test : sert la page (site/) et imite l'API de Supabase pour les fonctions SQL.

POST /rest/v1/rpc/<fonction>  → select public.<fonction>(…) avec le rôle « anon », comme Supabase.
Les erreurs reviennent comme celles de Supabase : {"code": "P0001", "message": "…"}.
"""
import datetime
import http.server
import json
import pathlib
import re
import threading
import uuid

import psycopg
from psycopg.types.json import Jsonb

SITE = pathlib.Path(__file__).resolve().parents[2] / "site"


def _valeur(v):
    if isinstance(v, (dict, list)):
        return Jsonb(v)
    if isinstance(v, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}", v):
        try:
            return datetime.date.fromisoformat(v)
        except ValueError:
            return v
    if isinstance(v, str) and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", v):
        return uuid.UUID(v)
    return v


def demarrer(dsn, port=0):
    """Démarre le serveur dans un fil d'exécution ; renvoie l'adresse de la page."""
    page = (SITE / "index.html").read_text(encoding="utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def _envoyer(self, status, corps, type_="application/json"):
            data = corps.encode() if isinstance(corps, str) else corps
            self.send_response(status)
            self.send_header("Content-Type", type_)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass   # le navigateur a fermé la page pendant une mise à jour automatique

        def do_GET(self):
            chemin = self.path.split("?")[0].split("#")[0]
            if chemin in ("/", "/index.html"):
                html = page.replace("https://VOTRE-PROJET.supabase.co", f"http://127.0.0.1:{self.server.server_port}") \
                           .replace("VOTRE-CLE-PUBLIQUE", "sb_publishable_test")
                return self._envoyer(200, html, "text/html; charset=utf-8")
            f = (SITE / chemin.lstrip("/")).resolve()
            if SITE in f.parents and f.is_file():
                return self._envoyer(200, f.read_bytes(), "application/javascript" if f.suffix == ".js" else "application/octet-stream")
            self._envoyer(404, "{}")

        def do_POST(self):
            m = re.fullmatch(r"/rest/v1/rpc/(\w+)", self.path)
            if not m:
                return self._envoyer(404, "{}")
            corps = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            args = ", ".join(f"{k} => %s" for k in corps)
            try:
                with psycopg.connect(dsn, autocommit=True) as c:
                    c.execute("set role anon")
                    v = c.execute(f"select public.{m.group(1)}({args})", [_valeur(x) for x in corps.values()]).fetchone()[0]
                self._envoyer(200, json.dumps(v, default=str))
            except psycopg.Error as e:
                self._envoyer(400, json.dumps({"code": e.sqlstate, "message": e.diag.message_primary}))

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{srv.server_port}/", srv
