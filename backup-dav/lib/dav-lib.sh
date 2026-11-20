# shellcheck shell=bash
#
# dav-lib.sh — the CalDAV/CardDAV helpers of backup-dav.sh and
# backup-dav-standby.sh: talking to a DAV server with curl, reading its
# multistatus answers, checking and splitting iCalendar and vCard exports, and
# the manifest that the export leaves for the standby and the trend guard.
#
# This is NOT a standalone program: it is sourced by the two scripts of this
# module and by tests/run-tests.sh. It is the counterpart of backup-tar's
# lib/tar-lib.sh: everything specific to DAV lives here, while WHICH accounts
# are handled stays in instances/<account>.conf.
#
# Only awk, tr, grep and sed are used, in a form that works with bash 3.2,
# busybox and the BSD tools of macOS: no interval expressions, no gensub, no
# length(array), no GNU-only options. Nothing needs python3 or jq.
#
# The network helpers read their settings by name at call time:
#   CURL_BIN              curl binary (default "curl")
#   CURL_CONNECT_TIMEOUT  seconds (default 20)
#   CURL_MAX_TIME         seconds per request (default 600)
#   DAV_AUTH              "basic" (default) or "digest"
#   DAV_LOG_REQUESTS      1 (default) = log each request through runlib's
#                         cmd_run; 0 = run it silently (the standby's per-object
#                         PUTs would otherwise flood the log)
# Credentials come only from a netrc file (--netrc-file), never from an
# argument: a password on the command line shows up in ps.
#
# Log in the same format as runlib ("<ts> [LEVEL] msg"), but to STDERR and
# without touching the log file: the caller runs this in a subshell whose
# stdout+stderr are teed into the log in one place. STDERR on purpose — most
# helpers return their result on stdout via a command substitution. This bare
# log() is exactly what runlib deliberately does NOT define, so the two
# channels stay apart — see the header of runlib's log.sh.

log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" >&2
}

# ---------------------------------------------------------------------------
# URLs and the netrc
# ---------------------------------------------------------------------------

dav_url_origin() {
  # dav_url_origin <url> — "https://host[:port]" without path.
  local u="$1" scheme rest
  scheme="${u%%://*}"; rest="${u#*://}"
  printf '%s://%s' "$scheme" "${rest%%/*}"
}

dav_url_host() {
  # dav_url_host <url> — the host name alone: no user info, no port. This is
  # what curl looks up in the netrc, so it is what a "machine" line must say.
  local rest="${1#*://}" hp
  hp="${rest%%/*}"; hp="${hp##*@}"
  printf '%s' "${hp%%:*}"
}

dav_url_path() {
  # dav_url_path <url> — the path, starting with "/".
  local rest="${1#*://}"
  case "$rest" in
    */*) printf '/%s' "${rest#*/}" ;;
    *)   printf '/' ;;
  esac
}

dav_href_uri() {
  # dav_href_uri <href> — the last path segment of a collection href, i.e. the
  # collection's URI ("/remote.php/dav/calendars/u/personal/" -> "personal").
  local h="${1%/}"
  printf '%s' "${h##*/}"
}

netrc_has_machine() {
  # netrc_has_machine <netrc> <host> — 0 if the file has a "machine <host>"
  # entry. Tokens, not lines: netrc allows an entry to span several lines.
  # Prints nothing — the file holds passwords.
  awk -v H="$2" '
    { for (i = 1; i <= NF; i++) { if (prev == "machine" && $i == H) found = 1; prev = $i } }
    END { exit (found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

# shellcheck disable=SC2034  # read by runlib's loader, the scripts and the
# account configurations sourced on top of these defaults.
dav_account_reset() {
  # dav_account_reset <name> — every variable of an instances/<account>.conf,
  # set to its default. Both scripts call it before each file is sourced (and
  # again inside their worker's subshell), so a value from one account never
  # leaks into the next — and because it lives here, the export and the
  # standby cannot disagree about what an account's settings are. DAV_USER
  # defaults to the file name; MAX_SHRINK_PERCENT to the global value, which
  # the scripts keep in DEFAULT_MAX_SHRINK_PERCENT.
  local name="${1:-}"
  DAV_URL=""
  DAV_USER="$name"
  NETRC_FILE=""
  ENABLED="true"
  INCLUDE_SHARED="false"
  EXCLUDE_COLLECTIONS=()
  MAX_SHRINK_PERCENT="${DEFAULT_MAX_SHRINK_PERCENT:-20}"
  ACCEPT_SHRINK="false"
  STANDBY="true"
  STANDBY_USER=""
}

file_private() {
  # file_private <path> — 0 if <path> is a regular file that neither group nor
  # others can read, write or execute: the same strictness ssh applies to a
  # private key. POSIX find predicates only, so it works on busybox and macOS.
  local f="$1" open
  [[ -f "$f" && ! -L "$f" ]] || return 1
  open="$(find "$f" -prune \( -perm -040 -o -perm -020 -o -perm -010 \
    -o -perm -004 -o -perm -002 -o -perm -001 \) -print 2>/dev/null)"
  [[ -z "$open" ]]
}

# ---------------------------------------------------------------------------
# HTTP through curl
# ---------------------------------------------------------------------------

dav_request() {
  # dav_request <method> <url> <netrc> <out-file> [extra curl args...]
  #
  # One request. The response body goes to <out-file>; stdout carries
  # "<http-code> <content-type>" (curl's --write-out), "000 " if no response
  # arrived. Returns curl's own exit code — 0 also for a 4xx/5xx answer: there
  # is no --fail, because the caller needs the status (401 must stop the
  # account, 404 means something else) and, for a PUT, the server's error
  # text in the body.
  local method="$1" url="$2" netrc="$3" out="$4"
  shift 4
  local auth="--basic"
  [[ "${DAV_AUTH:-basic}" == "digest" ]] && auth="--digest"
  local cmd=("${CURL_BIN:-curl}" --silent --show-error --globoff
             --netrc-file "$netrc" "$auth"
             --connect-timeout "${CURL_CONNECT_TIMEOUT:-20}"
             --max-time "${CURL_MAX_TIME:-600}"
             --request "$method" --output "$out"
             --write-out '%{http_code} %{content_type}'
             "$@" "$url")
  if [[ "${DAV_LOG_REQUESTS:-1}" -eq 1 ]] && declare -F cmd_run >/dev/null; then
    cmd_run "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

dav_propfind() {
  # dav_propfind <url> <netrc> <depth> <body> <out-file> — one PROPFIND; the
  # multistatus lands in <out-file>, stdout and exit code as dav_request. The
  # body goes in through stdin, so the logged command stays one short line.
  local url="$1" netrc="$2" depth="$3" body="$4" out="$5"
  printf '%s' "$body" | dav_request PROPFIND "$url" "$netrc" "$out" \
    --header "Depth: $depth" \
    --header "Content-Type: application/xml; charset=utf-8" \
    --data-binary @-
}

# The two PROPFIND bodies the scripts use. Single lines on purpose.
# shellcheck disable=SC2034  # read by the scripts that source this library.
DAV_PROPFIND_COLLECTIONS='<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:resourcetype/><d:displayname/><cs:getctag/><c:supported-calendar-component-set/></d:prop></d:propfind>'
# shellcheck disable=SC2034
DAV_PROPFIND_ETAGS='<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>'

http_text() {
  # http_text <code> — a status code in words, for a log line.
  case "$1" in
    000) printf 'no response' ;;
    200) printf 'OK' ;;
    201) printf 'created' ;;
    204) printf 'no content' ;;
    207) printf 'multi-status' ;;
    400) printf 'bad request' ;;
    401) printf 'unauthorized — wrong user or password' ;;
    403) printf 'forbidden' ;;
    404) printf 'not found' ;;
    405) printf 'method not allowed' ;;
    409) printf 'conflict' ;;
    412) printf 'precondition failed' ;;
    415) printf 'unsupported media type' ;;
    423) printf 'locked' ;;
    429) printf 'too many requests — throttled' ;;
    500) printf 'internal server error' ;;
    502) printf 'bad gateway' ;;
    503) printf 'service unavailable' ;;
    504) printf 'gateway timeout' ;;
    507) printf 'insufficient storage' ;;
    *)   printf 'HTTP %s' "$1" ;;
  esac
}

http_auth_refused() {
  # http_auth_refused <code> — 0 for the answers after which an account must
  # stop at once, without a retry and without trying its other collections:
  # Nextcloud throttles failed logins per source IP, so one wrong password,
  # retried, slows down or locks out every account requested from this host.
  case "$1" in
    401|403|429) return 0 ;;
  esac
  return 1
}

curl_rc_text() {
  # curl_rc_text <exit-code> — what curl means by it (man curl, "EXIT
  # CODES"), for a log line that does not make the reader look it up.
  case "$1" in
    0)  printf 'success' ;;
    1)  printf 'unsupported protocol' ;;
    2)  printf 'failed to initialise' ;;
    3)  printf 'malformed URL' ;;
    5)  printf 'could not resolve proxy' ;;
    6)  printf 'could not resolve host' ;;
    7)  printf 'failed to connect' ;;
    8)  printf 'weird server reply' ;;
    16) printf 'HTTP/2 error' ;;
    18) printf 'partial file — transfer cut short' ;;
    22) printf 'HTTP error' ;;
    23) printf 'write error — local disk?' ;;
    26) printf 'read error' ;;
    27) printf 'out of memory' ;;
    28) printf 'timeout' ;;
    35) printf 'TLS handshake failed' ;;
    47) printf 'too many redirects' ;;
    52) printf 'empty reply from server' ;;
    55) printf 'failed sending data' ;;
    56) printf 'failed receiving data' ;;
    58) printf 'problem with the local client certificate' ;;
    60) printf 'server certificate could not be verified' ;;
    77) printf 'problem reading the CA certificates' ;;
    92) printf 'HTTP/2 stream error' ;;
    *)  printf 'curl error %s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Multistatus
# ---------------------------------------------------------------------------

ms_responses() {
  # ms_responses <multistatus-file> — one tab-separated line per <response>:
  #
  #   href  resourcetype  displayname  etag  ctag  components
  #
  # resourcetype and components are comma-separated lists of local names
  # ("collection,calendar", "VEVENT,VTODO"); the etag loses its quotes. An
  # empty field is written as "-", so that bash's "read" (which collapses
  # adjacent tabs) keeps the columns apart. Only properties from a propstat
  # with status 200 count.
  #
  # Minimal on purpose: a tag-by-tag walk that drops the namespace prefix
  # ("d:", "D:", "x1:" or none — servers differ) and knows the handful of
  # elements asked for. Not a general XML parser: CDATA and comments holding
  # "<" are not expected in a multistatus and are not handled.
  awk '
    BEGIN { RS = "<" }
    function trim(s) { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
    function dec(s) {
      gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&quot;/, "\"", s)
      gsub(/&#34;/, "\"", s); gsub(/&apos;/, "'"'"'", s); gsub(/&#39;/, "'"'"'", s)
      gsub(/&amp;/, "\\&", s)
      return s
    }
    function clean(s) { s = trim(dec(s)); gsub(/[\t\r\n]+/, " ", s); return (s == "" ? "-" : s) }
    function add(list, item) { return (list == "" ? item : list "," item) }
    function attr(a, n,   v) {
      if (match(a, n "=\"[^\"]*\"")) { v = substr(a, RSTART + length(n) + 2, RLENGTH - length(n) - 3); return v }
      if (match(a, n "='"'"'[^'"'"']*'"'"'")) { v = substr(a, RSTART + length(n) + 2, RLENGTH - length(n) - 3); return v }
      return ""
    }
    NR == 1 { next }
    {
      gt = index($0, ">"); if (gt == 0) next
      tag = substr($0, 1, gt - 1); text = substr($0, gt + 1)
      c = substr(tag, 1, 1)
      if (c == "?" || c == "!") next
      closing = 0; selfc = 0
      if (c == "/") { closing = 1; tag = substr(tag, 2) }
      if (substr(tag, length(tag), 1) == "/") { selfc = 1; tag = substr(tag, 1, length(tag) - 1) }
      name = tag; sub(/[ \t\r\n].*$/, "", name)
      attrs = substr(tag, length(name) + 1)
      sub(/^.*:/, "", name)

      if (!closing) {
        if (name == "response") {
          inr = 1; inps = 0; inrt = 0; incs = 0
          href = ""; types = ""; dn = ""; et = ""; ct = ""; comps = ""
        } else if (inr && !inps && name == "href") {
          href = text
        } else if (inr && name == "propstat") {
          inps = 1; st = ""; t_types = ""; t_dn = ""; t_et = ""; t_ct = ""; t_comps = ""
        } else if (inps) {
          if (inrt) t_types = add(t_types, name)
          if (incs && name == "comp") t_comps = add(t_comps, attr(attrs, "name"))
          if (name == "resourcetype") inrt = 1
          else if (name == "supported-calendar-component-set") incs = 1
          else if (name == "displayname") t_dn = text
          else if (name == "getetag") t_et = text
          else if (name == "getctag") t_ct = text
          else if (name == "status") st = text
        }
      }
      if (closing || selfc) {
        if (name == "resourcetype") inrt = 0
        else if (name == "supported-calendar-component-set") incs = 0
        else if (name == "propstat" && inps) {
          if (st ~ / 200( |$)/) {
            if (t_types != "") types = t_types
            if (t_dn != "") dn = t_dn
            if (t_et != "") et = t_et
            if (t_ct != "") ct = t_ct
            if (t_comps != "") comps = t_comps
          }
          inps = 0; inrt = 0; incs = 0
        } else if (name == "response" && inr) {
          e = clean(et); gsub(/"/, "", e)
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", clean(href), clean(types), clean(dn), e, clean(ct), clean(comps)
          inr = 0
        }
      }
    }
  ' "$1"
}

ms_member_count() {
  # ms_member_count <multistatus-file> — how many objects a Depth-1 PROPFIND
  # of a collection listed: every response whose href does not end in "/".
  # The collection itself (and any sub-collection) ends in "/"; an object is a
  # file ("….ics", "….vcf"). Always prints a number.
  ms_responses "$1" | awk -F '\t' '$1 !~ /\/$/ { n++ } END { printf "%d", n + 0 }'
}

dav_skip_reason() {
  # dav_skip_reason <kind> <uri> <resourcetype> <include-shared> [pattern...]
  #
  # Decides whether a collection found in an account's calendar or address
  # book home is backed up. <kind> is "calendar" or "addressbook",
  # <resourcetype> the comma list from ms_responses, <include-shared> 1 or 0,
  # the patterns are EXCLUDE_COLLECTIONS (globs on the URI). Prints the reason
  # and returns 0 for a collection to skip; prints nothing and returns 1 for
  # one to keep. The account root itself is the caller's business (it compares
  # hrefs).
  local kind="$1" uri="$2" rtype="$3" types=",$3," shared="$4" pat
  shift 4
  case "$uri" in
    inbox)    printf 'scheduling inbox'; return 0 ;;
    outbox)   printf 'scheduling outbox'; return 0 ;;
    trashbin) printf 'trash bin'; return 0 ;;
  esac
  case "$types" in
    *,subscribed,*) printf 'subscription (read-only copy of an external calendar)'; return 0 ;;
  esac
  case "$uri" in
    contact_birthdays) printf 'generated birthday calendar'; return 0 ;;
    app-generated--deck--board-*) printf 'Deck board calendar'; return 0 ;;
    z-app-generated--contactsinteraction--recent) printf 'generated "recently contacted" address book'; return 0 ;;
  esac
  case "$types" in
    *,"$kind",*) ;;
    *) if [[ "$kind" == addressbook ]]; then printf 'not an address book (resourcetype %s)' "$rtype"; else printf 'not a calendar (resourcetype %s)' "$rtype"; fi; return 0 ;;
  esac
  case "$uri" in
    *_shared_by_*)
      if [[ "$shared" != 1 ]]; then
        printf 'shared with this account (INCLUDE_SHARED=false)'; return 0
      fi
      ;;
  esac
  for pat in "$@"; do
    [[ -n "$pat" ]] || continue
    # shellcheck disable=SC2254  # $pat is meant to be used as a glob
    case "$uri" in
      $pat) printf "excluded by EXCLUDE_COLLECTIONS pattern '%s'" "$pat"; return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# iCalendar and vCard
#
# Both formats are line-based with "folding": a physical line that starts with
# a space or a tab continues the previous one (RFC 5545 3.1, RFC 6350 3.2).
# Everything below parses the UNFOLDED logical lines, but ics_split/vcf_split
# write the ORIGINAL physical lines back out, so an object keeps the shape the
# server delivered it in.
# ---------------------------------------------------------------------------

ics_unfold() {
  # ics_unfold [file] — remove CRs and join folded lines; stdin if no file.
  awk '
    { gsub(/\r/, "") }
    /^[ \t]/ { buf = buf substr($0, 2); next }
    { if (started) print buf; buf = $0; started = 1 }
    END { if (started) print buf }
  ' "$@"
}

# The iCalendar walker shared by ics_stats and ics_split. MODE=stats prints
# "<bad> <vevents> <vtodos> <uids>"; MODE=split writes one file per UID into
# OUT and prints the number of objects.
#
# <bad> is "-" for a sound file, otherwise the FIRST problem found, as one
# word (see dav_bad_text). Objects are counted by UID, not by component: the
# exceptions of a recurring event are further VEVENTs with the same UID in the
# same object. Only a UID directly inside a top-level component counts — the
# UID of a VALARM (RFC 9074) sits one level deeper.
# shellcheck disable=SC2016  # an awk program: the $ are awk's, not the shell's.
_DAV_ICS_AWK='
  function colon(L,   i, n, ch, q) {
    # Position of the first ":" outside double quotes — the end of the
    # name+parameters part. Scans only that part, never a long value.
    n = length(L); q = 0
    for (i = 1; i <= n; i++) {
      ch = substr(L, i, 1)
      if (ch == "\"") q = !q
      else if (ch == ":" && !q) return i
    }
    return 0
  }
  function tzparam(L,   c, head, p, v) {
    c = colon(L); if (c == 0) return ""
    head = substr(L, 1, c - 1)
    p = index(toupper(head), ";TZID="); if (p == 0) return ""
    v = substr(head, p + 6)
    if (substr(v, 1, 1) == "\"") { v = substr(v, 2); sub(/".*$/, "", v) }
    else sub(/;.*$/, "", v)
    return v
  }
  function setbad(t) { if (bad == "") bad = t }
  function proc(L, R,   nm, un, v, c, t) {
    if (L == "") return
    nlines++
    nm = L; sub(/[;:].*$/, "", nm); un = toupper(nm)
    c = colon(L); v = (c ? substr(L, c + 1) : "")
    if (nlines == 1 && !(un == "BEGIN" && toupper(v) == "VCALENDAR")) setbad("no-begin")
    last = L
    if (un == "BEGIN") {
      v = toupper(v); sub(/[ \t]+$/, "", v)
      depth++; stk[depth] = v
      if (depth == 1 && v != "VCALENDAR") setbad("no-begin")
      if (depth == 2) { comp = v; craw = R; cuid = ""; ctz = ""; ctzid = "" }
      else if (depth > 2) craw = craw "\n" R
      return
    }
    if (un == "END") {
      v = toupper(v); sub(/[ \t]+$/, "", v)
      if (depth == 0 || stk[depth] != v) { setbad("unbalanced"); return }
      if (depth > 2) craw = craw "\n" R
      if (depth == 2) {
        craw = craw "\n" R
        if (comp == "VTIMEZONE") {
          if (ctzid != "" && !(ctzid in tzraw)) tzraw[ctzid] = craw
        } else if (comp == "VEVENT" || comp == "VTODO" || comp == "VJOURNAL" || comp == "VFREEBUSY") {
          if (cuid == "") setbad("no-uid")
          else {
            if (!(cuid in otype)) { nobj++; ord[nobj] = cuid; otype[cuid] = comp; oraw[cuid] = craw; otz[cuid] = ctz }
            else { oraw[cuid] = oraw[cuid] "\n" craw; otz[cuid] = otz[cuid] ctz }
          }
        }
      }
      depth--
      return
    }
    if (depth == 0) { setbad("outside"); return }
    if (depth == 1) {
      if (un == "VERSION" && hver == "") hver = R
      else if (un == "PRODID" && hprod == "") hprod = R
      else if (un == "CALSCALE" && hcal == "") hcal = R
      return
    }
    craw = craw "\n" R
    if (depth == 2 && un == "UID" && cuid == "") cuid = v
    if (depth == 2 && un == "TZID" && comp == "VTIMEZONE") ctzid = v
    t = tzparam(L)
    if (t != "") ctz = ctz "\001" t
  }
  { gsub(/\r/, "") }
  /^[ \t]/ { if (started) { lbuf = lbuf substr($0, 2); rbuf = rbuf "\n" $0 }; next }
  { if (started) proc(lbuf, rbuf); lbuf = $0; rbuf = $0; started = 1 }
  END {
    if (started) proc(lbuf, rbuf)
    if (nlines == 0) setbad("empty")
    else if (depth > 0) setbad("truncated")
    else if (toupper(last) != "END:VCALENDAR") setbad("no-end")
    if (MODE == "stats") {
      for (i = 1; i <= nobj; i++) {
        if (otype[ord[i]] == "VEVENT") ev++
        else if (otype[ord[i]] == "VTODO") td++
      }
      printf "%s %d %d %d\n", (bad == "" ? "-" : bad), ev, td, nobj
      exit 0
    }
    # MODE == "split"
    if (bad != "") { print "ics_split: " bad > "/dev/stderr"; exit 1 }
    if (hver == "") hver = "VERSION:2.0"
    if (hprod == "") hprod = "PRODID:-//backup-dav//EN"
    idx = OUT "/.index"
    for (i = 1; i <= nobj; i++) {
      u = ord[i]; f = OUT "/" i ".ics"
      out = "BEGIN:VCALENDAR\n" hver "\n" hprod
      if (hcal != "") out = out "\n" hcal
      # The time zones this object references, each once, in the order of
      # first reference; one the export does not define is left out.
      split("", seen); n = split(otz[u], tl, "\001")
      for (j = 1; j <= n; j++) {
        if (tl[j] == "" || (tl[j] in seen)) continue
        seen[tl[j]] = 1
        if (tl[j] in tzraw) out = out "\n" tzraw[tl[j]]
      }
      out = out "\n" oraw[u] "\nEND:VCALENDAR"
      gsub(/\n/, "\r\n", out)
      printf "%s\r\n", out > f; close(f)
      printf "%d\t%s\n", i, u > idx
    }
    close(idx)
    printf "%d\n", nobj
  }
'

ics_stats() {
  # ics_stats <file> — "<bad> <vevents> <vtodos> <uids>", see _DAV_ICS_AWK.
  # vevents/vtodos count objects (UIDs) by the type of their first component;
  # uids counts every object, VJOURNAL included.
  awk -v MODE=stats "$_DAV_ICS_AWK" "$1"
}

# shellcheck disable=SC2016  # as above
_DAV_VCF_AWK='
  function colon(L,   i, n, ch, q) {
    n = length(L); q = 0
    for (i = 1; i <= n; i++) {
      ch = substr(L, i, 1)
      if (ch == "\"") q = !q
      else if (ch == ":" && !q) return i
    }
    return 0
  }
  function setbad(t) { if (bad == "") bad = t }
  function proc(L, R,   nm, un, v, c) {
    if (L == "") return
    nlines++
    nm = L; sub(/[;:].*$/, "", nm); un = toupper(nm)
    # A group prefix ("item1.EMAIL") belongs to the property, not to its name.
    sub(/^[^.]*\./, "", un)
    c = colon(L); v = (c ? substr(L, c + 1) : "")
    if (nlines == 1 && !(un == "BEGIN" && toupper(v) == "VCARD")) setbad("no-begin")
    last = L
    if (un == "BEGIN") {
      v = toupper(v); sub(/[ \t]+$/, "", v)
      depth++; stk[depth] = v
      if (depth == 1) {
        if (v != "VCARD") setbad("no-begin")
        ncard++; craw[ncard] = R; cuid[ncard] = ""
      } else craw[ncard] = craw[ncard] "\n" R
      return
    }
    if (un == "END") {
      v = toupper(v); sub(/[ \t]+$/, "", v)
      if (depth == 0 || stk[depth] != v) { setbad("unbalanced"); return }
      craw[ncard] = craw[ncard] "\n" R
      depth--
      return
    }
    if (depth == 0) { setbad("outside"); return }
    craw[ncard] = craw[ncard] "\n" R
    if (depth == 1 && un == "UID" && cuid[ncard] == "") cuid[ncard] = v
  }
  { gsub(/\r/, "") }
  /^[ \t]/ { if (started) { lbuf = lbuf substr($0, 2); rbuf = rbuf "\n" $0 }; next }
  { if (started) proc(lbuf, rbuf); lbuf = $0; rbuf = $0; started = 1 }
  END {
    if (started) proc(lbuf, rbuf)
    if (nlines == 0) setbad("empty")
    else if (depth > 0) setbad("truncated")
    else if (toupper(last) != "END:VCARD") setbad("no-end")
    if (MODE == "stats") { printf "%s %d\n", (bad == "" ? "-" : bad), ncard; exit 0 }
    if (bad != "") { print "vcf_split: " bad > "/dev/stderr"; exit 1 }
    idx = OUT "/.index"
    for (i = 1; i <= ncard; i++) {
      f = OUT "/" i ".vcf"; out = craw[i]
      gsub(/\n/, "\r\n", out)
      printf "%s\r\n", out > f; close(f)
      # A UID that occurs twice keeps the cards apart instead of letting the
      # second overwrite the first; the count check then shows the problem.
      u = cuid[i]
      if (u != "") { dup[u]++; if (dup[u] > 1) u = u "#" dup[u] }
      printf "%d\t%s\n", i, u > idx
    }
    close(idx)
    printf "%d\n", ncard
  }
'

vcf_stats() {
  # vcf_stats <file> — "<bad> <cards>". <bad> as in ics_stats.
  awk -v MODE=stats "$_DAV_VCF_AWK" "$1"
}

dav_bad_text() {
  # dav_bad_text <token> — the <bad> word of ics_stats/vcf_stats in words.
  case "$1" in
    -)          printf 'sound' ;;
    empty)      printf 'the file is empty' ;;
    no-begin)   printf 'does not start with BEGIN:VCALENDAR / BEGIN:VCARD — not an export (an error page?)' ;;
    no-end)     printf 'does not end with END:VCALENDAR / END:VCARD' ;;
    truncated)  printf 'cut off in the middle of an object (BEGIN without END)' ;;
    unbalanced) printf 'BEGIN:/END: do not match' ;;
    outside)    printf 'content outside of BEGIN:/END:' ;;
    no-uid)     printf 'an object without UID' ;;
    *)          printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Splitting an export into objects
#
# Done when the standby imports, not in staging: staging keeps the server's
# export unchanged, as a plain copy of what the server delivered.
# ---------------------------------------------------------------------------

_DAV_MD5_TOOL=""

dav_md5() {
  # dav_md5 [file] — the md5 of a file (stdin if none) as 32 hex digits. The
  # tool differs between DSM and busybox (md5sum) and macOS (md5), so it is
  # looked up once.
  if [[ -z "$_DAV_MD5_TOOL" ]]; then
    if command -v md5sum >/dev/null 2>&1; then _DAV_MD5_TOOL="md5sum"
    elif command -v md5 >/dev/null 2>&1; then _DAV_MD5_TOOL="md5"
    elif command -v openssl >/dev/null 2>&1; then _DAV_MD5_TOOL="openssl"
    else log ERROR "dav_md5: neither md5sum, md5 nor openssl found"; return 1
    fi
  fi
  case "$_DAV_MD5_TOOL" in
    md5sum)  md5sum "$@" | awk '{ print $1 }' ;;
    md5)     if [[ $# -gt 0 ]]; then md5 -q "$1"; else md5 -q; fi ;;
    openssl) openssl md5 -r "$@" | awk '{ print $1 }' ;;
  esac
}

uid_name() {
  # uid_name <uid> — a stable, path-safe file name stem for a UID: its md5.
  # Hashed rather than escaped, because UIDs contain "/", "@", spaces and
  # worse, and an escaped name could still grow beyond what a file name may.
  printf '%s' "$1" | dav_md5
}

_dav_split_rename() {
  # _dav_split_rename <outdir> <ext> — give the numbered files of a split
  # their final names "<uid_name>.<ext>" from the .index the awk wrote. An
  # object without UID (only possible for a vCard) is named by its content.
  local dir="$1" ext="$2" n uid stem
  while IFS="$(printf '\t')" read -r n uid; do
    if [[ -n "$uid" ]]; then stem="$(uid_name "$uid")"
    else stem="$(dav_md5 "$dir/$n.$ext")"
    fi
    mv -f "$dir/$n.$ext" "$dir/$stem.$ext" || return 1
  done < "$dir/.index"
  rm -f "$dir/.index"
}

ics_split() {
  # ics_split <file> <outdir> — one VCALENDAR per UID in <outdir>, named
  # "<uid_name>.ics", each carrying the calendar's VERSION/PRODID/CALSCALE and
  # exactly the VTIMEZONE blocks its TZIDs reference. Lines end in CRLF.
  # Prints the number of objects; fails (writing nothing useful) for a file
  # that ics_stats does not call sound.
  local file="$1" dir="$2" n
  mkdir -p "$dir" || return 1
  n="$(awk -v MODE=split -v OUT="$dir" "$_DAV_ICS_AWK" "$file")" || return 1
  _dav_split_rename "$dir" ics || return 1
  printf '%s\n' "$n"
}

vcf_split() {
  # vcf_split <file> <outdir> — one VCARD per file in <outdir>, named
  # "<uid_name>.vcf". Lines end in CRLF. Prints the number of cards.
  local file="$1" dir="$2" n
  mkdir -p "$dir" || return 1
  n="$(awk -v MODE=split -v OUT="$dir" "$_DAV_VCF_AWK" "$file")" || return 1
  _dav_split_rename "$dir" vcf || return 1
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------
# The manifest (interface)
#
# manifest.tsv in every account's staging directory, one line per collection,
# tab-separated, after a "#" header line:
#
#   kind  uri  displayname  server_count  objects  vevents  vtodos  cards  bytes
#
# kind is "calendar" or "addressbook". objects is the number the checks and the
# trend guard compare: UIDs for a calendar, cards for an address book. An empty
# displayname is "-". The standby, the restore test and the trend guard read
# it; treat the columns as an interface, like the marker keys.
# ---------------------------------------------------------------------------

manifest_header() {
  printf '# kind\turi\tdisplayname\tserver_count\tobjects\tvevents\tvtodos\tcards\tbytes\n'
}

manifest_row() {
  # manifest_row <kind> <uri> <displayname> <server_count> <objects> <vevents>
  #              <vtodos> <cards> <bytes>
  local dn="$3"
  dn="$(printf '%s' "$dn" | tr '\t\r\n' '   ')"
  [[ -n "$dn" ]] || dn="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$dn" "$4" "$5" "$6" "$7" "$8" "$9"
}

manifest_rows() {
  # manifest_rows <manifest> — the data lines, without header and blank lines.
  awk -F '\t' '/^#/ || NF == 0 { next } { print }' "$1"
}

manifest_compare() {
  # manifest_compare <old> <new> <max-shrink-percent>
  #
  # The trend guard. Compares each collection of <old> with the same
  # collection (kind + uri) in <new> and prints one tab-separated line per
  # problem:
  #
  #   shrunk  <kind>  <uri>  <old objects>  <new objects>
  #   gone    <kind>  <uri>  <old objects>  0
  #
  # "shrunk" means the object count dropped by MORE than the percentage;
  # "gone" is a collection that held objects and is missing from <new>
  # altogether (an empty one that disappears costs nothing). Returns 1 if it
  # printed anything, 0 otherwise. Integer arithmetic only: new*100 <
  # old*(100-pct).
  awk -F '\t' -v PCT="$3" '
    /^#/ || NF == 0 { next }
    FNR == NR { k = $1 SUBSEP $2; old[k] = $5 + 0; ord[++n] = k; okind[k] = $1; ouri[k] = $2; next }
    { new[$1 SUBSEP $2] = $5 + 0 }
    END {
      for (i = 1; i <= n; i++) {
        k = ord[i]
        if (!(k in new)) {
          if (old[k] > 0) { printf "gone\t%s\t%s\t%d\t0\n", okind[k], ouri[k], old[k]; bad = 1 }
        } else if (new[k] * 100 < old[k] * (100 - PCT)) {
          printf "shrunk\t%s\t%s\t%d\t%d\n", okind[k], ouri[k], old[k], new[k]; bad = 1
        }
      }
      exit (bad ? 1 : 0)
    }
  ' "$1" "$2"
}
