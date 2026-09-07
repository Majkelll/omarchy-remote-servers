#!/bin/sh
#
# Runs on the remote host, piped in over stdin as `ssh ... 'sh -s' < this
# file`. Never copied to disk there, never marked executable. POSIX sh only:
# the remote's login shell may be dash, busybox ash, or anything else.
#
# Prints one \x1f-separated (octal \037) line, all of it from /proc, so no
# sudo and no extra packages are ever needed on the far end:
#   hostname \x1f cores \x1f load1 \x1f memTotalKB \x1f memAvailKB \x1f uptimeSec

set -eu

host=$(uname -n 2>/dev/null) || host="unknown"

if command -v nproc >/dev/null 2>&1; then
  cores=$(nproc 2>/dev/null) || cores=1
else
  cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || cores=1
fi

load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || load1=0
uptime_s=$(cut -d'.' -f1 /proc/uptime 2>/dev/null) || uptime_s=0

mem=$(awk '
  /^MemTotal:/ { t = $2 }
  /^MemAvailable:/ { a = $2 }
  END { printf "%d %d", t + 0, a + 0 }
' /proc/meminfo 2>/dev/null) || mem="0 0"
mem_total=${mem% *}
mem_avail=${mem#* }

printf '%s\037%s\037%s\037%s\037%s\037%s\n' \
  "$host" "${cores:-1}" "${load1:-0}" "${mem_total:-0}" "${mem_avail:-0}" "${uptime_s:-0}"
