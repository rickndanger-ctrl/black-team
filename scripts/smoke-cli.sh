#!/usr/bin/env bash
# A short end-to-end check of the engine through the black-team command, for a Mac or a Linux computer.
# It prints one PASS or FAIL line per step and exits non-zero if any step failed.
#
#   scripts/smoke-cli.sh <path to black-team> [--data <folder>] [--install <starter id>] [--code]
#
# --data     use this data folder instead of the app's own (a fresh folder makes it a first-run test)
# --install  when no model is set up yet, download this starter model first (for example qwen3.5-0.8b)
# --code     also run a small coding task; needs a model that can use tools (Ornith 1.5 9B or better)
#
# The app must be closed while this runs: only one program may start a local model at a time.
set -u
bin="${1:?usage: smoke-cli.sh <path to black-team> [--data <folder>] [--install <starter id>] [--code]}"; shift
data=""; install=""; code=0
while [ $# -gt 0 ]; do
  case "$1" in
    --data) data="$2"; shift 2 ;;
    --install) install="$2"; shift 2 ;;
    --code) code=1; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done
[ -x "$bin" ] || { echo "FAIL  the program is not there or cannot run: $bin"; exit 1; }
[ -n "$data" ] && { mkdir -p "$data"; chmod 700 "$data"; export BLACK_TEAM_DATA="$data"; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
failed=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failed=1; }
step() { # step "<name>" "<text the output must contain>" command...
  local name="$1" want="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qiE -- "$want"; then pass "$name"; else fail "$name (exit $rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ' | cut -c1-300)"; fi
}
model_servers() { pgrep -f '[l]lama-server' 2>/dev/null | wc -l | tr -d ' '; }
before="$(model_servers)"

echo "== $("$bin" --version 2>&1) on $(uname -sm), data: ${BLACK_TEAM_DATA:-the default folder}"
step "the program starts and reports a version" 'black-team [0-9]' "$bin" --version
step "status answers" 'setup complete' "$bin" status
step "the starter list has a recommendation" 'recommended' "$bin" starter list

if "$bin" status 2>&1 | grep -q 'setup complete: no'; then
  if [ -n "$install" ]; then
    start=$(date +%s)
    step "download and set up starter model $install" 'Set up ' "$bin" starter install "$install"
    echo "      took $(( $(date +%s) - start )) s"
  else
    fail "no model is set up and --install was not given"
  fi
fi
step "a model is set up" 'setup complete: yes' "$bin" status

start=$(date +%s)
# Any answer passes: this tests that the app loads the model and gets a reply, not how clever the model is
# (the smallest starter model gets even "repeat this word" wrong some of the time).
step "a chat message gets an answer from the model" '[[:alnum:]]' "$bin" -p "Say hello in one short sentence."
echo "      took $(( $(date +%s) - start )) s"

if [ $code -eq 1 ]; then
  start=$(date +%s)
  ( cd "$work" && "$bin" code "Create a file named smoke.txt containing the single line: smoke test ok" --workspace "$work" --approve once >"$work/.code.log" 2>&1 )
  if grep -q 'smoke test ok' "$work/smoke.txt" 2>/dev/null; then pass "a coding task wrote the file it was asked for"; else fail "coding task: smoke.txt is missing or wrong: $(tail -3 "$work/.code.log" | tr '\n' ' ' | cut -c1-300)"; fi
  echo "      took $(( $(date +%s) - start )) s"
fi

sleep 2
after="$(model_servers)"
if [ "$after" -le "$before" ]; then pass "no model server was left running"; else fail "a model server was left running ($before before, $after after)"; fi

[ $failed -eq 0 ] && echo "== ALL PASSED" || echo "== SOMETHING FAILED"
exit $failed
