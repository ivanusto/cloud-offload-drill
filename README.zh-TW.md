# cloud-offload-drill

[English](README.md) | 繁體中文

把 NAS 的資料外移到物件儲存，補上 3-2-1 的最後一個 1 與不可變的那個 1，並把費用、上傳時間、還原時間與「真的刪不掉」量成數字。搭配 Google Cloud Storage 與任何支援 Object Lock 的 S3 相容服務。

| 檔案 | 跑在哪 | 做什麼 |
|---|---|---|
| `offload-cost.py` | 任何有 Python 3 的機器 | 讀 `prices.json` 與 `datasets.json`，印出每個資料集在每個儲存類別的月費、首次上傳時間、PUT 費、月變動費、還原一次的費用與一年總額，固定月費供應商另列一表，可重下載的資料另算「存起來還是重抓」 |
| `prices.json` | 資料 | 每個價格都有來源與查核日。GCS 取自 Cloud Billing Catalog API 的 asia-east1 SKU，單位是 GiB |
| `datasets.json` | 資料 | 這個場域的資料集、大小、檔案數與月變動量，前三個是上傳後 `rclone size` 的實測值 |
| `gcs-bucket.sh` | 有 gcloud 的機器 | 建 bucket（區域、版本、保留政策、生命週期、禁止公開）、上傳身分與自訂角色、HBS 3 需要的列 bucket 權限、HMAC 金鑰、列出設定當證據、鎖定保留政策 |
| `s3-bucket.sh` | 有 aws CLI 的機器 | 在 S3 相容服務建同樣的 bucket，Object Lock 在建立時啟用 |
| `iam/` | 資料 | 自訂角色、生命週期與 Object Lock 設定檔 |
| `offload-drill.sh` | 有 rclone 的機器 | 上傳計時、還原並過 manifest、刪除被保留的物件（預期被拒）、冷層首位元組延遲，各印一列 drill-log 與 JSONL |
| `hmac-rm-generation.py` | 有 Python 3 與 botocore 的機器 | 用上傳身分的 HMAC 金鑰刪除 GCS 物件的指定 generation，證明擋下來的是保留政策 |
| `policy.md` | 文件 | 外移什麼、不可變怎麼做才算數、上傳工具、排程、隱藏成本、實測到的邊界 |
| `drill-log.md` | 文件 | 演練紀錄 |
| `redownload-plan.md` | 文件 | 2.9 TiB 模型權重不備份的另一半 |
| `tests/` | 任何 Linux | 假 rclone、gcloud、aws 跑完整流程，成本模型的單元測試 |

## 用法

試算：

```sh
./offload-cost.py                                   # datasets.json，12 個月，1 次還原
./offload-cost.py --months 36 --restores 2
./offload-cost.py one --gib 262 --files 4400 --change-gib 40
```

建 bucket 與身分（GCS）：

```sh
./gcs-bucket.sh create my-project nas-offsite-drill asia-east1 7d
./gcs-bucket.sh sa     my-project nas-offsite-drill nas-offload
./gcs-bucket.sh lister my-project nas-offload@my-project.iam.gserviceaccount.com   # 只有 HBS 3 需要
./gcs-bucket.sh hmac   my-project nas-offload@my-project.iam.gserviceaccount.com
./gcs-bucket.sh show   nas-offsite-drill > bucket-evidence.yaml
```

建 bucket（S3 相容，以 Linode 東京為例）：

```sh
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com ./s3-bucket.sh create nas-offsite-drill 7
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com ./s3-bucket.sh show   nas-offsite-drill
```

演練：

```sh
./offload-drill.sh upload    /mnt/music gcs:nas-offsite-drill/Music --label "1a. rclone 上傳 Music"
RCLONE_S3_STORAGE_CLASS=COLDLINE \
./offload-drill.sh upload    /mnt/hdp gcs:nas-offsite-drill/HDP_Business --label "1c. 上傳 HDP_Business"
./offload-drill.sh restore   gcs:nas-offsite-drill/Music /mnt/music --manifest music.sha256 --label "2. 還原 Music"

# 上傳身分：刪現行版本，再刪指定 generation
./offload-drill.sh lock-test gcs:nas-offsite-drill/drill/canary/payload.bin --label "3a. 上傳身分"
./hmac-rm-generation.py nas-offsite-drill/drill/canary/payload.bin GENERATION
# 專案 Owner：gcloud 登入的身分刪現行版本與指定 generation
RCLONE_GCS_ACCESS_TOKEN=$(gcloud auth print-access-token) \
./offload-drill.sh lock-test gcs-owner:nas-offsite-drill/drill/canary/payload.bin \
  --gs gs://nas-offsite-drill/drill/canary/payload.bin --label "3b. Owner"
# S3 Object Lock：刪物件，再刪指定版本
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com \
./offload-drill.sh lock-test linode:nas-offsite-drill/drill/canary/payload.bin \
  --s3 nas-offsite-drill/drill/canary/payload.bin --label "3c. S3 Object Lock"

./offload-drill.sh latency   gcs:nas-offsite-drill/HDP_Business/some.pack --repeat 5 --label "4. Coldline 首位元組"
```

`gcs:`、`gcs-owner:`、`linode:` 是 rclone 的遠端名稱。`gcs:` 用 HMAC 金鑰走 S3 後端（`provider = GCS`，endpoint `https://storage.googleapis.com`），`gcs-owner:` 是原生 gcs 後端，權杖由 `RCLONE_GCS_ACCESS_TOKEN` 帶入，不落地。

## 實測後才知道的五件事

1. **上傳身分不能沒有 `storage.objects.delete`。** GCS 覆寫既有物件需要 delete 權限，開了版本也一樣，沒有它 PutObject 回 403，同步工具遇到變過的檔案就失敗。給了 delete 也安全：刪現行版本只會讓它變成 noncurrent，刪任何一個未滿保留期的 generation 都回 `403 RetentionPolicyNotMet`，上傳身分與專案 Owner 都一樣。保護的時間窗就是保留期。
2. **HBS 3 的 Google Cloud Storage 連接器不收 HMAC**，只有 OAuth、P12 與 JSON 金鑰。要共用 HMAC 得選「S3 相容」，而 HBS 3 建帳戶時用 ListBuckets 驗證，上傳身分要另外在專案層級拿到 `storage.buckets.list`（`gcs-bucket.sh lister`），否則回 `cloud_unauthorized`。
3. **GCS 經 S3 相容端點列得出舊版，讀不出來。** 回應裡沒有 VersionId，rclone 的 `--s3-versions` 能列名稱，取檔時回 object not found。回復 noncurrent 版本要用 `gcloud storage cp gs://BUCKET/KEY#GENERATION`。S3 Object Lock（Linode）用 rclone `--s3-versions` 就能取回。
4. **`rclone lsf` 對不存在的檔案也回 0。** `lock-test` 判斷物件還在不在，看的是輸出而不是結束碼。
5. **稀疏檔會被整個傳上去。** HDP_Business 的 VM 磁碟映像在 ZFS 上用 262 GiB，表面大小 901 GiB，rclone 照傳，上傳 4.4 小時。容量是 3.4 倍（901 對 262 GiB），Coldline 一年費用是 3.7 倍（約 $176 對 $48）：儲存費跟著容量走，還原的流出費在每月前 100 GiB 免費之後才開始算，所以漲得更多。HBS 3 的雲端同步也沒有稀疏檔偵測。上傳前先比 `du` 與 `du --apparent-size`。

## 結束碼

`offload-drill.sh upload`：0 rclone 成功，其他值照 rclone，紀錄仍會寫入。`restore`：0 manifest 全數通過，4 有缺檔或雜湊不符。`lock-test`：0 資料還在（刪除被拒、只留 delete marker、轉成 noncurrent，或指定 generation 刪除被拒），1 資料真的消失。`hmac-rm-generation.py`：0 刪除被拒，1 刪除成功。`offload-cost.py`：0。

## 測試

```sh
python3 -m unittest discover -s tests
sh tests/fake-flow.sh
shellcheck gcs-bucket.sh s3-bucket.sh offload-drill.sh tests/fake-flow.sh
```

CI 在每次 push 跑這三項。

## 授權

Apache-2.0
