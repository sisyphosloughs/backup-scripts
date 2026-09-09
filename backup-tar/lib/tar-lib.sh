# shellcheck shell=bash
#
# tar-lib.sh — the archive helpers of backup-tar.sh: choosing a compressor,
# creating the archive, verifying it, writing its checksum and rotating old
# ones.
#
# This is NOT a standalone program: it is sourced by backup-tar.sh (and could be
# sourced by a per-path hook that wants the same helpers). It is the counterpart
# of backup-docker-db's lib/db-dump-lib.sh: everything generic about producing one
# archive lives here, while WHICH paths are archived stays in paths/<name>.conf.
#
# All helpers run INSIDE the per-path subshell of backup-tar.sh and read the
# per-path variables (SOURCE, DEST_DIR, EXCLUDES, …) by name at call time — the
# same contract db-dump-lib.sh has with its stack configurations.
#
# Log in the same format as runlib ("<ts> [LEVEL] msg"), but to STDERR and
# without touching the log file: the caller runs this in a subshell whose
# stdout+stderr are teed into the log in one place. STDERR on purpose —
# compressor_spec returns its result on stdout via a command substitution, so
# diagnostics must not pollute that channel. This bare log() is exactly what
# runlib deliberately does NOT define, so the two channels stay apart — see the
# header of runlib's log.sh.

log() {
  local level="$1"; shift
  printf '%s %-7s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "[${level}]" "$*" >&2
}

# The timestamp in every archive name. Sortable both chronologically and
# lexically — archive_rotate() relies on exactly that to find the newest
# archives without asking the filesystem for mtimes (see there).
_archive_ts() { date +%Y-%m-%dT%H-%M-%S; }

# ---------------------------------------------------------------------------
# Compression
# ---------------------------------------------------------------------------

compressor_spec() {
  # compressor_spec <mode> [level] [threads] — prints "<suffix>|<program>" for
  # tar's --use-compress-program, e.g. ".tar.gz|pigz -6 -p 4". An empty program
  # means "no compression" (mode=none).
  #
  # The parallel implementation is preferred when it is installed, because a tar
  # backup of a large tree is CPU-bound on the compressor, not on the disk:
  # gzip/bzip2 use one core no matter how many the host has. pigz/pbzip2 produce
  # ordinary .gz/.bz2 files, so nothing about restoring changes — "tar -xzf"
  # works either way, with or without pigz on the restoring host.
  #
  # Returns 1 (and logs) if the requested compressor is not installed. Callers
  # must not silently fall back to another format: the file name says .zst, so a
  # gzip stream in it would be a lie on disk.
  local mode="${1:-gz}" level="${2:-}" threads="${3:-0}"
  local lvl="" suffix=""
  local -a prog=()

  [[ -n "$level" ]] && lvl="-$level"

  case "$mode" in
    none|tar)
      printf '.tar|'
      return 0
      ;;
    gz|gzip)
      suffix=".tar.gz"
      if command -v pigz >/dev/null 2>&1; then
        prog=(pigz)
        [[ -n "$lvl" ]] && prog+=("$lvl")
        # pigz without -p already uses every core; only a deliberate limit is
        # worth passing on.
        [[ "$threads" != "0" ]] && prog+=(-p "$threads")
      elif command -v gzip >/dev/null 2>&1; then
        prog=(gzip)
        [[ -n "$lvl" ]] && prog+=("$lvl")
      else
        log ERROR "COMPRESSION=gz, but neither pigz nor gzip is installed"
        return 1
      fi
      ;;
    zst|zstd)
      suffix=".tar.zst"
      if ! command -v zstd >/dev/null 2>&1; then
        log ERROR "COMPRESSION=zst, but zstd is not installed"
        return 1
      fi
      prog=(zstd)
      [[ -n "$lvl" ]] && prog+=("$lvl")
      # -T0 = every core. zstd is single-threaded without it.
      prog+=("-T${threads}")
      ;;
    xz)
      suffix=".tar.xz"
      if ! command -v xz >/dev/null 2>&1; then
        log ERROR "COMPRESSION=xz, but xz is not installed"
        return 1
      fi
      prog=(xz)
      [[ -n "$lvl" ]] && prog+=("$lvl")
      prog+=("-T${threads}")
      ;;
    bz2|bzip2)
      suffix=".tar.bz2"
      if command -v pbzip2 >/dev/null 2>&1; then
        prog=(pbzip2)
        [[ -n "$lvl" ]] && prog+=("$lvl")
        [[ "$threads" != "0" ]] && prog+=(-p"$threads")
      elif command -v bzip2 >/dev/null 2>&1; then
        prog=(bzip2)
        [[ -n "$lvl" ]] && prog+=("$lvl")
      else
        log ERROR "COMPRESSION=bz2, but neither pbzip2 nor bzip2 is installed"
        return 1
      fi
      ;;
    *)
      log ERROR "unknown COMPRESSION '$mode' (gz|zst|xz|bz2|none)"
      return 1
      ;;
  esac

  printf '%s|%s' "$suffix" "${prog[*]}"
  return 0
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

archive_rotate() {
  # archive_rotate <dir> <name> <days> <keep_min> — delete this path's archives
  # older than <days>, but never go below <keep_min> archives.
  #
  # KEEP_MIN is the part that a plain "find -mtime +N -delete" gets wrong: a
  # source that has not changed for months would have all its archives expire on
  # the same day and leave the path with no backup at all. The newest <keep_min>
  # archives are therefore protected regardless of age.
  #
  # "Newest" is decided by the timestamp IN THE FILE NAME (%Y-%m-%dT%H-%M-%S),
  # which sorts lexically exactly as it sorts chronologically. That avoids
  # GNU-only "find -printf '%T@'" (this also has to work on a busybox host) and
  # it survives a copy that did not preserve mtimes.
  local dir="$1" name="$2" days="$3" keep_min="$4"
  local f idx=0 removed=0
  local -a archives=()

  [[ -d "$dir" ]] || return 0

  while IFS= read -r f; do
    [[ -n "$f" ]] && archives+=("$f")
  done < <(find "$dir" -type f -name "${name}-*.tar*" \
             ! -name '*.sha256' ! -name '*.part' 2>/dev/null | sort -r)

  for f in "${archives[@]+"${archives[@]}"}"; do
    idx=$((idx + 1))
    [[ "$idx" -le "$keep_min" ]] && continue
    # POSIX find on the single file: prints it only if it is older than <days>.
    [[ -n "$(find "$f" -type f -mtime +"$days" -print 2>/dev/null)" ]] || continue
    rm -f "$f" "$f.sha256"
    removed=$((removed + 1))
  done

  # Leftovers of an aborted run (see create_archive: the archive is written to
  # "<final>.part" and only then moved into place). A .part file that survived a
  # day belongs to a run that is long dead.
  find "$dir" -type f -name "${name}-*.part" -mtime +0 -delete 2>/dev/null

  if [[ "$removed" -gt 0 ]]; then
    log INFO "${name}: removed $removed archive(s) older than ${days} days in $dir (keeping at least ${keep_min})"
  else
    log INFO "${name}: nothing to rotate in $dir (retention ${days} days, keep at least ${keep_min})"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Free space
# ---------------------------------------------------------------------------

free_space_mb() {
  # free_space_mb <dir> — free megabytes on <dir>'s filesystem, or "" if that
  # cannot be determined (then the caller skips the check instead of refusing to
  # work).
  local dir="$1" out
  out="$(LC_ALL=C df -Pm "$dir" 2>/dev/null | awk 'NR==2 { print $4 }')" || return 1
  [[ "$out" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# The archive itself
# ---------------------------------------------------------------------------

# shellcheck disable=SC2034  # ARCHIVE_PATH is the return channel to
# backup-tar.sh (verify_archive/write_checksum are called on it there), not a
# local of this function.
create_archive() {
  # create_archive <name> — archive $SOURCE into $DEST_DIR. Every other input is
  # read from the per-path variables at call time (COMPRESSION, EXCLUDES, …),
  # because they are what paths/<name>.conf sets.
  #
  # Prints nothing on stdout; the resulting path is reported through
  # ARCHIVE_PATH so the caller can verify/checksum it.
  local name="$1"
  local src parent base spec suffix prog final tmp rc free_mb
  local -a tar_cmd=() opts=()

  ARCHIVE_PATH=""

  src="${SOURCE%/}"
  if [[ -z "$src" ]]; then
    log ERROR "${name}: SOURCE is empty"
    return 1
  fi
  if [[ ! -e "$src" ]]; then
    log ERROR "${name}: source does not exist: $src"
    return 1
  fi
  if [[ ! -r "$src" ]]; then
    log ERROR "${name}: source is not readable: $src"
    return 1
  fi

  # The archive stores paths RELATIVE to the source's parent ("-C <parent>
  # <base>"), so it unpacks into "<base>/…" anywhere instead of insisting on the
  # absolute path it came from. That is what makes a restore into a staging
  # directory possible at all — and why "/" cannot be handled here.
  parent="$(dirname "$src")"
  base="$(basename "$src")"
  if [[ "$src" == "/" || -z "$base" || "$base" == "/" ]]; then
    log ERROR "${name}: SOURCE=\"/\" is not supported — configure the directories below it instead"
    return 1
  fi

  spec="$(compressor_spec "$COMPRESSION" "$COMPRESSION_LEVEL" "$COMPRESSION_THREADS")" || return 1
  suffix="${spec%%|*}"
  prog="${spec#*|}"

  final="${DEST_DIR%/}/${name}-$(_archive_ts)${suffix}"
  # Written under ".part" and moved into place only after tar succeeded: an
  # interrupted run (disk full, reboot, SIGKILL) must never leave something
  # behind that looks like a finished archive. The move is a rename within the
  # same directory, so it is atomic.
  tmp="${final}.part"

  if [[ "$MIN_FREE_MB" -gt 0 ]]; then
    if free_mb="$(free_space_mb "$DEST_DIR")"; then
      if [[ "$free_mb" -lt "$MIN_FREE_MB" ]]; then
        log ERROR "${name}: only ${free_mb} MB free in $DEST_DIR, MIN_FREE_MB=${MIN_FREE_MB} — no archive written"
        return 1
      fi
    else
      log WARN "${name}: free space of $DEST_DIR could not be determined — MIN_FREE_MB not checked"
    fi
  fi

  # --- tar options ---------------------------------------------------------
  opts=(--create --file "$tmp")
  [[ -n "$prog" ]] && opts+=(--use-compress-program "$prog")

  # Excludes are matched against the stored (relative) names, i.e. against
  # "<base>/…" — the same thing the user sees in "tar -tf".
  local pattern
  for pattern in "${EXCLUDES[@]+"${EXCLUDES[@]}"}"; do
    [[ -n "$pattern" ]] && opts+=(--exclude="$pattern")
  done
  if [[ -n "$EXCLUDE_FROM" ]]; then
    if [[ -r "$EXCLUDE_FROM" ]]; then
      opts+=(--exclude-from="$EXCLUDE_FROM")
    else
      log ERROR "${name}: EXCLUDE_FROM is not readable: $EXCLUDE_FROM"
      return 1
    fi
  fi
  # Directories tagged by CACHEDIR.TAG (thumbnail caches, build caches, …). They
  # are regenerated on use, so archiving them only costs space.
  is_truthy "$EXCLUDE_CACHES" && opts+=(--exclude-caches)
  is_truthy "$EXCLUDE_VCS"    && opts+=(--exclude-vcs)
  # Do not descend into other filesystems: without it a bind mount or an NFS
  # share below the source silently ends up in the archive.
  is_truthy "$ONE_FILE_SYSTEM" && opts+=(--one-file-system)
  # Store holes instead of the zeroes in them — cheap for VM images and sparse
  # database files, a measurable slowdown for everything else, hence optional.
  is_truthy "$SPARSE" && opts+=(--sparse)
  # Whatever the configuration still wants: --acls, --xattrs, --numeric-owner, …
  opts+=("${TAR_EXTRA_OPTS[@]+"${TAR_EXTRA_OPTS[@]}"}")
  opts+=(--directory "$parent" -- "$base")

  # nice/ionice keep a nightly multi-gigabyte archive from starving whatever
  # else the host is doing. Both are optional: a container host may not have
  # ionice, and a missing one must not fail the backup.
  tar_cmd=()
  if [[ "$NICE_LEVEL" != "0" ]] && command -v nice >/dev/null 2>&1; then
    tar_cmd+=(nice -n "$NICE_LEVEL")
  fi
  if [[ -n "$IONICE_CLASS" ]] && command -v ionice >/dev/null 2>&1; then
    tar_cmd+=(ionice -c "$IONICE_CLASS")
  fi
  tar_cmd+=("$TAR_BIN")

  log INFO "${name}: archiving $src -> $final"

  # cmd_run logs the argument vector it then executes — one call, so the logged
  # line cannot drift from the real one. It logged "${TAR_BIN} ${opts[*]}" here
  # before, which omitted the nice/ionice prefixes and lost every quote.
  # shellcheck disable=SC2034  # read by cmd_run through dynamic scoping
  local CMD_PREFIX="${name}: "
  cmd_run "${tar_cmd[@]}" "${opts[@]}"
  rc=$?

  # tar's exit codes are not a simple ok/failed:
  #   0  everything archived
  #   1  "some files differ" — files changed WHILE they were read. On a live
  #      system that is normal (a log file grew, a temp file vanished); the
  #      archive is complete and readable, those entries are just a snapshot of
  #      a moving target. A warning, not a failed backup — otherwise every
  #      nightly run of a busy host would report a failure.
  #   2+ fatal: the archive is unusable.
  if [[ "$rc" -eq 1 ]]; then
    log WARN "${name}: tar reported changed files during the run (exit 1) — the archive was written, single files may be inconsistent"
    rc=0
  elif [[ "$rc" -ne 0 ]]; then
    log ERROR "${name}: tar failed (exit $rc) — no archive written"
    rm -f "$tmp"
    return 1
  fi

  if [[ ! -s "$tmp" ]]; then
    log ERROR "${name}: tar produced an empty file — discarded"
    rm -f "$tmp"
    return 1
  fi

  if ! mv -f "$tmp" "$final"; then
    log ERROR "${name}: archive could not be moved into place: $final"
    rm -f "$tmp"
    return 1
  fi

  ARCHIVE_PATH="$final"
  log INFO "${name}: archive written: $final ($(human_bytes "$(wc -c < "$final" 2>/dev/null || echo 0)"))"
  return 0
}

verify_archive() {
  # verify_archive <name> <archive> — read the archive back completely and list
  # its contents. This decompresses everything, so it costs roughly the read
  # half of the backup again — and it is the only thing that proves the archive
  # can be read at all, which is the one property a backup must have. A file
  # that fails here is deleted: an unreadable archive that stays on disk looks
  # like a backup and is not one.
  local name="$1" archive="$2" rc
  log INFO "${name}: verifying $archive"
  # ">/dev/null" applies to tar's listing, not to the logged line: cmd_run
  # writes to stderr only, exactly so that a caller's redirection keeps
  # belonging to the payload.
  # shellcheck disable=SC2034  # read by cmd_run through dynamic scoping
  local CMD_PREFIX="${name}: "
  cmd_run "$TAR_BIN" --list --file "$archive" >/dev/null
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    log ERROR "${name}: archive is not readable (tar --list exit $rc) — deleting $archive"
    rm -f "$archive"
    return 1
  fi
  log INFO "${name}: archive verified"
  return 0
}

write_checksum() {
  # write_checksum <name> <archive> — "<archive>.sha256" next to the archive, in
  # sha256sum's own format and with the BARE file name in it, so a later
  # "cd <dir> && sha256sum -c <archive>.sha256" works no matter where the
  # directory has been moved or copied to in the meantime.
  local name="$1" archive="$2" dir base
  command -v sha256sum >/dev/null 2>&1 || {
    log WARN "${name}: sha256sum not found — no checksum written"
    return 0
  }
  dir="$(dirname "$archive")"
  base="$(basename "$archive")"
  if ! ( cd "$dir" && sha256sum "$base" > "${base}.sha256" ); then
    log ERROR "${name}: checksum could not be written for $archive"
    rm -f "${archive}.sha256"
    return 1
  fi
  log INFO "${name}: checksum written: ${archive}.sha256"
  return 0
}
