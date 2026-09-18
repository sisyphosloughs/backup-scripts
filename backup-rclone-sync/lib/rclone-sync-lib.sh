# shellcheck shell=bash
#
# rclone-sync-lib.sh — the rclone helpers of backup-rclone-sync.sh: telling a
# remote from a local path, fetching a source's completion marker, turning
# rclone's JSON log into readable lines, and reading its final statistics.
#
# This is NOT a standalone program: it is sourced by backup-rclone-sync.sh. It
# is the counterpart of backup-tar's lib/tar-lib.sh: everything specific to
# driving rclone lives here, while WHICH trees are mirrored stays in
# instances/<name>.conf.
#
# All helpers run INSIDE the per-mirror subshell of backup-rclone-sync.sh (or
# on the run level before it) and read the globals they need — RCLONE_BIN,
# RCLONE_CONFIG_ARGS — by name at call time.
#
# Log in the same format as runlib ("<ts> [LEVEL] msg"), but to STDERR and
# without touching the log file: the caller runs this in a subshell whose
# stdout+stderr are teed into the log in one place. STDERR on purpose —
# spec_kind and stats_num return their result on stdout via a command
# substitution, so diagnostics must not pollute that channel. This bare log() is
# exactly what runlib deliberately does NOT define, so the two channels stay
# apart — see the header of runlib's log.sh.

log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" >&2
}

# ---------------------------------------------------------------------------
# Local or remote?
# ---------------------------------------------------------------------------

spec_kind() {
  # spec_kind <spec> — prints "local", "remote" or "invalid".
  #
  # rclone's own rule is "anything with a colon before the first slash is a
  # remote"; this script narrows it so a typo cannot silently become a local
  # path: a local path must be ABSOLUTE, and everything else must carry a
  # colon (a configured "name:path" or an on-the-fly ":sftp,host=…:path").
  case "$1" in
    /*)  printf 'local' ;;
    *:*) printf 'remote' ;;
    *)   printf 'invalid' ;;
  esac
}

# ---------------------------------------------------------------------------
# The source's completion marker
# ---------------------------------------------------------------------------

fetch_source_marker() {
  # fetch_source_marker <source-spec> <marker-name> <out-file>
  #
  # Copies the marker a producer left at the root of <source-spec> into
  # <out-file>, through rclone so it works for a remote and a local source
  # alike. Short timeouts and no retries: this is the first contact with the
  # source, and an unreachable host should fail in seconds, not minutes. stdin
  # from /dev/null keeps rclone from blocking on a prompt (an encrypted
  # configuration's password) under cron. Returns rclone's exit code; 3 = the
  # marker (or its directory) does not exist.
  #
  # cmd_run logs the command on stderr and never on stdout, which is what makes
  # the redirection below safe: stdout IS the marker's content.
  local src="$1" marker="$2" out="$3"
  cmd_run "$RCLONE_BIN" "${RCLONE_CONFIG_ARGS[@]+"${RCLONE_CONFIG_ARGS[@]}"}" \
    --contimeout "${RCLONE_PROBE_CONTIMEOUT:-20s}" \
    --timeout "${RCLONE_PROBE_TIMEOUT:-45s}" \
    --retries 1 --low-level-retries 2 \
    cat "${src%/}/${marker}" </dev/null >"$out"
}

# ---------------------------------------------------------------------------
# rclone's output
# ---------------------------------------------------------------------------

rclone_log_filter() {
  # rclone_log_filter <mirror-name> <stats-file>
  #
  # Reads rclone's --use-json-log stream on stdin (one JSON object per line)
  # and writes readable lines to stdout:
  #   - a "stats" object (one per --stats interval, and a final one) becomes ONE
  #     compact progress line and is also saved verbatim to <stats-file>, last
  #     one wins — the caller reads the final counts from there;
  #   - every other message keeps its level, object and text, in the log's own
  #     timestamp format so the lines sort with the rest;
  #   - a line that is not JSON (cmd_run's own log line, a shell error) passes
  #     through unchanged.
  # Written for gawk, mawk and busybox awk: no interval expressions, no gensub.
  local mname="$1" sfile="$2"
  # LC_ALL=C so decimals print with a dot regardless of the host's locale, and
  # so byte counts are parsed as numbers, not as text with a comma in it.
  LC_ALL=C awk -v MNAME="$mname" -v SFILE="$sfile" '
    function field(name,   pat, s) {
      # "name":"value" — the value up to the first unescaped quote.
      pat = "\"" name "\":\"([^\"\\\\]|\\\\.)*\""
      if (match($0, pat)) {
        s = substr($0, RSTART + length(name) + 4, RLENGTH - length(name) - 5)
        gsub(/\\"/, "\"", s); gsub(/\\t/, " ", s); gsub(/\\n/, " | ", s); gsub(/\\\\/, "\\", s)
        return s
      }
      return ""
    }
    function num(name,   pat, s) {
      # "name":123 or "name":1.5 — inside the stats object; -1 if absent.
      pat = "\"" name "\":[0-9.]+"
      if (match($0, pat)) {
        s = substr($0, RSTART, RLENGTH); sub("\"" name "\":", "", s); return s + 0
      }
      return -1
    }
    function hb(b,   u, i) {
      split("B KB MB GB TB PB", u, " "); i = 1
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      if (i == 1) return sprintf("%d %s", b, u[i])
      return sprintf("%.1f %s", b, u[i])
    }
    function dur(s) { if (s < 0) return "?"; return sprintf("%dm%02ds", int(s / 60), s % 60) }
    function ts(   t) {
      # "time":"2026-09-18T13:47:16.156813863+02:00" -> "2026-09-18 13:47:16"
      t = field("time"); if (t == "") return "                   "
      return substr(t, 1, 10) " " substr(t, 12, 8)
    }
    /^\{/ {
      if ($0 ~ /"stats":\{/) {
        print $0 > SFILE; close(SFILE)
        b = num("bytes"); tb = num("totalBytes"); tr = num("transfers"); ttr = num("totalTransfers")
        d = num("deletes"); el = num("elapsedTime"); eta = num("eta"); e = num("errors"); c = num("checks")
        if (tb > 0) {
          pct = int(b * 100 / tb + 0.5)
          printf "%s [STATS]  %s: %3d%%  %s/%s  %d/%d files  %d deleted  %d errors  elapsed %s  ETA %s\n", \
            ts(), MNAME, pct, hb(b < 0 ? 0 : b), hb(tb < 0 ? 0 : tb), (tr < 0 ? 0 : tr), (ttr < 0 ? 0 : ttr), \
            (d < 0 ? 0 : d), (e < 0 ? 0 : e), dur(el), dur(eta)
        } else {
          # Nothing to transfer (yet): the source is being listed and compared.
          printf "%s [STATS]  %s: nothing to transfer so far  %d checked  %d deleted  %d errors  elapsed %s\n", \
            ts(), MNAME, (c < 0 ? 0 : c), (d < 0 ? 0 : d), (e < 0 ? 0 : e), dur(el)
        }
        fflush(); next
      }
      lvl = toupper(field("level")); obj = field("object"); msg = field("msg")
      if (lvl == "") lvl = "RCLONE"
      printf "%s [RCLONE] %s: %s%s\n", ts(), lvl, (obj != "" ? obj ": " : ""), msg
      fflush(); next
    }
    { print; fflush() }
  '
}

stats_num() {
  # stats_num <stats-file> <field> — a numeric field of the saved final stats
  # object, e.g. "bytes", "transfers", "deletes", "checks", "errors". Always
  # prints a number (0 if the file or the field is absent).
  local file="$1" name="$2" v=""
  if [[ -r "$file" ]]; then
    v="$(LC_ALL=C awk -v NAME="$name" '
      { pat = "\"" NAME "\":[0-9]+"
        if (match($0, pat)) { s = substr($0, RSTART, RLENGTH); sub("\"" NAME "\":", "", s); print s + 0; exit } }
    ' "$file")"
  fi
  printf '%s' "${v:-0}"
}

rclone_rc_text() {
  # rclone_rc_text <exit-code> — what rclone means by it (rclone.org/docs,
  # "Exit Code"), for a log line that does not make the reader look it up.
  case "$1" in
    0)  printf 'success' ;;
    1)  printf 'syntax or usage error' ;;
    2)  printf 'error not otherwise categorised' ;;
    3)  printf 'directory not found' ;;
    4)  printf 'file not found' ;;
    5)  printf 'temporary error, retries exhausted' ;;
    6)  printf 'less serious errors (some files not transferred)' ;;
    7)  printf 'fatal error — check for "--max-delete threshold reached"' ;;
    8)  printf 'transfer limit (--max-transfer) exceeded' ;;
    9)  printf 'no files transferred' ;;
    10) printf 'duration limit (--max-duration) exceeded' ;;
    *)  printf 'unknown exit code' ;;
  esac
}
