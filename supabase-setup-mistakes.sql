-- 錯題本後端設定：在 Supabase → SQL Editor 貼上執行一次即可。
-- 若「沒有錯題」是因為當初只建了 activity、漏了 mistakes，執行這段就會開始記錄。
-- 已經建過舊版的話，這份用 add column if not exists / create or replace，重跑也安全。

-- 1) 錯題資料表（欄位對應前端 index.html：unit_id / question / answer / given / count / explain / tip）
create table if not exists public.mistakes (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  unit_id     text not null,
  question    text not null,
  answer      text,
  given       text,
  count       int  not null default 1,
  explain     text,                 -- 詳解（步驟 HTML，看答案時顯示）
  tip         text,                 -- 提示口訣
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, unit_id, question)   -- 同一題只留一筆，靠 count 累加
);

-- 舊表補欄位（第一次建表可忽略，重跑不會出錯）
alter table public.mistakes add column if not exists explain text;
alter table public.mistakes add column if not exists tip text;

-- 2) 開啟 Row Level Security，讓每個帳號只看得到自己的錯題
alter table public.mistakes enable row level security;

drop policy if exists "mistakes_select_own" on public.mistakes;
drop policy if exists "mistakes_insert_own" on public.mistakes;
drop policy if exists "mistakes_update_own" on public.mistakes;
drop policy if exists "mistakes_delete_own" on public.mistakes;

create policy "mistakes_select_own" on public.mistakes for select using (auth.uid() = user_id);
create policy "mistakes_insert_own" on public.mistakes for insert with check (auth.uid() = user_id);
create policy "mistakes_update_own" on public.mistakes for update using (auth.uid() = user_id);
create policy "mistakes_delete_own" on public.mistakes for delete using (auth.uid() = user_id);

-- 3) log_mistake：答錯時前端呼叫。存在就 count+1 並更新詳解，不存在就新增。
--    先移除可能存在的舊版（4 參數）再建新版（6 參數）。
drop function if exists public.log_mistake(text, text, text, text);
create or replace function public.log_mistake(p_unit text, p_q text, p_ans text, p_given text, p_explain text default '', p_tip text default '')
returns void
language plpgsql
as $$
begin
  insert into public.mistakes (user_id, unit_id, question, answer, given, explain, tip, count)
  values (auth.uid(), p_unit, p_q, p_ans, p_given, p_explain, p_tip, 1)
  on conflict (user_id, unit_id, question)
  do update set count      = mistakes.count + 1,
                given      = excluded.given,
                answer     = excluded.answer,
                explain    = excluded.explain,
                tip        = excluded.tip,
                updated_at = now();
end;
$$;

-- 完成後，去練習頁答錯一題，回錯題本按「看答案」就會看到答案＋詳解步驟。
