"""Installation et mise à jour du schéma (supabase/schema.sql)."""
import psycopg

from conftest import ADMIN, SCHEMA, SCHEMA_V1, Db


def test_base_vide_recoit_les_trois_journees_de_depart(nouvelle_base):
    dsn = nouvelle_base()
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute(SCHEMA)
        db = Db(c)
        assert [r[0] for r in db.sql("select id from journees order by date_jour")] == ["marcinelle-2027", "philippeville-2027", "pqr-2027"]
        for jid in ("marcinelle-2027", "philippeville-2027", "pqr-2027"):
            assert db.val("select count(*) from activites where journee = %s and id <> 'pause'", [jid]) == 17
            assert db.val("select count(*) from activites where journee = %s and id = 'pause'", [jid]) == 1
            assert db.val("select count(*) from tournantes where journee = %s", [jid]) == 15
        # Aucune journée n'est ouverte tant qu'elle n'a pas de code.
        assert db.val("select count(*) from journees where code_hash is not null") == 0


def test_relancer_le_schema_ne_change_pas_les_modifications_de_l_organisateur(db):
    db.admin("apa_admin_enregistrer_journee", p_id="marcinelle-2027", p_nouvelle=False,
             p_data={"nom": "Marcinelle renommée", "date": "2027-03-31", "lieu": "Marcinelle", "places_max": 40})
    db.admin("apa_admin_enregistrer_atelier", p_journee="marcinelle-2027", p_id="zumba", p_nom="Zumba XL", p_lieu="P2", p_cap=24, p_ordre=1)
    db.admin("apa_admin_supprimer_atelier", p_journee="marcinelle-2027", p_id="massage", p_confirmer=False)
    db.admin("apa_admin_definir_code", p_journee="marcinelle-2027", p_code="granit-hibou-77")
    db.sql(SCHEMA)   # comme si on relançait le script dans le SQL Editor
    assert db.sql("select nom, date_jour::text, places_max from journees where id = 'marcinelle-2027'")[0] == ("Marcinelle renommée", "2027-03-31", 40)
    assert db.sql("select nom, cap from activites where journee = 'marcinelle-2027' and id = 'zumba'")[0] == ("Zumba XL", 24)
    assert db.val("select count(*) from activites where journee = 'marcinelle-2027' and id = 'massage'") == 0   # pas recréé
    assert db.rpc("apa_connexion", p_journee="marcinelle-2027", p_code="granit-hibou-77") is True               # code gardé


def test_relancer_le_schema_garde_les_inscriptions_et_le_code_organisateur(db):
    db.journee()
    inst = db.institution()
    db.lot(inst, db.lignes(inst, {"Participant 1": {"1": "zumba"}}))
    db.sql(SCHEMA)
    assert db.val("select count(*) from inscriptions where journee = 'test-2027'") == 1
    assert db.admin("apa_admin_journees")   # le code organisateur marche toujours


def test_relancer_le_schema_ajoute_la_pause_aux_journees_qui_n_en_ont_pas(db):
    db.journee()
    db.sql("delete from activites where journee = 'test-2027' and id = 'pause'")
    db.sql(SCHEMA)
    assert db.val("select count(*) from activites where journee = 'test-2027' and id = 'pause'") == 1


def test_migration_depuis_la_journee_du_17_novembre(nouvelle_base):
    """L'ancienne base (une seule journée) est archivée sans perte, puis la nouvelle s'installe."""
    dsn = nouvelle_base()
    with psycopg.connect(dsn, autocommit=True) as c:
        c.execute(SCHEMA_V1)
        c.execute("insert into institutions (nom, nb_attendu) values ('Ancienne institution', 2)")
        c.execute("insert into beneficiaires (nom, institution_id) select 'Jean', id from institutions")
        c.execute("insert into inscriptions select id, 1, 'zumba' from beneficiaires")
        c.execute(SCHEMA)
        db = Db(c)
        assert db.val("select count(*) from archive_17_novembre.inscriptions") == 1
        assert db.val("select nom from archive_17_novembre.beneficiaires") == "Jean"
        assert db.val("select count(*) from journees") == 3
        assert db.val("select count(*) from beneficiaires") == 0   # rien de l'ancienne journée dans la nouvelle
        c.execute(SCHEMA)   # et on peut encore relancer
        c.execute("select public.apa_definir_code_admin(%s)", [ADMIN])
        assert len(db.rpc("apa_admin_journees", p_code_admin=ADMIN)) == 3
