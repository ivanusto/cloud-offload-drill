# cloud-offload-drill

把 NAS 的資料外移到物件儲存，補上 3-2-1 的最後一個 1 與不可變的那個 1，並把費用、上傳時間、還原時間與「真的刪不掉」量成數字。搭配 Google Cloud Storage 與任何支援 Object Lock 的 S3 相容服務。

| 檔案 | 跑在哪 | 做什麼 |
|---|---|---|
| `offload-cost.py` | 任何有 Python 3 的機器 | 讀 `prices.json` 與 `datasets.json`，印出每個資料集在每個儲存類別的月費、首次上傳時間、PUT 費、月變動費、還原一次的費用與一年總額，固定月費供應商另列一表，可重下載的資料另算「存起來還是重抓」 |
| `prices.json` | 資料 | 每個價格都有來源與查核日 |
| `datasets.json` | 資料 | 這個場域的資料集、大小、檔案數與月變動量 |
| `gcs-bucket.sh` | 有 gcloud 的機器 | 建 bucket（區域、版本、保留政策、生命週期、禁止公開）、最小權限服務帳號與自訂角色、HMAC 金鑰、列出設定當證據、鎖定保留政策 |
| `s3-bucket.sh` | 有 aws CLI 的機器 | 在 S3 相容服務建同樣的 bucket，Object Lock 在建立時啟用 |
| `iam/` | 資料 | 自訂角色、生命週期與 Object Lock 設定檔 |
| `offload-drill.sh` | 有 rclone 的機器 | 上傳計時、還原並過 manifest、刪除鎖定物件（預期被拒）、冷層首位元組延遲，各印一列 drill-log 與 JSONL |
| `policy.md` | 文件 | 外移什麼、不可變怎麼做才算數、上傳工具、排程、隱藏成本、待測邊界 |
| `drill-log.md` | 文件 | 四個演練與紀錄表 |
| `redownload-plan.md` | 文件 | 3.1 TB 模型權重不備份的另一半 |
| `tests/` | 任何 Linux | 假 rclone 跑完整流程，成本模型的單元測試 |

## 用法

試算：

```sh
./offload-cost.py                                   # datasets.json，12 個月，1 次還原
./offload-cost.py --months 36 --restores 2
./offload-cost.py one --gb 262 --files 4400 --change-gb 40
```

建 bucket 與身分（GCS）：

```sh
./gcs-bucket.sh create my-project nas-offsite-drill asia-east1 7d
./gcs-bucket.sh sa     my-project nas-offsite-drill nas-offload
./gcs-bucket.sh hmac   my-project nas-offload@my-project.iam.gserviceaccount.com
./gcs-bucket.sh show   nas-offsite-drill > bucket-evidence.yaml
```

演練：

```sh
./offload-drill.sh upload    /mnt/music gcs:nas-offsite-drill/Music --label "1a. rclone 上傳 Music"
./offload-drill.sh restore   gcs:nas-offsite-drill/Music /mnt/music-restore --manifest music.sha256 --label "2. 還原 Music"
./offload-drill.sh lock-test gcs:nas-offsite-drill/Music/canary/payload.bin --label "3. 刪除被保留的物件"
./offload-drill.sh latency   gcs:nas-offsite-drill/HDP_Business/some.pack --label "4. Coldline 首位元組"
```

`gcs:` 與 `linode:` 是 rclone 的遠端名稱。GCS 可用 HMAC 金鑰走 S3 後端（endpoint `https://storage.googleapis.com`），也可用原生後端。

## 為什麼是版本加保留，不是只有保留

GCS 的保留政策禁止在期限內刪除或取代物件。沒開 Object Versioning 時，同步工具覆寫一個變過的檔案會收到 403 retentionPolicyNotMet，整個工作失敗。開了版本，覆寫是建立新版本，舊版本變 noncurrent 並繼續受保護到期滿。來源 https://docs.cloud.google.com/storage/docs/bucket-lock

S3 Object Lock 本來就建立在版本之上，覆寫產生新版本，刪除產生 delete marker，被鎖的版本留著。`lock-test` 把「刪除回 0 但物件仍可讀」也算通過，原因在此。

## 結束碼

`offload-drill.sh restore`：0 manifest 全數通過，4 有缺檔或雜湊不符。`lock-test`：0 刪除被拒或只留 delete marker，1 物件真的消失。`offload-cost.py`：0。

## 測試

```sh
python3 -m unittest discover -s tests
sh tests/fake-flow.sh
shellcheck gcs-bucket.sh s3-bucket.sh offload-drill.sh tests/fake-flow.sh
```

CI 在每次 push 跑這三項。

## 授權

Apache-2.0
