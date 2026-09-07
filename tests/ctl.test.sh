#!/usr/bin/env bash
#
# Argument handling and wire format for bin/omarchy-remote-servers-ctl,
# without needing a peer to talk to. The full round trip against a real sshd
# lives in .github/workflows/tests.yml.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CTL="$ROOT/bin/omarchy-remote-servers-ctl"
PROBE="$ROOT/bin/omarchy-remote-servers-probe.sh"
SESSION="$ROOT/bin/omarchy-remote-servers-session"
FS=$'\x1f'

# A port nothing listens on, so ssh fails immediately rather than on a timeout.
readonly CLOSED_PORT=2399

pass=0
fail=0

check() {
  local name=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     expected: %q\n     actual:   %q\n' "$name" "$expected" "$actual"
  fi
}

check_status() {
  local name=$1 expected=$2
  shift 2
  "$@" >/dev/null 2>&1
  check "$name" "$expected" "$?"
}

encode() {
  local id=$1 host=$2 port=$3 user=$4 identity=$5 timeout=$6
  printf '%s%s%s%s%s%s%s%s%s%s%s' \
    "$id" "$FS" "$host" "$FS" "$port" "$FS" "$user" "$FS" "$identity" "$FS" "$timeout"
}

# --------------------------------------------------------------- subcommands

check "unknown subcommand names itself" \
  "unknown-command" "$("$CTL" bogus 2>&1 >/dev/null)"
check_status "unknown subcommand exits non-zero" 1 "$CTL" bogus

check "no subcommand is an unknown subcommand" \
  "unknown-command" "$("$CTL" 2>&1 >/dev/null)"

check "connect without a host refuses" \
  "no-host" "$("$CTL" connect "" "" "" "" 5 2>&1 >/dev/null)"

check "restart is no longer a subcommand" \
  "unknown-command" "$("$CTL" restart host "" "" "" 5 "reboot" 2>&1 >/dev/null)"

check "setup-key without a host refuses" \
  "no-host" "$("$CTL" setup-key "" "" "" "" 5 2>&1 >/dev/null)"

check "stats-all without a probe script refuses" \
  "probe-missing" "$("$CTL" stats-all /nonexistent/probe.sh "$(encode a h '' '' '' 2)" 2>&1 >/dev/null)"

check "stats-all with no arguments at all refuses" \
  "probe-missing" "$("$CTL" stats-all 2>&1 >/dev/null)"

# --------------------------------------------------------------- wire format

out=$(timeout 30 "$CTL" stats-all "$PROBE" "$(encode srv1 127.0.0.1 "$CLOSED_PORT" '' '' 2)")
check "an unreachable host reports one err line" \
  "srv1${FS}err${FS}unreachable" "$(grep -v "^#network" <<<"$out")"

check "a connectivity line comes first, before any server" \
  "yes" "$(head -1 <<<"$out" | grep -q "^#network${FS}" && echo yes || echo no)"

check "the connectivity verdict is one of three words" \
  "yes" "$(head -1 <<<"$out" | cut -d"$FS" -f2 |
    grep -qE '^(online|offline|unknown)$' && echo yes || echo no)"

# An unroutable probe address must read as offline rather than as silence.
out_off=$(OMARCHY_REMOTE_SERVERS_PROBE=192.0.2.1 timeout 30 "$CTL" stats-all "$PROBE" \
  "$(encode srv1 127.0.0.1 "$CLOSED_PORT" '' '' 2)")
check "an unanswering probe reports offline" \
  "offline" "$(head -1 <<<"$out_off" | cut -d"$FS" -f2)"

out=$(timeout 30 "$CTL" stats-all "$PROBE" \
  "$(encode a 127.0.0.1 "$CLOSED_PORT" '' '' 2)" \
  "$(encode b 127.0.0.1 "$CLOSED_PORT" '' '' 2)")
check "one line per server" 2 "$(printf '%s\n' "$out" | grep -c "${FS}err${FS}")"

# Probes run in parallel, so two 2-second timeouts must not cost four seconds.
start=$SECONDS
timeout 30 "$CTL" stats-all "$PROBE" \
  "$(encode a 10.255.255.1 22 '' '' 2)" \
  "$(encode b 10.255.255.2 22 '' '' 2)" >/dev/null
elapsed=$((SECONDS - start))
check "two slow probes overlap rather than stack" \
  "under 8s" "$([[ $elapsed -lt 8 ]] && echo "under 8s" || echo "${elapsed}s")"

check "a row with no id is skipped, not half-parsed" \
  "" "$(timeout 30 "$CTL" stats-all "$PROBE" "$(encode '' 127.0.0.1 "$CLOSED_PORT" '' '' 2)" |
    grep -v "^#network")"

check "a row with no host is skipped, not half-parsed" \
  "" "$(timeout 30 "$CTL" stats-all "$PROBE" "$(encode srv1 '' '' '' '' 2)" | grep -v "^#network")"

# The cap exists so a hand-edited servers.json cannot fork unboundedly.
many=()
for i in $(seq 1 70); do many+=("$(encode "s$i" 127.0.0.1 "$CLOSED_PORT" '' '' 2)"); done
lines=$(timeout 60 "$CTL" stats-all "$PROBE" "${many[@]}" | grep -vc "^#network")
check "no more than 64 servers are probed" 64 "$lines"

# ------------------------------------------------------------------- probe

check "the probe is POSIX sh" 0 "$(sh -n "$PROBE" >/dev/null 2>&1; echo $?)"

out=$(sh "$PROBE")
check "the probe prints six fields" 6 "$(awk -F'\037' '{print NF}' <<<"$out")"
check "the probe reports this machine's own hostname" "$(uname -n)" "$(cut -d$'\037' -f1 <<<"$out")"
check "the probe reports a positive core count" \
  "positive" "$([[ $(cut -d$'\037' -f2 <<<"$out") -ge 1 ]] && echo positive || echo "not positive")"
check "the probe reports a nonzero total memory" \
  "nonzero" "$([[ $(cut -d$'\037' -f4 <<<"$out") -gt 0 ]] && echo nonzero || echo zero)"

# ------------------------------------------------------------------ limits

# A hostile or faulty server can answer a hundred-byte probe with gigabytes.
# Both streams are capped where they are read, so nothing downstream is ever
# asked to hold an unbounded amount of a remote machine's output.
check "the probe output ceiling is declared" \
  "yes" "$(grep -q 'MAX_PROBE_BYTES=' "$CTL" && echo yes || echo no)"

check "the stderr ceiling is declared" \
  "yes" "$(grep -q 'MAX_STDERR_BYTES=' "$CTL" && echo yes || echo no)"

check "stdout is capped where it is read, not after buffering" \
  "yes" "$(grep -q 'head -c "$((MAX_PROBE_BYTES + 1))"' "$CTL" && echo yes || echo no)"

check "stderr is capped where it is written" \
  "yes" "$(grep -q 'head -c "$MAX_STDERR_BYTES"' "$CTL" && echo yes || echo no)"

# timeout signals the child's process group, and -k follows TERM with a KILL,
# so an ssh that spawned anything is reaped rather than left behind.
check "the probe is killed, not just asked to stop" \
  "yes" "$(grep -q 'timeout -k 2s' "$CTL" && echo yes || echo no)"

check "an overrun is reported as an error, never half-parsed" \
  "yes" "$(grep -q 'oversized' "$CTL" && echo yes || echo no)"

# ---------------------------------------------------------------- rendering

# Server names and remote error text reach QML Text elements. Qt's default
# AutoText would render markup in them, so every sink is pinned to plain text.
check "every Text in the panel is pinned to plain text" 0 \
  "$(awk '/^[[:space:]]*Text \{$/ { want = NR + 1 } NR == want && !/textFormat/ { n++ } END { print n + 0 }' "$ROOT/Panel.qml")"

# ---------------------------------------------------------- terminal helper

# omarchy-launch-terminal hands its arguments to xdg-terminal-exec, which
# re-tokenizes the command the way the desktop-entry spec says to. A shell
# script arriving as one long argument goes through that expansion and
# silently loses its ${array[@]}, which is how `setup-key` once shipped
# broken while passing a CI run whose fake launcher just exec'd its args.
# Nothing here may hand the terminal a script body again.
check "the terminal is never given a script body to expand" \
  0 "$(grep -c 'bash -c' "$CTL")"

check "the terminal helper is a real file, and executable" \
  "yes" "$([[ -x $SESSION ]] && echo yes || echo no)"

check "the terminal helper parses" 0 "$(bash -n "$SESSION" >/dev/null 2>&1; echo $?)"

check "the terminal helper rejects an unknown subcommand" \
  "unknown-command" "$("$SESSION" bogus 2>&1 >/dev/null </dev/null)"

check "the terminal helper no longer restarts anything" \
  "unknown-command" "$("$SESSION" restart target "reboot" 2>&1 >/dev/null </dev/null)"

check "ctl refuses to launch a terminal when its helper is missing" \
  "session-missing" "$(PATH="$ROOT/tests:$PATH" bash -c '
    tmp=$(mktemp -d); cp "$1" "$tmp/"; mkdir -p "$tmp/fake"
    printf "#!/bin/sh\nexit 0\n" > "$tmp/fake/omarchy-launch-terminal"
    chmod +x "$tmp/fake/omarchy-launch-terminal"
    PATH="$tmp/fake:$PATH" "$tmp/$(basename "$1")" setup-key host "" "" "" 5 2>&1 >/dev/null
    rm -rf "$tmp"' _ "$CTL")"

# ------------------------------------------------------------------- results

printf '\nctl.test.sh: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
