"""Espace organisateur : créer, modifier, ouvrir, fermer, dupliquer, cacher et supprimer une journée."""
import pytest


def menu(db):
    return {j["id"]: j for j in db.rpc("apa_journees")}


def test_creer_une_journee_vide(db):
    db.admin("apa_admin_enregistrer_journee", p_id="couvin-2027", p_nouvelle=True,
             p_data={"nom": "Journée APA de Couvin", "date": "2027-06-10", "lieu": "Couvin"})
    j = menu(db)["couvin-2027"]
    assert (j["nom"], j["date"], j["lieu"], j["ouverte"]) == ("Journée APA de Couvin", "2027-06-10", "Couvin", False)
    d = db.admin("apa_admin_journee", p_journee="couvin-2027")
    assert d["ateliers"] == [] and d["tournantes"] == []
    # « Pause / repos » est créée d'office (cachée dans la liste des ateliers).
    assert db.val("select cap from activites where journee = 'couvin-2027' and id = 'pause'") == 999


@pytest.mark.parametrize("jid", ["Couvin-2027", "couvin 2027", "c", "couvin--2027", "-couvin", "organisateur", "admin", "é-2027", "x" * 41])
def test_identifiant_de_journee_invalide(db, jid):
    db.err("22023", "apa_admin_enregistrer_journee", p_code_admin="organisateur-test-2027", p_id=jid, p_nouvelle=True,
           p_data={"nom": "X", "date": "2027-06-10"})


def test_identifiant_deja_pris(db):
    msg = db.err("P0009", "apa_admin_enregistrer_journee", p_code_admin="organisateur-test-2027", p_id="marcinelle-2027",
                 p_nouvelle=True, p_data={"nom": "Doublon", "date": "2027-06-10"})
    assert "existe déjà" in msg


@pytest.mark.parametrize("data, morceau", [
    ({"nom": "", "date": "2027-06-10"}, "nom"),
    ({"nom": "   ", "date": "2027-06-10"}, "nom"),
    ({"nom": "X", "date": ""}, "date"),
    ({"nom": "X", "date": "2027-02-30"}, "date"),
    ({"nom": "X", "date": "demain"}, "date"),
    ({"nom": "X", "date": "2027-06-10", "places_max": "0"}, "places"),
    ({"nom": "X", "date": "2027-06-10", "places_max": "-5"}, "places"),
    ({"nom": "X", "date": "2027-06-10", "places_max": "beaucoup"}, "nombre"),
    ({"nom": "X", "date": "2027-06-10", "description": "x" * 1001}, "trop long"),
])
def test_infos_de_journee_invalides(db, data, morceau):
    msg = db.err("22023", "apa_admin_enregistrer_journee", p_code_admin="organisateur-test-2027", p_id="nouvelle-2027",
                 p_nouvelle=True, p_data=data)
    assert morceau in msg.lower()


def test_modifier_les_infos_se_voit_dans_le_menu_et_la_journee(db):
    db.journee()
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False, p_data={
        "nom": "Journée renommée", "date": "2027-07-01", "lieu": "Ailleurs", "description": "Accueil dès 9h30.",
        "acces": "Réservé aux institutions de test", "pause_midi": "Dîner à 12h", "places_max": "30", "visible": True})
    j = menu(db)["test-2027"]
    assert (j["nom"], j["date"], j["lieu"], j["acces"], j["places_max"]) == ("Journée renommée", "2027-07-01", "Ailleurs", "Réservé aux institutions de test", 30)
    e = db.etat()["journee"]
    assert (e["description"], e["pause_midi"]) == ("Accueil dès 9h30.", "Dîner à 12h")


def test_modifier_une_journee_inconnue(db):
    db.err("P0006", "apa_admin_enregistrer_journee", p_code_admin="organisateur-test-2027", p_id="inconnue-2027",
           p_nouvelle=False, p_data={"nom": "X", "date": "2027-06-10"})


def test_places_maximum_pas_sous_les_places_deja_prises(db):
    db.journee(places_max=20)
    db.institution(places=12)
    base = {"nom": "Journée test", "date": "2027-06-10"}
    msg = db.err("P0007", "apa_admin_enregistrer_journee", p_code_admin="organisateur-test-2027", p_id="test-2027",
                 p_nouvelle=False, p_data={**base, "places_max": 11})
    assert "12 places prises" in msg
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False, p_data={**base, "places_max": 12})
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False, p_data={**base, "places_max": ""})   # sans limite
    assert menu(db)["test-2027"]["places_max"] is None


def test_cacher_une_journee_la_retire_du_menu_mais_pas_de_l_espace_organisateur(db):
    db.journee()
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False,
             p_data={"nom": "Journée test", "date": "2027-06-10", "visible": False})
    assert "test-2027" not in menu(db)
    assert any(j["id"] == "test-2027" and j["visible"] is False for j in db.admin("apa_admin_journees"))
    # Le lien direct marche encore pour qui a le code (les institutions déjà inscrites).
    assert db.rpc("apa_connexion", p_journee="test-2027", p_code="tilleul-brume-42") is True


# ---------------- Code d'accès ----------------

def test_ouvrir_les_inscriptions_avec_un_code(db):
    db.journee(code=None)
    assert menu(db)["test-2027"]["ouverte"] is False
    db.err("P0005", "apa_connexion", p_journee="test-2027", p_code="nimporte")
    assert db.admin("apa_admin_definir_code", p_journee="test-2027", p_code="colibri-orage-31") is True
    assert menu(db)["test-2027"]["ouverte"] is True
    assert db.rpc("apa_connexion", p_journee="test-2027", p_code="colibri-orage-31") is True
    db.err("28000", "apa_connexion", p_journee="test-2027", p_code="Colibri-Orage-31")   # sensible à la casse


@pytest.mark.parametrize("code", ["court", "testville", "TestVille99", "test-2027", "Journée test", "test-et-autre"])
def test_code_trop_court_ou_trop_facile(db, code):
    db.journee(code=None)
    db.err("22023", "apa_admin_definir_code", p_code_admin="organisateur-test-2027", p_journee="test-2027", p_code=code)


def test_remplacer_le_code_bloque_l_ancien(db):
    db.journee()
    db.admin("apa_admin_definir_code", p_journee="test-2027", p_code="lagune-cerise-58")
    db.err("28000", "apa_connexion", p_journee="test-2027", p_code="tilleul-brume-42")
    assert db.rpc("apa_connexion", p_journee="test-2027", p_code="lagune-cerise-58")


def test_fermer_les_inscriptions(db):
    db.journee()
    inst = db.institution()
    assert db.admin("apa_admin_definir_code", p_journee="test-2027", p_code="") is False
    assert menu(db)["test-2027"]["ouverte"] is False
    db.err("P0005", "apa_connexion", p_journee="test-2027", p_code="tilleul-brume-42")
    db.err("P0005", "apa_etat", p_journee="test-2027", p_code="tilleul-brume-42")
    db.err("P0005", "apa_enregistrer_lot", p_journee="test-2027", p_code="tilleul-brume-42", p_institution=inst, p_lignes=[])
    # Les inscriptions déjà faites restent.
    assert db.val("select count(*) from beneficiaires where journee = 'test-2027'") == 8


def test_le_code_n_est_jamais_renvoye(db):
    db.journee()
    for data in (db.rpc("apa_journees"), db.admin("apa_admin_journees"), db.etat()):
        texte = str(data)
        assert "code_hash" not in texte and "$2a$" not in texte and "$2b$" not in texte


# ---------------- Dupliquer ----------------

def test_dupliquer_copie_infos_ateliers_horaires_sans_inscriptions_ni_code(db):
    db.journee(places_max=50)
    db.admin("apa_admin_enregistrer_journee", p_id="test-2027", p_nouvelle=False,
             p_data={"nom": "Journée test", "date": "2027-06-10", "lieu": "Testville", "pause_midi": "Dîner 12h", "places_max": 50})
    db.institution()
    db.admin("apa_admin_dupliquer_journee", p_source="test-2027", p_id="test-2028", p_nom="Journée test 2028", p_date="2028-06-08")
    j = menu(db)["test-2028"]
    assert (j["nom"], j["date"], j["lieu"], j["pause_midi"], j["places_max"], j["ouverte"]) == ("Journée test 2028", "2028-06-08", "Testville", "Dîner 12h", 50, False)
    src, cop = db.admin("apa_admin_journee", p_journee="test-2027"), db.admin("apa_admin_journee", p_journee="test-2028")
    assert [(a["nom"], a["lieu"], a["cap"]) for a in cop["ateliers"]] == [(a["nom"], a["lieu"], a["cap"]) for a in src["ateliers"]]
    assert [(t["debut"], t["fin"]) for t in cop["tournantes"]] == [(t["debut"], t["fin"]) for t in src["tournantes"]]
    assert db.val("select count(*) from institutions where journee = 'test-2028'") == 0
    assert db.val("select count(*) from activites where journee = 'test-2028' and id = 'pause'") == 1


def test_dupliquer_refuse_un_identifiant_pris_ou_invalide(db):
    db.journee()
    db.err("P0009", "apa_admin_dupliquer_journee", p_code_admin="organisateur-test-2027", p_source="test-2027", p_id="marcinelle-2027", p_nom="X", p_date="2028-01-01")
    db.err("22023", "apa_admin_dupliquer_journee", p_code_admin="organisateur-test-2027", p_source="test-2027", p_id="Pas Bon", p_nom="X", p_date="2028-01-01")
    db.err("P0006", "apa_admin_dupliquer_journee", p_code_admin="organisateur-test-2027", p_source="inconnue", p_id="ok-2028", p_nom="X", p_date="2028-01-01")
    db.err("22023", "apa_admin_dupliquer_journee", p_code_admin="organisateur-test-2027", p_source="test-2027", p_id="ok-2028", p_nom=" ", p_date="2028-01-01")


def test_les_places_de_la_copie_sont_independantes(db):
    db.journee(ateliers=(("Massage", "P1", 4),))
    db.admin("apa_admin_dupliquer_journee", p_source="test-2027", p_id="test-2028", p_nom="Copie", p_date="2028-06-08")
    db.admin("apa_admin_definir_code", p_journee="test-2028", p_code="bouleau-glacier-14")
    a = db.institution(places=4)
    db.lot(a, [dict(l, plan={"1": "massage"}) for l in db.lignes(a)])        # Massage T1 plein dans l'original…
    b = db.institution("test-2028", places=4, code="bouleau-glacier-14")
    db.lot(b, [dict(l, plan={"1": "massage"}) for l in db.lignes(b, jid="test-2028", code="bouleau-glacier-14")],
           jid="test-2028", code="bouleau-glacier-14")                        # …et libre dans la copie


# ---------------- Supprimer ----------------

def test_supprimer_une_journee_avec_institutions_est_refuse(db):
    db.journee()
    inst = db.institution()
    msg = db.err("P0011", "apa_admin_supprimer_journee", p_code_admin="organisateur-test-2027", p_journee="test-2027")
    assert "1 institution(s) et 8 participant(s)" in msg
    db.admin("apa_admin_supprimer_institution", p_institution=inst)
    db.admin("apa_admin_supprimer_journee", p_journee="test-2027")
    assert "test-2027" not in menu(db)
    assert db.val("select count(*) from activites where journee = 'test-2027'") == 0
    assert db.val("select count(*) from tournantes where journee = 'test-2027'") == 0


def test_supprimer_une_journee_inconnue(db):
    db.err("P0006", "apa_admin_supprimer_journee", p_code_admin="organisateur-test-2027", p_journee="inconnue")
