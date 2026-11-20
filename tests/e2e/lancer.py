"""Lance les tests de bout en bout : base temporaire + vrai schema.sql + serveur + navigateur.

    python3 tests/e2e/lancer.py

Il faut PostgreSQL (APA_TEST_DSN, comme pour pytest), Node.js et Playwright (npm i playwright).
"""
import os
import pathlib
import subprocess
import sys
import uuid

import psycopg
from psycopg.conninfo import conninfo_to_dict, make_conninfo

ICI = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ICI.parent))
from conftest import ADMIN, DSN, PREPARATION, SCHEMA  # noqa: E402
from serveur import demarrer  # noqa: E402

nom = "apa_e2e_" + uuid.uuid4().hex[:8]
with psycopg.connect(DSN, autocommit=True) as c:
    c.execute(f'create database "{nom}"')
params = conninfo_to_dict(DSN)
params["dbname"] = nom
dsn = make_conninfo(**params)
try:
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute(PREPARATION)
        c.execute(SCHEMA)
        c.execute("select public.apa_definir_code_admin(%s)", [ADMIN])
    url, srv = demarrer(dsn)
    env = dict(os.environ, APA_URL=url, APA_ADMIN=ADMIN)
    code = subprocess.call(["node", str(ICI / "parcours.cjs")], env=env)
    srv.shutdown()
finally:
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute(f'drop database if exists "{nom}" with (force)')
sys.exit(code)
