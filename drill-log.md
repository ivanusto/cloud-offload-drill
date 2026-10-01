# 異地副本演練紀錄

每一列由 `offload-drill.sh` 印出，貼上後補「備註」欄。時間全部 UTC，秒數從指令送出算起。1b 由 HBS 3 的工作統計換算，3a 的 generation 刪除由 `hmac-rm-generation.py` 執行。

欄位說明

- 大小：上傳是遠端 `rclone size` 的位元組數，還原是本機 `du` 的結果
- 速率：大小除以總秒數，還原的秒數含 manifest 逐檔雜湊
- 結果：上傳 OK 是 rclone 回 0，還原 OK 是 manifest 全數通過，lock-test OK 是資料還在（刪除被拒、只留 delete marker、轉成 noncurrent，或指定 generation 刪除被拒）

## 2026-10-02 首輪（保留 7 天、未鎖定）

| T0 | 演練 | 目標 | 大小 | 秒數 | 速率 | 結果 | 備註 |
|---|---|---|---:|---:|---:|---|---|
| 17:38:09 | 1a. rclone 上傳 Music | GCS asia-east1 Standard | 4,831 MiB | 83 | 58.2 MiB/s | OK | 128 個物件，transfers=8 |
| 23:41:32 | 1b. HBS 3 上傳 Music | GCS asia-east1 Standard | 4,831 MiB | 82 | 59.0 MiB/s | OK | 雲端同步、S3 相容帳戶、copy、並行 10；隱藏檔預設不傳，97 個物件 |
| 17:41:22 | 1c. rclone 上傳 Wordpress | GCS Standard | 17,969 MiB | 301 | 59.7 MiB/s | OK | 31 個物件 |
| 17:47:25 | 1c. rclone 上傳 Container | GCS Standard | 10,755 MiB | 728 | 14.8 MiB/s | rc=1 | 45,042 個物件；第一輪 728 秒，兩次重試共 942 秒；1 個目錄無讀取權限，4 個執行中檔案上傳途中被改、更新修改時間被拒 403 |
| 18:03:13 | 1c. rclone 上傳 HDP_Business | GCS Coldline | 922,892 MiB | 15,842 | 58.3 MiB/s | OK | 4,626 個物件。ZFS 實際用量 262 GiB，上傳 901 GiB：VM 磁碟映像是稀疏檔，零照傳；大檔先讀完算 MD5 才開始傳 |
| 23:32:41 | 1d. rclone 上傳 Music 到 Linode | Linode jp-tyo-1 | 4,831 MiB | 223 | 21.7 MiB/s | OK | 同一份 Music，東京 |
| 23:43:59 | 2. 從雲端還原 Music 到主 NAS | GCS → 主 NAS | 4,808 MiB | 92 | 52.3 MiB/s | OK | 複製 86 秒，manifest ok=97 missing=0 mismatch=0；從刪除（23:43:49）到校驗完成 102 秒 |
| 17:47:36 | 3a-0. 上傳身分（無 delete）刪除與覆寫 | GCS | | 1 | | OK | 刪除 403 AccessDenied；覆寫同一路徑也 403 AccessDenied，同步工具無法更新變過的檔案 |
| 17:59:04 | 3a. 上傳身分（有 delete） | GCS | | 1 | | OK | 刪除成功但只轉成 noncurrent；刪除指定 generation 403 RetentionPolicyNotMet |
| 17:47:59 | 3b. 專案 Owner | GCS | | 1 | | OK | 刪除成功但只轉成 noncurrent；刪除指定 generation 403，until 2026-10-08 |
| 17:59:37 | 3c. Linode 全權限金鑰 | Linode jp-tyo-1 | | 2 | | OK | 刪除只留 delete marker；刪除指定版本 AccessDenied: forbidden by object lock |
| 23:32:33 | 4. Coldline 首位元組 | GCS Coldline | | | | OK | 中位數 141 ms（217、172、141、130、136），含 rclone 啟動 |
| 23:32:34 | 4. Standard 首位元組（對照） | GCS Standard | | | | OK | 中位數 160 ms（195、152、160、126、186） |

原始 JSONL 與拒絕訊息原文另存，不進 repo。

## 演練做法

| 演練 | 做法 | 看什麼 |
|---|---|---|
| 1. 上傳 | 同一份 Music 分別用 rclone（`offload-drill.sh upload`）與 HBS 3 雲端工作上傳到同一個 bucket 的不同前綴，再用 rclone 上傳 Wordpress、Container、HDP_Business；Music 另傳一份到 Linode | 兩種工具的速率，HBS 3 對保留政策 bucket 有沒有報錯，小檔與大檔的速率差 |
| 2. 還原 | 刪掉主 NAS 的 `Music` 內容（先確認次要 NAS 副本對 manifest 全數通過），`offload-drill.sh restore` 拉回並過 manifest | 速率，manifest 全數通過，與 Day 17 演練 3 從次要 NAS 拉回的 47.7 MiB/s 比較 |
| 3. 鎖定 | 上傳身分、專案 Owner、Linode 金鑰各做一次：先刪現行版本，再刪指定 generation 或版本 | 「刪除成功」不等於資料不見；指定 generation 的刪除都要被拒，Owner 被拒才證明是保留政策在擋 |
| 4. 延遲 | 對 Coldline 的 HDP_Business 物件與 Standard 的 Music 物件各量 5 次 | GCS 冷層沒有解凍等待 |

前置條件

- bucket 已用 `gcs-bucket.sh create` 建好，`gcs-bucket.sh show` 的輸出存檔
- 上傳身分的 HMAC 金鑰已填進 rclone 與 HBS 3；HBS 3 需要 `gcs-bucket.sh lister`
- HBS 3 的目的地前綴要先存在（`rclone mkdir --s3-directory-markers`），否則工作回「Failed to locate the destination folder」
- Music 的 manifest 已用 nas-backup-drill 的 `replica-verify.sh manifest` 做好
- 演練 2 之前確認次要 NAS 的 Music 副本對 manifest 全數通過，這是演練失敗時的退路

演練後檢查與清理

- 還原的檔案擁有者會變成執行 rclone 的帳號，演練 2 後群組要改回 `users`；原本屬於 root 的縮圖快取改由 NAS 重建
- 演練用的前綴（`drill/`、`Music-hbs/`）內的物件要等保留期滿才能刪，lifecycle 會在 noncurrent 30 天後清掉
- 專案 Owner 的存取權杖只在環境變數裡，用完即失效
- 第一個月帳單出來後，數字回填 `policy.md`

## 已知的工具行為

- `rclone lsf` 對不存在的檔案也回 0
- GCS 經 S3 相容端點列得出舊版但讀不出來（沒有 VersionId），回復 noncurrent 版本用 `gcloud storage cp gs://BUCKET/KEY#GENERATION`
- aws CLI v1 對 GCS 的 PutObject 會簽章錯誤，GCS 這邊一律用 rclone 或 gcloud
- HBS 3 的雲端同步工作沒有「備份前先建快照」與稀疏檔偵測欄位，送了會被 schema 拒絕
