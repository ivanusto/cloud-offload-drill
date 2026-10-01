#!/bin/sh
# End-to-end test with a fake rclone that uses a local directory as the
# "remote". No cloud account, no network. Covers upload, restore with
# manifest (pass and fail), lock-test (refused, delete marker, noncurrent,
# really deleted, generation delete refused and allowed) and latency, plus the cost model's CLI.
# shellcheck disable=SC2016,SC2034
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$T"
export OUT="$T/drills.jsonl" NBD="$T/no-such-dir" PATH="$T/bin:$PATH" FAKE_REMOTE="$T/remote"
mkdir -p bin remote

# --- fake rclone: remote "fake:" maps to $FAKE_REMOTE
cat > bin/rclone <<'EOF'
#!/bin/sh
set -eu
p() { case "$1" in fake:*) printf '%s/%s' "$FAKE_REMOTE" "${1#fake:}" ;; *) printf '%s' "$1" ;; esac; }
cmd=$1; shift
case "$cmd" in
  sync|copy) src=$(p "$1"); dst=$(p "$2"); mkdir -p "$dst"; cp -r "$src"/. "$dst"/ ;;
  size) printf '{"count":3,"bytes":%s}\n' "$(du -sb "$(p "$2")" | cut -f1)" ;;
  lsf)
    if [ "$1" = --s3-versions ]; then ls "$(p "$2")" "$FAKE_REMOTE/.versions" 2>/dev/null; else [ -e "$(p "$1")" ]; fi ;;
  deletefile)
    f=$(p "$1")
    case "${FAKE_LOCK:-locked}" in
      locked) printf 'ERROR : %s: Failed to delete: 403 retentionPolicyNotMet\n' "$1" >&2; exit 1 ;;
      marker) exit 0 ;;
      noncurrent) mkdir -p "$FAKE_REMOTE/.versions"; mv "$f" "$FAKE_REMOTE/.versions/$(basename "$f")-v2026-10-02-000000-000" ;;
      open) rm -f "$f" ;;
    esac ;;
  cat) head -c 1 "$(p "$1")" ;;
  *) exit 2 ;;
esac
EOF
chmod +x bin/rclone

# --- fake gcloud: generations live in $FAKE_REMOTE/.gens, one line each
cat > bin/gcloud <<'EOF'
#!/bin/sh
set -eu
g="$FAKE_REMOTE/.gens"
case "$1 $2 $3" in
  "storage ls -a") sed "s|^|$4#|" "$g" ;;
  "storage rm "*)
    case "${FAKE_GEN:-locked}" in
      locked) printf 'ERROR: HTTPError 403: Object is subject to bucket retention policy\n' >&2; exit 1 ;;
      open) sed -i "/^${3##*#}\$/d" "$g" ;;
    esac ;;
  *) exit 2 ;;
esac
EOF
chmod +x bin/gcloud

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- source with a manifest
mkdir -p src/data src/canary
head -c 200000 /dev/urandom > src/data/a.bin
printf 'hello\n' > src/data/b.txt
now=$(date -u +%s)
printf '%s %s host\n' $((now - 600)) "$(date -u -d "@$((now - 600))" +%Y-%m-%dT%H:%M:%SZ)" > src/canary/beats.log
( cd src && find . -type f ! -name beats.log | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done ) > m.sha256
check "manifest has 2 files" '[ "$(wc -l < m.sha256)" -eq 2 ]'

# --- upload
r=$("$HERE/offload-drill.sh" upload "$T/src" fake:bucket/drill --label up 2>/dev/null)
check "upload prints an OK row with MiB/s" 'printf "%s" "$r" | grep -q "MiB/s" && printf "%s" "$r" | grep -q "| OK |"'
check "upload landed in the fake remote" '[ -f remote/bucket/drill/data/a.bin ]'

# --- restore, intact
r=$("$HERE/offload-drill.sh" restore fake:bucket/drill "$T/back" --manifest m.sha256 --label back 2>/dev/null)
check "restore passes manifest" 'printf "%s" "$r" | grep -q "| OK |" && printf "%s" "$r" | grep -q "missing=0 mismatch=0"'

# --- restore, damaged remote
printf 'x' >> remote/bucket/drill/data/b.txt
rm -rf back2
set +e; "$HERE/offload-drill.sh" restore fake:bucket/drill "$T/back2" --manifest m.sha256 >/dev/null 2>&1; rc=$?; set -e
check "restore exits 4 on mismatch" '[ "$rc" -eq 4 ]'

# --- lock-test
check "lock-test PASS when delete is refused" 'FAKE_LOCK=locked "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/a.bin 2>/dev/null | grep -q "| OK |"'
check "lock-test records the refusal text" 'grep -q "retentionPolicyNotMet" "$OUT"'
check "lock-test PASS on delete marker (object still readable)" 'FAKE_LOCK=marker "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/a.bin 2>/dev/null | grep -q "| OK |"'
set +e; FAKE_LOCK=open "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/b.txt >/dev/null 2>&1; rc=$?; set -e
check "lock-test FAIL when the object really goes away" '[ "$rc" -ne 0 ] && [ ! -f remote/bucket/drill/data/b.txt ]'

check "lock-test PASS when the object only becomes noncurrent" 'FAKE_LOCK=noncurrent "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/a.bin 2>/dev/null | grep -q "noncurrent version is kept"'
cp src/data/a.bin remote/bucket/drill/data/a.bin
printf '1001\n1002\n' > remote/.gens
check "lock-test --gs PASS when the generation delete is refused" 'FAKE_LOCK=locked FAKE_GEN=locked "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/a.bin --gs gs://bucket/drill/data/a.bin 2>/dev/null | grep -q "| OK |.*gen 1001 delete refused.*2 generations kept"'
set +e; FAKE_LOCK=locked FAKE_GEN=open "$HERE/offload-drill.sh" lock-test fake:bucket/drill/data/a.bin --gs gs://bucket/drill/data/a.bin >/dev/null 2>&1; rc=$?; set -e
check "lock-test --gs FAIL when a generation really goes away" '[ "$rc" -ne 0 ] && [ "$(wc -l < remote/.gens)" -eq 1 ]'

# --- latency
check "latency prints the median of N reads" '"$HERE/offload-drill.sh" latency fake:bucket/drill/data/a.bin --repeat 3 2>/dev/null | grep -q "first byte median [0-9]* ms of 3"'
check "upload rate has one decimal" 'grep -q "\"rate\":\"[0-9]*\.[0-9] MiB/s\"" "$OUT"'

# --- cost model
check "cost model runs on datasets.json" 'python3 "$HERE/offload-cost.py" | grep -q "HDP_Business | coldline"'
check "cost model one-off" 'python3 "$HERE/offload-cost.py" one --gb 100 --files 10 | grep -q "| dataset | archive |"'
check "jsonl has one record per drill" '[ "$(wc -l < "$OUT")" -eq 10 ]'

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
