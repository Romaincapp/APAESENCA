"""Espace organisateur : ateliers et horaires, y compris après des inscriptions."""
import pytest

ADMIN = "organisateur-test-2027"


def ateliers(db, jid="test-2027"):
    return {a["id"]: a for a in db.admin("apa_admin_journee", p_journee=jid)["ateliers"]}


def inscrire(db, inst, plans):
    """plans : {"Participant 1": {"1": "zumba"}, …} puis enregistrement de l'institution."""
    db.lot(inst, db.lignes(inst, plans))


# ---------------- Ateliers ----------------

def test_ajouter_des_ateliers_donne_des_identifiants_lisibles(db):
    db.journee(ateliers=())
    ids = [db.admin("apa_admin_enregistrer_atelier", p_journee="test-2027", p_id=None, p_nom=n, p_lieu="P1", p_cap=8, p_ordre=None)
           for n in ("Soin des cheveux", "Fléchettes ventouses", "Œuf & cuillère", "Soin des cheveux !", "!!!")]
    assert ids == ["soin-des-cheveux", "flechettes-ventouses", "oeuf-cuillere", "soin-des-cheveux-2", "atelier"]
    assert [a["ordre"] for a in ateliers(db).values()] == [1, 2, 3, 4, 5]
    # Visibles tout de suite pour les institutions, dans l'ordre.
    assert [a["nom"] for a in db.etat()["activites"] if a["id"] != "pause"][:2] == ["Soin des cheveux", "Fléchettes ventouses"]


@pytest.mark.parametrize("nom, lieu, cap, code", [
    ("", "P1", 8, "22023"), ("Zumba", "", 8, "22023"), ("Zumba", "P" * 21, 8, "22023"),
    ("Zumba", "P1", 0, "22023"), ("Zumba", "P1", 501, "22023"), ("Zumba", "P1", None, "22023"),
    ("zumba", "P1", 8, "P0009"), ("  ZUMBA ", "P1", 8, "P0009"), ("Pause / repos", "P1", 8, "P0009"),
])
def test_atelier_invalide_ou_en_double(db, nom, lieu, cap, code):
    db.journee()
    db.err(code, "apa_admin_enregistrer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id=None, p_nom=nom, p_lieu=lieu, p_cap=cap, p_ordre=None)


def test_modifier_un_atelier_garde_ses_inscriptions(db):
    db.journee()
    inst = db.institution()
    inscrire(db, inst, {"Participant 1": {"1": "zumba"}, "Participant 2": {"1": "zumba"}})
    db.admin("apa_admin_enregistrer_atelier", p_journee="test-2027", p_id="zumba", p_nom="Zumba géante", p_lieu="P3", p_cap=30, p_ordre=9)
    a = {x["id"]: x for x in db.etat()["activites"]}["zumba"]
    assert (a["nom"], a["lieu"], a["cap"]) == ("Zumba géante", "P3", 30)
    assert db.val("select count(*) from inscriptions where activite = 'zumba' and journee = 'test-2027'") == 2


def test_baisser_les_places_sous_les_inscrits_est_refuse(db):
    db.journee()
    inst = db.institution()
    inscrire(db, inst, {f"Participant {k}": {"2": "boccia"} for k in range(1, 6)} | {"Participant 6": {"1": "boccia"}})
    msg = db.err("P0012", "apa_admin_enregistrer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id="boccia",
                 p_nom="Boccia", p_lieu="P1", p_cap=4, p_ordre=None)
    assert "5 inscrits" in msg and "T2" in msg
    db.admin("apa_admin_enregistrer_atelier", p_journee="test-2027", p_id="boccia", p_nom="Boccia", p_lieu="P1", p_cap=5, p_ordre=None)
    assert ateliers(db)["boccia"]["cap"] == 5
    # Avec 5 places, une 6e inscription en T2 est refusée.
    db.err("P0001", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst,
           p_lignes=db.lignes(inst, {"Participant 6": {"1": "boccia", "2": "boccia"}}))


def test_la_pause_ne_se_modifie_ni_ne_se_supprime(db):
    db.journee()
    db.err("22023", "apa_admin_enregistrer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id="pause", p_nom="Repos", p_lieu="P1", p_cap=5, p_ordre=None)
    db.err("22023", "apa_admin_supprimer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id="pause", p_confirmer=True)


def test_modifier_un_atelier_supprime_entre_temps(db):
    db.journee()
    db.err("P0002", "apa_admin_enregistrer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id="inconnu", p_nom="X", p_lieu="P1", p_cap=5, p_ordre=None)


def test_supprimer_un_atelier_sans_inscrit(db):
    db.journee()
    assert db.admin("apa_admin_supprimer_atelier", p_journee="test-2027", p_id="kinball", p_confirmer=False) == 0
    assert "kinball" not in ateliers(db)


def test_supprimer_un_atelier_avec_inscrits_demande_confirmation_et_montre_qui_est_touche(db):
    db.journee()
    a = db.institution(nom="Les Tilleuls")
    b = db.institution(nom="Le Chêne", places=4)
    inscrire(db, a, {"Participant 1": {"1": "zumba"}, "Participant 2": {"2": "zumba", "1": "boccia"}})
    inscrire(db, b, {"Participant 1": {"3": "zumba"}})
    db.rpc("apa_verrouiller", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=b)   # PDF déjà téléchargé

    imp = db.admin("apa_admin_impact", p_journee="test-2027", p_activite="zumba", p_tournante_min=None)
    assert (imp["inscriptions"], imp["participants"]) == (3, 3)
    assert imp["institutions"] == [{"nom": "Le Chêne", "n": 1, "verrouillee": True}, {"nom": "Les Tilleuls", "n": 2, "verrouillee": False}]

    msg = db.err("P0010", "apa_admin_supprimer_atelier", p_code_admin=ADMIN, p_journee="test-2027", p_id="zumba", p_confirmer=False)
    assert "3 inscription(s)" in msg
    assert "zumba" in ateliers(db)                     # rien n'a bougé

    assert db.admin("apa_admin_supprimer_atelier", p_journee="test-2027", p_id="zumba", p_confirmer=True) == 3
    assert "zumba" not in ateliers(db)
    assert db.val("select count(*) from beneficiaires where journee = 'test-2027'") == 12          # personne n'est supprimé
    assert db.val("select count(*) from inscriptions where journee = 'test-2027'") == 1           # reste Boccia T1
    plans = {(b["institution"], b["nom"]): b["plan"] for b in db.etat()["beneficiaires"]}
    assert plans[(a, "Participant 2")] == {"1": "boccia"}                                       # sa case T2 est « à choisir »


def test_un_brouillon_ouvert_pendant_la_suppression_est_refuse_proprement(db):
    db.journee()
    inst = db.institution()
    inscrire(db, inst, {"Participant 1": {"1": "zumba"}})
    brouillon = db.lignes(inst)                       # une éducatrice a la page ouverte…
    db.admin("apa_admin_supprimer_atelier", p_journee="test-2027", p_id="zumba", p_confirmer=True)
    for l in brouillon:
        l["plan"] = {"2": "boccia"}
    msg = db.err("P0003", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst, p_lignes=brouillon)
    assert "modifiée par quelqu'un d'autre" in msg
    # Un nouveau participant qui citerait l'atelier supprimé : message clair, pas d'erreur technique.
    msg = db.err("P0013", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst,
                 p_lignes=[{"id": None, "nom": "Nouveau", "plan": {"1": "zumba"}}])
    assert "n'existe plus" in msg


# ---------------- Horaires ----------------

def h(*plages, demi="Matin"):
    return [{"debut": d, "fin": f, "demi": demi} for d, f in plages]


def test_enregistrer_des_horaires(db):
    db.journee(tournantes=0)
    liste = h(("09:45", "10:00"), ("10:05", "10:20")) + h(("12:50", "13:05"), demi="Après-midi")
    assert db.admin("apa_admin_enregistrer_horaires", p_journee="test-2027", p_liste=liste, p_confirmer=False) == 0
    t = db.etat()["tournantes"]
    assert [(x["id"], x["debut"], x["fin"], x["demi"]) for x in t] == [(1, "09:45", "10:00", "Matin"), (2, "10:05", "10:20", "Matin"), (3, "12:50", "13:05", "Après-midi")]


@pytest.mark.parametrize("liste, morceau", [
    ([], "entre 1 et 40"),
    (h(*[("09:00", "09:10")] * 41), "entre 1 et 40"),
    (h(("10:00", "09:45")), "après"),
    (h(("10:00", "10:00")), "après"),
    (h(("09:00", "09:30"), ("09:15", "09:45")), "commence avant"),
    (h(("9h", "10h")), "invalide"),
    (h(("25:00", "26:00")), "invalide"),
    ([{"debut": "09:00", "fin": "09:15", "demi": ""}], "matin"),
])
def test_horaires_invalides(db, liste, morceau):
    db.journee()
    msg = db.err("22023", "apa_admin_enregistrer_horaires", p_code_admin=ADMIN, p_journee="test-2027", p_liste=liste, p_confirmer=False)
    assert morceau in msg.lower()
    assert len(db.etat()["tournantes"]) == 3                 # rien n'a changé


def test_decaler_les_horaires_garde_les_inscriptions(db):
    db.journee()
    inst = db.institution()
    inscrire(db, inst, {"Participant 1": {"1": "zumba", "3": "boccia"}})
    db.admin("apa_admin_enregistrer_horaires", p_journee="test-2027", p_confirmer=False,
             p_liste=h(("10:00", "10:20"), ("10:30", "10:50"), ("11:00", "11:20")))
    assert db.etat()["tournantes"][0]["debut"] == "10:00"
    assert {b["nom"]: b["plan"] for b in db.etat()["beneficiaires"]}["Participant 1"] == {"1": "zumba", "3": "boccia"}


def test_retirer_des_tournantes_avec_inscriptions_demande_confirmation(db):
    db.journee()
    inst = db.institution()
    inscrire(db, inst, {"Participant 1": {"1": "zumba", "3": "boccia"}, "Participant 2": {"3": "zumba"}})
    imp = db.admin("apa_admin_impact", p_journee="test-2027", p_activite=None, p_tournante_min=3)
    assert (imp["inscriptions"], imp["participants"]) == (2, 2)
    msg = db.err("P0010", "apa_admin_enregistrer_horaires", p_code_admin=ADMIN, p_journee="test-2027",
                 p_liste=h(("09:00", "09:15"), ("10:00", "10:15")), p_confirmer=False)
    assert "2 inscription(s)" in msg
    assert len(db.etat()["tournantes"]) == 3
    assert db.admin("apa_admin_enregistrer_horaires", p_journee="test-2027", p_confirmer=True,
                    p_liste=h(("09:00", "09:15"), ("10:00", "10:15"))) == 2
    e = db.etat()
    assert len(e["tournantes"]) == 2
    assert {b["nom"]: b["plan"] for b in e["beneficiaires"]}["Participant 1"] == {"1": "zumba"}
    # Une page restée ouverte qui enverrait encore T3 reçoit un message clair.
    msg = db.err("P0013", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst,
                 p_lignes=[{"id": None, "nom": "Nouveau", "plan": {"3": "boccia"}}])
    assert "T3 n'existe plus" in msg


def test_ajouter_des_tournantes(db):
    db.journee()
    db.admin("apa_admin_enregistrer_horaires", p_journee="test-2027", p_confirmer=False,
             p_liste=h(*[(f"{9 + i:02d}:00", f"{9 + i:02d}:15") for i in range(5)]))
    assert len(db.etat()["tournantes"]) == 5
    inst = db.institution()
    inscrire(db, inst, {"Participant 1": {"5": "kinball"}})
