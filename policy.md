# 異地副本原則（物件儲存、不可變與成本）

適用版本：主 NAS QuTS hero h6.0.2.3591，HBS 3 26.4.4.788，rclone（版本待填），gcloud（版本待填）。價格以 `prices.json` 的查核日為準，發票數字出來後回填 `drill-log.md`。

## 要補的兩個數字

Day 17 的 3-2-1 對照表留下兩個紅燈，異地的 1 與不可變的 1。本日用一個 bucket 同時補上，異地由區域提供，不可變由 bucket 層級的保留政策提供，上傳端不需要支援任何東西。

## 外移什麼

延續 Day 17 的分級。數字來自 `offload-cost.py`（12 個月、1 次完整還原、WAN 500 Mbps 的 85%）。

| 資料集 | 大小 | 類別 | 一年費用（含一次還原） | 決定 | 理由 |
|---|---|---|---:|---|---|
| Public/Music | 5 GB | Standard，30 天後 Nearline | 約 $1.3 到 $1.9 | 上雲 | 唯一副本，小，整份做還原演練 |
| Public/Wordpress | 10.7 GB | 同上 | 約 $2.9 到 $4.3 | 上雲 | 唯一副本 |
| Container | 22.5 GB | Standard，30 天後 Nearline | 約 $7.5 到 $9.9 | 上雲 | 唯一副本。檔案數多（估 6 萬），PUT 請求費高於儲存費，不適合 Coldline 與 Archive |
| HDP_Business | 262 GB | Coldline | 約 $55 | 上雲 | 唯一副本。Coldline 與 Archive 一年費用相當，Coldline 最低保存 90 天，30 天版本輪替不會被 365 天綁住 |
| JustBackup | 258 GB | 不上雲 | 0 | 不上雲 | HDP_Business 的第二套，Day 17 已在次要 NAS 單碟池 |
| AIModels、models、comfyui | 約 3.1 TB | 不上雲 | 0（重下載） | 重下載計畫 | 放 Archive 一年約 $45，取回一次約 $506。重下載以線速估 17 小時，費用 0。見 `redownload-plan.md` |

合計上雲約 300 GB。Linode Object Storage 以固定月費計（$5 含 250 GB 與 1 TB 流出，超量 $0.02/GB），一年約 $72，與 GCS 把 HDP_Business 放 Coldline 的約 $70 相當，差別在 Linode 沒有冷層與取回費，GCS 有台灣區域。價格來源見 `prices.json`，Linode 的數字來自第三方整理，正式採用前要對官方區域價格頁（待查）。

## 不可變怎麼做才算數

| 層 | 做法 | 擋住什麼 | 擋不住什麼 |
|---|---|---|---|
| Day 16 HDP 本機不可變 | 新寫入的 pack 設唯讀，atime 設到期日 | 客體端勒索與誤刪 | 拿到 NAS 管理者權限的人，儲存池損毀 |
| Day 17 次要 NAS 快照 | ZFS 唯讀快照，保留 14 份 | 主 NAS 整台損毀，同步過去的壞檔 | 拿到次要 NAS 管理者權限的人，機房損毀 |
| 本日 GCS 保留政策 | bucket 層級，7 天內物件不能刪除也不能取代，鎖定後政策本身不能縮短或移除 | 拿到 NAS 任何權限的人，機房損毀，上傳憑證外洩 | 拿到 GCP 專案 Owner 的人（未鎖定時），帳單欠費 |
| 本日 S3 Object Lock | bucket 建立時啟用，預設保留 COMPLIANCE 7 天 | 同上，連帳號擁有者都刪不掉 | 帳單欠費，供應商關閉帳號 |

設定上的三個關鍵。

1. GCS 要同時開 Object Versioning。開了之後，同步工具覆寫一個變過的檔案會成功，舊版本轉為 noncurrent 並繼續受保留政策保護。沒開版本，覆寫本身就被 403 retentionPolicyNotMet 拒絕，同步工作會失敗。來源 https://docs.cloud.google.com/storage/docs/bucket-lock
2. 上傳身分只給 create、get、list，不給 delete。IAM 定義在 `iam/gcs-role.yaml`，綁在 bucket 上，不綁在專案上。憑證外洩的最壞情況是對方往 bucket 裡塞東西，看得到資料，但刪不掉。
3. 演練期保留 7 天且不鎖定，正式上線改 30 天並執行 `gcs-bucket.sh lock`。鎖定不可逆，bucket 要等所有物件到期才能刪，專案會被加上 lien。

## 上傳工具

| 工具 | 跑在哪 | 優點 | 缺點 |
|---|---|---|---|
| HBS 3 雲端工作 | 主 NAS | 與 Day 17 的工作在同一個介面，有工作紀錄 | 對保留政策 bucket 的行為待測，刪除多餘檔案在版本化 bucket 上只會留 delete marker |
| rclone | 掛載共享資料夾的 Linux 主機 | 參數透明，`--transfers` 可調，速率可量，`offload-drill.sh` 直接用它 | 要另一台主機，排程自己管 |

兩者都做一次上傳，速率寫進 `drill-log.md`，正式工作用快的那個。

## 排程

| 項目 | 值 | 依據 |
|---|---|---|
| 上傳 | 每日 05:30 | Day 17 的 HBS 3 同步 04:00，次要 NAS 快照 05:00，雲端副本在兩者之後 |
| 來源 | 主 NAS 的共享資料夾，開「備份前先建快照」 | 與 Day 17 相同，上雲的是一致版本 |
| 版本 | Object Versioning，noncurrent 30 天後由生命週期刪除，保留政策會把刪除延到 7 天期滿 | `iam/gcs-lifecycle.json` |
| 分層 | HDP_Business 與 JustBackup 前綴立即 Coldline，Music、Wordpress、Container 30 天後 Nearline | 同上 |
| 完整性 | 每月一次 `offload-drill.sh restore` 抽還原一個資料集並過 manifest | 演練 2 |

## 隱藏成本清單

- PUT 請求費。Container 6 萬個檔案在 Archive 類別的首次 PUT 約 $3，比它一年的儲存費高。檔案多的資料集留在 Standard 或 Nearline。
- 最低保存天數。Nearline 30 天、Coldline 90 天、Archive 365 天，提早刪除照收。版本輪替快的資料放 Archive 等於每一個版本都付一年。
- 取回費加流出費。GCS Archive 取回 $0.05/GB，流出 $0.12/GB，3.1 TB 拿回來一次約 $506。
- 軟刪除（soft delete）。GCS 預設保留已刪除物件 7 天並計費，與保留政策重疊，`gcs-bucket.sh create` 設為 0（計費影響待測）。
- 第一次上傳的時間。300 GB 在 500 Mbps 線路約 1.7 小時，3.1 TB 約 17 小時，實際受上游工具與單檔大小影響，待測。

## 實測到的邊界（待演練後填）

- rclone 與 HBS 3 的實際上傳速率，各自的 `--transfers` 或執行緒數
- HBS 3 對保留政策 bucket 的行為，覆寫與刪除分別發生什麼
- `lock-test` 的拒絕訊息原文
- Coldline 物件的首位元組延遲
- 第一個月的實際帳單，與 `offload-cost.py` 的差距
