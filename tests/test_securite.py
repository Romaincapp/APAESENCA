"""Sécurité : codes, droits d'appel, cloisonnement entre journées."""
import pytest

ADMIN = "organisateur-test-2027"

# Toutes les fonctions de l'organisateur, avec des arguments plausibles : sans le bon code, aucune ne passe.
FONCTIONS_ADMIN = [
    ("apa_admin_journees", {}),
    ("apa_admin_journee", {"p_journee": "marcinelle-2027"}),
    ("apa_admin_enregistrer_journee", {"p_id": "pirate-2027", "p_nouvelle": True, "p_data": {"nom": "X", "date": "2027-01-01"}}),
    ("apa_admin_definir_code", {"p_journee": "marcinelle-2027", "p_code": "pirate-code-99"}),
    ("apa_admin_dupliquer_journee", {"p_source": "marcinelle-2027", "p_id": "pirate-2027", "p_nom": "X", "p_date": "2027-01-01"}),
    ("apa_admin_supprimer_journee", {"p_journee": "marcinelle-2027"}),
    ("apa_admin_enregistrer_atelier", {"p_journee": "marcinelle-2027", "p_id": None, "p_nom": "X", "p_lieu": "P1", "p_cap": 5, "p_ordre": None}),
    ("apa_admin_impact", {"p_journee": "marcinelle-2027", "p_activite": "zumba", "p_tournante_min": None}),
    ("apa_admin_supprimer_atelier", {"p_journee": "marcinelle-2027", "p_id": "zumba", "p_confirmer": True}),
    ("apa_admin_enregistrer_horaires", {"p_journee": "marcinelle-2027", "p_liste": [{"debut": "09:00", "fin": "10:00", "demi": "Matin"}], "p_confirmer": True}),
    ("apa_admin_modifier_institution", {"p_institution": "00000000-0000-0000-0000-000000000000", "p_nom": "X", "p_responsable": "", "p_email": "", "p_telephone": "", "p_places": 1, "p_educateurs": 0, "p_pmr": 0}),
    ("apa_admin_institutions", {"p_journee": "marcinelle-2027"}),
    ("apa_admin_supprimer_institution", {"p_institution": "00000000-0000-0000-0000-000000000000"}),
    ("apa_deverrouiller", {"p_institution": "00000000-0000-0000-0000-000000000000"}),
]


@pytest.mark.parametrize("fn, args", FONCTIONS_ADMIN, ids=[f for f, _ in FONCTIONS_ADMIN])
@pytest.mark.parametrize("code", ["mauvais-code", "", None, "tilleul-brume-42"])
def test_l_espace_organisateur_exige_le_code_organisateur(db, fn, args, code):
    db.journee()   # « tilleul-brume-42 » est le code d'une journée, pas celui de l'organisateur
    db.err("28000", fn, p_code_admin=code, **args)
    assert db.val("select count(*) from journees where id = 'pirate-2027'") == 0
    assert db.val("select count(*) from activites where journee = 'marcinelle-2027' and id = 'zumba'") == 1


@pytest.mark.parametrize("fn, args", [
    ("_apa_check_code", "'marcinelle-2027', 'x'"), ("_apa_check_admin", "'x'"), ("_apa_places_prises", "'marcinelle-2027'"),
    ("_apa_impact", "'marcinelle-2027', null, null"), ("_apa_slug", "'x'"), ("_apa_check_plan", "'marcinelle-2027', '{}'::jsonb"),
    ("apa_definir_code", "'marcinelle-2027', 'pirate-code'"), ("apa_definir_code_admin", "'pirate-code'"),
])
def test_les_fonctions_internes_ne_sont_pas_appelables_avec_la_cle_publique(db, fn, args):
    with db.conn.transaction():
        db.conn.execute("savepoint s")
        db.conn.execute("set local role anon")
        try:
            db.conn.execute(f"select public.{fn}({args})")
            assert False, f"{fn} est appelable par anon"
        except Exception as e:
            assert getattr(e, "sqlstate", None) == "42501", e
        db.conn.execute("rollback to savepoint s")


@pytest.mark.parametrize("table", ["journees", "activites", "tournantes", "institutions", "beneficiaires", "inscriptions", "config"])
def test_aucune_table_lisible_directement(db, table):
    # Sur Supabase, anon a des droits sur les tables mais la sécurité par ligne (sans règle) ne montre rien.
    db.sql(f"grant select on public.{table} to anon")
    db.journee()
    db.institution()
    with db.conn.transaction():
        db.conn.execute("set local role anon")
        assert db.conn.execute(f"select count(*) from public.{table}").fetchone()[0] == 0
        db.conn.execute("reset role")


def test_le_code_d_une_journee_n_ouvre_pas_une_autre(db):
    db.journee()
    db.admin("apa_admin_definir_code", p_journee="pqr-2027", p_code="orage-sapin-61")
    db.err("28000", "apa_etat", p_journee="pqr-2027", p_code="tilleul-brume-42")
    db.err("28000", "apa_connexion", p_journee="test-2027", p_code="orage-sapin-61")


def test_une_institution_d_une_autre_journee_est_refusee(db):
    db.journee()
    autre = db.journee(jid="autre-2027", nom="Autre", code="riviere-hibou-23")
    inst = db.institution("autre-2027", code="riviere-hibou-23")
    db.err("22023", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst, p_lignes=[])
    db.err("22023", "apa_modifier_reservation", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst, p_places=3, p_educateurs=0, p_pmr=0)
    pid = db.lignes(inst, jid=autre, code="riviere-hibou-23")[0]["id"]
    db.rpc("apa_supprimer", p_journee="test-2027", p_code="tilleul-brume-42", p_id=pid)        # sans effet sur l'autre journée
    assert db.val("select count(*) from beneficiaires where id = %s", [pid]) == 1


def test_changer_le_code_organisateur(db):
    db.err("28000", "apa_admin_changer_code", p_ancien="mauvais", p_nouveau="nouveau-code-123")
    db.err("22023", "apa_admin_changer_code", p_ancien=ADMIN, p_nouveau="court")
    db.err("22023", "apa_admin_changer_code", p_ancien=ADMIN, p_nouveau=ADMIN)
    db.rpc("apa_admin_changer_code", p_ancien=ADMIN, p_nouveau="nouveau-code-123")
    db.err("28000", "apa_admin_journees", p_code_admin=ADMIN)
    assert db.rpc("apa_admin_journees", p_code_admin="nouveau-code-123")


def test_les_textes_sont_stockes_tels_quels(db):
    """Du HTML dans un nom n'est pas interprété par la base (la page l'échappe à l'affichage)."""
    db.journee()
    inst = db.institution(nom="<script>alert(1)</script>")
    assert next(i for i in db.etat()["institutions"] if i["id"] == inst)["nom"] == "<script>alert(1)</script>"
