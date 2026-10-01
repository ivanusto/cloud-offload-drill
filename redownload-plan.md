# 模型權重重下載計畫

Day 17 決定 AIModels、models、comfyui 共約 3.1 TB 不複製到次要 NAS，本日決定也不上雲。這份文件是「不備份」這個決定的另一半，沒有它，不備份就只是沒做。

## 為什麼不備份

| 方案 | 一年費用 | 拿回來一次 | 時間 |
|---|---:|---:|---|
| GCS Archive | 約 $45 | 約 $506 | 上傳約 17 小時，取回受流出速率限制 |
| 從上游重下載 | $0 | $0 | 以 500 Mbps 線速估約 17 小時，上游實際速率待測 |

兩個方案時間相當，費用差一個數量級。代價是上游下架的模型拿不回來，所以要有清單。

## 清單從哪裡來

Day 13 的 `mlib.py` 已經為 `Public/models` 維護 manifest，每個模型有來源、版本與每個檔案的 sha256。重下載計畫就是把 manifest 當採購單。

1. `Public/models`（476 GiB）以 manifest 為準，逐一 `mlib.py fetch` 再 `mlib.py verify`（指令名稱依 Day 13 的 repo 為準，待確認）。
2. `Public/AIModels`（2.29 TiB）目前沒有 manifest，本日先產生一份清單，欄位為路徑、大小、sha256、來源網址、授權。沒有來源網址的檔案列為「不可重下載」，這些才是真正要備份的，數量與大小待盤點後決定去向。
3. `Public/comfyui`（104 GiB）的模型多來自 Civitai 與 Hugging Face，同樣先列清單。Civitai 的模型下架率高，不可重下載的比例預期高於前兩者，待盤點。

## 演練

每季抽一個模型，刪掉本機副本，依清單重下載，用 manifest 校驗，記錄時間與實際速率。這一列也進 `drill-log.md`。

## 待查

- Hugging Face 對單一 IP 的下載速率上限
- Ollama registry 的下載速率
- AIModels 與 comfyui 中沒有來源網址的檔案數量與大小
