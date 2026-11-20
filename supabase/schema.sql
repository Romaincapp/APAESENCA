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

-- ---------- Données de référence -------------------------------------

insert into public.journees (id, nom, date_jour, lieu, description, acces, pause_midi, ordre) values
  ('marcinelle-2027',    'Journée APA de Marcinelle',    '2027-03-30', 'Marcinelle',    '', '',
     'Dîner pour tous à 12h05 · reprise à 12h50', 1),
  ('philippeville-2027', 'Journée APA de Philippeville', '2027-04-22', 'Philippeville', '', '',
     'Dîner pour tous à 12h05 · reprise à 12h50', 2),
  ('pqr-2027',           'Poire qui Roule (PQR)',        '2027-05-27', '',              '',
     'Réservé aux institutions de la région de Chimay',
     'Dîner pour tous à 12h05 · reprise à 12h50', 3)
on conflict (id) do update
  set nom = excluded.nom, date_jour = excluded.date_jour, lieu = excluded.lieu,
      description = excluded.description, acces = excluded.acces,
      pause_midi = excluded.pause_midi, ordre = excluded.ordre;
-- (code_hash n'est jamais touché ici : il se définit avec apa_definir_code)

-- ⚠ PROVISOIRE : les activités et les horaires ci-dessous sont ceux de la
-- journée du 17 novembre, recopiés pour chaque journée en attendant les
-- vraies listes. Remplace-les journée par journée quand tu les as.
with j(journee) as (values ('marcinelle-2027'), ('philippeville-2027'), ('pqr-2027')),
a(id, nom, lieu, cap, ordre) as (values
  ('cheveux',    'Soin des cheveux',         'P1',  3,  1),
  ('ongles',     'Soin des ongles',          'P1',  3,  2),
  ('bocaux',     'Customisation de bocaux',  'P1',  6,  3),
  ('mandalas',   'Mandalas',                 'P1', 10,  4),
  ('massage',    'Massage',                  'P1',  4,  5),
  ('parachute',  'Parachute',                'P1', 10,  6),
  ('cirque',     'Cirque assiettes',         'P1',  5,  7),
  ('antistress', 'Balle anti-stress',        'P1',  8,  8),
  ('zumba',      'Zumba',                    'P2', 15,  9),
  ('massacre',   'Jeu de massacre',          'P2',  6, 10),
  ('kinball',    'Kinball',                  'P2', 16, 11),
  ('boccia',     'Boccia',                   'P2',  6, 12),
  ('basket',     'Initiation basket',        'P3', 10, 13),
  ('bowling',    'Bowling',                  'P3',  6, 14),
  ('psychomot',  'Parcours psychomotricité', 'P3',  6, 15),
  ('football',   'Initiation football',      'P3', 10, 16),
  ('flechettes', 'Fléchettes ventouses',     'P3',  5, 17),
  -- « Pause » : marque volontairement une tournante sans activité
  -- (différent d'une case oubliée). Pas de limite de places. À garder.
  ('pause',      'Pause / repos',            '—', 999, 99))
insert into public.activites (journee, id, nom, lieu, cap, ordre)
select j.journee, a.id, a.nom, a.lieu, a.cap, a.ordre from j cross join a
on conflict (journee, id) do update
  set nom = excluded.nom, lieu = excluded.lieu, cap = excluded.cap, ordre = excluded.ordre;

with j(journee) as (values ('marcinelle-2027'), ('philippeville-2027'), ('pqr-2027')),
t(id, debut, fin, demi) as (values
  ( 1, '09:45'::time, '10:00'::time, 'Matin'),
  ( 2, '10:05', '10:20', 'Matin'),
  ( 3, '10:25', '10:40', 'Matin'),
  ( 4, '10:45', '11:00', 'Matin'),
  ( 5, '11:05', '11:20', 'Matin'),
  ( 6, '11:25', '11:40', 'Matin'),
  ( 7, '11:45', '12:00', 'Matin'),
  ( 8, '12:50', '13:05', 'Après-midi'),
  ( 9, '13:10', '13:25', 'Après-midi'),
  (10, '13:30', '13:45', 'Après-midi'),
  (11, '13:50', '14:05', 'Après-midi'),
  (12, '14:10', '14:25', 'Après-midi'),
  (13, '14:30', '14:45', 'Après-midi'),
  (14, '14:50', '15:05', 'Après-midi'),
  (15, '15:10', '15:25', 'Après-midi'))
insert into public.tournantes (journee, id, debut, fin, demi)
select j.journee, t.id, t.debut, t.fin, t.demi from j cross join t
on conflict (journee, id) do update
  set debut = excluded.debut, fin = excluded.fin, demi = excluded.demi;

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
       set nom = trim(p_nom), groupe = coalesce(trim(p_groupe), ''), institution_id = p_institution, updated_at = now()
     where id = v_id and journee = p_journee;
    if not found then
      raise exception 'Cette fiche a été supprimée entre-temps.' using errcode = 'P0002';
    end if;
    delete from public.inscriptions where beneficiaire_id = v_id;
  end if;

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
         set nom = v_nom, equipe = v_eq, institution_id = p_institution, updated_at = now()
       where id = v_id;
      delete from public.inscriptions where beneficiaire_id = v_id;
    end if;

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
