# cloud-offload-drill

English | [繁體中文](README.zh-TW.md)

Move NAS data to object storage to complete the last 1 of 3-2-1 and the immutable 1, and turn cost, upload time, restore time and "it really cannot be deleted" into numbers. Works with Google Cloud Storage and any S3 compatible service that supports Object Lock.

| File | Runs on | What it does |
|---|---|---|
| `offload-cost.py` | Any host with Python 3 | Reads `prices.json` and `datasets.json` and prints, per dataset and storage class, the monthly cost, first upload time, PUT cost, monthly change cost, the cost of one restore and the one year total. Flat fee providers get their own table, and data that can be downloaded again is priced as "keep a copy or fetch it again" |
| `prices.json` | Data | Every price has a source and a check date. GCS prices come from the asia-east1 SKUs in the Cloud Billing Catalog API, in GiB |
| `datasets.json` | Data | The site's datasets with size, file count and monthly change. The first three are `rclone size` measurements taken after upload |
| `gcs-bucket.sh` | A host with gcloud | Creates the bucket (region, versioning, retention policy, lifecycle, public access prevention), the upload identity and its custom role, the bucket list permission HBS 3 needs, the HMAC key, dumps the settings as evidence, and locks the retention policy |
| `s3-bucket.sh` | A host with the aws CLI | Creates the same bucket on an S3 compatible service, with Object Lock enabled at creation |
| `iam/` | Data | Custom roles, lifecycle and Object Lock configuration |
| `offload-drill.sh` | A host with rclone | Timed upload, restore with a manifest check, deleting retained objects (expected to be refused), and cold tier first byte latency. Each prints one drill log row and a JSONL record |
| `hmac-rm-generation.py` | A host with Python 3 and botocore | Deletes a specific generation of a GCS object with the upload identity's HMAC key, to show that the retention policy is what blocks it |
| `policy.md` | Document (Traditional Chinese) | What to move offsite, what makes immutability count, upload tools, schedule, hidden costs, and limits found in testing |
| `drill-log.md` | Document (Traditional Chinese) | Drill log |
| `redownload-plan.md` | Document (Traditional Chinese) | The other half: 2.9 TiB of model weights that are not backed up |
| `tests/` | Any Linux | Runs the whole flow against fake rclone, gcloud and aws, plus unit tests for the cost model |

## Usage

Estimate:

```sh
./offload-cost.py                                   # datasets.json, 12 months, 1 restore
./offload-cost.py --months 36 --restores 2
./offload-cost.py one --gib 262 --files 4400 --change-gib 40
```

Create the bucket and identities (GCS):

```sh
./gcs-bucket.sh create my-project nas-offsite-drill asia-east1 7d
./gcs-bucket.sh sa     my-project nas-offsite-drill nas-offload
./gcs-bucket.sh lister my-project nas-offload@my-project.iam.gserviceaccount.com   # only needed for HBS 3
./gcs-bucket.sh hmac   my-project nas-offload@my-project.iam.gserviceaccount.com
./gcs-bucket.sh show   nas-offsite-drill > bucket-evidence.yaml
```

Create the bucket (S3 compatible, Linode Tokyo as the example):

```sh
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com ./s3-bucket.sh create nas-offsite-drill 7
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com ./s3-bucket.sh show   nas-offsite-drill
```

Drills:

```sh
./offload-drill.sh upload    /mnt/music gcs:nas-offsite-drill/Music --label "1a. rclone upload Music"
RCLONE_S3_STORAGE_CLASS=COLDLINE \
./offload-drill.sh upload    /mnt/hdp gcs:nas-offsite-drill/HDP_Business --label "1c. upload HDP_Business"
./offload-drill.sh restore   gcs:nas-offsite-drill/Music /mnt/music --manifest music.sha256 --label "2. restore Music"

# Upload identity: delete the live version, then a specific generation
./offload-drill.sh lock-test gcs:nas-offsite-drill/drill/canary/payload.bin --label "3a. upload identity"
./hmac-rm-generation.py nas-offsite-drill/drill/canary/payload.bin GENERATION
# Project Owner: the gcloud login deletes the live version and a specific generation
RCLONE_GCS_ACCESS_TOKEN=$(gcloud auth print-access-token) \
./offload-drill.sh lock-test gcs-owner:nas-offsite-drill/drill/canary/payload.bin \
  --gs gs://nas-offsite-drill/drill/canary/payload.bin --label "3b. Owner"
# S3 Object Lock: delete the object, then a specific version
S3_ENDPOINT=https://jp-tyo-1.linodeobjects.com \
./offload-drill.sh lock-test linode:nas-offsite-drill/drill/canary/payload.bin \
  --s3 nas-offsite-drill/drill/canary/payload.bin --label "3c. S3 Object Lock"

./offload-drill.sh latency   gcs:nas-offsite-drill/HDP_Business/some.pack --repeat 5 --label "4. Coldline first byte"
```

`gcs:`, `gcs-owner:` and `linode:` are rclone remote names. `gcs:` uses the HMAC key through the S3 backend (`provider = GCS`, endpoint `https://storage.googleapis.com`). `gcs-owner:` is the native gcs backend; its token comes from `RCLONE_GCS_ACCESS_TOKEN` and is never written to disk.

## Five things we only learned by testing

1. **The upload identity needs `storage.objects.delete`.** Overwriting an existing GCS object requires delete permission, even with versioning on. Without it PutObject returns 403 and sync tools fail on any file that changed. Granting delete is still safe: deleting the live version only makes it noncurrent, and deleting any generation still inside the retention period returns `403 RetentionPolicyNotMet`, for the upload identity and the project Owner alike. The protection window is the retention period.
2. **The HBS 3 Google Cloud Storage connector does not accept HMAC keys**, only OAuth, P12 and JSON keys. To reuse an HMAC key you have to pick "S3 compatible", and HBS 3 validates a new account with ListBuckets, so the upload identity also needs `storage.buckets.list` at project level (`gcs-bucket.sh lister`). Otherwise it returns `cloud_unauthorized`.
3. **Through the S3 compatible endpoint, GCS lists old versions but cannot read them.** The response has no VersionId, so rclone `--s3-versions` lists the names and then returns object not found when fetching. To restore a noncurrent version use `gcloud storage cp gs://BUCKET/KEY#GENERATION`. With S3 Object Lock (Linode), rclone `--s3-versions` gets them back.
4. **`rclone lsf` returns 0 even for a file that does not exist.** `lock-test` checks the output, not the exit code, to decide whether the object is still there.
5. **Sparse files are uploaded in full.** The HDP_Business VM disk images use 262 GiB on ZFS but have an apparent size of 901 GiB. rclone uploads all of it in 4.4 hours. That is 3.4 times the capacity (901 vs 262 GiB) and 3.7 times the one year Coldline cost (about $176 vs $48): storage follows capacity, while restore egress is free for the first 100 GiB a month and only charged above it, so it grows faster. HBS 3 cloud sync has no sparse file detection either. Compare `du` with `du --apparent-size` before uploading.

## Exit codes

`offload-drill.sh upload`: 0 when rclone succeeds, otherwise rclone's code; the record is written either way. `restore`: 0 when the manifest fully passes, 4 for missing files or hash mismatches. `lock-test`: 0 when the data is still there (delete refused, only a delete marker left, turned noncurrent, or deleting the specific generation refused), 1 when the data is really gone. `hmac-rm-generation.py`: 0 when the delete is refused, 1 when it succeeds. `offload-cost.py`: 0.

## Tests

```sh
python3 -m unittest discover -s tests
sh tests/fake-flow.sh
shellcheck gcs-bucket.sh s3-bucket.sh offload-drill.sh tests/fake-flow.sh
```

CI runs all three on every push.

## License

Apache-2.0
