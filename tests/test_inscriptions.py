"""Parcours des institutions : inscription, planning, groupes, places, verrouillage, modifications."""
import pytest

CODE = "tilleul-brume-42"
ADMIN = "organisateur-test-2027"


def plans(db, inst):
    return {b["nom"]: b["plan"] for b in db.etat()["beneficiaires"] if b["institution"] == inst}


# ---------------- Inscription d'une institution ----------------

def test_inscription_cree_les_participants(db):
    db.journee()
    inst = db.institution(places=5, educ=2, pmr=1)
    e = db.etat()
    i = next(x for x in e["institutions"] if x["id"] == inst)
    assert (i["nb_attendu"], i["nb_educateurs"], i["nb_pmr"]) == (5, 2, 1)
    assert sorted(b["nom"] for b in e["beneficiaires"]) == [f"Participant {k}" for k in range(1, 6)]
    assert "email" not in str(e) and "0470" not in str(e)        # coordonnées invisibles avec le code de la journée


@pytest.mark.parametrize("champs, code", [
    ({"p_nom": " "}, "22023"), ({"p_responsable": ""}, "22023"), ({"p_email": "pas-un-mail"}, "22023"),
    ({"p_email": "a@b"}, "22023"), ({"p_telephone": "123"}, "22023"), ({"p_places": 0}, "22023"),
    ({"p_educateurs": -1}, "22023"), ({"p_pmr": 9}, "22023"), ({"p_code": "faux-code-00"}, "28000"),
])
def test_inscription_invalide(db, champs, code):
    db.journee()
    args = dict(p_journee="test-2027", p_code=CODE, p_nom="Les Tilleuls", p_responsable="Marie", p_email="marie@example.be",
                p_telephone="0470 12 34 56", p_places=8, p_educateurs=1, p_pmr=0) | champs
    db.err(code, "apa_inscrire_institution", **args)


def test_une_institution_ne_s_inscrit_qu_une_fois(db):
    db.journee()
    db.institution(nom="Gai Séjour")
    for nom in ("Gai Séjour", "gai séjour", "  GAI SÉJOUR "):
        assert "déjà inscrite" in db.err("P0009", "apa_inscrire_institution", p_journee="test-2027", p_code=CODE, p_nom=nom,
                                          p_responsable="X", p_email="x@y.be", p_telephone="0470123456", p_places=1, p_educateurs=0, p_pmr=0)


def test_places_maximum_de_la_journee(db):
    db.journee(places_max=10)
    db.institution(nom="A", places=6)
    assert "Il ne reste que 4 places" in db.err("P0007", "apa_inscrire_institution", p_journee="test-2027", p_code=CODE, p_nom="B",
                                                  p_responsable="X", p_email="x@y.be", p_telephone="0470123456", p_places=5, p_educateurs=0, p_pmr=0)
    db.institution(nom="B", places=4)
    assert "complète" in db.err("P0007", "apa_inscrire_institution", p_journee="test-2027", p_code=CODE, p_nom="C",
                                p_responsable="X", p_email="x@y.be", p_telephone="0470123456", p_places=1, p_educateurs=0, p_pmr=0)
    assert next(j for j in db.rpc("apa_journees") if j["id"] == "test-2027")["places_prises"] == 10


def test_inscription_individuelle_compte_dans_les_places(db):
    db.journee(places_max=9)
    db.institution(places=8)
    db.rpc("apa_enregistrer", p_journee="test-2027", p_code=CODE, p_id=None, p_nom="Solo", p_groupe="", p_plan={"1": "zumba"}, p_institution=None)
    db.err("P0007", "apa_enregistrer", p_journee="test-2027", p_code=CODE, p_id=None, p_nom="Solo 2", p_groupe="", p_plan={"1": "zumba"}, p_institution=None)


# ---------------- Planning ----------------

def test_enregistrer_un_planning_avec_groupes(db):
    db.journee()
    inst = db.institution(places=4)
    lignes = db.lignes(inst)
    for k, l in enumerate(lignes):
        l["equipe"] = "Groupe de Marie" if k < 3 else ""
        l["plan"] = {"1": "zumba", "2": "pause"}
    assert db.lot(inst, lignes) == 4
    e = db.etat()
    assert sorted(b["equipe"] for b in e["beneficiaires"]) == ["", "Groupe de Marie", "Groupe de Marie", "Groupe de Marie"]
    assert all(b["plan"] == {"1": "zumba", "2": "pause"} for b in e["beneficiaires"])


def test_capacite_d_un_atelier_tout_ou_rien(db):
    db.journee()
    inst = db.institution(places=6)
    lignes = db.lignes(inst)
    for l in lignes:
        l["plan"] = {"1": "massage"}                 # 6 personnes pour 4 places
    assert "Massage (T1)" in db.err("P0001", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=inst, p_lignes=lignes)
    assert all(p == {} for p in plans(db, inst).values())     # rien n'a été enregistré


def test_capacite_partagee_entre_institutions(db):
    db.journee()
    a, b = db.institution(nom="A", places=3), db.institution(nom="B", places=3)
    db.lot(a, [dict(l, plan={"1": "massage"}) for l in db.lignes(a)])
    lb = db.lignes(b)
    lb[0]["plan"] = {"1": "massage"}
    db.lot(b, lb)                                      # 4e et dernière place
    lb = db.lignes(b)
    lb[1]["plan"] = {"1": "massage"}
    db.err("P0001", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=b, p_lignes=lb)


def test_une_seule_activite_par_tournante(db):
    db.journee()
    inst = db.institution(places=1)
    db.lot(inst, [dict(l, plan={"1": "zumba"}) for l in db.lignes(inst)])
    db.lot(inst, [dict(l, plan={"1": "boccia"}) for l in db.lignes(inst)])
    assert db.val("select count(*) from inscriptions where journee = 'test-2027'") == 1


def test_plus_de_participants_que_de_places_reservees(db):
    db.journee()
    inst = db.institution(places=2)
    lignes = db.lignes(inst) + [{"id": None, "nom": "En trop", "plan": {}}]
    assert "3 participants pour 2 places" in db.err("P0008", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=inst, p_lignes=lignes)
    db.rpc("apa_modifier_reservation", p_journee="test-2027", p_code=CODE, p_institution=inst, p_places=3, p_educateurs=1, p_pmr=0)
    db.lot(inst, lignes)


def test_reduire_la_reservation_sous_les_participants(db):
    db.journee()
    inst = db.institution(places=5)
    db.err("P0008", "apa_modifier_reservation", p_journee="test-2027", p_code=CODE, p_institution=inst, p_places=4, p_educateurs=1, p_pmr=0)


def test_deux_personnes_modifient_la_meme_fiche(db):
    db.journee()
    inst = db.institution(places=2)
    a, b = db.lignes(inst), db.lignes(inst)            # deux éducateurs ouvrent la page
    a[0]["plan"] = {"1": "zumba"}
    db.lot(inst, a)
    b[0]["plan"] = {"1": "boccia"}
    db.err("P0003", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=inst, p_lignes=b)
    assert plans(db, inst)["Participant 1"] == {"1": "zumba"}


def test_supprimer_un_participant(db):
    db.journee()
    inst = db.institution(places=2)
    pid = db.lignes(inst)[0]["id"]
    db.rpc("apa_supprimer", p_journee="test-2027", p_code=CODE, p_id=pid)
    assert len(plans(db, inst)) == 1
    db.lot(inst, [{"id": pid, "nom": "Revenant", "plan": {}}][:0] + db.lignes(inst))   # la fiche restante s'enregistre
    db.err("P0002", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=inst,
           p_lignes=[{"id": pid, "nom": "Revenant", "maj": "2020-01-01T00:00:00+00:00", "plan": {}}])


# ---------------- Verrouillage (PDF téléchargé) ----------------

def test_verrouillage_puis_deverrouillage_par_l_organisateur(db):
    db.journee()
    inst = db.institution(places=2)
    db.rpc("apa_verrouiller", p_journee="test-2027", p_code=CODE, p_institution=inst)
    db.err("P0004", "apa_enregistrer_lot", p_journee="test-2027", p_code=CODE, p_institution=inst, p_lignes=db.lignes(inst))
    db.err("P0004", "apa_supprimer", p_journee="test-2027", p_code=CODE, p_id=db.lignes(inst)[0]["id"])
    db.err("P0004", "apa_modifier_reservation", p_journee="test-2027", p_code=CODE, p_institution=inst, p_places=3, p_educateurs=1, p_pmr=0)
    db.err("28000", "apa_deverrouiller", p_code_admin="mauvais", p_institution=inst)
    db.rpc("apa_deverrouiller", p_code_admin=ADMIN, p_institution=inst)
    db.lot(inst, db.lignes(inst))


def test_l_organisateur_peut_corriger_une_institution_verrouillee(db):
    db.journee()
    inst = db.institution(places=2)
    db.rpc("apa_verrouiller", p_journee="test-2027", p_code=CODE, p_institution=inst)
    db.admin("apa_admin_modifier_institution", p_institution=inst, p_nom="Les Tilleuls", p_responsable="Paul",
             p_email="paul@example.be", p_telephone="0470 00 00 00", p_places=3, p_educateurs=2, p_pmr=1)
    i = next(x for x in db.admin("apa_admin_institutions", p_journee="test-2027") if x["id"] == inst)
    assert (i["responsable"], i["email"], i["places"], i["educateurs"], i["pmr"]) == ("Paul", "paul@example.be", 3, 2, 1)


# ---------------- L'organisateur modifie après les inscriptions ----------------

def test_modifications_de_l_organisateur_visibles_par_les_institutions(db):
    db.journee()
    inst = db.institution(places=2)
    db.lot(inst, db.lignes(inst, {"Participant 1": {"1": "zumba", "2": "kinball"}}))
    db.admin("apa_admin_enregistrer_atelier", p_journee="test-2027", p_id="zumba", p_nom="Danse", p_lieu="P2", p_cap=20, p_ordre=None)
    db.admin("apa_admin_supprimer_atelier", p_journee="test-2027", p_id="kinball", p_confirmer=True)
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False, p_data={"nom": "Nouveau nom", "date": "2027-06-11"})
    e = db.etat()
    assert e["journee"]["nom"] == "Nouveau nom" and e["journee"]["date"] == "2027-06-11"
    assert {a["id"]: a["nom"] for a in e["activites"]}["zumba"] == "Danse"
    assert "kinball" not in {a["id"] for a in e["activites"]}
    assert plans(db, inst)["Participant 1"] == {"1": "zumba"}


@pytest.mark.parametrize("champs, code", [
    ({"p_email": "pas-un-mail"}, "22023"), ({"p_nom": ""}, "22023"), ({"p_places": 1}, "P0008"),
    ({"p_nom": "Autre"}, "P0009"), ({"p_places": 99}, "P0007"), ({"p_pmr": 3}, "22023"),
])
def test_modification_d_institution_par_l_organisateur_refusee(db, champs, code):
    db.journee(places_max=20)
    inst = db.institution(places=2)
    db.institution(nom="Autre", places=2)
    args = dict(p_code_admin=ADMIN, p_institution=inst, p_nom="Les Tilleuls", p_responsable="Marie", p_email="marie@example.be",
                p_telephone="0470", p_places=2, p_educateurs=1, p_pmr=0) | champs
    db.err(code, "apa_admin_modifier_institution", **args)


def test_supprimer_une_institution_supprime_ses_participants(db):
    db.journee()
    inst = db.institution(places=3)
    db.lot(inst, db.lignes(inst, {"Participant 1": {"1": "zumba"}}))
    db.admin("apa_admin_supprimer_institution", p_institution=inst)
    assert db.val("select count(*) from beneficiaires where journee = 'test-2027'") == 0
    assert db.val("select count(*) from inscriptions where journee = 'test-2027'") == 0
