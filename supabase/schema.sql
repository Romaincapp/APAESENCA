-- =====================================================================
-- APAESENCA – inscriptions aux journées APA (plusieurs journées)
-- À coller dans Supabase > SQL Editor, puis "Run".
-- Le script peut être relancé : il recrée les fonctions et les données
-- de référence (journées, activités, tournantes) sans toucher aux
-- inscriptions ni aux codes d'accès.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- Passage de l'ancienne version (une seule journée) --------
-- Si la base contient encore les tables de la journée du 17 novembre
-- (sans colonne « journee »), elles sont déplacées telles quelles dans le
-- schéma « archive_17_novembre » (invisible depuis la page). Rien n'est
-- effacé. Pour les supprimer définitivement plus tard :
--   drop schema archive_17_novembre cascade;
do $$ begin
  if to_regclass('public.activites') is not null and not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'activites' and column_name = 'journee'
  ) then
    create schema if not exists archive_17_novembre;
    alter table public.inscriptions  set schema archive_17_novembre;
    alter table public.beneficiaires set schema archive_17_novembre;
    alter table public.institutions  set schema archive_17_novembre;
    alter table public.tournantes    set schema archive_17_novembre;
    alter table public.activites     set schema archive_17_novembre;
    revoke all on schema archive_17_novembre from public;
  end if;
end $$;

-- Anciennes fonctions (sans paramètre « journée ») : remplacées plus bas.
drop function if exists public.apa_connexion(text);
drop function if exists public.apa_etat(text);
drop function if exists public.apa_enregistrer(text, uuid, text, text, jsonb);
drop function if exists public.apa_enregistrer(text, uuid, text, text, jsonb, uuid);
drop function if exists public.apa_enregistrer_lot(text, uuid, jsonb);
drop function if exists public.apa_supprimer(text, uuid);
drop function if exists public.apa_verrouiller(text, uuid);
drop function if exists public.apa_definir_code(text);
drop function if exists public._apa_check_code(text);
drop function if exists public._apa_check_capacite();

-- ---------- Tables ----------------------------------------------------

-- Une ligne par journée. code_hash : code d'accès de la journée (haché,
-- jamais lisible depuis la page). Tant qu'il est vide, la journée apparaît
-- dans le menu mais les inscriptions ne sont pas ouvertes.
create table if not exists public.journees (
  id          text primary key check (id ~ '^[a-z0-9-]{2,40}$'),
  nom         text not null,
  date_jour   date not null,
  lieu        text not null default '',
  description text not null default '',   -- texte d'accueil affiché dans le menu
  acces       text not null default '',   -- mention publique, ex. « Réservé aux institutions … »
  pause_midi  text not null default '',   -- ex. « Dîner pour tous à 12h05 · reprise à 12h50 »
  ordre       int  not null default 0,
  visible     boolean not null default true,
  code_hash   text
);

create table if not exists public.activites (
  journee text not null references public.journees(id) on delete cascade,
  id      text not null,
  nom     text not null,
  lieu    text not null,
  cap     int  not null check (cap > 0),
  ordre   int  not null,
  primary key (journee, id)
);

create table if not exists public.tournantes (
  journee text not null references public.journees(id) on delete cascade,
  id      int  not null,                -- 1, 2, 3…
  debut   time not null,
  fin     time not null,
  demi    text not null,                -- 'Matin' / 'Après-midi'
  primary key (journee, id)
);

create table if not exists public.institutions (
  id            uuid primary key default gen_random_uuid(),
  journee       text not null references public.journees(id) on delete cascade,
  nom           text not null check (length(trim(nom)) between 1 and 120),
  nb_attendu    int  not null default 0 check (nb_attendu >= 0),
  ordre         int  not null default 0,
  verrouille_le timestamptz,            -- date du téléchargement du PDF (null = modifiable)
  unique (journee, nom)
);

create table if not exists public.beneficiaires (
  id             uuid primary key default gen_random_uuid(),
  journee        text not null references public.journees(id) on delete cascade,
  nom            text not null check (length(trim(nom)) between 1 and 120),
  groupe         text not null default '' check (length(groupe) <= 120),
  institution_id uuid references public.institutions(id) on delete set null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists beneficiaires_journee on public.beneficiaires (journee);
create index if not exists beneficiaires_institution on public.beneficiaires (institution_id);

create table if not exists public.inscriptions (
  beneficiaire_id uuid not null references public.beneficiaires(id) on delete cascade,
  journee         text not null,
  tournante       int  not null,
  activite        text not null,
  primary key (beneficiaire_id, tournante),            -- une seule activité par tournante
  foreign key (journee, tournante) references public.tournantes(journee, id),
  foreign key (journee, activite)  references public.activites(journee, id)
);
create index if not exists inscriptions_creneau on public.inscriptions (journee, tournante, activite);

-- Code organisateur (commun à toutes les journées) : seul à pouvoir déverrouiller.
create table if not exists public.config (
  id         int primary key default 1 check (id = 1),
  code_hash  text,                      -- ancien code d'équipe, plus utilisé
  admin_hash text
);
alter table public.config alter column code_hash drop not null;

-- Nombre maximum de participants pour la journée (null = pas de limite).
-- Se règle dans le SQL Editor : update public.journees set places_max = 60 where id = '…';
alter table public.journees add column if not exists places_max int check (places_max > 0);

-- Inscription des institutions (remplace le Google Form).
-- nb_attendu = nombre de places réservées par l'institution.
-- Les coordonnées ne sont lisibles qu'avec le code organisateur.
alter table public.institutions add column if not exists responsable   text not null default '' check (length(responsable) <= 120);
alter table public.institutions add column if not exists email         text not null default '' check (length(email) <= 200);
alter table public.institutions add column if not exists telephone     text not null default '' check (length(telephone) <= 40);
alter table public.institutions add column if not exists nb_educateurs int  not null default 0 check (nb_educateurs between 0 and 100);
alter table public.institutions add column if not exists nb_pmr        int  not null default 0 check (nb_pmr between 0 and 300);
-- Groupe du participant dans son institution (ex. « Groupe de Marie », ~8 résidents par éducateur).
alter table public.beneficiaires add column if not exists equipe text not null default '' check (length(equipe) <= 60);
alter table public.institutions add column if not exists inscrite_le   timestamptz not null default now();
alter table public.config add column if not exists admin_hash text;

-- ---------- Sécurité : aucune lecture/écriture directe ----------------
-- La page passe UNIQUEMENT par les fonctions ci-dessous, qui vérifient le
-- code d'accès de la journée. Sans ce code, rien n'est lisible (ni les
-- noms, ni les codes).

alter table public.journees      enable row level security;
alter table public.activites     enable row level security;
alter table public.tournantes    enable row level security;
alter table public.beneficiaires enable row level security;
alter table public.institutions  enable row level security;
alter table public.inscriptions  enable row level security;
alter table public.config        enable row level security;
drop policy if exists "lecture activites"  on public.activites;
drop policy if exists "lecture tournantes" on public.tournantes;
-- (aucune policy = aucun accès direct avec la clé publique)

-- ---------- Données de départ ---------------------------------------
-- Créées UNE SEULE FOIS, sur une base vide. Ensuite, les journées, ateliers et
-- horaires se gèrent depuis l'espace organisateur de la page (…/#organisateur) :
-- relancer ce script ne les écrase plus.
do $$ begin
  if not exists (select 1 from public.journees) then
    insert into public.journees (id, nom, date_jour, lieu, description, acces, pause_midi, ordre) values
      ('marcinelle-2027',    'Journée APA de Marcinelle',    '2027-03-30', 'Marcinelle',    '', '',
         'Dîner pour tous à 12h05 · reprise à 12h50', 1),
      ('philippeville-2027', 'Journée APA de Philippeville', '2027-04-22', 'Philippeville', '', '',
         'Dîner pour tous à 12h05 · reprise à 12h50', 2),
      ('pqr-2027',           'Poire qui Roule (PQR)',        '2027-05-27', '',              '',
         'Réservé aux institutions de la région de Chimay',
         'Dîner pour tous à 12h05 · reprise à 12h50', 3);

    -- Ateliers et horaires provisoires (ceux de la journée du 17 novembre).
    insert into public.activites (journee, id, nom, lieu, cap, ordre)
    select j.id, a.id, a.nom, a.lieu, a.cap, a.ordre from public.journees j cross join (values
      ('cheveux',    'Soin des cheveux',         'P1',  3,  1), ('ongles',     'Soin des ongles',          'P1',  3,  2),
      ('bocaux',     'Customisation de bocaux',  'P1',  6,  3), ('mandalas',   'Mandalas',                 'P1', 10,  4),
      ('massage',    'Massage',                  'P1',  4,  5), ('parachute',  'Parachute',                'P1', 10,  6),
      ('cirque',     'Cirque assiettes',         'P1',  5,  7), ('antistress', 'Balle anti-stress',        'P1',  8,  8),
      ('zumba',      'Zumba',                    'P2', 15,  9), ('massacre',   'Jeu de massacre',          'P2',  6, 10),
      ('kinball',    'Kinball',                  'P2', 16, 11), ('boccia',     'Boccia',                   'P2',  6, 12),
      ('basket',     'Initiation basket',        'P3', 10, 13), ('bowling',    'Bowling',                  'P3',  6, 14),
      ('psychomot',  'Parcours psychomotricité', 'P3',  6, 15), ('football',   'Initiation football',      'P3', 10, 16),
      ('flechettes', 'Fléchettes ventouses',     'P3',  5, 17)) a(id, nom, lieu, cap, ordre);

    insert into public.tournantes (journee, id, debut, fin, demi)
    select j.id, t.id, t.debut::time, t.fin::time, t.demi from public.journees j cross join (values
      ( 1, '09:45', '10:00', 'Matin'), ( 2, '10:05', '10:20', 'Matin'), ( 3, '10:25', '10:40', 'Matin'),
      ( 4, '10:45', '11:00', 'Matin'), ( 5, '11:05', '11:20', 'Matin'), ( 6, '11:25', '11:40', 'Matin'),
      ( 7, '11:45', '12:00', 'Matin'), ( 8, '12:50', '13:05', 'Après-midi'), ( 9, '13:10', '13:25', 'Après-midi'),
      (10, '13:30', '13:45', 'Après-midi'), (11, '13:50', '14:05', 'Après-midi'), (12, '14:10', '14:25', 'Après-midi'),
      (13, '14:30', '14:45', 'Après-midi'), (14, '14:50', '15:05', 'Après-midi'), (15, '15:10', '15:25', 'Après-midi')) t(id, debut, fin, demi);
  end if;
end $$;

-- « Pause / repos » : marque volontairement une tournante sans activité (différent d'une
-- case oubliée). Présente dans chaque journée, sans limite de places, jamais supprimée.
insert into public.activites (journee, id, nom, lieu, cap, ordre)
select id, 'pause', 'Pause / repos', '—', 999, 999 from public.journees
on conflict (journee, id) do nothing;

-- ---------- Fonctions -------------------------------------------------

-- Vérifie le code d'accès d'une journée.
create or replace function public._apa_check_code(p_journee text, p_code text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  select code_hash into v_hash from public.journees where id = p_journee;
  if not found then
    raise exception 'Journée inconnue.' using errcode = 'P0006';
  end if;
  if v_hash is null then
    raise exception 'Les inscriptions pour cette journée ne sont pas encore ouvertes.' using errcode = 'P0005';
  end if;
  if p_code is null or v_hash <> crypt(p_code, v_hash) then
    raise exception 'Code d''accès incorrect.' using errcode = '28000';
  end if;
end $$;

-- Définit ou change le code d'accès d'une journée. SQL Editor uniquement :
--   select public.apa_definir_code('marcinelle-2027', 'code-secret');
create or replace function public.apa_definir_code(p_journee text, p_nouveau text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_nouveau is null or length(p_nouveau) < 4 then
    raise exception 'Le code doit faire au moins 4 caractères.';
  end if;
  update public.journees set code_hash = crypt(p_nouveau, gen_salt('bf')) where id = p_journee;
  if not found then
    raise exception 'Journée inconnue : %', p_journee;
  end if;
end $$;

-- Code organisateur (commun). SQL Editor uniquement :
--   select public.apa_definir_code_admin('code-organisateur');
create or replace function public.apa_definir_code_admin(p_nouveau text)
returns void language sql security definer set search_path = public, extensions as $$
  insert into public.config (id, admin_hash) values (1, crypt(p_nouveau, gen_salt('bf')))
  on conflict (id) do update set admin_hash = excluded.admin_hash;
$$;

create or replace function public._apa_check_admin(p_code text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_code is null or not exists (
    select 1 from public.config where admin_hash is not null and admin_hash = crypt(p_code, admin_hash)
  ) then
    raise exception 'Code organisateur incorrect.' using errcode = '28000';
  end if;
end $$;

-- Refuse toute modification d'une institution verrouillée (et verrouille sa
-- ligne pendant la transaction pour qu'un verrouillage et un enregistrement
-- simultanés ne puissent pas se croiser).
create or replace function public._apa_check_ouvert(p_institution uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_nom text; v_le timestamptz;
begin
  if p_institution is null then return; end if;
  select nom, verrouille_le into v_nom, v_le from public.institutions where id = p_institution for update;
  if v_le is not null then
    raise exception 'Le planning de % est verrouillé depuis le téléchargement du PDF. Demande à l''organisateur de le déverrouiller.', v_nom
      using errcode = 'P0004';
  end if;
end $$;

-- Places prises dans une journée : places réservées par les institutions
-- (ou leur nombre réel de participants s'il est plus grand) + inscriptions
-- individuelles sans institution.
create or replace function public._apa_places_prises(p_journee text)
returns int language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select sum(greatest(i.nb_attendu,
                     (select count(*) from public.beneficiaires b where b.institution_id = i.id)))
                     from public.institutions i where i.journee = p_journee), 0)::int
       + (select count(*) from public.beneficiaires b where b.journee = p_journee and b.institution_id is null)::int;
$$;

-- Après une écriture : une institution ne dépasse pas ses places réservées,
-- et la journée ne dépasse pas son maximum.
create or replace function public._apa_check_places(p_journee text, p_institution uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_nom text; v_res int; v_n int; v_max int; v_prises int;
begin
  if p_institution is not null then
    select nom, nb_attendu into v_nom, v_res from public.institutions where id = p_institution;
    select count(*) into v_n from public.beneficiaires where institution_id = p_institution;
    if v_res > 0 and v_n > v_res then   -- 0 = pas de réservation (institution chargée à la main)
      raise exception '% a % participants pour % places réservées. Augmente la réservation ou retire des participants.', v_nom, v_n, v_res
        using errcode = 'P0008';
    end if;
  end if;
  select places_max into v_max from public.journees where id = p_journee;
  if v_max is not null then
    v_prises := public._apa_places_prises(p_journee);
    if v_prises > v_max then
      raise exception 'La journée est complète (% places).', v_max using errcode = 'P0007';
    end if;
  end if;
end $$;

-- Valide les champs d'une réservation.
create or replace function public._apa_check_reservation(p_places int, p_educateurs int, p_pmr int)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_places is null or p_places < 1 or p_places > 300 then
    raise exception 'Indique le nombre de participants (au moins 1).' using errcode = '22023';
  end if;
  if p_educateurs is null or p_educateurs < 0 or p_educateurs > 100 then
    raise exception 'Nombre d''éducateurs invalide.' using errcode = '22023';
  end if;
  if p_pmr is null or p_pmr < 0 or p_pmr > p_places then
    raise exception 'Le nombre de PMR doit être entre 0 et le nombre de participants.' using errcode = '22023';
  end if;
end $$;

-- Une institution s'inscrit à la journée (remplace le Google Form).
-- Crée aussi ses lignes « Participant 1…N », prêtes à être nommées et planifiées.
create or replace function public.apa_inscrire_institution(
  p_journee text, p_code text, p_nom text, p_responsable text, p_email text, p_telephone text,
  p_places int, p_educateurs int, p_pmr int)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_max int; v_reste int;
begin
  perform public._apa_check_code(p_journee, p_code);
  if length(trim(coalesce(p_nom, ''))) = 0 then
    raise exception 'Indique le nom de l''institution.' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_responsable, ''))) = 0 then
    raise exception 'Indique le nom de la personne responsable.' using errcode = '22023';
  end if;
  if trim(coalesce(p_email, '')) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Adresse e-mail invalide.' using errcode = '22023';
  end if;
  if length(regexp_replace(coalesce(p_telephone, ''), '\D', '', 'g')) < 8 then
    raise exception 'Numéro de téléphone invalide.' using errcode = '22023';
  end if;
  perform public._apa_check_reservation(p_places, p_educateurs, p_pmr);

  -- Une seule inscription à la fois par journée : les places ne peuvent pas être prises deux fois.
  select places_max into v_max from public.journees where id = p_journee for update;
  if v_max is not null then
    v_reste := v_max - public._apa_places_prises(p_journee);
    if v_reste <= 0 then
      raise exception 'La journée est complète.' using errcode = 'P0007';
    elsif p_places > v_reste then
      raise exception 'Il ne reste que % place%.', v_reste, case when v_reste > 1 then 's' else '' end using errcode = 'P0007';
    end if;
  end if;

  if exists (select 1 from public.institutions
              where journee = p_journee and lower(trim(nom)) = lower(trim(p_nom))) then
    raise exception '« % » est déjà inscrite à cette journée. Choisis-la dans la liste.', trim(p_nom) using errcode = 'P0009';
  end if;

  begin
    insert into public.institutions (journee, nom, nb_attendu, responsable, email, telephone, nb_educateurs, nb_pmr, ordre)
    values (p_journee, trim(p_nom), p_places, trim(p_responsable), lower(trim(p_email)), trim(p_telephone), p_educateurs, p_pmr,
            coalesce((select max(ordre) + 1 from public.institutions where journee = p_journee), 1))
    returning id into v_id;
  exception when unique_violation then
    raise exception '« % » est déjà inscrite à cette journée. Choisis-la dans la liste.', trim(p_nom) using errcode = 'P0009';
  end;

  insert into public.beneficiaires (journee, nom, institution_id)
  select p_journee, 'Participant ' || k, v_id from generate_series(1, p_places) k;
  return v_id;
end $$;

-- Modifie la réservation d'une institution (places, éducateurs, PMR).
create or replace function public.apa_modifier_reservation(p_journee text, p_code text, p_institution uuid, p_places int, p_educateurs int, p_pmr int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_max int; v_reste int; v_n int;
begin
  perform public._apa_check_code(p_journee, p_code);
  if p_institution is null then
    raise exception 'Institution inconnue.' using errcode = '22023';
  end if;
  perform public._apa_check_institution(p_journee, p_institution);
  perform public._apa_check_reservation(p_places, p_educateurs, p_pmr);
  perform public._apa_check_ouvert(p_institution);
  select count(*) into v_n from public.beneficiaires where institution_id = p_institution;
  if p_places < v_n then
    raise exception 'L''institution a déjà % participants : retire d''abord des participants.', v_n using errcode = 'P0008';
  end if;
  select places_max into v_max from public.journees where id = p_journee for update;
  if v_max is not null then
    v_reste := v_max - public._apa_places_prises(p_journee)
             + (select greatest(nb_attendu, v_n) from public.institutions where id = p_institution);
    if p_places > v_reste then
      raise exception 'Il ne reste que % place% pour cette institution.', v_reste, case when v_reste > 1 then 's' else '' end using errcode = 'P0007';
    end if;
  end if;
  update public.institutions set nb_attendu = p_places, nb_educateurs = p_educateurs, nb_pmr = p_pmr where id = p_institution;
end $$;

-- ORGANISATEUR : liste des institutions avec leurs coordonnées.
create or replace function public.apa_admin_institutions(p_code_admin text, p_journee text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'nom', i.nom, 'responsable', i.responsable, 'email', i.email, 'telephone', i.telephone,
      'places', i.nb_attendu, 'educateurs', i.nb_educateurs, 'pmr', i.nb_pmr, 'inscrite_le', i.inscrite_le,
      'verrouille_le', i.verrouille_le,
      'participants', (select count(*) from public.beneficiaires b where b.institution_id = i.id)
    ) order by i.inscrite_le), '[]')
    from public.institutions i where i.journee = p_journee);
end $$;

-- ORGANISATEUR : supprime une institution et tous ses participants.
create or replace function public.apa_admin_supprimer_institution(p_code_admin text, p_institution uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  delete from public.beneficiaires where institution_id = p_institution;
  delete from public.institutions where id = p_institution;
end $$;

-- Menu d'accueil : liste publique des journées (sans aucun nom ni code).
create or replace function public.apa_journees()
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'nom', nom, 'date', date_jour, 'lieu', lieu, 'description', description,
    'acces', acces, 'pause_midi', pause_midi, 'ouverte', code_hash is not null,
    'places_max', places_max, 'places_prises', public._apa_places_prises(id)
  ) order by date_jour, ordre), '[]')
  from public.journees where visible;
$$;

-- Vérifie le code (écran de connexion de la page).
create or replace function public.apa_connexion(p_journee text, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_code(p_journee, p_code);
  return true;
end $$;

-- Tout l'état utile à la page pour UNE journée.
create or replace function public.apa_etat(p_journee text, p_code text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_code(p_journee, p_code);
  return jsonb_build_object(
    'journee', (select jsonb_build_object('id', id, 'nom', nom, 'date', date_jour, 'lieu', lieu, 'description', description,
                  'places_max', places_max, 'places_prises', public._apa_places_prises(id),
                  'acces', acces, 'pause_midi', pause_midi) from public.journees where id = p_journee),
    'activites', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'lieu', lieu, 'cap', cap) order by ordre), '[]')
                    from public.activites where journee = p_journee),
    'tournantes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'debut', to_char(debut, 'HH24:MI'), 'fin', to_char(fin, 'HH24:MI'), 'demi', demi) order by id), '[]')
                    from public.tournantes where journee = p_journee),
    'institutions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'nom', nom, 'nb_attendu', nb_attendu, 'verrouille_le', verrouille_le,
                      'nb_educateurs', nb_educateurs, 'nb_pmr', nb_pmr) order by ordre, nom), '[]')
                    from public.institutions where journee = p_journee),
    'beneficiaires', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'nom', b.nom, 'groupe', b.groupe, 'equipe', b.equipe, 'maj', b.updated_at, 'institution', b.institution_id,
        'plan', coalesce((select jsonb_object_agg(i.tournante::text, i.activite) from public.inscriptions i where i.beneficiaire_id = b.id), '{}'::jsonb)
      ) order by b.nom), '[]')
      from public.beneficiaires b where b.journee = p_journee)
  );
end $$;

-- Aucune tournante/activité de la journée ne dépasse sa capacité.
-- Appelé APRÈS les écritures, pendant que les activités sont verrouillées.
create or replace function public._apa_check_capacite(p_journee text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_pleins text;
begin
  select string_agg(format('%s (T%s)', a.nom, i.tournante), ', ' order by i.tournante, a.nom)
    into v_pleins
    from (select tournante, activite, count(*) n from public.inscriptions
           where journee = p_journee group by tournante, activite) i
    join public.activites a on a.journee = p_journee and a.id = i.activite
   where i.n > a.cap;
  if v_pleins is not null then
    raise exception 'Plus de place pour : %', v_pleins using errcode = 'P0001';  -- annule tout
  end if;
end $$;

-- Un planning ne cite que des tournantes et des ateliers qui existent encore
-- (l'organisateur peut en supprimer pendant qu'un brouillon est ouvert).
create or replace function public._apa_check_plan(p_journee text, p_plan jsonb)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare k text; v text;
begin
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' then return; end if;
  for k, v in select key, value from jsonb_each_text(p_plan) loop
    if k !~ '^[0-9]{1,3}$' or not exists (select 1 from public.tournantes where journee = p_journee and id = k::int) then
      raise exception 'La tournante T% n''existe plus : l''organisateur a changé les horaires. Recharge la page.', k using errcode = 'P0013';
    end if;
    if not exists (select 1 from public.activites where journee = p_journee and id = v) then
      raise exception 'Un atelier choisi n''existe plus : l''organisateur l''a supprimé. Recharge la page et choisis-en un autre.' using errcode = 'P0013';
    end if;
  end loop;
end $$;

-- L'institution doit appartenir à la journée.
create or replace function public._apa_check_institution(p_journee text, p_institution uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_institution is not null and not exists (
    select 1 from public.institutions where id = p_institution and journee = p_journee
  ) then
    raise exception 'Institution inconnue.' using errcode = '22023';
  end if;
end $$;

-- Crée ou modifie UN bénéficiaire et son planning, en une seule transaction.
-- p_plan : {"1": "zumba", "4": "kinball", ...}  (tournante -> activité)
create or replace function public.apa_enregistrer(p_journee text, p_code text, p_id uuid, p_nom text, p_groupe text, p_plan jsonb, p_institution uuid default null)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare
  v_id uuid := p_id;
begin
  perform public._apa_check_code(p_journee, p_code);
  perform public._apa_check_institution(p_journee, p_institution);

  if p_nom is null or length(trim(p_nom)) = 0 then
    raise exception 'Le nom est obligatoire.' using errcode = '22023';
  end if;
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' or (p_id is null and p_plan = '{}'::jsonb) then
    raise exception 'Choisis au moins une activité.' using errcode = '22023';
  end if;

  perform public._apa_check_ouvert(p_institution);
  if v_id is not null then
    perform public._apa_check_ouvert((select institution_id from public.beneficiaires where id = v_id and journee = p_journee));
  end if;

  -- Verrou sur les activités de la journée (toujours dans le même ordre : pas d'interblocage).
  perform 1 from public.activites where journee = p_journee order by id for update;

  if v_id is null then
    insert into public.beneficiaires (journee, nom, groupe, institution_id)
    values (p_journee, trim(p_nom), coalesce(trim(p_groupe), ''), p_institution)
    returning id into v_id;
  else
    update public.beneficiaires
       set nom = trim(p_nom), groupe = coalesce(trim(p_groupe), ''), institution_id = p_institution, updated_at = clock_timestamp()
     where id = v_id and journee = p_journee;
    if not found then
      raise exception 'Cette fiche a été supprimée entre-temps.' using errcode = 'P0002';
    end if;
    delete from public.inscriptions where beneficiaire_id = v_id;
  end if;

  perform public._apa_check_plan(p_journee, p_plan);
  insert into public.inscriptions (beneficiaire_id, journee, tournante, activite)
  select v_id, p_journee, key::int, value from jsonb_each_text(p_plan);

  perform public._apa_check_capacite(p_journee);
  perform public._apa_check_places(p_journee, p_institution);
  return v_id;
end $$;

-- Enregistre TOUTE une institution d'un coup (onglet « Par institution »).
-- p_lignes : [{"id": uuid|null, "nom": "...", "equipe": "Groupe 1", "maj": "<date lue>", "plan": {"1": "zumba", ...}}, ...]
-- Tout passe ou rien ne passe. Si une fiche a été modifiée par quelqu'un d'autre
-- depuis son chargement ("maj" différent), l'enregistrement est refusé.
create or replace function public.apa_enregistrer_lot(p_journee text, p_code text, p_institution uuid, p_lignes jsonb)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  l     jsonb;
  v_id  uuid;
  v_maj timestamptz;
  v_nom text;
  v_eq  text;
  n     int := 0;
begin
  perform public._apa_check_code(p_journee, p_code);
  if p_institution is null then
    raise exception 'Institution inconnue.' using errcode = '22023';
  end if;
  perform public._apa_check_institution(p_journee, p_institution);
  if p_lignes is null or jsonb_typeof(p_lignes) <> 'array' or jsonb_array_length(p_lignes) > 300 then
    raise exception 'Liste de participants invalide.' using errcode = '22023';
  end if;
  perform public._apa_check_ouvert(p_institution);

  perform 1 from public.activites where journee = p_journee order by id for update;

  for l in select * from jsonb_array_elements(p_lignes) loop
    v_nom := trim(coalesce(l->>'nom', ''));
    if v_nom = '' then
      raise exception 'Un participant n''a pas de nom.' using errcode = '22023';
    end if;
    v_id := nullif(l->>'id', '')::uuid;
    v_eq := left(trim(coalesce(l->>'equipe', '')), 60);

    if v_id is null then
      insert into public.beneficiaires (journee, nom, equipe, institution_id) values (p_journee, v_nom, v_eq, p_institution)
      returning id into v_id;
    else
      select updated_at into v_maj from public.beneficiaires where id = v_id and journee = p_journee for update;
      if not found then
        raise exception '% a été supprimé·e entre-temps.', v_nom using errcode = 'P0002';
      end if;
      perform public._apa_check_ouvert((select institution_id from public.beneficiaires where id = v_id));
      if l ? 'maj' and (l->>'maj')::timestamptz <> v_maj then
        raise exception 'La fiche de % a été modifiée par quelqu''un d''autre entre-temps.', v_nom using errcode = 'P0003';
      end if;
      update public.beneficiaires
         set nom = v_nom, equipe = v_eq, institution_id = p_institution, updated_at = clock_timestamp()
       where id = v_id;
      delete from public.inscriptions where beneficiaire_id = v_id;
    end if;

    perform public._apa_check_plan(p_journee, l->'plan');
    insert into public.inscriptions (beneficiaire_id, journee, tournante, activite)
    select v_id, p_journee, key::int, value from jsonb_each_text(coalesce(l->'plan', '{}'::jsonb));
    n := n + 1;
  end loop;

  perform public._apa_check_capacite(p_journee);
  perform public._apa_check_places(p_journee, p_institution);
  return n;
end $$;

create or replace function public.apa_supprimer(p_journee text, p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_code(p_journee, p_code);
  perform public._apa_check_ouvert((select institution_id from public.beneficiaires where id = p_id and journee = p_journee));
  delete from public.beneficiaires where id = p_id and journee = p_journee;
end $$;

-- Verrouille le planning d'une institution (appelé au téléchargement du PDF).
create or replace function public.apa_verrouiller(p_journee text, p_code text, p_institution uuid)
returns timestamptz language plpgsql security definer set search_path = public, extensions as $$
declare v_le timestamptz;
begin
  perform public._apa_check_code(p_journee, p_code);
  update public.institutions set verrouille_le = coalesce(verrouille_le, now())
   where id = p_institution and journee = p_journee returning verrouille_le into v_le;
  if not found then
    raise exception 'Institution inconnue.' using errcode = '22023';
  end if;
  return v_le;
end $$;

-- Déverrouille : réservé à l'organisateur (code organisateur).
create or replace function public.apa_deverrouiller(p_code_admin text, p_institution uuid)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  update public.institutions set verrouille_le = null where id = p_institution;
end $$;

-- =====================================================================
-- ESPACE ORGANISATEUR : journées, accès, ateliers, horaires, institutions.
-- Toutes ces fonctions exigent le code organisateur.
-- =====================================================================

-- Identifiant de journée valide (sert dans l'adresse de la page : …/#marcinelle-2027).
create or replace function public._apa_id_ok(p text)
returns boolean language sql immutable as $$
  select coalesce(p ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(p) between 2 and 40 and p not in ('organisateur', 'admin'), false);
$$;

-- Identifiant lisible à partir d'un nom : « Soin des cheveux » -> « soin-des-cheveux ».
create or replace function public._apa_slug(p text)
returns text language sql immutable as $$
  select coalesce(nullif(left(trim(both '-' from regexp_replace(
    translate(replace(replace(lower(coalesce(p, '')), 'œ', 'oe'), 'æ', 'ae'), 'àáâäãåçèéêëìíîïñòóôöõùúûüýÿ', 'aaaaaaceeeeiiiinooooouuuuyy'),
    '[^a-z0-9]+', '-', 'g')), 30), ''), 'atelier');
$$;

create or replace function public._apa_journee_existe(p_journee text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.journees where id = p_journee) then
    raise exception 'Journée inconnue.' using errcode = 'P0006';
  end if;
end $$;

-- Les inscriptions touchées par une suppression : combien, et de quelles institutions.
-- p_activite et/ou p_tournante_min (toutes les tournantes à partir de ce numéro).
create or replace function public._apa_impact(p_journee text, p_activite text, p_tournante_min int)
returns jsonb language sql stable security definer set search_path = public, extensions as $$
  with x as (
    select i.beneficiaire_id, b.institution_id from public.inscriptions i
      join public.beneficiaires b on b.id = i.beneficiaire_id
     where i.journee = p_journee
       and (p_activite is null or i.activite = p_activite)
       and (p_tournante_min is null or i.tournante >= p_tournante_min))
  select jsonb_build_object(
    'inscriptions', (select count(*) from x),
    'participants', (select count(distinct beneficiaire_id) from x),
    'institutions', coalesce((select jsonb_agg(jsonb_build_object('nom', coalesce(n.nom, 'Sans institution'), 'n', n.c, 'verrouillee', n.v is not null) order by n.nom)
      from (select inst.nom, inst.verrouille_le v, count(*) c from x left join public.institutions inst on inst.id = x.institution_id
             group by inst.nom, inst.verrouille_le) n), '[]'));
$$;

-- Liste de toutes les journées, cachées comprises, avec quelques chiffres.
create or replace function public.apa_admin_journees(p_code_admin text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'id', j.id, 'nom', j.nom, 'date', j.date_jour, 'lieu', j.lieu, 'description', j.description, 'acces', j.acces,
      'pause_midi', j.pause_midi, 'places_max', j.places_max, 'visible', j.visible, 'ordre', j.ordre,
      'ouverte', j.code_hash is not null, 'places_prises', public._apa_places_prises(j.id),
      'nb_institutions', (select count(*) from public.institutions i where i.journee = j.id),
      'nb_participants', (select count(*) from public.beneficiaires b where b.journee = j.id),
      'nb_ateliers', (select count(*) from public.activites a where a.journee = j.id and a.id <> 'pause'),
      'nb_tournantes', (select count(*) from public.tournantes t where t.journee = j.id)
    ) order by j.date_jour, j.ordre), '[]') from public.journees j);
end $$;

-- Détail d'une journée : ateliers (avec inscrits) et horaires (avec inscrits).
create or replace function public.apa_admin_journee(p_code_admin text, p_journee text)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  return jsonb_build_object(
    'ateliers', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'nom', a.nom, 'lieu', a.lieu, 'cap', a.cap, 'ordre', a.ordre,
        'inscrits', (select count(*) from public.inscriptions i where i.journee = p_journee and i.activite = a.id),
        'inscrits_max', coalesce((select max(c) from (select count(*) c from public.inscriptions i where i.journee = p_journee and i.activite = a.id group by i.tournante) z), 0)
      ) order by a.ordre, a.nom), '[]') from public.activites a where a.journee = p_journee and a.id <> 'pause'),
    'tournantes', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'debut', to_char(t.debut, 'HH24:MI'), 'fin', to_char(t.fin, 'HH24:MI'), 'demi', t.demi,
        'inscrits', (select count(*) from public.inscriptions i where i.journee = p_journee and i.tournante = t.id)
      ) order by t.id), '[]') from public.tournantes t where t.journee = p_journee));
end $$;

-- Crée (p_nouvelle = true) ou modifie une journée.
-- p_data : {"nom", "date" (AAAA-MM-JJ), "lieu", "description", "acces", "pause_midi", "places_max", "visible", "ordre"}
create or replace function public.apa_admin_enregistrer_journee(p_code_admin text, p_id text, p_nouvelle boolean, p_data jsonb)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  v_nom text := trim(coalesce(p_data->>'nom', ''));
  v_date date; v_max int; v_prises int;
begin
  perform public._apa_check_admin(p_code_admin);
  if v_nom = '' or length(v_nom) > 120 then
    raise exception 'Indique le nom de la journée (120 caractères maximum).' using errcode = '22023';
  end if;
  begin v_date := (p_data->>'date')::date; exception when others then v_date := null; end;
  if v_date is null then
    raise exception 'Indique une date valide.' using errcode = '22023';
  end if;
  begin v_max := nullif(trim(coalesce(p_data->>'places_max', '')), '')::int; exception when others then
    raise exception 'Le nombre maximum de places doit être un nombre.' using errcode = '22023';
  end;
  if v_max is not null and (v_max < 1 or v_max > 5000) then
    raise exception 'Le nombre maximum de places doit être entre 1 et 5000 (ou vide pour aucune limite).' using errcode = '22023';
  end if;
  if length(coalesce(p_data->>'lieu', '')) > 120 or length(coalesce(p_data->>'description', '')) > 1000
     or length(coalesce(p_data->>'acces', '')) > 200 or length(coalesce(p_data->>'pause_midi', '')) > 200 then
    raise exception 'Un des textes est trop long.' using errcode = '22023';
  end if;

  if p_nouvelle then
    if not public._apa_id_ok(p_id) then
      raise exception 'Identifiant invalide : lettres minuscules, chiffres et tirets uniquement (ex. couvin-2027).' using errcode = '22023';
    end if;
    if exists (select 1 from public.journees where id = p_id) then
      raise exception 'L''identifiant « % » existe déjà.', p_id using errcode = 'P0009';
    end if;
    insert into public.journees (id, nom, date_jour, lieu, description, acces, pause_midi, places_max, visible, ordre)
    values (p_id, v_nom, v_date, trim(coalesce(p_data->>'lieu', '')), trim(coalesce(p_data->>'description', '')),
            trim(coalesce(p_data->>'acces', '')), trim(coalesce(p_data->>'pause_midi', '')), v_max,
            coalesce((p_data->>'visible')::boolean, true),
            coalesce((p_data->>'ordre')::int, (select coalesce(max(ordre), 0) + 1 from public.journees)));
    insert into public.activites (journee, id, nom, lieu, cap, ordre) values (p_id, 'pause', 'Pause / repos', '—', 999, 999);
  else
    select places_max into v_prises from public.journees where id = p_id for update;
    if not found then raise exception 'Journée inconnue.' using errcode = 'P0006'; end if;
    v_prises := public._apa_places_prises(p_id);
    if v_max is not null and v_max < v_prises then
      raise exception 'Il y a déjà % places prises : le maximum ne peut pas être plus bas.', v_prises using errcode = 'P0007';
    end if;
    update public.journees set nom = v_nom, date_jour = v_date, lieu = trim(coalesce(p_data->>'lieu', '')),
           description = trim(coalesce(p_data->>'description', '')), acces = trim(coalesce(p_data->>'acces', '')),
           pause_midi = trim(coalesce(p_data->>'pause_midi', '')), places_max = v_max,
           visible = coalesce((p_data->>'visible')::boolean, visible), ordre = coalesce((p_data->>'ordre')::int, ordre)
     where id = p_id;
  end if;
  return p_id;
end $$;

-- Ouvre les inscriptions (nouveau code) ou les ferme (code vide).
create or replace function public.apa_admin_definir_code(p_code_admin text, p_journee text, p_code text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare j record; v text := trim(coalesce(p_code, ''));
begin
  perform public._apa_check_admin(p_code_admin);
  select * into j from public.journees where id = p_journee;
  if not found then raise exception 'Journée inconnue.' using errcode = 'P0006'; end if;
  if v = '' then
    update public.journees set code_hash = null where id = p_journee;
    return false;
  end if;
  if length(v) < 6 then
    raise exception 'Le code doit faire au moins 6 caractères.' using errcode = '22023';
  end if;
  if position(lower(v) in lower(j.id || ' ' || j.nom || ' ' || j.lieu)) > 0
     or (length(j.lieu) >= 3 and position(lower(j.lieu) in lower(v)) > 0)
     or position(lower(split_part(j.id, '-', 1)) in lower(v)) > 0 then
    raise exception 'Ce code est trop facile à deviner : n''utilise pas le nom ou le lieu de la journée.' using errcode = '22023';
  end if;
  update public.journees set code_hash = crypt(v, gen_salt('bf')) where id = p_journee;
  return true;
end $$;

-- Copie une journée (infos, ateliers, horaires), sans institutions, inscriptions ni code.
create or replace function public.apa_admin_dupliquer_journee(p_code_admin text, p_source text, p_id text, p_nom text, p_date date)
returns text language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_source);
  if not public._apa_id_ok(p_id) then
    raise exception 'Identifiant invalide : lettres minuscules, chiffres et tirets uniquement (ex. couvin-2027).' using errcode = '22023';
  end if;
  if exists (select 1 from public.journees where id = p_id) then
    raise exception 'L''identifiant « % » existe déjà.', p_id using errcode = 'P0009';
  end if;
  if length(trim(coalesce(p_nom, ''))) = 0 or p_date is null then
    raise exception 'Indique le nom et la date de la nouvelle journée.' using errcode = '22023';
  end if;
  insert into public.journees (id, nom, date_jour, lieu, description, acces, pause_midi, places_max, visible, ordre)
  select p_id, trim(p_nom), p_date, lieu, description, acces, pause_midi, places_max, true,
         (select coalesce(max(ordre), 0) + 1 from public.journees)
    from public.journees where id = p_source;
  insert into public.activites (journee, id, nom, lieu, cap, ordre)
  select p_id, id, nom, lieu, cap, ordre from public.activites where journee = p_source;
  insert into public.activites (journee, id, nom, lieu, cap, ordre) values (p_id, 'pause', 'Pause / repos', '—', 999, 999)
  on conflict (journee, id) do nothing;
  insert into public.tournantes (journee, id, debut, fin, demi)
  select p_id, id, debut, fin, demi from public.tournantes where journee = p_source;
  return p_id;
end $$;

-- Supprime une journée. Refusé tant qu'elle a des participants (cache-la plutôt du menu).
create or replace function public.apa_admin_supprimer_journee(p_code_admin text, p_journee text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare n int; ni int;
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  select count(*) into n from public.beneficiaires where journee = p_journee;
  select count(*) into ni from public.institutions where journee = p_journee;
  if n > 0 or ni > 0 then
    raise exception 'Cette journée a encore % institution(s) et % participant(s). Supprime-les d''abord, ou cache la journée du menu.', ni, n
      using errcode = 'P0011';
  end if;
  delete from public.journees where id = p_journee;   -- ateliers et horaires partent avec
end $$;

-- Crée (p_id null) ou modifie un atelier. Renvoie son identifiant.
create or replace function public.apa_admin_enregistrer_atelier(p_code_admin text, p_journee text, p_id text, p_nom text, p_lieu text, p_cap int, p_ordre int)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare v_id text := p_id; v_base text; k int := 1; v_max int; v_t int;
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  if length(trim(coalesce(p_nom, ''))) = 0 or length(p_nom) > 120 then
    raise exception 'Indique le nom de l''atelier.' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_lieu, ''))) = 0 or length(p_lieu) > 20 then
    raise exception 'Indique le lieu ou plateau (ex. P1), 20 caractères maximum.' using errcode = '22023';
  end if;
  if p_cap is null or p_cap < 1 or p_cap > 500 then
    raise exception 'Le nombre de places doit être entre 1 et 500.' using errcode = '22023';
  end if;
  if exists (select 1 from public.activites where journee = p_journee and lower(trim(nom)) = lower(trim(p_nom))
              and id is distinct from p_id) or lower(trim(p_nom)) = lower('Pause / repos') then
    raise exception 'Un atelier « % » existe déjà dans cette journée.', trim(p_nom) using errcode = 'P0009';
  end if;
  -- Verrou sur les ateliers de la journée : pas d'inscription pendant le changement de places.
  perform 1 from public.activites where journee = p_journee order by id for update;

  if v_id is null then
    v_base := public._apa_slug(p_nom); v_id := v_base;
    while v_id = 'pause' or exists (select 1 from public.activites where journee = p_journee and id = v_id) loop
      k := k + 1; v_id := v_base || '-' || k;
    end loop;
    insert into public.activites (journee, id, nom, lieu, cap, ordre)
    values (p_journee, v_id, trim(p_nom), trim(p_lieu), p_cap,
            coalesce(p_ordre, (select coalesce(max(ordre) filter (where id <> 'pause'), 0) + 1 from public.activites where journee = p_journee)));
  else
    if v_id = 'pause' then raise exception '« Pause / repos » ne se modifie pas.' using errcode = '22023'; end if;
    if not exists (select 1 from public.activites where journee = p_journee and id = v_id) then
      raise exception 'Cet atelier a été supprimé entre-temps.' using errcode = 'P0002';
    end if;
    select c, tournante into v_max, v_t from (select count(*) c, tournante from public.inscriptions
      where journee = p_journee and activite = v_id group by tournante order by 1 desc, 2 limit 1) z;
    if v_max is not null and v_max > p_cap then
      raise exception 'Il y a déjà % inscrits à cet atelier en T% : impossible de descendre à % places.', v_max, v_t, p_cap using errcode = 'P0012';
    end if;
    update public.activites set nom = trim(p_nom), lieu = trim(p_lieu), cap = p_cap, ordre = coalesce(p_ordre, ordre)
     where journee = p_journee and id = v_id;
  end if;
  return v_id;
end $$;

-- Ce que supprimerait un atelier ou des tournantes (affiché avant de confirmer).
create or replace function public.apa_admin_impact(p_code_admin text, p_journee text, p_activite text, p_tournante_min int)
returns jsonb language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  return public._apa_impact(p_journee, p_activite, p_tournante_min);
end $$;

-- Supprime un atelier. S'il a des inscrits, il faut confirmer : leurs cases redeviennent « à choisir ».
create or replace function public.apa_admin_supprimer_atelier(p_code_admin text, p_journee text, p_id text, p_confirmer boolean)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  if p_id = 'pause' then raise exception '« Pause / repos » ne peut pas être supprimé.' using errcode = '22023'; end if;
  perform 1 from public.activites where journee = p_journee order by id for update;
  select count(*) into n from public.inscriptions where journee = p_journee and activite = p_id;
  if n > 0 and not coalesce(p_confirmer, false) then
    raise exception '% inscription(s) à cet atelier seront effacées : confirme la suppression.', n using errcode = 'P0010';
  end if;
  -- Les fiches touchées changent de version : un brouillon ouvert ailleurs sera prévenu.
  update public.beneficiaires set updated_at = clock_timestamp()
   where id in (select beneficiaire_id from public.inscriptions where journee = p_journee and activite = p_id);
  delete from public.inscriptions where journee = p_journee and activite = p_id;
  delete from public.activites where journee = p_journee and id = p_id;
  return n;
end $$;

-- Remplace tous les horaires d'une journée. p_liste : [{"debut": "09:45", "fin": "10:00", "demi": "Matin"}, …]
-- dans l'ordre. Les inscriptions restent attachées au numéro de tournante (T1, T2…) ;
-- celles des tournantes retirées sont effacées (confirmation demandée).
create or replace function public.apa_admin_enregistrer_horaires(p_code_admin text, p_journee text, p_liste jsonb, p_confirmer boolean)
returns int language plpgsql security definer set search_path = public, extensions as $$
declare
  n int; k int := 0; x jsonb; v_debut time; v_fin time; v_prec time; v_demi text; v_eff int;
begin
  perform public._apa_check_admin(p_code_admin);
  perform public._apa_journee_existe(p_journee);
  if p_liste is null or jsonb_typeof(p_liste) <> 'array' or jsonb_array_length(p_liste) not between 1 and 40 then
    raise exception 'Il faut entre 1 et 40 tournantes.' using errcode = '22023';
  end if;
  n := jsonb_array_length(p_liste);
  for x in select * from jsonb_array_elements(p_liste) loop
    k := k + 1;
    begin v_debut := (x->>'debut')::time; v_fin := (x->>'fin')::time;
    exception when others then raise exception 'T% : heure invalide.', k using errcode = '22023'; end;
    v_demi := trim(coalesce(x->>'demi', ''));
    if v_debut is null or v_fin is null or v_fin <= v_debut then
      raise exception 'T% : l''heure de fin doit être après l''heure de début.', k using errcode = '22023';
    end if;
    if v_prec is not null and v_debut < v_prec then
      raise exception 'T% commence avant la fin de T%.', k, k - 1 using errcode = '22023';
    end if;
    if v_demi = '' or length(v_demi) > 30 then
      raise exception 'T% : indique « Matin », « Après-midi »…', k using errcode = '22023';
    end if;
    v_prec := v_fin;
  end loop;

  perform 1 from public.activites where journee = p_journee order by id for update;
  select count(*) into v_eff from public.inscriptions where journee = p_journee and tournante > n;
  if v_eff > 0 and not coalesce(p_confirmer, false) then
    raise exception '% inscription(s) des tournantes retirées seront effacées : confirme.', v_eff using errcode = 'P0010';
  end if;
  update public.beneficiaires set updated_at = clock_timestamp()
   where id in (select beneficiaire_id from public.inscriptions where journee = p_journee and tournante > n);
  delete from public.inscriptions where journee = p_journee and tournante > n;
  delete from public.tournantes where journee = p_journee and id > n;
  k := 0;
  for x in select * from jsonb_array_elements(p_liste) loop
    k := k + 1;
    insert into public.tournantes (journee, id, debut, fin, demi)
    values (p_journee, k, (x->>'debut')::time, (x->>'fin')::time, trim(x->>'demi'))
    on conflict (journee, id) do update set debut = excluded.debut, fin = excluded.fin, demi = excluded.demi;
  end loop;
  return v_eff;
end $$;

-- Modifie une institution (coordonnées et réservation), même verrouillée.
create or replace function public.apa_admin_modifier_institution(p_code_admin text, p_institution uuid, p_nom text, p_responsable text,
  p_email text, p_telephone text, p_places int, p_educateurs int, p_pmr int)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare v_j text; v_n int; v_max int; v_reste int; v_res int;
begin
  perform public._apa_check_admin(p_code_admin);
  select journee, nb_attendu into v_j, v_res from public.institutions where id = p_institution;
  if not found then raise exception 'Institution inconnue.' using errcode = '22023'; end if;
  if length(trim(coalesce(p_nom, ''))) = 0 or length(p_nom) > 120 then
    raise exception 'Indique le nom de l''institution.' using errcode = '22023';
  end if;
  if exists (select 1 from public.institutions where journee = v_j and id <> p_institution and lower(trim(nom)) = lower(trim(p_nom))) then
    raise exception '« % » est déjà inscrite à cette journée.', trim(p_nom) using errcode = 'P0009';
  end if;
  if trim(coalesce(p_email, '')) <> '' and trim(p_email) !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Adresse e-mail invalide.' using errcode = '22023';
  end if;
  if length(coalesce(p_responsable, '')) > 120 or length(coalesce(p_telephone, '')) > 40 then
    raise exception 'Un des textes est trop long.' using errcode = '22023';
  end if;
  perform public._apa_check_reservation(p_places, p_educateurs, p_pmr);
  select count(*) into v_n from public.beneficiaires where institution_id = p_institution;
  if p_places < v_n then
    raise exception 'L''institution a déjà % participants : retire d''abord des participants.', v_n using errcode = 'P0008';
  end if;
  select places_max into v_max from public.journees where id = v_j for update;
  if v_max is not null then
    v_reste := v_max - public._apa_places_prises(v_j) + greatest(v_res, v_n);
    if p_places > v_reste then
      raise exception 'Il ne reste que % place(s) pour cette institution.', v_reste using errcode = 'P0007';
    end if;
  end if;
  update public.institutions set nom = trim(p_nom), responsable = trim(coalesce(p_responsable, '')), email = lower(trim(coalesce(p_email, ''))),
         telephone = trim(coalesce(p_telephone, '')), nb_attendu = p_places, nb_educateurs = p_educateurs, nb_pmr = p_pmr
   where id = p_institution;
end $$;

-- Change le code organisateur (l'ancien est demandé).
create or replace function public.apa_admin_changer_code(p_ancien text, p_nouveau text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public._apa_check_admin(p_ancien);
  if length(trim(coalesce(p_nouveau, ''))) < 8 then
    raise exception 'Le nouveau code doit faire au moins 8 caractères.' using errcode = '22023';
  end if;
  if p_nouveau = p_ancien then
    raise exception 'Le nouveau code est identique à l''ancien.' using errcode = '22023';
  end if;
  update public.config set admin_hash = crypt(trim(p_nouveau), gen_salt('bf')) where id = 1;
end $$;

-- ---------- Droits d'appel --------------------------------------------
revoke all on function public._apa_check_code(text, text)            from public, anon, authenticated;
revoke all on function public._apa_check_capacite(text)              from public, anon, authenticated;
revoke all on function public._apa_check_institution(text, uuid)     from public, anon, authenticated;
revoke all on function public._apa_check_admin(text)                 from public, anon, authenticated;
revoke all on function public._apa_check_ouvert(uuid)                from public, anon, authenticated;
revoke all on function public.apa_definir_code(text, text)           from public, anon, authenticated;
revoke all on function public.apa_definir_code_admin(text)           from public, anon, authenticated;
revoke all on function public._apa_places_prises(text)               from public, anon, authenticated;
revoke all on function public._apa_check_places(text, uuid)          from public, anon, authenticated;
revoke all on function public._apa_check_reservation(int, int, int)  from public, anon, authenticated;
grant execute on function public.apa_inscrire_institution(text, text, text, text, text, text, int, int, int) to anon, authenticated;
grant execute on function public.apa_modifier_reservation(text, text, uuid, int, int, int)                  to anon, authenticated;
grant execute on function public.apa_admin_institutions(text, text)                                         to anon, authenticated;
grant execute on function public.apa_admin_supprimer_institution(text, uuid)                                to anon, authenticated;
revoke all on function public._apa_check_plan(text, jsonb)           from public, anon, authenticated;
revoke all on function public._apa_id_ok(text)                       from public, anon, authenticated;
revoke all on function public._apa_slug(text)                        from public, anon, authenticated;
revoke all on function public._apa_journee_existe(text)              from public, anon, authenticated;
revoke all on function public._apa_impact(text, text, int)           from public, anon, authenticated;
grant execute on function public.apa_admin_journees(text)                                          to anon, authenticated;
grant execute on function public.apa_admin_journee(text, text)                                     to anon, authenticated;
grant execute on function public.apa_admin_enregistrer_journee(text, text, boolean, jsonb)         to anon, authenticated;
grant execute on function public.apa_admin_definir_code(text, text, text)                          to anon, authenticated;
grant execute on function public.apa_admin_dupliquer_journee(text, text, text, text, date)         to anon, authenticated;
grant execute on function public.apa_admin_supprimer_journee(text, text)                           to anon, authenticated;
grant execute on function public.apa_admin_enregistrer_atelier(text, text, text, text, text, int, int) to anon, authenticated;
grant execute on function public.apa_admin_impact(text, text, text, int)                           to anon, authenticated;
grant execute on function public.apa_admin_supprimer_atelier(text, text, text, boolean)            to anon, authenticated;
grant execute on function public.apa_admin_enregistrer_horaires(text, text, jsonb, boolean)        to anon, authenticated;
grant execute on function public.apa_admin_modifier_institution(text, uuid, text, text, text, text, int, int, int) to anon, authenticated;
grant execute on function public.apa_admin_changer_code(text, text)                                to anon, authenticated;
grant execute on function public.apa_journees()                                             to anon, authenticated;
grant execute on function public.apa_connexion(text, text)                                  to anon, authenticated;
grant execute on function public.apa_etat(text, text)                                       to anon, authenticated;
grant execute on function public.apa_enregistrer(text, text, uuid, text, text, jsonb, uuid) to anon, authenticated;
grant execute on function public.apa_enregistrer_lot(text, text, uuid, jsonb)               to anon, authenticated;
grant execute on function public.apa_supprimer(text, text, uuid)                            to anon, authenticated;
grant execute on function public.apa_verrouiller(text, text, uuid)                          to anon, authenticated;
grant execute on function public.apa_deverrouiller(text, uuid)                              to anon, authenticated;

-- ---------- Codes d'accès ---------------------------------------------
-- ⚠ Ne mets JAMAIS un vrai code dans ce fichier : le dépôt est public.
-- Une journée sans code apparaît dans le menu comme « pas encore ouverte ».
-- Pour ouvrir une journée, lance dans le SQL Editor de Supabase :
--   select public.apa_definir_code('marcinelle-2027',    'code-marcinelle');
--   select public.apa_definir_code('philippeville-2027', 'code-philippeville');
--   select public.apa_definir_code('pqr-2027',           'code-pqr');   -- à ne donner qu'aux institutions de Chimay
