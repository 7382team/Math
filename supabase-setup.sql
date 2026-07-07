-- ============================================================
-- 學習聯絡簿 · Supabase 一次性設定
-- 在 Supabase → SQL Editor 全選貼上、按 Run。可重複執行、對現有資料安全。
--
-- 這份會做兩件事：
--   1. 錯題本：補上 explain/tip 欄位，把 log_mistake 升級成「含詳解」版本
--   2. 隱私：把 settings 與 mistakes 的 RLS 打開，每個帳號只看得到自己的資料
--      （目前這兩張表沒登入也讀得到，這份會鎖起來）
-- 註：activity（做題數/月曆）沒有動，維持原狀。
-- ============================================================


-- ---------- 1. 錯題表 mistakes ----------

-- 資料表若不存在才建立（已存在則略過，不動你現有欄位）
create table if not exists public.mistakes (
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  unit_id     text not null,
  question    text not null,
  answer      text,
  given       text,
  count       int  not null default 1,
  explain     text,
  tip         text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- 補上詳解 / 提示 / 選項 / 間隔複習欄位（舊表沒有的話）
alter table public.mistakes add column if not exists explain text;
alter table public.mistakes add column if not exists tip     text;
alter table public.mistakes add column if not exists choices jsonb;             -- 選擇題的選項（讓錯題本用「選」的訂正）
alter table public.mistakes add column if not exists box     int  not null default 0;             -- 間隔複習的 Leitner 盒子
alter table public.mistakes add column if not exists due     date not null default current_date;  -- 下次該複習的日期

-- 確保新資料列會自動帶入登入者的 user_id
alter table public.mistakes alter column user_id set default auth.uid();

-- log_mistake 用 (user_id, unit_id, question) 做「同一題只留一筆、count 累加」
-- 目前表是空的，建這個唯一索引安全
create unique index if not exists mistakes_uidx
  on public.mistakes (user_id, unit_id, question);

-- 打開 RLS：每個帳號只能存取自己的錯題
alter table public.mistakes enable row level security;
drop policy if exists "mistakes_select_own" on public.mistakes;
drop policy if exists "mistakes_insert_own" on public.mistakes;
drop policy if exists "mistakes_update_own" on public.mistakes;
drop policy if exists "mistakes_delete_own" on public.mistakes;
create policy "mistakes_select_own" on public.mistakes for select using (auth.uid() = user_id);
create policy "mistakes_insert_own" on public.mistakes for insert with check (auth.uid() = user_id);
create policy "mistakes_update_own" on public.mistakes for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "mistakes_delete_own" on public.mistakes for delete using (auth.uid() = user_id);

-- 升級 log_mistake：加入詳解(p_explain)、提示(p_tip)、選項(p_choices)。先移除舊版本。
drop function if exists public.log_mistake(text, text, text, text);
drop function if exists public.log_mistake(text, text, text, text, text, text);
create or replace function public.log_mistake(
  p_unit text, p_q text, p_ans text, p_given text,
  p_explain text default '', p_tip text default '', p_choices jsonb default null
) returns void
language plpgsql
security invoker            -- 以呼叫者身分執行，讓上面的 RLS 生效
as $$
begin
  insert into public.mistakes (user_id, unit_id, question, answer, given, explain, tip, choices, box, due, count)
  values (auth.uid(), p_unit, p_q, p_ans, p_given, p_explain, p_tip, p_choices, 0, current_date, 1)
  on conflict (user_id, unit_id, question)
  do update set count      = mistakes.count + 1,
                given      = excluded.given,
                answer     = excluded.answer,
                explain    = excluded.explain,
                tip        = excluded.tip,
                choices    = excluded.choices,
                box        = 0,              -- 又答錯了 → 重置間隔，明天起重來
                due        = current_date,
                updated_at = now();
end;
$$;


-- ---------- 2. 設定表 settings ----------

-- 補齊前端會寫入、但你的表目前缺少的欄位（course_id / reward_msg / rest_days）。
-- 只要缺任一欄，整筆存檔都會被拒 → 勾選的單元存不進去、重整就消失。這是主因。
alter table public.settings add column if not exists display_name   text;
alter table public.settings add column if not exists course_id      text;
alter table public.settings add column if not exists reward_msg     text;
alter table public.settings add column if not exists selected_units    jsonb default '[]'::jsonb;
alter table public.settings add column if not exists daily_goals       jsonb default '{}'::jsonb;
alter table public.settings add column if not exists rest_days         jsonb default '[]'::jsonb;
alter table public.settings add column if not exists course_by_subject jsonb default '{}'::jsonb;  -- 各科各自選的版本
alter table public.settings add column if not exists parent_pin text;                             -- 家長 PIN（雜湊後存）

-- 確保新資料列會自動帶入登入者的 user_id
alter table public.settings alter column user_id set default auth.uid();

-- 確保 user_id 唯一（前端存檔用 onConflict:user_id，需要這個；目前每人一列，建立安全）
create unique index if not exists settings_user_uidx on public.settings (user_id);

-- 打開 RLS：每個帳號只能存取自己的設定（含勾選的單元、每日題數等）
alter table public.settings enable row level security;
drop policy if exists "settings_select_own" on public.settings;
drop policy if exists "settings_insert_own" on public.settings;
drop policy if exists "settings_update_own" on public.settings;
drop policy if exists "settings_delete_own" on public.settings;
create policy "settings_select_own" on public.settings for select using (auth.uid() = user_id);
create policy "settings_insert_own" on public.settings for insert with check (auth.uid() = user_id);
create policy "settings_update_own" on public.settings for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "settings_delete_own" on public.settings for delete using (auth.uid() = user_id);

-- ---------- 3. 遊戲存檔 game_state（給 game.html 用；聯絡簿完全不受影響）----------
-- 一人一列，整包遊戲進度（英雄、已攻略樓層、素材）存在 data 這個 jsonb。
-- 以後遊戲長出裝備/建設，只要往 data 塞更多欄位，不用改表結構。
create table if not exists public.game_state (
  user_id    uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.game_state alter column user_id set default auth.uid();

-- 打開 RLS：每個帳號只能存取自己的存檔（別人看不到、也刪不掉）
alter table public.game_state enable row level security;
drop policy if exists "game_state_select_own" on public.game_state;
drop policy if exists "game_state_insert_own" on public.game_state;
drop policy if exists "game_state_update_own" on public.game_state;
create policy "game_state_select_own" on public.game_state for select using (auth.uid() = user_id);
create policy "game_state_insert_own" on public.game_state for insert with check (auth.uid() = user_id);
create policy "game_state_update_own" on public.game_state for update using (auth.uid() = user_id) with check (auth.uid() = user_id);


-- 完成。跑完後：
--   ‧ 錯題本會記錄並顯示詳解（看答案時）
--   ‧ 別人（含沒登入）再也讀不到你的 settings / mistakes / game_state
--   ‧ 遊戲(game.html)登入後，英雄/樓層/素材會存雲端，跨裝置同步、不會被清掉
--   ‧ 記得在 App 重新勾選一次要練的單元（雲端那份先前被清空了），之後就會跨裝置同步
