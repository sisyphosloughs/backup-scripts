#!/usr/bin/env bash
#
# run-tests.sh — offline tests of lib/dav-lib.sh. No framework, no network, no
# root, no host: each case runs one library function against a synthetic
# fixture in tests/fixtures/ and compares what it printed with the file of the
# same name in tests/expected/ (diff -u). One PASS/FAIL line per case; the
# exit code is the number of failures.
#
#   tests/run-tests.sh            run every case
#   tests/run-tests.sh --update   rewrite tests/expected/ from the current
#                                 output — then READ the diff before committing
#                                 it: an expected file nobody checked proves
#                                 nothing
#
# Runs under bash 3.2 (macOS /bin/bash) as well as bash 4.4 (ikaria), which is
# what tests the compatibility targets: run it with both.

# shellcheck disable=SC2329  # the case helpers below are called through check().
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$TESTS_DIR/fixtures"
EXP="$TESTS_DIR/expected"

UPDATE=0
case "${1:-}" in
  --update) UPDATE=1 ;;
  "") ;;
  *) echo "usage: $0 [--update]" >&2; exit 2 ;;
esac

# shellcheck source=lib/dav-lib.sh  # relative to the module dir, where shellcheck runs
source "$TESTS_DIR/../lib/dav-lib.sh"

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t davtests)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

FAILS=0
PASSES=0

check() {
  # check <case-name> <command...> — run the command (stdout and the exit
  # code, as "rc=N" on a last line, are the result) and compare with
  # expected/<case-name>.
  local name="$1" rc=0
  shift
  "$@" > "$WORK/actual" 2>"$WORK/stderr" || rc=$?
  printf 'rc=%d\n' "$rc" >> "$WORK/actual"
  if [[ "$UPDATE" -eq 1 ]]; then
    cp "$WORK/actual" "$EXP/$name"
    printf 'UPDATED %s\n' "$name"
    return 0
  fi
  if [[ ! -f "$EXP/$name" ]]; then
    printf 'FAIL    %s — no expected/%s (run with --update, then check it)\n' "$name" "$name"
    FAILS=$((FAILS + 1))
    return 0
  fi
  if diff -u "$EXP/$name" "$WORK/actual" > "$WORK/diff"; then
    printf 'PASS    %s\n' "$name"
    PASSES=$((PASSES + 1))
  else
    printf 'FAIL    %s\n' "$name"
    sed 's/^/        /' "$WORK/diff"
    [[ -s "$WORK/stderr" ]] && sed 's/^/        stderr: /' "$WORK/stderr"
    FAILS=$((FAILS + 1))
  fi
}

# --- helpers that turn a result into comparable text -------------------------

dump_dir() {
  # dump_dir <dir> — every file, sorted by name, with its content. CRs are
  # shown as a trailing "<CR>" so the line endings are part of the comparison
  # and the expected files stay readable.
  # Dot files too: a split must not leave its .index behind.
  local f
  for f in "$1"/* "$1"/.[!.]*; do
    [[ -e "$f" ]] || continue
    printf '=== %s\n' "${f##*/}"
    awk '{ if (sub(/\r$/, "")) print $0 "<CR>"; else print }' "$f"
  done
}

split_case() {
  # split_case <ics|vcf> <fixture> — split into a fresh dir and dump it.
  local kind="$1" fixture="$2" dir="$WORK/split.$RANDOM" n rc=0
  if [[ "$kind" == ics ]]; then
    n="$(ics_split "$FIX/$fixture" "$dir")" || rc=$?
  else
    n="$(vcf_split "$FIX/$fixture" "$dir")" || rc=$?
  fi
  printf 'objects=%s\n' "$n"
  [[ -d "$dir" ]] && dump_dir "$dir"
  return "$rc"
}

classify_case() {
  # classify_case <kind> <fixture> <include-shared> [pattern...] — the filter
  # rules of the export over every response of a recorded multistatus.
  local kind="$1" fixture="$2" shared="$3" href types dn uri reason
  shift 3
  while IFS="$(printf '\t')" read -r href types dn _; do
    uri="$(dav_href_uri "$href")"
    if reason="$(dav_skip_reason "$kind" "$uri" "$types" "$shared" "$@")"; then
      printf '%s\tskip\t%s\n' "$uri" "$reason"
    else
      printf '%s\tkeep\t%s\n' "$uri" "$dn"
    fi
  done < <(ms_responses "$FIX/$fixture")
}

uid_names() {
  # Stable, path-safe names for awkward UIDs; the same UID twice must give the
  # same name.
  local u
  for u in "simple" "with/slash@example.org" "with space" "urn:uuid:0b6f3d3c" "simple"; do
    printf '%s\t%s\n' "$(uid_name "$u")" "$u"
  done
}

url_parts() {
  local u
  for u in "https://example.your-storageshare.de/remote.php/dav" \
           "http://192.168.223.2:9976/dav.php" \
           "https://user@host.example:8443/" \
           "https://host.example"; do
    printf '%s | %s | %s | %s\n' "$u" "$(dav_url_origin "$u")" "$(dav_url_host "$u")" "$(dav_url_path "$u")"
  done
}

netrc_case() {
  local f="$WORK/test.netrc"
  printf 'machine a.example login u password p\nmachine\n  192.168.223.2\n  login u password q\n' > "$f"
  for h in a.example 192.168.223.2 b.example; do
    if netrc_has_machine "$f" "$h"; then printf '%s yes\n' "$h"; else printf '%s no\n' "$h"; fi
  done
}

private_case() {
  local f="$WORK/private.netrc"
  : > "$f"
  chmod 600 "$f"; if file_private "$f"; then echo "600 private"; else echo "600 open"; fi
  chmod 640 "$f"; if file_private "$f"; then echo "640 private"; else echo "640 open"; fi
  chmod 604 "$f"; if file_private "$f"; then echo "604 private"; else echo "604 open"; fi
  if file_private "$WORK"; then echo "dir private"; else echo "dir refused"; fi
}

plan_case() {
  # The sync plan of simple.ics against a recorded listing of a Baïkal
  # collection that holds it, after a client changed one object, deleted
  # another and added one under its own name: same, changed, new, delete.
  local dir="$WORK/plan.$RANDOM"
  ics_split "$FIX/simple.ics" "$dir" > /dev/null || return 1
  dav_sync_plan "$dir" "$FIX/propfind-standby.xml"
}

object_uid_case() {
  # The UID of each split object: the VEVENT's, not the VALARM's; the card's.
  local f dir="$WORK/uid.$RANDOM"
  ics_split "$FIX/valarm-uid.ics" "$dir/ics" > /dev/null || return 1
  vcf_split "$FIX/contacts.vcf" "$dir/vcf" > /dev/null || return 1
  for f in "$dir"/ics/* "$dir"/vcf/*; do
    printf '%s\t%s\n' "${f##*/}" "$(dav_object_uid "$f")"
  done
}

xml_escape_case() {
  printf '%s' 'Familie & Freunde <privat> "x"' | dav_xml_escape
  echo
}

manifest_case() {
  manifest_header
  manifest_row calendar personal "Name	with tab" 3 3 2 1 0 999
  manifest_row addressbook contacts "" 0 0 0 0 0 0
}

# --- the cases ---------------------------------------------------------------

for f in simple recurrence timezones folded valarm-uid truncated empty-calendar; do
  check "ics_stats.$f" ics_stats "$FIX/$f.ics"
done
check "ics_stats.error-page" ics_stats "$FIX/error-page.html"
check "vcf_stats.contacts" vcf_stats "$FIX/contacts.vcf"
check "vcf_stats.empty" vcf_stats "$FIX/empty.vcf"
check "vcf_stats.error-page" vcf_stats "$FIX/error-page.html"

check "ics_unfold.folded" ics_unfold "$FIX/folded.ics"

for f in simple recurrence timezones folded valarm-uid; do
  check "ics_split.$f" split_case ics "$f.ics"
done
check "ics_split.truncated" split_case ics truncated.ics
check "vcf_split.contacts" split_case vcf contacts.vcf

for f in nextcloud nextcloud-addressbooks baikal baikal-home prefixes; do
  check "ms_responses.$f" ms_responses "$FIX/propfind-$f.xml"
done
check "ms_member_count.baikal" ms_member_count "$FIX/propfind-baikal.xml"

check "classify.calendars" classify_case calendar propfind-nextcloud.xml 0
check "classify.calendars-shared-excluded" classify_case calendar propfind-nextcloud.xml 1 "old-*"
check "classify.addressbooks" classify_case addressbook propfind-nextcloud-addressbooks.xml 0

check "uid_name" uid_names
check "url_parts" url_parts
check "netrc_has_machine" netrc_case
check "file_private" private_case
check "manifest_row" manifest_case

check "dav_sync_plan.standby" plan_case
check "dav_object_uid" object_uid_case
check "dav_error_text.baikal-415" dav_error_text "$FIX/error-baikal-415.xml"
check "dav_error_text.empty" dav_error_text "$FIX/empty.vcf"
check "dav_xml_escape" xml_escape_case

check "manifest_compare.within" manifest_compare "$FIX/manifest-old.tsv" "$FIX/manifest-within.tsv" 20
check "manifest_compare.over" manifest_compare "$FIX/manifest-old.tsv" "$FIX/manifest-over.tsv" 20
check "manifest_compare.gone" manifest_compare "$FIX/manifest-old.tsv" "$FIX/manifest-gone.tsv" 20
check "manifest_compare.zero-percent" manifest_compare "$FIX/manifest-old.tsv" "$FIX/manifest-within.tsv" 0

if [[ "$UPDATE" -eq 1 ]]; then
  echo "expected/ rewritten — review it with git diff before committing"
  exit 0
fi
printf '%d passed, %d failed (bash %s)\n' "$PASSES" "$FAILS" "$BASH_VERSION"
exit "$FAILS"
