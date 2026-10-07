-- =========================================================
-- 釣果ボード：データベースの準備
-- Supabase の管理画面 →「SQL Editor」にこのファイルの中身を
-- すべて貼り付けて「Run」を押してください（1回だけでOK）。
-- =========================================================

-- ---------- メンバー ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users on delete cascade,
  login_id text unique not null,
  display_name text not null,
  role text not null default 'member' check (role in ('admin','member')),
  created_at timestamptz not null default now()
);

-- ---------- 港・釣り場（潮汐表示用。今後使用） ----------
create table if not exists public.spots (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  tide_station text,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- 投稿（1回の釣行・写真1枚） ----------
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id),          -- 釣った人
  posted_by uuid not null references public.profiles(id),        -- 投稿した人（代理投稿のとき異なる）
  kind text not null check (kind in ('fish','ika')),             -- 魚 / 白イカ
  caught_on date not null,
  spot_name text,
  memo text,
  photo_path text,
  ai_result jsonb,
  created_at timestamptz not null default now()
);
create index if not exists posts_caught_on_idx on public.posts (caught_on desc);

-- ---------- 投稿の中身（魚種ごとの行） ----------
create table if not exists public.catch_items (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  species text not null,
  size_cm numeric,
  count int not null check (count >= 1),
  sort int not null default 0
);
create index if not exists catch_items_post_idx on public.catch_items (post_id);

-- ---------- チャット ----------
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) default auth.uid(),
  kind text not null default 'text' check (kind in ('text','photo','catch')),
  body text,
  photo_path text,
  post_id uuid references public.posts(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists chat_messages_created_idx on public.chat_messages (created_at desc);

create table if not exists public.chat_reads (
  user_id uuid primary key references public.profiles(id) on delete cascade default auth.uid(),
  last_read_at timestamptz not null default now()
);

-- ---------- 判定用の関数 ----------
create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid());
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

-- ---------- アカウントが作られたら、メンバー情報を自動で作る ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, login_id, display_name)
  values (
    new.id,
    split_part(new.email, '@', 1),
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), split_part(new.email, '@', 1))
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 投稿を保存する（投稿・魚種・チャットのお知らせをまとめて作成） ----------
create or replace function public.create_post(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  pid uuid;
  it jsonb;
  k text := p->>'kind';
  summary text := '';
  line text;
begin
  if not public.is_member() then
    raise exception 'メンバーだけが投稿できます';
  end if;
  if not exists (select 1 from public.profiles where id = (p->>'user_id')::uuid) then
    raise exception '釣った人が見つかりません';
  end if;
  if jsonb_array_length(coalesce(p->'items', '[]'::jsonb)) = 0 then
    raise exception '魚種を入力してください';
  end if;

  insert into public.posts (user_id, posted_by, kind, caught_on, spot_name, memo, photo_path)
  values ((p->>'user_id')::uuid, auth.uid(), k, (p->>'caught_on')::date,
          nullif(trim(p->>'spot_name'), ''), nullif(trim(p->>'memo'), ''), nullif(p->>'photo_path', ''))
  returning id into pid;

  for it in select * from jsonb_array_elements(p->'items') loop
    insert into public.catch_items (post_id, species, size_cm, count, sort)
    values (pid,
            case when k = 'ika' then '白イカ' else trim(it->>'species') end,
            case when k = 'ika' then null else nullif(it->>'size_cm', '')::numeric end,
            (it->>'count')::int,
            coalesce((it->>'sort')::int, 0));

    if k = 'ika' then
      line := '白イカ ' || (it->>'count') || '杯';
    else
      line := trim(it->>'species')
           || coalesce(' ' || nullif(it->>'size_cm', '') || 'cm', '')
           || case when (it->>'count')::int > 1 then ' ' || (it->>'count') || '匹' else '' end;
    end if;
    summary := summary || case when summary = '' then '' else '、' end || line;
  end loop;

  insert into public.chat_messages (user_id, kind, body, post_id)
  values ((p->>'user_id')::uuid, 'catch', summary, pid);

  return pid;
end;
$$;

-- ---------- 権限 ----------
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;
revoke execute on function public.create_post(jsonb) from public, anon;
grant execute on function public.create_post(jsonb), public.is_admin(), public.is_member() to authenticated;

-- ---------- セキュリティ（RLS） ----------
alter table public.profiles      enable row level security;
alter table public.spots         enable row level security;
alter table public.posts         enable row level security;
alter table public.catch_items   enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_reads    enable row level security;

-- メンバー：ログイン済みなら全員見られる
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles_admin_update" on public.profiles;
create policy "profiles_admin_update" on public.profiles for update to authenticated using (public.is_admin());

-- 港：全員見られる、管理者だけ変更できる
drop policy if exists "spots_select" on public.spots;
create policy "spots_select" on public.spots for select to authenticated using (true);
drop policy if exists "spots_admin" on public.spots;
create policy "spots_admin" on public.spots for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- 投稿：全員見られる。追加は create_post 経由のみ。削除は釣った人・投稿した人・管理者
drop policy if exists "posts_select" on public.posts;
create policy "posts_select" on public.posts for select to authenticated using (public.is_member());
drop policy if exists "posts_delete" on public.posts;
create policy "posts_delete" on public.posts for delete to authenticated
  using (auth.uid() in (user_id, posted_by) or public.is_admin());

drop policy if exists "catch_items_select" on public.catch_items;
create policy "catch_items_select" on public.catch_items for select to authenticated using (public.is_member());

-- チャット：全員見られる。送信は自分の名前で文字・写真のみ。削除は本人と管理者
drop policy if exists "chat_select" on public.chat_messages;
create policy "chat_select" on public.chat_messages for select to authenticated using (public.is_member());
drop policy if exists "chat_insert" on public.chat_messages;
create policy "chat_insert" on public.chat_messages for insert to authenticated
  with check (user_id = auth.uid() and kind in ('text','photo') and public.is_member());
drop policy if exists "chat_delete" on public.chat_messages;
create policy "chat_delete" on public.chat_messages for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- 未読管理：自分の分だけ
drop policy if exists "reads_own" on public.chat_reads;
create policy "reads_own" on public.chat_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---------- 写真の保存場所（非公開） ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('photos', 'photos', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

drop policy if exists "photos_select" on storage.objects;
create policy "photos_select" on storage.objects for select to authenticated
  using (bucket_id = 'photos' and public.is_member());
drop policy if exists "photos_insert" on storage.objects;
create policy "photos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'photos' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos_delete" on storage.objects;
create policy "photos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'photos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------- チャットをリアルタイムで届ける ----------
do $$
begin
  alter publication supabase_realtime add table public.chat_messages;
exception when duplicate_object then null;
end $$;
