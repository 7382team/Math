# 題庫（學習聯絡簿）↔ MMO 遊戲　整合介面文件

> 給「MMO session」看的。兩邊在**同一個資料夾、同一個 Supabase 專案、同一組登入帳號**下開發。
> 本文由「題庫側」session 撰寫，說明題庫側對外提供的介面、資料，以及需要兩邊一起拍板的重疊決策。
> **題庫側的承諾：下列 postMessage 格式、欄位、資料表結構不會在沒先講的情況下亂改。** MMO 可安心依賴。

---

## 0. 職責劃分（先講清楚誰管什麼）

| 區塊 | 擁有者 | 內容 |
|---|---|---|
| **題庫單元** `*.html`（48 個，7 科） | 題庫側 | 出題、判分、詳解、間隔複習資料、遊戲指令介面 |
| **`units.json` / 單元 meta** | 題庫側 | 內容清單（自我描述，見 §1）。**MMO 唯讀** |
| **`index.html`**（聯絡簿主程式） | 題庫側 | 每日任務、錯題本、家長 PIN、登入/忘記密碼 |
| **`game.html` / `parent.html` / `GDD.md`** | MMO 側 | 遊戲本體、家長入口、遊戲設計 |
| **Supabase：`settings` / `activity` / `mistakes`** | 題庫側（寫入） | 設定、每日做題紀錄、錯題本。MMO 可**唯讀**取用 |
| **Supabase：`game_state`** | MMO 側 | 英雄、樓層、素材等遊戲存檔 |

原則：**內容清單與作答紀錄由題庫側當唯一真相來源，MMO 讀取、不要反寫。** 遊戲進度歸 `game_state`。

---

## 1. 內容清單：單元 meta（自我描述）

每個單元 HTML 的 `<head>` 內都有一段純資料（不執行）：

```html
<script type="application/json" id="unit-meta">
{ "id":"linear-eq", "title":"一元一次方程式", "subject":"數學",
  "grade":"國一", "term":"上", "chapter":8, "tag":"方程式", "ready":true }
</script>
```

- MMO 要列出/篩選單元時，**掃這段 meta**（或讀題庫側自動生成的 `units.json` 的 `units` 陣列），不要自己另維護一份清單。
- `units.json` 由題庫側用 `tools/gen_units.py` 從所有 meta 自動生成；另有兩塊**不在 meta 裡**、需保留：`subjects`（各科 icon/色）與 `courses`（各出版社單元排序）。

---

## 2. 單元 iframe 訊息協定（戰鬥/技能掛鉤）★核心

把任何單元用 `<iframe src="xxx.html?level=basic">` 嵌進遊戲畫面即可。雙向 `postMessage`：

### 子 →父（單元回報）
```js
// 載入完成，回報支援的技能（MMO 據此決定顯示哪些技能鈕）
{ type:'unit-ready', supports:['hint'] }            // 數學題
{ type:'unit-ready', supports:['hint','fifty'] }    // 選擇題

// 每次作答
{ type:'unit-progress', unitDone:1, unitCorrect:0|1 }              // 做了 1 題、對或錯
{ type:'unit-mistake', q, ans, given, choices?, steps?, tip? }     // 答錯時（含正解、詳解、選項）
```

### 父 →子（下技能）
```js
iframe.contentWindow.postMessage({ type:'unit-command', cmd:'hint'  }, '*'); // 提示（不洩答案）
iframe.contentWindow.postMessage({ type:'unit-command', cmd:'fifty' }, '*'); // 選擇題：刪去一個錯選項
```

MMO 端最小接收範例：
```js
const iframe = document.querySelector('#battle-unit');
window.addEventListener('message', e => {
  const d = e.data; if (!d) return;
  if (d.type === 'unit-ready')    showSkillButtons(d.supports);        // 依 supports 顯示技能鈕
  if (d.type === 'unit-progress') { if (d.unitCorrect) dealDamage(); else takeDamage(); }
  if (d.type === 'unit-mistake')  logMistakeToSupabase(d);            // ← 見 §4 重疊點 a
});
// 玩家按技能鈕時：
iframe.contentWindow.postMessage({ type:'unit-command', cmd:'hint' }, '*');
```

**技能行為**：`hint` 在題目下方顯示口訣/知識點（不給答案）；`fifty` 選擇題反灰並停用一個**非正解**選項（正解永遠不被消掉）。單獨開單元（無父視窗）時這些都不觸發、照舊。

---

## 3. Supabase 資料表（共用專案、共用登入）

| 表 | 用途 | 誰寫 | 備註 |
|---|---|---|---|
| `settings` | 聯絡簿設定（選單元、每日題數、各科版本、家長 PIN） | 題庫側 | 一人一列，RLS 只看自己 |
| `activity` | 每日每單元做題數/答對數（`day, unit_id, done, correct`） | 題庫側（`log_activity` RPC） | 月曆、連續達標用 |
| `mistakes` | 錯題本＋間隔複習（`box, due, choices, explain, tip, count`） | 題庫側（`log_mistake` RPC） | RLS 只看自己 |
| `game_state` | 遊戲存檔（`data` jsonb：英雄/樓層/素材） | MMO 側 | RLS 只看自己 |

- 全部在**同一個 Supabase 專案**、用**同一組帳號登入**。所有表都已開 RLS（每個帳號只看自己的）。
- MMO 若要「用學習成果換遊戲獎勵」，**讀** `activity` / `mistakes` 即可（別寫）。

---

## 4. 需要兩邊一起拍板的重疊點（含我的建議）

**a. 戰鬥中作答，誰把它寫進 `activity` / `mistakes`？**
目前單元本身**不直接寫 Supabase**——是父視窗（`index.html`）收到 `unit-progress`/`unit-mistake` 後才呼叫 `log_activity`/`log_mistake`。所以單元跑在 MMO 裡時，**MMO 這個父視窗也要負責寫入**，否則戰鬥答題不會進錯題本/月曆。
→ **建議：抽一支共用的 `unit-bridge.js`**（收 postMessage → 呼叫 `log_activity`/`log_mistake`），`index.html` 和 `game.html` 都 include，兩邊行為一致、只維護一份。我可以幫忙定這支的介面。

**b. 共用登入（重要陷阱）。**
Supabase 的登入 session 存在 **localStorage、以 origin 為界**。若聯絡簿與遊戲部署在**不同網址**（不同網域或不同路徑的不同 origin），使用者會**要登入兩次**、且 `game_state` 與 `settings` 綁在不同 session。
→ **建議：兩個 app 部署在同一個 origin**（例如同一個 GitHub Pages repo 下 `/index.html` 與 `/game.html`），session 就自然共用、一次登入到底。若非得跨 origin，再談 session 傳遞方案。

**c. 間隔複習 ↔ 遊戲關卡。**
`mistakes` 有 `due`（下次該複習日）與 `box`（Leitner 盒子）。「今天該複習的題」＝ `select * from mistakes where due <= today`。
→ **建議：MMO 把「今日要複習的錯題」當成一種每日副本/挑戰**（答對就照題庫側規則把 `due` 往後拉、`box+1`）。這樣遊戲的每日循環＝有效的間隔複習，不用另做記憶系統。若 MMO 要自己更新 `box/due`，規則要跟題庫側一致（答對 1→2→4→8 天、答錯歸零），最好也走共用 bridge。

**d. 家長概念別做兩套。**
題庫側已有「家長 PIN 鎖設定」。MMO 有 `parent.html`。
→ **建議：統一成一個家長入口/一組驗證**（例如家長 PIN 或帳號密碼二選一），避免孩子端出現兩套權限、兩處可繞過。可討論由誰當主。

**e. 技能顯示要先問單元。**
不是每種單元都支援每種技能（數學只有 `hint`、選擇題有 `hint`+`fifty`）。
→ MMO 顯示技能鈕前，**一定要先收 `unit-ready.supports`** 再決定顯示哪些，別寫死。

---

## 5. 題庫側可以配合做的事（你們開口就好）

- 幫 `game.html` 寫 **iframe 接收端 + `unit-bridge.js`** 的範例。
- 單元加**更多技能**：如 `reroll`（重骰一題）、`freeze`（凍結計時）、`show-steps`（看完整詳解，代價換遊戲資源）。照現有 `unit-command` 格式擴充即可。
- 依 `game_state` 或戰鬥需求，調整單元回報的欄位（會先跟你們對格式再改）。
- 把新科目/新單元都用同一套 meta + postMessage 介面產出，MMO 不用為新內容改程式。

---

## 6. 建議的協調清單（打勾用）

- [ ] 部署 origin：聯絡簿與遊戲**同 origin**？（決定要不要處理雙重登入）
- [ ] 作答寫入：抽共用 `unit-bridge.js`？由誰寫、放哪？
- [ ] 間隔複習：MMO today 副本讀 `mistakes.due`？`box/due` 更新走 bridge？
- [ ] 家長入口：統一成一套？主控在題庫側還是 MMO？
- [ ] 技能清單：MMO 技能鈕對應哪些 `unit-command`？要不要我加新技能？
- [ ] `units.json` 生成：MMO 端唯讀，`subjects`/`courses` 由誰維護？

---

## 7. 【題庫側 2026-07-08】年級·學期分類（網頁端已上線，建議遊戲端對齊）

網頁端單元頁上線了「**年級·學期**」切換：頂端一排膠囊（國一上／國一下…），選哪個就只顯示那學期的科目與單元，每個單元掛學期標籤；學期選項是**從內容長出來的**，國二/國三內容一進來就自動多一顆，不用改程式。

**你們不用等我加任何欄位——資料早就在 meta 裡了。** 每個單元的 `unit-meta`（§1）與 `units.json` 每一筆都有：
- `grade`：`"國一"` / `"國二"` / `"國三"`（已統一。原本 `units.json` 有「國一上／國中」等雜寫，現在都是純年級）
- `term`：`"上"` / `"下"`
- **學期鍵 = `grade + term`**，例如 `"國一上"`。

**建議遊戲端也照這個分**（世界地圖／副本選單最上層用「年級·學期」，label 用一樣的「國一上／國一下」保持兩邊一致）：
```js
const key = u => u.grade + u.term;                       // "國一上"
const val = k => ({'國一':1,'國二':2,'國三':3}[k.slice(0,2)]||9)*10 + (k.slice(2)==='下'?2:1);
const terms = [...new Set(units.map(key))].sort((a,b)=>val(a)-val(b));   // ["國一上","國一下",...]
const inTerm = units.filter(u => key(u) === selected);   // 選了某學期 → 只顯示該學期單元
```

**要點**：
- **哪個學期沒單元就不會出現**（例：目前「國一下」數學/公民/國文還沒做，所以國一下只會有生物/歷史/地理/英文）。內容補上就自動長出來。
- **全年科（生物、國文）不用特例**：每個單元本身已有明確 `term`（生物 上5／下4 等），照 `term` 歸位即可。
- **「目前學期」怎麼記**：網頁端存 localStorage（純檢視偏好、非資料真相）。建議遊戲端存自己的 `game_state` 即可，**兩邊各記各的、不用共用**——孩子在哪個學期玩是各端的 UI 狀態。
- **記得重讀 `units.json`**：這次更新了它（grade 統一 + 新增 `term` 欄位 + 新單元共 48 個），MMO 若有快取要更新。
