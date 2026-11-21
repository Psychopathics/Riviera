-- RIVERA Online: in Supabase unter SQL Editor vollständig ausführen.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Mitglied',
  role text not null default 'member' check (role in ('admin','member')),
  created_at timestamptz not null default now()
);

create or replace function public.rivera_new_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.profiles(id,display_name,role)
  values(new.id,coalesce(new.raw_user_meta_data->>'display_name','Mitglied'),'member')
  on conflict(id) do nothing;
  return new;
end; $$;
drop trigger if exists rivera_auth_user_created on auth.users;
create trigger rivera_auth_user_created after insert on auth.users
for each row execute procedure public.rivera_new_profile();

create table if not exists public.members (
 id uuid primary key default gen_random_uuid(), name text not null, rank integer not null default 1 check(rank between 1 and 12), created_at timestamptz not null default now()
);
create table if not exists public.stock_items (
 id uuid primary key default gen_random_uuid(), warehouse text not null check(warehouse in ('leader','general')), name text not null, stock integer not null default 0 check(stock>=0), created_at timestamptz not null default now(), unique(warehouse,name)
);
create table if not exists public.stock_logs (
 id uuid primary key default gen_random_uuid(), warehouse text not null check(warehouse in ('leader','general')), item_name text not null, move_type text not null check(move_type in ('in','out')), quantity integer not null check(quantity>0), stock_after integer not null, note text, user_id uuid references auth.users(id), user_name text not null, created_at timestamptz not null default now()
);
create table if not exists public.attendance (id uuid primary key default gen_random_uuid(), entry text not null, user_id uuid references auth.users(id), created_by_name text not null default '', created_at timestamptz not null default now());
create table if not exists public.routes (id uuid primary key default gen_random_uuid(), entry text not null, user_id uuid references auth.users(id), created_by_name text not null default '', created_at timestamptz not null default now());
create table if not exists public.dues (id uuid primary key default gen_random_uuid(), entry text not null, user_id uuid references auth.users(id), created_by_name text not null default '', created_at timestamptz not null default now());

create or replace function public.rivera_is_admin()
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;

-- Buchung atomar in der Datenbank: parallele Ausbuchungen können keinen negativen Bestand erzeugen.
create or replace function public.rivera_book_stock(p_warehouse text,p_item_name text,p_move_type text,p_quantity integer,p_note text default '')
returns void language plpgsql security definer set search_path=public as $$
declare v_item public.stock_items%rowtype; v_new integer; v_user text;
begin
 if auth.uid() is null then raise exception 'Bitte anmelden.'; end if;
 if p_warehouse not in ('leader','general') or p_move_type not in ('in','out') or p_quantity is null or p_quantity<=0 or p_item_name is null or length(trim(p_item_name))=0 then raise exception 'Ungültige Buchungsdaten.'; end if;
 insert into public.stock_items(warehouse,name,stock) values(p_warehouse,trim(p_item_name),0) on conflict(warehouse,name) do nothing;
 select * into v_item from public.stock_items where warehouse=p_warehouse and name=trim(p_item_name) for update;
 if p_move_type='out' and p_quantity>v_item.stock then raise exception 'Nicht genügend Bestand. Aktuell vorhanden: %',v_item.stock; end if;
 v_new:=case when p_move_type='in' then v_item.stock+p_quantity else v_item.stock-p_quantity end;
 update public.stock_items set stock=v_new where id=v_item.id;
 select coalesce(display_name,'Mitglied') into v_user from public.profiles where id=auth.uid();
 insert into public.stock_logs(warehouse,item_name,move_type,quantity,stock_after,note,user_id,user_name)
 values(p_warehouse,trim(p_item_name),p_move_type,p_quantity,v_new,coalesce(p_note,''),auth.uid(),coalesce(v_user,'Mitglied'));
end; $$;

alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.stock_items enable row level security;
alter table public.stock_logs enable row level security;
alter table public.attendance enable row level security;
alter table public.routes enable row level security;
alter table public.dues enable row level security;

drop policy if exists "profiles read authenticated" on public.profiles;
create policy "profiles read authenticated" on public.profiles for select to authenticated using(true);
drop policy if exists "profiles admin update" on public.profiles;
create policy "profiles admin update" on public.profiles for update to authenticated using(public.rivera_is_admin()) with check(public.rivera_is_admin());

drop policy if exists "members read authenticated" on public.members;
create policy "members read authenticated" on public.members for select to authenticated using(true);
drop policy if exists "members admin insert" on public.members;
create policy "members admin insert" on public.members for insert to authenticated with check(public.rivera_is_admin());
drop policy if exists "members admin delete" on public.members;
create policy "members admin delete" on public.members for delete to authenticated using(public.rivera_is_admin());

-- Bestände und Protokolle sind für angemeldete Nutzer sichtbar. Schreibzugriffe auf Bestände erfolgen ausschließlich über die RPC-Funktion.
drop policy if exists "stock items read" on public.stock_items;
create policy "stock items read" on public.stock_items for select to authenticated using(true);
drop policy if exists "stock logs read" on public.stock_logs;
create policy "stock logs read" on public.stock_logs for select to authenticated using(true);

-- Mitglieder dürfen Einträge hinzufügen; nur Admins dürfen Einträge löschen.
do $$ declare t text; begin foreach t in array array['attendance','routes','dues'] loop
 execute format('drop policy if exists %I on public.%I',t||' read',t);
 execute format('create policy %I on public.%I for select to authenticated using(true)',t||' read',t);
 execute format('drop policy if exists %I on public.%I',t||' insert',t);
 execute format('create policy %I on public.%I for insert to authenticated with check(auth.uid()=user_id)',t||' insert',t);
 execute format('drop policy if exists %I on public.%I',t||' admin delete',t);
 execute format('create policy %I on public.%I for delete to authenticated using(public.rivera_is_admin())',t||' admin delete',t);
end loop; end $$;

-- Trigger setzt Erstellerdaten sicher aus der angemeldeten Sitzung.
create or replace function public.rivera_set_entry_owner() returns trigger language plpgsql security definer set search_path=public as $$
begin new.user_id:=auth.uid(); select coalesce(display_name,'Mitglied') into new.created_by_name from public.profiles where id=auth.uid(); return new; end; $$;
do $$ declare t text; begin foreach t in array array['attendance','routes','dues'] loop
 execute format('drop trigger if exists rivera_owner on public.%I',t);
 execute format('create trigger rivera_owner before insert on public.%I for each row execute function public.rivera_set_entry_owner()',t);
end loop; end $$;

-- Realtime für alle gemeinsam sichtbaren Tabellen einschalten.
do $$ declare t text; begin foreach t in array array['profiles','members','stock_items','stock_logs','attendance','routes','dues'] loop
 begin execute format('alter publication supabase_realtime add table public.%I',t); exception when duplicate_object then null; when undefined_object then null; end;
end loop; end $$;

grant execute on function public.rivera_book_stock(text,text,text,integer,text) to authenticated;
grant execute on function public.rivera_is_admin() to authenticated;

-- WICHTIG: Nach der ersten Registrierung die E-Mail des gewünschten Administrators hier einsetzen:
-- update public.profiles p set role='admin' from auth.users u where p.id=u.id and u.email='DEINE-ADMIN-EMAIL@BEISPIEL.DE';
