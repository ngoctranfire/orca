#!/bin/bash
# Rebase our fork's branches onto stablyai/orca main and push them to our fork.
#
# Runs daily from launchd (see install.sh). Safe by default:
#   - a branch checked out with uncommitted changes is skipped, never touched
#   - a rebase that conflicts is aborted, so the branch stays as it was
#   - pushes use --force-with-lease, so they never clobber commits we don't have
# You get a macOS notification for anything that needs a human.
#
# Which branches: `git config --add spyhop.syncBranch <name>` (default: main).
# Manual run: .spyhop/sync-upstream.sh   (add --dry-run to only report)

set -uo pipefail

REPO="${SPYHOP_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"

# Run from a temp copy: this file is tracked, so the rebase below rewrites it mid-run.
if [[ -z "${SPYHOP_SYNC_COPY:-}" ]]; then
  copy=$(mktemp "${TMPDIR:-/tmp}/spyhop-sync-upstream.XXXXXX") && cp "$0" "$copy" || exit 1
  SPYHOP_SYNC_COPY="$copy" SPYHOP_REPO="$REPO" exec /bin/bash "$copy" "$@"
fi
rm -f "$SPYHOP_SYNC_COPY"
UPSTREAM_REMOTE=upstream
UPSTREAM_REF=upstream/main
FORK_REMOTE=origin
LOG_DIR="$HOME/Library/Logs/spyhop"
LOCK_DIR="${TMPDIR:-/tmp}/spyhop-sync-upstream.lock"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$LOG_DIR"
if [[ -t 1 ]]; then
  exec > >(tee -a "$LOG_DIR/sync-upstream.log") 2>&1
else
  exec >>"$LOG_DIR/sync-upstream.log" 2>&1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
notify() {
  log "NOTIFY: $1"
  /usr/bin/osascript -e "display notification \"${1//\"/\\\"}\" with title \"Spyhop upstream sync\"" >/dev/null 2>&1 || true
}
# Husky hooks need node_modules and can block automation; never run them here.
g() { git -c core.hooksPath=/dev/null "$@"; }

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  log "another sync is running; exiting"
  exit 0
fi
TEMP_WT=""
cleanup() {
  [[ -n "$TEMP_WT" ]] && g -C "$REPO" worktree remove --force "$TEMP_WT" >/dev/null 2>&1
  rmdir "$LOCK_DIR" 2>/dev/null
}
trap cleanup EXIT

log "=== sync start (repo: $REPO, dry-run: $DRY_RUN) ==="

if ! g -C "$REPO" fetch --quiet "$UPSTREAM_REMOTE" || ! g -C "$REPO" fetch --quiet --prune "$FORK_REMOTE"; then
  notify "Fetch failed (offline?). Will retry tomorrow."
  exit 1
fi
log "upstream main is $(g -C "$REPO" rev-parse --short "$UPSTREAM_REF")"

# Print the worktree path where a branch is checked out, if any.
worktree_for() {
  g -C "$REPO" worktree list --porcelain | awk -v ref="refs/heads/$1" '
    /^worktree / { wt = substr($0, 10) }
    $0 == "branch " ref { print wt; exit }'
}

in_progress() {
  local gitdir
  gitdir=$(g -C "$1" rev-parse --absolute-git-dir)
  [[ -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" || -f "$gitdir/MERGE_HEAD" || -f "$gitdir/CHERRY_PICK_HEAD" ]]
}

BRANCHES=$(g -C "$REPO" config --get-all spyhop.syncBranch || echo main)
FAILED=()
UPDATED=()

for branch in $BRANCHES; do
  if ! g -C "$REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    log "[$branch] no such local branch; skipping"
    continue
  fi

  behind=$(g -C "$REPO" rev-list --count "$branch..$UPSTREAM_REF")
  if [[ "$behind" == 0 ]]; then
    log "[$branch] already on top of upstream"
  elif (( DRY_RUN )); then
    log "[$branch] would rebase onto $behind new upstream commit(s)"
    continue
  else
    wt=$(worktree_for "$branch")
    TEMP_WT=""
    if [[ -n "$wt" ]]; then
      if in_progress "$wt"; then
        FAILED+=("$branch"); notify "$branch: skipped, a rebase/merge is already in progress in $wt"; continue
      fi
      if [[ -n "$(g -C "$wt" status --porcelain --untracked-files=no)" ]]; then
        FAILED+=("$branch"); notify "$branch: skipped, uncommitted changes in $wt"; continue
      fi
    else
      TEMP_WT=$(mktemp -d "${TMPDIR:-/tmp}/spyhop-sync.XXXXXX")
      rmdir "$TEMP_WT"
      if ! g -C "$REPO" worktree add --quiet "$TEMP_WT" "$branch"; then
        FAILED+=("$branch"); notify "$branch: could not create a temporary worktree"; TEMP_WT=""; continue
      fi
      wt="$TEMP_WT"
    fi

    before=$(g -C "$wt" rev-parse --short HEAD)
    if g -C "$wt" rebase --quiet "$UPSTREAM_REF"; then
      log "[$branch] rebased $before -> $(g -C "$wt" rev-parse --short HEAD) ($behind upstream commit(s))"
      UPDATED+=("$branch")
    else
      conflicts=$(g -C "$wt" diff --name-only --diff-filter=U | head -5 | tr '\n' ' ')
      g -C "$wt" rebase --abort
      log "[$branch] rebase conflict, aborted. Conflicting files: $conflicts"
      FAILED+=("$branch")
      notify "$branch: rebase conflicts with upstream ($conflicts). Branch left unchanged; rebase by hand."
    fi

    if [[ -n "$TEMP_WT" ]]; then
      g -C "$REPO" worktree remove --force "$TEMP_WT"; TEMP_WT=""
    fi
    [[ " ${FAILED[*]-} " == *" $branch "* ]] && continue
  fi

  # Push whenever the fork's copy differs (also covers a previous failed push).
  if [[ "$(g -C "$REPO" rev-parse "$branch")" != "$(g -C "$REPO" rev-parse --verify --quiet "$FORK_REMOTE/$branch")" ]]; then
    if g -C "$REPO" push --quiet --force-with-lease="$branch" "$FORK_REMOTE" "$branch"; then
      log "[$branch] pushed to $FORK_REMOTE"
    else
      FAILED+=("$branch"); notify "$branch: push to fork failed (it may have commits you don't have locally)"
    fi
  fi
done

if (( ${#FAILED[@]} )); then
  log "=== sync done with problems: ${FAILED[*]} ==="
  exit 1
fi
log "=== sync done (updated: ${UPDATED[*]:-none}) ==="
