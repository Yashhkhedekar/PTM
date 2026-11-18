-- Run this once: Supabase dashboard > SQL Editor > New query > paste > Run.
create table if not exists public.app_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.app_state enable row level security;
create policy "own select" on public.app_state for select using (auth.uid() = user_id);
create policy "own insert" on public.app_state for insert with check (auth.uid() = user_id);
create policy "own update" on public.app_state for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- There is deliberately no delete policy: rows are only removed when the user deletes their account.

-- Safety net: a snapshot of the previous data is kept at most once an hour (latest 200 kept).
create table if not exists public.app_state_history (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  saved_at timestamptz not null default now()
);
alter table public.app_state_history enable row level security;
create policy "own history" on public.app_state_history for select using (auth.uid() = user_id);

create or replace function public.keep_history() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.app_state_history where user_id = old.user_id and saved_at > now() - interval '1 hour') then
    insert into public.app_state_history(user_id, data) values (old.user_id, old.data);
    delete from public.app_state_history where user_id = old.user_id
      and id not in (select id from public.app_state_history where user_id = old.user_id order by id desc limit 200);
  end if;
  return new;
end $$;
drop trigger if exists app_state_history_t on public.app_state;
create trigger app_state_history_t before update on public.app_state for each row execute function public.keep_history();

-- Required by the App Store: the user can delete their own account from inside the app.
create or replace function public.delete_my_account() returns void
language sql security definer set search_path = public, auth as $$
  delete from auth.users where id = auth.uid();
$$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
