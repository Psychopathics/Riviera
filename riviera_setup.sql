-- RIVIERA Supabase schema. Run in Supabase SQL Editor as project owner.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null unique check (username ~ '^[A-Za-z0-9_.-]{3,32}$'),
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 is_superadmin boolean not null default false,
 rank smallint null check (rank between 1 and 12),
 permissions text[] not null default '{}',
 delegable_permissions text[] not null default '{}',
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.inventory_items (
 id uuid primary key default gen_random_uuid(), warehouse text not null check (warehouse in ('leader','general')),
 name text not null, category text not null default '', description text not null default '', stock integer not null default 0 check(stock >= 0), minimum integer not null default 0 check(minimum >= 0),
 created_by uuid references public.profiles(id), created_at timestamptz not null default now(), unique(warehouse,name)
);
create table if not exists public.inventory_logs (
 id bigint generated always as identity primary key, item_id uuid not null references public.inventory_items(id), warehouse text not null check (warehouse in ('leader','general')),
 movement text not null check(movement in ('in','out')), quantity integer not null check(quantity > 0), stock_after integer not null check(stock_after >= 0), note text not null default '', actor uuid not null references public.profiles(id), created_at timestamptz not null default now()
);
create table if not exists public.attendance (
 id uuid primary key default gen_random_uuid(), member_id uuid not null references public.profiles(id), attendance_date date not null,
 status text not null check(status in ('Anwesend','Abwesend','Entschuldigt','Verspätet')), note text not null default '', actor uuid not null references public.profiles(id), created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(member_id,attendance_date)
);
create table if not exists public.permission_audit (
 id bigint generated always as identity primary key, actor uuid not null references public.profiles(id), target uuid not null references public.profiles(id),
 old_permissions text[] not null, new_permissions text[] not null, old_delegable text[] not null, new_delegable text[] not null, created_at timestamptz not null default now()
);
create table if not exists public.app_settings (key text primary key, value jsonb not null, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now());

create or replace function public.current_profile() returns public.profiles language sql stable security definer set search_path=public as $$ select p from public.profiles p where p.id=auth.uid() $$;
create or replace function public.has_permission(p text) returns boolean language sql stable security definer set search_path=public as $$ select exists(select 1 from public.profiles where id=auth.uid() and status='approved' and (is_superadmin or p=any(permissions))) $$;
revoke all on function public.current_profile() from public; grant execute on function public.current_profile() to authenticated;
revoke all on function public.has_permission(text) from public; grant execute on function public.has_permission(text) to authenticated;

alter table public.profiles enable row level security;
alter table public.inventory_items enable row level security;
alter table public.inventory_logs enable row level security;
alter table public.attendance enable row level security;
alter table public.permission_audit enable row level security;
alter table public.app_settings enable row level security;
-- Profiles visible to approved members with member-list permission; users may read own pending profile.
create policy profiles_read on public.profiles for select to authenticated using (id=auth.uid() or public.has_permission('members_view') or public.has_permission('admin_manage'));
create policy inventory_read on public.inventory_items for select to authenticated using (public.has_permission(warehouse||'_view'));
create policy inventory_logs_read on public.inventory_logs for select to authenticated using (public.has_permission(warehouse||'_view'));
create policy attendance_read on public.attendance for select to authenticated using (public.has_permission('attendance_view') or member_id=auth.uid());
create policy permission_audit_read on public.permission_audit for select to authenticated using (public.has_permission('admin_manage'));
create policy settings_read on public.app_settings for select to authenticated using (public.has_permission('admin_manage'));
-- No direct INSERT/UPDATE/DELETE policies: all sensitive mutations go through constrained SECURITY DEFINER RPCs.

create or replace function public.riviera_book_stock(p_item uuid,p_movement text,p_quantity integer,p_note text default '') returns public.inventory_logs
language plpgsql security definer set search_path=public as $$
declare v_item public.inventory_items; v_log public.inventory_logs; v_perm text;
begin
 if auth.uid() is null then raise exception 'not_authenticated'; end if;
 select * into v_item from public.inventory_items where id=p_item for update;
 if not found then raise exception 'item_not_found'; end if;
 v_perm:=v_item.warehouse||'_book';
 if not public.has_permission(v_perm) then raise exception 'forbidden'; end if;
 if p_quantity is null or p_quantity<=0 or p_quantity>1000000 or p_movement not in ('in','out') then raise exception 'invalid_movement'; end if;
 if p_movement='out' and v_item.stock<p_quantity then raise exception 'insufficient_stock'; end if;
 update public.inventory_items set stock=stock+case when p_movement='in' then p_quantity else -p_quantity end where id=p_item returning * into v_item;
 insert into public.inventory_logs(item_id,warehouse,movement,quantity,stock_after,note,actor) values(p_item,v_item.warehouse,p_movement,p_quantity,v_item.stock,left(coalesce(p_note,''),500),auth.uid()) returning * into v_log;
 return v_log;
end $$;
revoke all on function public.riviera_book_stock(uuid,text,integer,text) from public; grant execute on function public.riviera_book_stock(uuid,text,integer,text) to authenticated;

create or replace function public.riviera_set_permissions(p_target uuid,p_permissions text[],p_delegable text[],p_rank smallint default null) returns void
language plpgsql security definer set search_path=public as $$
declare actor public.profiles; target public.profiles; allowed text[]; valid text[] := array['dashboard','members_view','members_manage','registrations_approve','leader_view','leader_book','leader_manage','leader_permissions','general_view','general_book','general_manage','general_permissions','attendance_view','attendance_add','attendance_edit','quotas_view','permissions_grant','admin_manage'];
begin
 select * into actor from public.profiles where id=auth.uid() and status='approved'; if not found then raise exception 'not_authenticated'; end if;
 select * into target from public.profiles where id=p_target for update; if not found then raise exception 'target_not_found'; end if;
 if target.is_superadmin then raise exception 'protected_superadmin'; end if;
 if not (actor.is_superadmin or ('permissions_grant'=any(actor.permissions))) then raise exception 'forbidden'; end if;
 if p_rank is not null and (p_rank<1 or p_rank>12) then raise exception 'invalid_rank'; end if;
 if exists(select 1 from unnest(coalesce(p_permissions,'{}')||coalesce(p_delegable,'{}')) x where not x=any(valid)) then raise exception 'invalid_permission'; end if;
 if not actor.is_superadmin then
   allowed:=actor.delegable_permissions;
   if exists(select 1 from unnest(coalesce(p_permissions,'{}')||coalesce(p_delegable,'{}')) x where not x=any(allowed)) then raise exception 'cannot_delegate_permission';
 end if;
 insert into public.permission_audit(actor,target,old_permissions,new_permissions,old_delegable,new_delegable) values(auth.uid(),p_target,target.permissions,coalesce(p_permissions,'{}'),target.delegable_permissions,coalesce(p_delegable,'{}'));
 update public.profiles set permissions=coalesce(p_permissions,'{}'),delegable_permissions=coalesce(p_delegable,'{}'),rank=p_rank,updated_at=now() where id=p_target;
end $$;
revoke all on function public.riviera_set_permissions(uuid,text[],text[],smallint) from public; grant execute on function public.riviera_set_permissions(uuid,text[],text[],smallint) to authenticated;

create or replace function public.riviera_review_registration(p_target uuid,p_decision text) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.has_permission('registrations_approve') then raise exception 'forbidden'; end if;
 if p_decision not in ('approved','rejected') then raise exception 'invalid_decision'; end if;
 update public.profiles set status=p_decision,updated_at=now() where id=p_target and status='pending' and is_superadmin=false;
 if not found then raise exception 'pending_user_not_found'; end if;
end $$;
revoke all on function public.riviera_review_registration(uuid,text) from public; grant execute on function public.riviera_review_registration(uuid,text) to authenticated;

create or replace function public.riviera_set_attendance(p_member uuid,p_date date,p_status text,p_note text default '') returns public.attendance
language plpgsql security definer set search_path=public as $$ declare r public.attendance; begin
 if not (public.has_permission('attendance_add') or public.has_permission('attendance_edit')) then raise exception 'forbidden'; end if;
 if p_status not in ('Anwesend','Abwesend','Entschuldigt','Verspätet') then raise exception 'invalid_status'; end if;
 insert into public.attendance(member_id,attendance_date,status,note,actor) values(p_member,p_date,p_status,left(coalesce(p_note,''),500),auth.uid())
 on conflict(member_id,attendance_date) do update set status=excluded.status,note=excluded.note,actor=auth.uid(),updated_at=now() returning * into r; return r;
end $$;
revoke all on function public.riviera_set_attendance(uuid,date,text,text) from public; grant execute on function public.riviera_set_attendance(uuid,date,text,text) to authenticated;

create or replace view public.riviera_attendance_quotas with (security_invoker=true) as
select p.id,p.username,
 round(100.0*count(*) filter(where a.status in ('Anwesend','Verspätet'))/nullif(count(*) filter(where a.status in ('Anwesend','Verspätet','Abwesend')),0),2) as attendance_percent
from public.profiles p left join public.attendance a on a.member_id=p.id where p.status='approved' group by p.id,p.username;

-- Realtime: enable publication for data that clients subscribe to.
alter publication supabase_realtime add table public.inventory_items;
alter publication supabase_realtime add table public.inventory_logs;
alter publication supabase_realtime add table public.attendance;
alter publication supabase_realtime add table public.profiles;

-- Create/update catalog entries; direct table writes remain disabled by RLS.
create or replace function public.riviera_save_item(p_warehouse text,p_name text,p_category text default '',p_description text default '',p_minimum integer default 0,p_item uuid default null) returns public.inventory_items
language plpgsql security definer set search_path=public as $$ declare r public.inventory_items; perm text; begin
 if auth.uid() is null then raise exception 'not_authenticated'; end if;
 if p_warehouse not in ('leader','general') or p_name is null or length(trim(p_name)) not between 1 and 120 or coalesce(p_minimum,0)<0 then raise exception 'invalid_item'; end if;
 perm:=p_warehouse||'_manage'; if not public.has_permission(perm) then raise exception 'forbidden'; end if;
 if p_item is null then insert into public.inventory_items(warehouse,name,category,description,minimum,created_by) values(p_warehouse,trim(p_name),left(coalesce(p_category,''),80),left(coalesce(p_description,''),500),p_minimum,auth.uid()) returning * into r;
 else update public.inventory_items set name=trim(p_name),category=left(coalesce(p_category,''),80),description=left(coalesce(p_description,''),500),minimum=p_minimum where id=p_item and warehouse=p_warehouse returning * into r; if not found then raise exception 'item_not_found'; end if; end if; return r;
end $$;
revoke all on function public.riviera_save_item(text,text,text,text,integer,uuid) from public; grant execute on function public.riviera_save_item(text,text,text,text,integer,uuid) to authenticated;
