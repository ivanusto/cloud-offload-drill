# 異地副本演練紀錄

每一列由 `offload-drill.sh` 印出，貼上後補「備註」欄。時間全部 UTC，秒數從指令送出算起。

欄位說明

- 大小：上傳是遠端 `rclone size` 的位元組數，還原是本機 `du` 的結果
- 速率：大小除以總秒數，還原的秒數含 manifest 逐檔雜湊
- RPO：還原的目的目錄裡有 `canary/beats.log` 且找得到 nas-backup-drill 時，由 `share-canary.sh verify` 算出，否則為 -
- 結果：上傳 OK 是 rclone 回 0，還原 OK 是 manifest 全數通過，lock-test OK 是刪除被拒或只留 delete marker

| T0 | 演練 | 目標 | 大小 | 秒數 | 速率 | RPO | 結果 | 備註 |
|---|---|---|---|---|---|---|---|---|
| | 1a. rclone 上傳 Music | | | | | | | |
| | 1b. HBS 3 上傳 Music | | | | | | | |
| | 1c. rclone 上傳 Wordpress 與 Container | | | | | | | |
| | 2. 從雲端還原 Music 到主 NAS | | | | | | | |
| | 3. 刪除被保留的物件 | | | | | | | |
| | 4. Coldline 首位元組延遲 | | | | | | | |

## 四個演練

| 演練 | 做法 | 看什麼 |
|---|---|---|
| 1. 上傳 | 同一份 Music 分別用 rclone（`offload-drill.sh upload`）與 HBS 3 雲端工作上傳到同一個 bucket 的不同前綴，再用 rclone 上傳 Wordpress 與 Container | 兩種工具的速率，HBS 3 對保留政策 bucket 有沒有報錯，Container 的 6 萬個小檔實際花多久 |
| 2. 還原 | 刪掉主 NAS 的 `Music` 內容（先確認 Day 17 的次要 NAS 副本還在），`offload-drill.sh restore` 拉回並過 manifest | 速率，manifest 全數通過，與 Day 17 演練 3 從次要 NAS 拉回的 47.7 MiB/s 比較 |
| 3. 鎖定 | 用上傳身分的憑證對一個物件執行 `lock-test`，再用專案 Owner 的憑證執行一次 | 兩次都應該被拒。Owner 被拒才證明保留政策在擋，不是 IAM 在擋 |
| 4. 延遲 | 對一個已轉 Coldline 的 HDP_Business 物件執行 `latency` | GCS 冷層沒有解凍等待，首位元組應在毫秒級。對照 S3 Glacier Deep Archive 的小時級取回（未測，依官方文件） |

前置條件

- bucket 已用 `gcs-bucket.sh create` 建好，`gcs-bucket.sh show` 的輸出存檔
- 上傳身分的 HMAC 金鑰已填進 rclone 與 HBS 3
- Music 的 manifest 已用 nas-backup-drill 的 `replica-verify.sh manifest` 做好
- 演練 2 之前確認次要 NAS 的 Music 副本可讀，這是演練失敗時的退路

演練後檢查與清理

- 演練 1b 的 HBS 3 工作若報錯，保留錯誤訊息截圖再刪除工作
- 演練用的前綴（例如 `drill/`）內的物件要等 7 天保留期滿才能刪，lifecycle 會在期滿後清掉 noncurrent 版本，current 版本要手動刪
- 專案 Owner 憑證做完演練 3 立刻從操作主機移除
- 第一個月帳單出來後，數字回填 `policy.md` 的「實測到的邊界」
