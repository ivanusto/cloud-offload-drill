#!/bin/sh
# gcs-bucket: create and configure the off-site bucket on Google Cloud
# Storage, then the least-privilege identity the NAS uploads with.
#
#   gcs-bucket.sh create  PROJECT BUCKET [REGION] [RETENTION]   # bucket, versioning, retention, lifecycle, no public access
#   gcs-bucket.sh sa      PROJECT BUCKET SA_NAME                 # service account + custom role bound on the bucket only
#   gcs-bucket.sh lister  PROJECT SA_EMAIL                       # project-level storage.buckets.list, only for HBS 3
#   gcs-bucket.sh hmac    PROJECT SA_EMAIL                       # HMAC key for S3-compatible clients (HBS 3, rclone s3 backend)
#   gcs-bucket.sh show    BUCKET                                 # print the settings that matter, as evidence
#   gcs-bucket.sh lock    BUCKET                                 # lock the retention policy. IRREVERSIBLE. Asks twice.
#
# REGION defaults to asia-east1 (Changhua). RETENTION defaults to 7d for
# the drill; production uses 30d. The policy is left UNLOCKED by create
# so a mistake can still be fixed; "lock" is a separate, deliberate step.
#
# Why versioning plus retention: with Object Versioning on, a sync tool
# can overwrite a changed file (the old version becomes noncurrent and
# stays protected until its retention passes). Without versioning the
# overwrite itself is refused. Overwriting also needs
# storage.objects.delete, which is why the upload role has it; see
# iam/gcs-role.yaml. Source: https://docs.cloud.google.com/storage/docs/bucket-lock
#
# Needs gcloud (gcloud storage, not gsutil). POSIX sh.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
die() { printf 'gcs-bucket: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }

cmd_create() {
  project=$1; bucket=$2; region=${3:-asia-east1}; retention=${4:-7d}
  need gcloud
  gcloud storage buckets create "gs://$bucket" \
    --project="$project" --location="$region" \
    --default-storage-class=STANDARD \
    --uniform-bucket-level-access \
    --public-access-prevention \
    --retention-period="$retention"
  gcloud storage buckets update "gs://$bucket" --versioning
  # soft delete keeps deleted objects (and bills them) for 7 days by default;
  # retention plus versioning already cover that, so turn it off (待測: billing effect)
  gcloud storage buckets update "gs://$bucket" --soft-delete-duration=0
  gcloud storage buckets update "gs://$bucket" --lifecycle-file="$HERE/iam/gcs-lifecycle.json"
  printf 'created gs://%s in %s, retention %s (unlocked), versioning on, lifecycle set\n' "$bucket" "$region" "$retention"
}

cmd_sa() {
  project=$1; bucket=$2; sa=$3
  need gcloud
  gcloud iam roles create nasOffloadWriter --project="$project" \
    --file="$HERE/iam/gcs-role.yaml" 2>/dev/null \
    || gcloud iam roles update nasOffloadWriter --project="$project" --file="$HERE/iam/gcs-role.yaml"
  gcloud iam service-accounts create "$sa" --project="$project" \
    --display-name="NAS offload writer" 2>/dev/null || true
  email="$sa@$project.iam.gserviceaccount.com"
  # bind on the bucket only, not the project. A new custom role takes a
  # few seconds to become visible to the bucket ("does not exist in the
  # resource's hierarchy"), so retry for up to a minute.
  i=0
  until gcloud storage buckets add-iam-policy-binding "gs://$bucket" \
      --member="serviceAccount:$email" --role="projects/$project/roles/nasOffloadWriter" >/dev/null; do
    i=$((i + 1)); [ "$i" -lt 6 ] || die "binding failed"
    sleep 10
  done
  printf 'service account %s bound to gs://%s with nasOffloadWriter\n' "$email" "$bucket"
}

cmd_lister() {
  project=$1; email=$2
  need gcloud
  gcloud iam roles create nasOffloadLister --project="$project" \
    --file="$HERE/iam/gcs-lister-role.yaml" 2>/dev/null \
    || gcloud iam roles update nasOffloadLister --project="$project" --file="$HERE/iam/gcs-lister-role.yaml"
  gcloud projects add-iam-policy-binding "$project" --member="serviceAccount:$email" \
    --role="projects/$project/roles/nasOffloadLister" --condition=None --format=none
  printf '%s can list bucket names in %s (HBS 3 account validation)\n' "$email" "$project"
}

cmd_hmac() {
  project=$1; email=$2
  need gcloud
  gcloud storage hmac create "$email" --project="$project"
  printf 'store the secret now; it is shown once. S3 endpoint: https://storage.googleapis.com\n'
}

cmd_show() {
  bucket=$1
  need gcloud
  gcloud storage buckets describe "gs://$bucket" \
    --format="yaml(name,location,location_type,default_storage_class,versioning_enabled,retention_policy,uniform_bucket_level_access,public_access_prevention,soft_delete_policy,lifecycle_config)"
}

cmd_lock() {
  bucket=$1
  need gcloud
  printf 'This locks the retention policy on gs://%s. It cannot be unlocked, the period cannot be shortened, and the bucket cannot be deleted until every object ages out.\n' "$bucket"
  printf 'Type the bucket name to continue: '
  read -r a; [ "$a" = "$bucket" ] || die "aborted"
  printf 'Type LOCK to confirm: '
  read -r b; [ "$b" = "LOCK" ] || die "aborted"
  gcloud storage buckets update "gs://$bucket" --lock-retention-period
  printf 'locked\n'
}

[ $# -ge 2 ] || { sed -n '2,22p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  create) [ $# -ge 2 ] || die "create PROJECT BUCKET [REGION] [RETENTION]"; cmd_create "$@" ;;
  sa)     [ $# -eq 3 ] || die "sa PROJECT BUCKET SA_NAME"; cmd_sa "$@" ;;
  lister) [ $# -eq 2 ] || die "lister PROJECT SA_EMAIL"; cmd_lister "$@" ;;
  hmac)   [ $# -eq 2 ] || die "hmac PROJECT SA_EMAIL"; cmd_hmac "$@" ;;
  show)   cmd_show "$1" ;;
  lock)   cmd_lock "$1" ;;
  *) die "unknown command: $cmd" ;;
esac
