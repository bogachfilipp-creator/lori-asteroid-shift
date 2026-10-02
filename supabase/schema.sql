-- Lori's Logbook: Asteroid Shift — leaderboard schema
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.

-- Scores: anyone can read, nobody can write directly.
create table if not exists public.scores (
  id          bigint generated always as identity primary key,
  nickname    text        not null,
  score       integer     not null,
  ship        text        not null,
  created_at  timestamptz not null default now(),
  constraint scores_nickname_ok check (
    char_length(nickname) between 3 and 16
    and nickname ~ '^[A-Za-zА-Яа-яЁёІіЇїЄєҐґ0-9 _-]+$'
    and nickname = btrim(nickname)
  ),
  constraint scores_score_ok check (score between 0 and 5000000),
  constraint scores_ship_ok  check (ship in ('scout', 'paw', 'shade', 'crescent'))
);
create index if not exists scores_nick_best on public.scores (lower(nickname), score desc);
create index if not exists scores_best on public.scores (score desc);

alter table public.scores enable row level security;
revoke all on public.scores from anon, authenticated;
grant select on public.scores to anon, authenticated;

drop policy if exists "scores are public" on public.scores;
create policy "scores are public" on public.scores
  for select to anon, authenticated using (true);
-- No insert / update / delete policies: direct writes are refused for everyone.

-- Per-device rate limit. Hidden table: RLS on, no policies, no grants.
create table if not exists public.submit_log (
  device_id uuid        primary key,
  last_at   timestamptz not null
);
alter table public.submit_log enable row level security;
revoke all on public.submit_log from anon, authenticated;

-- The only way to add a score.
create or replace function public.submit_score(
  p_nickname text, p_score integer, p_ship text, p_device uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  ok boolean;
begin
  if p_device is null then
    raise exception 'device_required';
  end if;

  -- atomic: only passes if this device has not sent anything for 30 seconds
  insert into submit_log as s (device_id, last_at) values (p_device, now())
  on conflict (device_id) do update set last_at = now()
    where s.last_at < now() - interval '30 seconds'
  returning true into ok;
  if ok is null then
    raise exception 'too_fast';
  end if;

  -- table constraints validate nickname, score and ship
  insert into scores (nickname, score, ship)
  values (btrim(p_nickname), p_score, p_ship);
end;
$$;

-- Top N, one best row per nickname (case-insensitive).
create or replace function public.top_scores(p_limit integer default 10)
returns table (nickname text, score integer, ship text, created_at timestamptz)
language sql
stable
set search_path = public
as $$
  select t.nickname, t.score, t.ship, t.created_at
  from (
    select distinct on (lower(s.nickname)) s.nickname, s.score, s.ship, s.created_at
    from scores s
    order by lower(s.nickname), s.score desc, s.created_at asc
  ) t
  order by t.score desc, t.created_at asc
  limit least(greatest(coalesce(p_limit, 10), 1), 50);
$$;

revoke all on function public.submit_score(text, integer, text, uuid) from public;
revoke all on function public.top_scores(integer) from public;
grant execute on function public.submit_score(text, integer, text, uuid) to anon, authenticated;
grant execute on function public.top_scores(integer) to anon, authenticated;
