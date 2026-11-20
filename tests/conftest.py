"""Outils communs aux tests de la base (supabase/schema.sql).

Chaque session crée une base PostgreSQL temporaire, y installe le vrai schema.sql,
puis chaque test tourne dans une transaction annulée à la fin : les tests ne se
gênent pas entre eux.

Les fonctions sont appelées avec le rôle « anon », exactement comme la page avec la
clé publique de Supabase.

Connexion : variable APA_TEST_DSN (par défaut postgresql://postgres:postgres@localhost:5432/postgres).
"""
import datetime
import json
import os
import pathlib
import uuid

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from psycopg.types.json import Jsonb

RACINE = pathlib.Path(__file__).resolve().parent.parent
SCHEMA = (RACINE / "supabase" / "schema.sql").read_text(encoding="utf-8")
SCHEMA_V1 = (RACINE / "tests" / "fixtures" / "schema_v1.sql").read_text(encoding="utf-8")
DSN = os.environ.get("APA_TEST_DSN", "postgresql://postgres:postgres@localhost:5432/postgres")
ADMIN = "organisateur-test-2027"

# Ce que Supabase fournit déjà : les rôles de l'API et le schéma des extensions.
PREPARATION = """
do $$ begin
  if not exists (select from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create schema if not exists extensions;
grant usage on schema extensions to public;
"""


class ApaError(Exception):
    """Erreur renvoyée par une fonction SQL (code SQLSTATE + message en français)."""

    def __init__(self, code, message):
        super().__init__(f"[{code}] {message}")
        self.code, self.message = code, message


def _valeur(v):
    if isinstance(v, (dict, list)):
        return Jsonb(v)
    if isinstance(v, str) and len(v) == 10 and v[4] == "-" and v[7] == "-":
        try:
            return datetime.date.fromisoformat(v)
        except ValueError:
            return v
    if isinstance(v, str) and len(v) == 36 and v.count("-") == 4:
        try:
            return uuid.UUID(v)
        except ValueError:
            return v
    return v


class Db:
    def __init__(self, conn):
        self.conn = conn

    def sql(self, query, params=None):
        """Requête en tant que propriétaire (comme le SQL Editor de Supabase)."""
        cur = self.conn.execute(query, params)
        return cur.fetchall() if cur.description else None

    def val(self, query, params=None):
        rows = self.sql(query, params)
        return rows[0][0] if rows else None

    def rpc(self, fn, **kw):
        """Appelle une fonction comme la page : rôle anon, arguments nommés."""
        args = ", ".join(f"{k} => %s" for k in kw)
        try:
            with self.conn.transaction():          # point de sauvegarde : une erreur n'annule que cet appel
                self.conn.execute("set local role anon")
                row = self.conn.execute(f"select public.{fn}({args})", [_valeur(v) for v in kw.values()]).fetchone()
                self.conn.execute("reset role")
        except psycopg.Error as e:
            raise ApaError(e.sqlstate, e.diag.message_primary) from None
        v = row[0]
        if isinstance(v, uuid.UUID):
            return str(v)
        return json.loads(json.dumps(v, default=str)) if isinstance(v, (dict, list)) else v

    def err(self, code, fn, **kw):
        """L'appel doit échouer avec ce code ; renvoie le message."""
        with pytest.raises(ApaError) as e:
            self.rpc(fn, **kw)
        assert e.value.code == code, f"attendu {code}, reçu {e.value.code} : {e.value.message}"
        return e.value.message

    # ---- raccourcis pour préparer les cas ----
    def admin(self, fn, **kw):
        return self.rpc(fn, p_code_admin=ADMIN, **kw)

    def journee(self, jid="test-2027", nom="Journée test", date="2027-06-10", lieu="Testville", places_max=None,
                ateliers=(("Zumba", "P1", 16), ("Boccia", "P1", 8), ("Massage", "P1", 4), ("Kinball", "P2", 16)),
                tournantes=3, code="tilleul-brume-42"):
        """Crée une journée complète via l'espace organisateur et renvoie son identifiant."""
        self.admin("apa_admin_enregistrer_journee", p_id=jid, p_nouvelle=True,
                   p_data={"nom": nom, "date": date, "lieu": lieu, "places_max": places_max})
        for n, l, c in ateliers:
            self.admin("apa_admin_enregistrer_atelier", p_journee=jid, p_id=None, p_nom=n, p_lieu=l, p_cap=c, p_ordre=None)
        if tournantes:
            liste = [{"debut": f"{9 + i:02d}:00", "fin": f"{9 + i:02d}:15", "demi": "Matin"} for i in range(tournantes)]
            self.admin("apa_admin_enregistrer_horaires", p_journee=jid, p_liste=liste, p_confirmer=False)
        if code:
            self.admin("apa_admin_definir_code", p_journee=jid, p_code=code)
        return jid

    def institution(self, jid="test-2027", nom="Les Tilleuls", places=8, code="tilleul-brume-42", educ=1, pmr=0):
        return self.rpc("apa_inscrire_institution", p_journee=jid, p_code=code, p_nom=nom, p_responsable="Marie",
                        p_email="marie@example.be", p_telephone="0470 12 34 56", p_places=places, p_educateurs=educ, p_pmr=pmr)

    def etat(self, jid="test-2027", code="tilleul-brume-42"):
        return self.rpc("apa_etat", p_journee=jid, p_code=code)

    def lot(self, inst, lignes, jid="test-2027", code="tilleul-brume-42"):
        return self.rpc("apa_enregistrer_lot", p_journee=jid, p_code=code, p_institution=inst, p_lignes=lignes)

    def lignes(self, inst, plan_par_nom=None, jid="test-2027", code="tilleul-brume-42"):
        """Les participants enregistrés d'une institution, prêts à renvoyer dans apa_enregistrer_lot."""
        e = self.etat(jid, code)
        out = []
        for b in e["beneficiaires"]:
            if b["institution"] == inst:
                plan = dict(b["plan"])
                if plan_par_nom and b["nom"] in plan_par_nom:
                    plan = plan_par_nom[b["nom"]]
                out.append({"id": b["id"], "nom": b["nom"], "equipe": b.get("equipe", ""), "maj": b["maj"], "plan": plan})
        return out


def _creer_base(nom):
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute(f'create database "{nom}"')
    params = conninfo_to_dict(DSN)
    params["dbname"] = nom
    return make_conninfo(**params)


def _supprimer_base(nom):
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute(f'drop database if exists "{nom}" with (force)')


@pytest.fixture(scope="session")
def nouvelle_base():
    """Fabrique de bases vides (supprimées à la fin)."""
    crees = []

    def fabrique():
        nom = "apa_test_" + uuid.uuid4().hex[:10]
        dsn = _creer_base(nom)
        crees.append(nom)
        with psycopg.connect(dsn, autocommit=True) as c:
            c.execute(PREPARATION)
        return dsn

    yield fabrique
    for nom in crees:
        _supprimer_base(nom)


@pytest.fixture(scope="session")
def base(nouvelle_base):
    dsn = nouvelle_base()
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute(SCHEMA)
        c.execute("select public.apa_definir_code_admin(%s)", [ADMIN])
    return dsn


@pytest.fixture
def db(base):
    conn = psycopg.connect(base)
    try:
        # Tout le test dans une transaction annulée à la fin ; chaque appel y ouvre un point de sauvegarde.
        with conn.transaction(force_rollback=True):
            yield Db(conn)
    finally:
        conn.close()
