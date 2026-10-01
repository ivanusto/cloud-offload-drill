#!/bin/sh
# offload-drill: times the four things an off-site copy has to prove,
# and prints one drill-log row plus a JSONL record for each.
#
#   offload-drill.sh upload    SRC_DIR REMOTE:BUCKET/PREFIX [--label TEXT]
#       rclone sync, measures bytes and seconds, prints MiB/s
#   offload-drill.sh restore   REMOTE:BUCKET/PREFIX DST_DIR --manifest FILE [--label TEXT] [--failed-at ISO]
#       rclone copy back, then every file in the manifest is hashed; RTO
#       is the end of the manifest check. If DST_DIR/canary/beats.log
#       exists and nas-backup-drill is reachable, RPO comes from its
#       share-canary.sh verify (CANARY_KIND=frozen).
#   offload-drill.sh lock-test REMOTE:BUCKET/PREFIX/OBJECT [--label TEXT]
#       tries to delete one object with the upload identity. PASS means
#       the provider REFUSED. The refusal text is the evidence.
#   offload-drill.sh latency   REMOTE:BUCKET/PREFIX/OBJECT [--label TEXT]
#       time to first byte of one object (Archive and Coldline reads)
#
# Remotes are rclone remotes (rclone config): gcs: with the HMAC key on
# the S3 backend, or the native backend; linode: on the S3 backend.
# OUT=drills.jsonl, NBD=path to nas-backup-drill (default ../nas-backup-drill).
set -eu

OUT=${OUT:-drills.jsonl}
NBD=${NBD:-$(dirname "$0")/../nas-backup-drill}
RCLONE=${RCLONE:-rclone}

die() { printf 'offload-drill: %s\n' "$*" >&2; exit 1; }
now() { date -u +%s; }
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

hasher() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

remote_bytes() { "$RCLONE" size --json "$1" 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p'; }
mib() { echo $(( ${1:-0} / 1048576 )); }

label=; failed_at=; manifest=
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label=$2; shift 2 ;;
      --failed-at) failed_at=$2; shift 2 ;;
      --manifest) manifest=$2; shift 2 ;;
      *) die "unknown option $1" ;;
    esac
  done
}

row() {
  # row T0 label target bytes_mib seconds rate rpo result note
  # shellcheck disable=SC2016
  printf '| %s | %s | `%s` | %s MiB | %ss | %s | %s | %s | %s |\n' \
    "$(iso_of "$1")" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
  printf '{"t0":"%s","label":"%s","target":"%s","mib":%s,"seconds":%s,"rate":"%s","rpo":"%s","result":"%s","note":"%s"}\n' \
    "$(iso_of "$1")" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$OUT"
}

cmd_upload() {
  src=$1; dst=$2; shift 2; parse_opts "$@"
  [ -d "$src" ] || die "$src is not a directory"
  t0=$(now)
  "$RCLONE" sync "$src" "$dst" --stats-one-line --stats=30s --transfers=8 --checkers=8 >&2
  t1=$(now)
  b=$(remote_bytes "$dst"); s=$((t1 - t0)); [ "$s" -gt 0 ] || s=1
  row "$t0" "${label:-upload}" "$dst" "$(mib "$b")" "$s" "$(( $(mib "$b") / s )) MiB/s" "-" "OK" "rclone sync, transfers=8"
}

cmd_restore() {
  src=$1; dst=$2; shift 2; parse_opts "$@"
  [ -n "$manifest" ] || die "restore needs --manifest FILE"
  [ -s "$manifest" ] || die "manifest $manifest is empty"
  case "$manifest" in /*) ;; *) manifest=$(pwd)/$manifest ;; esac
  mkdir -p "$dst"
  t0=$(now)
  "$RCLONE" copy "$src" "$dst" --stats-one-line --stats=30s --transfers=8 --checkers=8 >&2
  t_copy=$(( $(now) - t0 ))
  ok=0; missing=0; bad=0
  while IFS= read -r line; do
    want=${line%% *}; f=${line#*  }
    if [ ! -f "$dst/$f" ]; then missing=$((missing + 1)); printf 'MISSING %s\n' "$f" >&2
    elif [ "$(hasher "$dst/$f")" = "$want" ]; then ok=$((ok + 1))
    else bad=$((bad + 1)); printf 'MISMATCH %s\n' "$f" >&2; fi
  done < "$manifest"
  t1=$(now); s=$((t1 - t0)); [ "$s" -gt 0 ] || s=1
  rpo=-
  if [ -s "$dst/canary/beats.log" ] && [ -x "$NBD/share-canary.sh" ]; then
    v=$(CANARY_KIND=frozen "$NBD/share-canary.sh" verify "$dst/canary" "$failed_at" 2>/dev/null || true)
    rpo=$(printf '%s' "$v" | sed -n 's/.*rpo=\([^ ]*\).*/\1/p'); rpo=${rpo:--}
  fi
  kb=$(du -sk "$dst" | cut -f1); m=$((kb / 1024))
  if [ "$missing" -eq 0 ] && [ "$bad" -eq 0 ]; then res=OK; code=0; else res=FAIL; code=4; fi
  row "$t0" "${label:-restore}" "$src" "$m" "$s" "$(( m / s )) MiB/s" "$rpo" "$res" "copy ${t_copy}s, manifest ok=$ok missing=$missing mismatch=$bad"
  exit "$code"
}

cmd_lock_test() {
  obj=$1; shift; parse_opts "$@"
  t0=$(now)
  err=$("$RCLONE" deletefile "$obj" 2>&1 >/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && "$RCLONE" lsf "$obj" >/dev/null 2>&1; then
    res=OK; note="delete refused: $(printf '%s' "$err" | tr -d '\n|' | tail -c 160)"
  elif [ "$rc" -eq 0 ] && "$RCLONE" lsf "$obj" >/dev/null 2>&1; then
    res=OK; note="delete returned 0 but a current version is still readable (delete marker on a versioned bucket)"
  else
    res=FAIL; note="object is gone: the identity can delete, or retention is not in force"
  fi
  row "$t0" "${label:-lock-test}" "$obj" "0" "$(( $(now) - t0 ))" "-" "-" "$res" "$note"
  [ "$res" = OK ]
}

cmd_latency() {
  obj=$1; shift; parse_opts "$@"
  t0=$(now)
  start=$(date +%s%N 2>/dev/null || echo "${t0}000000000")
  "$RCLONE" cat "$obj" --count 1 >/dev/null
  end=$(date +%s%N 2>/dev/null || echo "$(now)000000000")
  ms=$(( (end - start) / 1000000 ))
  row "$t0" "${label:-latency}" "$obj" "0" "$(( $(now) - t0 ))" "-" "-" "OK" "first byte ${ms} ms"
}

[ $# -ge 2 ] || { sed -n '2,22p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  upload)    [ $# -ge 2 ] || die "upload SRC_DIR REMOTE:PATH"; cmd_upload "$@" ;;
  restore)   [ $# -ge 2 ] || die "restore REMOTE:PATH DST_DIR --manifest FILE"; cmd_restore "$@" ;;
  lock-test) cmd_lock_test "$@" ;;
  latency)   cmd_latency "$@" ;;
  *) die "unknown command: $cmd" ;;
esac
