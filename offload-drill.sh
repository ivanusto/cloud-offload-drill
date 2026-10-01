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
#   offload-drill.sh lock-test REMOTE:BUCKET/PREFIX/OBJECT [--label TEXT] [--gs gs://BUCKET/OBJECT]
#       tries to delete one object with the remote's identity. PASS means
#       the data survived: the delete was refused, or on a versioned
#       bucket the object only became noncurrent and is still kept.
#       With --gs, gcloud (whoever it is logged in as) also tries to
#       delete one generation outright, which is what a retention policy
#       really has to refuse, and gcloud decides whether data survived.
#       The refusal texts are the evidence.
#   offload-drill.sh latency   REMOTE:BUCKET/PREFIX/OBJECT [--label TEXT] [--repeat N]
#       time to first byte of one object (Archive and Coldline reads),
#       median of N reads (default 5)
#
# Remotes are rclone remotes (rclone config): gcs: with the HMAC key on
# the S3 backend, or the native backend; linode: on the S3 backend.
# OUT=drills.jsonl, NBD=path to nas-backup-drill (default ../nas-backup-drill).
set -eu

OUT=${OUT:-drills.jsonl}
NBD=${NBD:-$(dirname "$0")/../nas-backup-drill}
RCLONE=${RCLONE:-rclone}
GCLOUD=${GCLOUD:-gcloud}

die() { printf 'offload-drill: %s\n' "$*" >&2; exit 1; }
now() { date -u +%s; }
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

hasher() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

remote_bytes() { "$RCLONE" size --json "$1" 2>/dev/null | sed -n 's/.*"bytes":\([0-9]*\).*/\1/p'; }
mib() { echo $(( ${1:-0} / 1048576 )); }
# rate MIB SECONDS -> "12.3 MiB/s"
rate() { awk -v m="$1" -v s="$2" 'BEGIN { printf "%.1f MiB/s", m / s }'; }
oneline() { tr -d '\n|"' | tail -c "${1:-160}"; }

label=; failed_at=; manifest=; gs=; repeat=5
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --label) label=$2; shift 2 ;;
      --failed-at) failed_at=$2; shift 2 ;;
      --manifest) manifest=$2; shift 2 ;;
      --gs) gs=$2; shift 2 ;;
      --repeat) repeat=$2; shift 2 ;;
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
  row "$t0" "${label:-upload}" "$dst" "$(mib "$b")" "$s" "$(rate "$(mib "$b")" "$s")" "-" "OK" "rclone sync, transfers=8"
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
  row "$t0" "${label:-restore}" "$src" "$m" "$s" "$(rate "$m" "$s")" "$rpo" "$res" "copy ${t_copy}s, manifest ok=$ok missing=$missing mismatch=$bad"
  exit "$code"
}

# gens URI: generations of one GCS object, live and noncurrent
gens() { "$GCLOUD" storage ls -a "$1" 2>/dev/null | sed -n 's/.*#\([0-9][0-9]*\)$/\1/p'; }

cmd_lock_test() {
  obj=$1; shift; parse_opts "$@"
  t0=$(now)
  if [ -n "$gs" ]; then before=$(gens "$gs"); [ -n "$before" ] || die "no generations at $gs"; fi
  err=$("$RCLONE" deletefile "$obj" 2>&1 >/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then a="delete refused: $(printf '%s' "$err" | oneline)"
  else a="delete returned 0"; fi
  if [ -n "$gs" ]; then
    g=$(printf '%s\n' "$before" | head -n 1)
    gerr=$("$GCLOUD" storage rm "$gs#$g" 2>&1 >/dev/null) && grc=0 || grc=$?
    if [ "$grc" -ne 0 ]; then b="gen $g delete refused: $(printf '%s' "$gerr" | oneline)"
    else b="gen $g delete returned 0"; fi
    after=$(gens "$gs")
    if printf '%s\n' "$after" | grep -qx "$g" && [ "$(printf '%s\n' "$after" | wc -l)" -ge "$(printf '%s\n' "$before" | wc -l)" ]; then
      res=OK; note="$a; $b; all $(printf '%s\n' "$after" | wc -l | tr -d ' ') generations kept"
    else
      res=FAIL; note="$a; $b; generations before: $(printf '%s' "$before" | tr '\n' ' ')after: $(printf '%s' "$after" | tr '\n' ' ')"
    fi
  elif "$RCLONE" lsf "$obj" >/dev/null 2>&1; then
    res=OK; note="$a; current version still readable"
  elif "$RCLONE" lsf --s3-versions "${obj%/*}" 2>/dev/null | grep -q "^${obj##*/}-v"; then
    res=OK; note="$a; current is gone but a noncurrent version is kept"
  else
    res=FAIL; note="$a; object is gone: the identity can delete, or retention is not in force"
  fi
  row "$t0" "${label:-lock-test}" "$obj" "0" "$(( $(now) - t0 ))" "-" "-" "$res" "$note"
  [ "$res" = OK ]
}

cmd_latency() {
  obj=$1; shift; parse_opts "$@"
  t0=$(now); all=
  i=0
  while [ "$i" -lt "$repeat" ]; do
    start=$(date +%s%N)
    "$RCLONE" cat "$obj" --count 1 >/dev/null
    end=$(date +%s%N)
    all="$all $(( (end - start) / 1000000 ))"
    i=$((i + 1))
  done
  med=$(echo "$all" | tr ' ' '\n' | sed '/^$/d' | sort -n | awk '{ v[NR] = $1 } END { print (NR % 2) ? v[(NR + 1) / 2] : int((v[NR / 2] + v[NR / 2 + 1]) / 2) }')
  row "$t0" "${label:-latency}" "$obj" "0" "$(( $(now) - t0 ))" "-" "-" "OK" "first byte median ${med} ms of ${repeat} (${all# })"
}

[ $# -ge 2 ] || { sed -n '2,29p' "$0"; exit 1; }
cmd=$1; shift
case "$cmd" in
  upload)    [ $# -ge 2 ] || die "upload SRC_DIR REMOTE:PATH"; cmd_upload "$@" ;;
  restore)   [ $# -ge 2 ] || die "restore REMOTE:PATH DST_DIR --manifest FILE"; cmd_restore "$@" ;;
  lock-test) cmd_lock_test "$@" ;;
  latency)   cmd_latency "$@" ;;
  *) die "unknown command: $cmd" ;;
esac
