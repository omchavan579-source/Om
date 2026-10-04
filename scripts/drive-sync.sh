#!/usr/bin/env bash
#
# drive-sync.sh — sync between Google Drive and this repository.
#
#   --mode=two-way   Two-way sync (rclone bisync). Changes on either side
#                    propagate to the other, deletions and renames included.
#   --mode=pull      One-way: Google Drive  ->  repo. Nothing is ever deleted
#                    from the repo, so it cannot destroy your work.
#   --mode=push      One-way: repo  ->  Google Drive.
#
#   --resync         Re-baseline two-way sync. Used for the FIRST two-way run,
#                    after editing .drivesync-ignore, or to recover when bisync
#                    asks for it. Copies files, never deletes them.
#   --dry-run        Show what would happen. Changes nothing. Always safe.
#
# Environment overrides (all optional):
#   DRIVE_REMOTE             rclone remote name            (default: gdrive)
#   DRIVE_PATH               sub-folder inside Drive       (default: repo root)
#   DRIVE_MAX_SIZE           per-file limit                (default: 45MiB)
#   DRIVE_MAX_DELETE_PERCENT safety brake on mass deletion (default: 10)
#   DRIVE_CONFLICT_RESOLVE   none|newer|older|larger|smaller|path1|path2
#   DRIVE_RESYNC_MODE        newer|older|larger|smaller|path1|path2
#   DRIVE_FORCE              true = bypass the mass-deletion brake (default: false)
#   DRIVE_SKIP_GDOCS         skip Google Docs/Sheets/Slides (default: true)
#   BISYNC_WORKDIR           where bisync keeps its state  (default: ~/.cache/rclone/bisync)
#   REPO_SYNC_ROOT           local folder to sync          (default: repo root)
#
# Needs rclone 1.66 or newer (the workflow installs the latest release).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '%s  ✓ %s%s\n' "$G" "$*" "$N"; }
warn() { printf '%s  ! %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%sERROR: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

: "${DRIVE_REMOTE:=gdrive}"
: "${DRIVE_PATH:=}"
: "${DRIVE_MAX_SIZE:=45MiB}"
: "${DRIVE_MAX_DELETE_PERCENT:=10}"
: "${DRIVE_CONFLICT_RESOLVE:=none}"
: "${DRIVE_RESYNC_MODE:=newer}"
: "${DRIVE_FORCE:=false}"
: "${DRIVE_SKIP_GDOCS:=true}"
: "${BISYNC_WORKDIR:=$HOME/.cache/rclone/bisync}"
: "${REPO_SYNC_ROOT:=$DEFAULT_ROOT}"

MODE="two-way"
RESYNC=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --mode=*)   MODE="${1#*=}" ;;
    --mode)     MODE="${2:-}"; shift ;;
    --resync)   RESYNC=true ;;
    --dry-run)  DRY_RUN=true ;;
    --remote=*) DRIVE_REMOTE="${1#*=}" ;;
    --path=*)   DRIVE_PATH="${1#*=}" ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "unknown argument '$1' (try --help)" ;;
  esac
  shift
done

case "$MODE" in
  two-way|bidirectional|bisync) MODE="two-way" ;;
  pull|drive-to-github)         MODE="pull" ;;
  push|github-to-drive)         MODE="push" ;;
  *) die "invalid --mode '$MODE' (expected two-way, pull or push)" ;;
esac

command -v rclone >/dev/null 2>&1 || die "rclone is not installed. See https://rclone.org/install/"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
LOCAL_PATH="$REPO_SYNC_ROOT/"
REMOTE_SPEC="$DRIVE_REMOTE:"
[ -n "$DRIVE_PATH" ] && REMOTE_SPEC="$DRIVE_REMOTE:$DRIVE_PATH"

[ -d "$REPO_SYNC_ROOT" ] || die "local folder '$REPO_SYNC_ROOT' does not exist"
mkdir -p "$BISYNC_WORKDIR"

FILTERS_SRC="$REPO_SYNC_ROOT/.drivesync-ignore"
FILTERS_WORK="$BISYNC_WORKDIR/filters.txt"
BISYNC_LOG="$BISYNC_WORKDIR/last-run.log"

step "Mode      : $MODE"
step "Local     : $LOCAL_PATH"
step "Drive     : $REMOTE_SPEC"
step "Max size  : $DRIVE_MAX_SIZE per file"
[ "$DRY_RUN" = true ] && step "Dry run   : yes — nothing will be written"

# ---------------------------------------------------------------------------
# Pre-flight: make sure the Drive side is reachable, so a typo in DRIVE_PATH
# gives a clear message instead of a mystery mid-sync failure.
# ---------------------------------------------------------------------------
if ! rclone lsf "$REMOTE_SPEC" --max-depth 1 >/dev/null 2>&1; then
  die "cannot read '$REMOTE_SPEC'.
     Check that the credential is valid, that DRIVE_REMOTE/DRIVE_PATH are spelled
     correctly, and that the folder already exists in Google Drive.
     Create it with:  rclone mkdir '$REMOTE_SPEC'"
fi

# ---------------------------------------------------------------------------
# Shared rclone flags
# ---------------------------------------------------------------------------
RCLONE_FLAGS=(
  --max-size "$DRIVE_MAX_SIZE"
  --drive-pacer-min-sleep 10ms          # be polite to Google's API
  --transfers 8
  --checkers 16
  --stats 30s
  --stats-one-line
  --log-level INFO
  -v
  # Non-negotiable safety: Git's internals must never leave this machine.
  # Everything else the sync hides lives in .drivesync-ignore, in plain sight.
  --exclude '/.git/**'
)

if [ -f "$FILTERS_SRC" ]; then
  ok "Using filters from $(basename "$FILTERS_SRC")"
else
  warn "No .drivesync-ignore found — nothing is excluded except /.git/**"
fi

if [ "$DRIVE_SKIP_GDOCS" = true ]; then
  # Google Docs/Sheets/Slides have no downloadable bytes: they arrive as
  # .docx/.xlsx/.pptx exports, and an edit to such an export cannot be pushed
  # back into the original Doc. rclone's own Drive bisync recipe skips them.
  RCLONE_FLAGS+=(--drive-skip-gdocs)
  ok "Google Docs/Sheets/Slides are skipped (set DRIVE_SKIP_GDOCS=false to include their exports)"
fi
[ "$DRY_RUN" = true ] && RCLONE_FLAGS+=(--dry-run)

# ---------------------------------------------------------------------------
# One-way modes: plain rclone copy. It only ever adds/updates the destination.
# ---------------------------------------------------------------------------
case "$MODE" in
  pull)
    step "Pulling Google Drive -> repo (adds/updates only; never deletes)"
    COPY_FLAGS=("${RCLONE_FLAGS[@]}")
    [ -f "$FILTERS_SRC" ] && COPY_FLAGS+=(--filter-from "$FILTERS_SRC")
    rclone copy "$REMOTE_SPEC" "$LOCAL_PATH" --checksum "${COPY_FLAGS[@]}" || die "pull failed"
    ok "Pull finished"
    ;;

  push)
    step "Pushing repo -> Google Drive (adds/updates only; never deletes)"
    COPY_FLAGS=("${RCLONE_FLAGS[@]}")
    [ -f "$FILTERS_SRC" ] && COPY_FLAGS+=(--filter-from "$FILTERS_SRC")
    rclone copy "$LOCAL_PATH" "$REMOTE_SPEC" --checksum "${COPY_FLAGS[@]}" || die "push failed"
    ok "Push finished"
    ;;

  two-way)
    step "Two-way sync (rclone bisync)"

    FIRST_RUN_MARKER="$BISYNC_WORKDIR/.first-run-done"
    if [ "$RESYNC" = false ] && [ ! -f "$FIRST_RUN_MARKER" ]; then
      warn "No previous sync state found — enabling --resync so both sides get baselined."
      RESYNC=true
    fi

    BISYNC_FLAGS=(
      --workdir "$BISYNC_WORKDIR"
      # Trust checksums, not timestamps. A fresh `git checkout` gives every file
      # a brand-new mtime, so modtime alone would look like "everything changed".
      --compare size,modtime,checksum
      --slow-hash-sync-only
      --resilient                          # retry instead of demanding --resync
      --recover                            # survive a killed/timed-out runner
      --max-lock 2m                        # ignore stale locks left by dead runs
      --max-delete "$DRIVE_MAX_DELETE_PERCENT"
      --conflict-loser num
      --resync-mode "$DRIVE_RESYNC_MODE"
      --create-empty-src-dirs
    )

    # bisync keeps its own copy of the filters file AND an md5 of it, side by
    # side. Living in the cached workdir means the md5 survives between runs,
    # and editing .drivesync-ignore still forces the resync rclone insists on.
    if [ -f "$FILTERS_SRC" ]; then
      cp -f "$FILTERS_SRC" "$FILTERS_WORK"
      BISYNC_FLAGS+=(--filters-file "$FILTERS_WORK")
    fi

    [ "$DRIVE_FORCE" = true ] && BISYNC_FLAGS+=(--force) && \
      warn "DRIVE_FORCE=true: the mass-deletion safety brake is OFF for this run."

    if [ "$DRIVE_CONFLICT_RESOLVE" != "none" ]; then
      BISYNC_FLAGS+=(--conflict-resolve "$DRIVE_CONFLICT_RESOLVE")
      ok "Conflicts auto-resolve in favour of the '$DRIVE_CONFLICT_RESOLVE' copy"
    else
      ok "Conflicts keep BOTH copies (e.g. notes.md.conflict1 / .conflict2)"
    fi

    [ "$RESYNC" = true ] && BISYNC_FLAGS+=(--resync) && \
      warn "--resync: anything present on only one side is copied to the other.

     It only ever copies — nothing is deleted — and where a file differs on
     both sides the '$DRIVE_RESYNC_MODE' copy wins (default: the newer one).
     Use --dry-run first if you want to see the plan."

    run_bisync() {
      rclone bisync "$LOCAL_PATH" "$REMOTE_SPEC" "${BISYNC_FLAGS[@]}" "${RCLONE_FLAGS[@]}"
    }

    if run_bisync 2>&1 | tee "$BISYNC_LOG"; then
      [ "$DRY_RUN" = false ] && touch "$FIRST_RUN_MARKER"
      ok "Two-way sync finished"
    elif [ "$RESYNC" = false ] && grep -qi "resync" "$BISYNC_LOG"; then
      # rclone refuses to change the set of files being compared without a
      # fresh baseline (someone edited .drivesync-ignore, the cache aged out,
      # or the previous run was interrupted). Resync only copies, so retrying
      # once here is safe — it cannot delete anything.
      warn "rclone wants a fresh baseline (filters changed, or sync state lost)."
      warn "Retrying once with --resync. Nothing will be deleted."
      BISYNC_FLAGS+=(--resync)
      if run_bisync 2>&1 | tee "$BISYNC_LOG"; then
        [ "$DRY_RUN" = false ] && touch "$FIRST_RUN_MARKER"
        ok "Two-way sync finished after an automatic resync"
      else
        warn "Full log: $BISYNC_LOG"
        die "bisync failed even after an automatic resync — read the log above."
      fi
    else
      warn "Full log: $BISYNC_LOG"
      die "bisync failed.
     If the log says a resync is required, re-run this workflow with the
     'resync' box ticked. If it says too many files would be deleted, that is
     the safety brake doing its job — review the log, then set the DRIVE_FORCE
     repository variable to 'true' for one run."
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Report what changed locally (the workflow uses this to decide what to commit)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = false ] && command -v git >/dev/null 2>&1 && \
   git -C "$REPO_SYNC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo
  step "Local changes after sync:"
  git -C "$REPO_SYNC_ROOT" status --short | head -50 || true
  CHANGED=$(git -C "$REPO_SYNC_ROOT" status --porcelain | wc -l | tr -d ' ')
  ok "$CHANGED file(s) added/changed/removed"
fi
