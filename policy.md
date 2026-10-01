# 異地副本原則（物件儲存、不可變與成本）

適用版本：主 NAS QuTS hero h6.0.2.3591，HBS 3 26.4.4.788，rclone v1.75.1，Google Cloud SDK 587.0.0，aws-cli 1.46.1。價格以 `prices.json` 的查核日為準，第一個月的帳單出來後回填本文最後一節。

## 要補的兩個數字

Day 17 的 3-2-1 對照表留下兩個紅燈，異地的 1 與不可變的 1。本日用一個 bucket 同時補上，異地由區域提供，不可變由 bucket 層級的保留政策提供，上傳端不需要支援任何東西。

## 外移什麼

延續 Day 17 的分級。數字來自 `offload-cost.py`（12 個月、1 次完整還原、WAN 500 Mbps 的 85%），大小是上傳後的實測值，單位 GiB。

| 資料集 | 大小 | 類別 | 一年費用（含一次還原） | 決定 | 理由 |
|---|---|---|---:|---|---|
| Public/Music | 4.7 GiB，128 檔 | Standard，30 天後 Nearline | 約 $0.7 到 $1.3 | 上雲 | 唯一副本，小，整份做還原演練。還原一次的流出落在每月 100 GiB 免費額度內 |
| Public/Wordpress | 17.6 GiB，31 檔 | 同上 | 約 $2.5 到 $4.7 | 上雲 | 唯一副本 |
| Container | 10.5 GiB，45,042 檔 | Standard，30 天後 Nearline | 約 $3.1 到 $4.3 | 上雲 | 唯一副本。檔案多，Archive 的首次 PUT 就要 $2.25，全年 $9.32，是 Nearline 的三倍 |
| HDP_Business | 901 GiB 上傳（ZFS 用量 262 GiB） | Coldline | 約 $176 | 上雲 | 唯一副本。VM 磁碟映像是稀疏檔，rclone 把零照傳，費用是 262 GiB 時（約 $48）的 3.7 倍。一次還原時 Archive 便宜約 $9，兩次還原就翻轉；Coldline 最低保存 90 天 |
| JustBackup | 258 GB | 不上雲 | 0 | 不上雲 | HDP_Business 的第二套，Day 17 已在次要 NAS 單碟池 |
| AIModels、models、comfyui | 約 2.9 TiB | 不上雲 | 0（重下載） | 重下載計畫 | 放 Archive 一年約 $53，取回一次約 $466。見 `redownload-plan.md` |

合計上雲約 934 GiB（1,003 GB），GCS 一年約 $182 到 $186。Linode Object Storage 以固定月費計（$5 含 250 GB，超量 $0.02/GB，每月 1 TB 流出免費），一年約 $241。若 HDP_Business 只傳實際用量，兩者分別約 $56 與 $76。Linode 沒有冷層也沒有取回費，還原一次幾乎不用錢；GCS 有台灣區域，上傳速率是 Linode 東京的 2.7 倍。

## 不可變怎麼做才算數

| 層 | 做法 | 擋住什麼 | 擋不住什麼 |
|---|---|---|---|
| Day 16 HDP 本機不可變 | 新寫入的 pack 設唯讀，atime 設到期日 | 客體端勒索與誤刪 | 拿到 NAS 管理者權限的人，儲存池損毀 |
| Day 17 次要 NAS 快照 | ZFS 唯讀快照，保留 14 份 | 主 NAS 整台損毀，同步過去的壞檔 | 拿到次要 NAS 管理者權限的人，機房損毀 |
| 本日 GCS 保留政策 | bucket 層級，每個 generation 在 7 天內不能刪除也不能取代，鎖定後政策本身不能縮短或移除 | 拿到 NAS 任何權限的人，機房損毀，上傳憑證外洩，專案 Owner 誤刪 | 未鎖定時，專案 Owner 可以縮短或移除政策；帳單欠費 |
| 本日 S3 Object Lock（Linode） | bucket 建立時啟用，預設保留 COMPLIANCE 7 天 | 同上，連全權限金鑰都刪不掉指定版本 | 帳單欠費，供應商關閉帳號 |

設定上的四個關鍵。

1. GCS 要同時開 Object Versioning。開了之後覆寫成功，舊版本轉為 noncurrent 並繼續受保留政策保護。來源 https://docs.cloud.google.com/storage/docs/bucket-lock
2. 上傳身分要有 `storage.objects.delete`。GCS 覆寫既有物件需要這個權限，沒有它同步工具遇到變過的檔案就 403（實測）。安全性由保留政策提供：刪現行版本只會讓它轉成 noncurrent，刪任何一個未滿保留期的 generation 都回 `403 RetentionPolicyNotMet`。角色綁在 bucket 上，不綁在專案上，定義在 `iam/gcs-role.yaml`。
3. 憑證外洩的最壞情況是對方把現行版本都刪成 noncurrent，看起來像資料不見了。資料還在，回復要用 `gcloud storage cp gs://BUCKET/KEY#GENERATION`；rclone 經 S3 相容端點列得出舊版但讀不出來。生命週期在 noncurrent 30 天後刪除，所以發現的期限是 30 天，保護的期限是保留期。
4. 演練期保留 7 天且不鎖定，正式上線改 30 天並執行 `gcs-bucket.sh lock`。鎖定不可逆，bucket 要等所有物件到期才能刪，專案會被加上 lien。

## 上傳工具

| 工具 | 跑在哪 | 優點 | 缺點 |
|---|---|---|---|
| HBS 3 雲端同步 | 主 NAS | 與 Day 17 的工作在同一個介面，有工作紀錄，Music 實測 59.0 MiB/s | GCS 連接器不收 HMAC，要用「S3 相容」並多給專案層級的 `storage.buckets.list`；目的地前綴要先存在；雲端同步沒有「備份前先建快照」也沒有稀疏檔偵測；隱藏檔預設不傳 |
| rclone | 掛載共享資料夾的 Linux 主機 | 參數透明，`--transfers` 可調，速率可量，Music 實測 58.2 MiB/s，`offload-drill.sh` 直接用它 | 要另一台主機，排程自己管；NFS 看不到快照，執行中的容器資料會傳到改到一半的檔案；不認得稀疏檔 |

兩者速率相同，線路是瓶頸。日常排程用 HBS 3，留在 NAS 的工作紀錄裡；演練與計時用 rclone。執行中的資料（Container）與稀疏的 VM 映像（HDP_Business）兩個工具都處理不好，下一步是從快照目錄上傳，以及換成會壓縮或去重的備份格式，未實測。

## 排程

| 項目 | 值 | 依據 |
|---|---|---|
| 上傳 | 每日 05:30 | Day 17 的 HBS 3 同步 04:00，次要 NAS 快照 05:00，雲端副本在兩者之後 |
| 來源 | 主 NAS 的共享資料夾，開「備份前先建快照」 | 與 Day 17 相同，上雲的是一致版本 |
| 版本 | Object Versioning，noncurrent 30 天後由生命週期刪除，保留政策會把刪除延到保留期滿 | `iam/gcs-lifecycle.json` |
| 分層 | HDP_Business 直接以 Coldline 上傳，生命週期對 HDP_Business 與 JustBackup 前綴立即轉 Coldline；Music、Wordpress、Container 30 天後 Nearline | 同上 |
| 完整性 | 每月一次 `offload-drill.sh restore` 抽還原一個資料集並過 manifest | 演練 2 |

## 隱藏成本清單

- PUT 請求費。Container 4.5 萬個檔案在 Archive 類別的首次 PUT 約 $2.25，接近它在 Standard 一整年的儲存費。檔案多的資料集留在 Standard 或 Nearline。
- 演練本身也要錢。保留期內刪不掉，Coldline 又有 90 天最低保存，HDP_Business 這 901 GiB 傳上去就至少付三個月，約 $13.5。
- 最低保存天數。Nearline 30 天、Coldline 90 天、Archive 365 天，提早刪除照收。版本輪替快的資料放 Archive 等於每一個版本都付一年。
- 取回費加流出費。GCS Archive 取回 $0.05/GiB，流出到亞太每月前 100 GiB 免費、之後 $0.12/GiB，2.9 TiB 拿回來一次約 $466。
- 軟刪除（soft delete）。GCS 預設保留已刪除物件 7 天並計費，與保留政策重疊，`gcs-bucket.sh create` 設為 0。
- 小檔案的時間成本。大檔每秒約 59 MiB，接近 500 Mbps 線速；Container 的 4.5 萬個小檔只有每秒 14.8 MiB。
- 稀疏檔。HDP_Business 的 VM 磁碟映像在 ZFS 上用 262 GiB，表面大小 901 GiB，rclone 全部照傳，上傳 4.4 小時，儲存費與還原費都乘上 3.4。上傳前先比 `du` 與 `du --apparent-size`。
- 大檔的前置雜湊。rclone 分段上傳前先把整個檔案讀完算 MD5，這段時間 NFS 讀 400 MiB/s 以上、上傳接近 0，看起來像卡住。
- 價格頁的數字不一定是你的區域。asia-east1 的 Coldline 是 $0.005、Archive 是 $0.0015，比常被引用的美國區域價格高兩成五；計價單位是 GiB。

## 實測到的邊界（2026-10-02）

見 `drill-log.md`。帳單出來後補：

- 第一個月的實際帳單，與 `offload-cost.py` 的差距
- 軟刪除設為 0 之後，帳單上是否還有 soft delete 的儲存費
