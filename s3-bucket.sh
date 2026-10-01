#!/bin/sh
# s3-bucket: the same bucket on an S3-compatible provider (Akamai/Linode
# Object Storage here, any S3 endpoint with Object Lock works).
#
#   s3-bucket.sh create BUCKET [DAYS]   # object lock enabled at creation, versioning, default retention, lifecycle
#   s3-bucket.sh show   BUCKET          # versioning, object lock, lifecycle, as evidence
#
# Environment
#   S3_ENDPOINT   https://jp-osa-1.linodeobjects.com (default)
#   AWS_PROFILE or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY for the aws CLI
#
# Object Lock must be enabled when the bucket is created; it cannot be
# turned on later. Default retention in COMPLIANCE mode: nobody, not
# even the account owner, can delete a locked version before it expires.
# DAYS defaults to 7 for the drill. Linode: Object Lock is listed as
# supported in the official docs; behaviour of default retention and
# bucket-scoped keys is 待測 on this account.
# https://techdocs.akamai.com/cloud-computing/docs/object-storage-pricing
#
# Needs the aws CLI. POSIX sh.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
EP=${S3_ENDPOINT:-https://jp-osa-1.linodeobjects.com}
die() { printf 's3-bucket: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }
s3() { aws --endpoint-url "$EP" s3api "$@"; }

cmd_create() {
  bucket=$1; days=${2:-7}
  need aws
  s3 create-bucket --bucket "$bucket" --object-lock-enabled-for-bucket
  s3 put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
  tmp=$(mktemp)
  sed "s/\"Days\": 7/\"Days\": $days/" "$HERE/iam/s3-object-lock.json" > "$tmp"
  s3 put-object-lock-configuration --bucket "$bucket" --object-lock-configuration "file://$tmp"
  rm -f "$tmp"
  s3 put-bucket-lifecycle-configuration --bucket "$bucket" --lifecycle-configuration "file://$HERE/iam/s3-lifecycle.json"
  printf 'created %s at %s, object lock COMPLIANCE %s days, versioning on, lifecycle set\n' "$bucket" "$EP" "$days"
}

cmd_show() {
  bucket=$1
  need aws
  printf '## versioning\n'; s3 get-bucket-versioning --bucket "$bucket"
  printf '## object lock\n'; s3 get-object-lock-configuration --bucket "$bucket"
  printf '## lifecycle\n'; s3 get-bucket-lifecycle-configuration --bucket "$bucket"
}

[ $# -ge 2 ] || { sed -n '2,20p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  create) cmd_create "$@" ;;
  show)   cmd_show "$1" ;;
  *) die "unknown command: $cmd" ;;
esac
