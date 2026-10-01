#!/usr/bin/env python3
"""Cost and time model for moving NAS data to object storage.

Reads prices.json (every price with a source and a check date) and a
datasets file, prints Markdown tables:

  1. per dataset and storage class: monthly storage, first upload time
     on the WAN, one-time PUT cost, monthly churn cost (including the
     minimum-duration exposure), one full restore (retrieval + egress),
     and a 12-month total with N restores
  2. the flat-rate provider (Linode) for the whole selection at once
  3. re-download from upstream versus keeping an archive copy, for data
     that can be fetched again (model weights)

Usage
  ./offload-cost.py                      # datasets.json, 12 months, 1 restore
  ./offload-cost.py --months 12 --restores 2 --datasets datasets.json
  ./offload-cost.py one --gb 262 --files 5000 --change-gb 3

Model, in plain words
  storage      gb * price per month
  put          files / 1000 * class A price, once at first upload, then
               changed files every month
  churn        changed GB are stored as new versions; each is billed for
               at least the class minimum duration (30/90/365 days) even
               if lifecycle deletes the noncurrent version sooner
  restore      gb * (retrieval + tiered egress), per restore
  upload time  bytes / (WAN upload Mbps * efficiency)
Everything is an estimate to one significant decision: which class and
which provider. Real invoices replace these numbers in drill-log.md.
"""
import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
GIB = 1024 ** 3


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def egress_cost(gb, tiers):
    """Tiered egress for one month. tiers: [[upper_gb or None, price], ...]."""
    cost, done = 0.0, 0.0
    for upper, price in tiers:
        if upper is None:
            cost += max(0.0, gb - done) * price
            break
        take = max(0.0, min(gb, upper) - done)
        cost += take * price
        done = upper
        if gb <= upper:
            break
    return cost


def hours(gb, wan):
    bytes_per_s = wan["upload_mbps"] * 1e6 * wan.get("efficiency", 1.0) / 8
    return gb * GIB / bytes_per_s / 3600


def fmt_h(h):
    if h < 1:
        return f"{h * 60:.0f} 分"
    if h < 48:
        return f"{h:.1f} 小時"
    return f"{h / 24:.1f} 天"


def class_row(ds, cls, c, prov, wan, months, restores):
    gb, files = ds["gb"], ds.get("files", 1)
    change_gb = ds.get("change_gb_month", 0.0)
    change_files = ds.get("change_files_month", 0)
    min_months = max(1.0, c["min_days"] / 30.0)
    storage = gb * c["storage_per_gb_month"]
    put_once = files / 1000 * c["class_a_per_1k"]
    churn = change_gb * c["storage_per_gb_month"] * min_months + change_files / 1000 * c["class_a_per_1k"]
    restore = gb * c["retrieval_per_gb"] + egress_cost(gb, prov["egress_per_gb_tiers"]) \
        + files / 1000 * c["class_b_per_1k"]
    # first upload is billed for at least min duration too
    first_min = gb * c["storage_per_gb_month"] * max(0.0, min_months - months)
    total = storage * months + put_once + churn * months + restore * restores + first_min
    return {
        "dataset": ds["name"], "class": cls, "storage": storage, "put": put_once,
        "churn": churn, "restore": restore, "total": total, "upload_h": hours(gb, wan),
        "min_days": c["min_days"],
    }


def table_classes(rows, months, restores):
    out = [f"| 資料集 | 類別 | 月儲存費 | 首次上傳 | 首次 PUT | 月變動費 | 還原一次 | {months} 個月含 {restores} 次還原 | 最低保存 |",
           "|---|---|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        out.append(f"| {r['dataset']} | {r['class']} | ${r['storage']:.2f} | {fmt_h(r['upload_h'])} | "
                   f"${r['put']:.2f} | ${r['churn']:.2f} | ${r['restore']:.2f} | **${r['total']:.2f}** | {r['min_days']} 天 |")
    return "\n".join(out)


def table_flat(datasets, prov, wan, months, restores):
    f = prov["flat"]
    gb = sum(d["gb"] for d in datasets)
    change = sum(d.get("change_gb_month", 0.0) for d in datasets)
    monthly = f["monthly_base"] + max(0.0, gb - f["included_gb"]) * f["storage_overage_per_gb_month"]
    restore_egress = max(0.0, gb - f["included_egress_gb"]) * f["egress_overage_per_gb"]
    total = monthly * months + restore_egress * restores
    out = [f"| 供應商 | 合計容量 | 月費 | 月變動 | 還原一次的流出費 | {months} 個月含 {restores} 次還原 | 首次上傳 |",
           "|---|---:|---:|---:|---:|---:|---:|",
           f"| {prov['name']} | {gb:.1f} GB | ${monthly:.2f} | {change:.1f} GB（含在月費內，版本另計） | "
           f"${restore_egress:.2f} | **${total:.2f}** | {fmt_h(hours(gb, wan))} |"]
    return "\n".join(out)


def table_redownload(ds, prov, wan, months):
    """Archive a re-downloadable dataset, or fetch it again from upstream."""
    gb = ds["gb"]
    c = prov["classes"]["archive"]
    keep = gb * c["storage_per_gb_month"] * max(months, c["min_days"] / 30.0)
    restore = gb * c["retrieval_per_gb"] + egress_cost(gb, prov["egress_per_gb_tiers"])
    # download at line rate; upstream (Hugging Face, Ollama) usually caps lower, note it
    dl_h = hours(gb, {"upload_mbps": wan.get("download_mbps", wan["upload_mbps"]), "efficiency": wan.get("efficiency", 1.0)})
    out = ["| 方案 | 一年費用 | 還原一次 | 拿回資料要多久 | 備註 |",
           "|---|---:|---:|---:|---|",
           f"| 放 {prov['name']} Archive | ${keep:.2f} | ${restore:.2f} | 首次上傳 {fmt_h(hours(gb, wan))}，取回受流出速率限制 | 最低保存 365 天，提早刪除照收 |",
           f"| 從上游重下載 | $0 | $0 | {fmt_h(dl_h)}（以 WAN 線速估，上游通常更慢，待測） | 以 Day 13 的 manifest 驗證，上游下架的模型拿不回來 |"]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--prices", default=str(HERE / "prices.json"))
    ap.add_argument("--datasets", default=str(HERE / "datasets.json"))
    ap.add_argument("--months", type=int, default=12)
    ap.add_argument("--restores", type=int, default=1)
    sub = ap.add_subparsers(dest="cmd")
    one = sub.add_parser("one", help="a single dataset from the command line")
    one.add_argument("--gb", type=float, required=True)
    one.add_argument("--files", type=int, default=1000)
    one.add_argument("--change-gb", type=float, default=0.0)
    one.add_argument("--change-files", type=int, default=0)
    one.add_argument("--name", default="dataset")
    a = ap.parse_args(argv)

    prices = load(a.prices)
    wan = prices["wan"]
    if a.cmd == "one":
        datasets = [{"name": a.name, "gb": a.gb, "files": a.files,
                     "change_gb_month": a.change_gb, "change_files_month": a.change_files}]
    else:
        datasets = load(a.datasets)["datasets"]

    gcs = prices["providers"]["gcs"]
    offload = [d for d in datasets if d.get("mode", "offload") == "offload"]
    redl = [d for d in datasets if d.get("mode") == "redownload"]

    print(f"# 外移成本試算（{a.months} 個月，{a.restores} 次完整還原，WAN 上傳 {wan['upload_mbps']} Mbps × {wan.get('efficiency', 1.0):.0%}）\n")
    print(f"價格來源 {gcs['source']}（{gcs['region']}，查核日 {gcs['checked']}）。模型假設見腳本開頭。\n")
    print(f"## {gcs['name']}，依類別\n")
    rows = [class_row(d, cls, c, gcs, wan, a.months, a.restores)
            for d in offload for cls, c in gcs["classes"].items()]
    print(table_classes(rows, a.months, a.restores))

    lin = prices["providers"].get("linode")
    if lin and offload:
        print(f"\n## {lin['name']}，固定月費（來源待查，見 prices.json）\n")
        print(table_flat(offload, lin, wan, a.months, a.restores))

    for d in redl:
        print(f"\n## {d['name']}（{d['gb']:.0f} GB，可重下載）\n")
        print(table_redownload(d, gcs, wan, a.months))
    return 0


if __name__ == "__main__":
    sys.exit(main())
