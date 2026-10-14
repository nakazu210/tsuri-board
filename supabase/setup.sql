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

  insert into public.posts (user_id, posted_by, kind, caught_on, spot_name, memo, photo_path, ai_result)
  values ((p->>'user_id')::uuid, auth.uid(), k, (p->>'caught_on')::date,
          nullif(trim(p->>'spot_name'), ''), nullif(trim(p->>'memo'), ''), nullif(p->>'photo_path', ''),
          nullif(p->'ai_result', 'null'::jsonb))
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
-- 初回ログイン時にパスワード変更を求めるための印
alter table public.profiles add column if not exists must_change_password boolean not null default true;

-- 自分でパスワードを変えたら、印を外す
create or replace function public.password_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_password = false where id = auth.uid();
$$;
revoke execute on function public.password_changed() from public, anon;
grant execute on function public.password_changed() to authenticated;

-- ---------- 釣り日記（参加者・徴収費用・ガソリン費用） ----------
create table if not exists public.fishing_logs (
  id uuid primary key default gen_random_uuid(),
  trip_date date not null,
  spot_name text,
  participants uuid[] not null default '{}',                      -- 参加したメンバー
  guest_count int not null default 0 check (guest_count >= 0),     -- メンバー以外の参加人数
  fee_per_person int not null default 0 check (fee_per_person >= 0), -- 1人あたりの徴収額（円）
  gas_cost int not null default 0 check (gas_cost >= 0),           -- ガソリン費用（円）
  memo text,
  created_by uuid not null references public.profiles(id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fishing_logs_date_idx on public.fishing_logs (trip_date desc);

-- アプリ全体の設定（返済の総額など）
create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

grant select, insert, update, delete on public.fishing_logs, public.app_settings to authenticated;
revoke all on public.fishing_logs, public.app_settings from anon;
alter table public.fishing_logs enable row level security;
alter table public.app_settings enable row level security;

-- 日記：全員見られる。書いた人と管理者だけが直したり消したりできる
drop policy if exists "logs_select" on public.fishing_logs;
create policy "logs_select" on public.fishing_logs for select to authenticated using (public.is_member());
drop policy if exists "logs_insert" on public.fishing_logs;
create policy "logs_insert" on public.fishing_logs for insert to authenticated
  with check (created_by = auth.uid() and public.is_member());
drop policy if exists "logs_update" on public.fishing_logs;
create policy "logs_update" on public.fishing_logs for update to authenticated
  using (created_by = auth.uid() or public.is_admin());
drop policy if exists "logs_delete" on public.fishing_logs;
create policy "logs_delete" on public.fishing_logs for delete to authenticated
  using (created_by = auth.uid() or public.is_admin());

-- 設定：全員見られる。変更は管理者だけ
drop policy if exists "settings_select" on public.app_settings;
create policy "settings_select" on public.app_settings for select to authenticated using (public.is_member());
drop policy if exists "settings_admin" on public.app_settings;
create policy "settings_admin" on public.app_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- 徴収額をメンバーとゲストで分ける（メンバー2,000円・ゲスト5,000円） ----------
alter table public.fishing_logs alter column fee_per_person set default 2000;
alter table public.fishing_logs add column if not exists guest_fee int not null default 5000 check (guest_fee >= 0);

-- ---------- チャットのプッシュ通知 ----------
-- 通知の届け先（スマホごと）
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  endpoint text unique not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
grant select, insert, update, delete on public.push_subscriptions to authenticated;
revoke all on public.push_subscriptions from anon;
alter table public.push_subscriptions enable row level security;
drop policy if exists "push_own" on public.push_subscriptions;
create policy "push_own" on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 新しいメッセージが入ったら、通知を送る機能（push-chat）を呼び出す
-- 呼び出し用の合言葉は Vault（暗号化された保管場所）の push_hook_secret に保存（このファイルには書かない）
create extension if not exists pg_net with schema extensions;

create or replace function public.notify_chat_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  secret text;
begin
  if new.kind not in ('text','photo') then
    return new;   -- 釣果のお知らせは通知しない
  end if;
  select decrypted_secret into secret from vault.decrypted_secrets where name = 'push_hook_secret';
  if secret is null then
    return new;
  end if;
  perform net.http_post(
    url := 'https://eiirhhjitxpewvhxuwuc.supabase.co/functions/v1/push-chat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-hook-secret', secret),
    body := jsonb_build_object('message_id', new.id)
  );
  return new;
end;
$$;

drop trigger if exists on_chat_message_push on public.chat_messages;
create trigger on_chat_message_push
  after insert on public.chat_messages
  for each row execute function public.notify_chat_push();
