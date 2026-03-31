---
model: haiku
description: Interactive cleanup of stale worktrees (merged branches, orphaned refs)
---

# Clean Worktree (Interactive)

Interactive cleanup of worktrees: lists merged/stale branches and asks confirmation before deleting.

**Difference with `/clean-worktrees`**:
- `/clean-worktree`: Interactive, asks confirmation
- `/clean-worktrees`: Automatic, no interaction

## Usage

```bash
/clean-worktree    # Interactive audit + cleanup
```

## Implementation

Execute this script:

```bash
#!/bin/bash
set -euo pipefail

detect_default_branch() {
  if remote_head=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
    printf '%s\n' "${remote_head#origin/}"
  elif git show-ref --verify --quiet refs/heads/main; then
    printf 'main\n'
  elif git show-ref --verify --quiet refs/heads/master; then
    printf 'master\n'
  else
    git branch --show-current
  fi
}

resolve_branch_ref() {
  local branch="$1"
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    printf '%s\n' "$branch"
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf 'origin/%s\n' "$branch"
  else
    printf '%s\n' "$branch"
  fi
}

list_branch_worktrees() {
  git worktree list --porcelain | awk '
    $1 == "worktree" { path = substr($0, 10) }
    $1 == "branch" {
      branch = $2
      sub(/^refs\/heads\//, "", branch)
      print branch "\t" path
    }
  '
}

is_protected_branch() {
  [ "$1" = "$DEFAULT_BRANCH" ] || [ "$1" = "main" ] || [ "$1" = "master" ]
}

safe_remove_worktree() {
  local path="$1"
  if git worktree remove "$path" 2>/dev/null; then
    return 0
  fi
  git worktree remove --force "$path" 2>/dev/null
}

DEFAULT_BRANCH="$(detect_default_branch)"
DEFAULT_BRANCH_REF="$(resolve_branch_ref "$DEFAULT_BRANCH")"

echo "=== Worktrees Status ==="
git worktree list
echo ""

echo "=== Pruning stale references ==="
git worktree prune
echo ""

echo "=== Merged branches (safe to delete) ==="
MERGED_FOUND=false
CURRENT_DIR="$(git rev-parse --show-toplevel)"
echo "Default branch: $DEFAULT_BRANCH"

while IFS=$'\t' read -r branch path; do
  [ -z "$branch" ] && continue
  is_protected_branch "$branch" && continue
  [ "$path" = "$CURRENT_DIR" ] && continue

  if git merge-base --is-ancestor "$branch" "$DEFAULT_BRANCH_REF" 2>/dev/null; then
    echo "  - $branch (at $path) - MERGED"
    MERGED_FOUND=true
  fi
done < <(list_branch_worktrees)

if [ "$MERGED_FOUND" = false ]; then
  echo "  (none found)"
  echo ""
  echo "=== Disk usage ==="
  du -sh .worktrees/ 2>/dev/null || echo "No .worktrees directory"
  exit 0
fi
echo ""

echo "=== Clean merged worktrees? [y/N] ==="
read -r confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
  while IFS=$'\t' read -r branch path; do
    [ -z "$branch" ] && continue
    is_protected_branch "$branch" && continue
    [ "$path" = "$CURRENT_DIR" ] && continue

    if git merge-base --is-ancestor "$branch" "$DEFAULT_BRANCH_REF" 2>/dev/null; then
      echo "  Removing $branch..."
      if safe_remove_worktree "$path"; then
        git branch -d "$branch" 2>/dev/null || echo "    (branch already deleted)"
      else
        echo "    (safe removal failed, manual intervention required)"
      fi
      echo "  Done: $branch"
    fi
  done < <(list_branch_worktrees)
  echo ""
  echo "Cleanup complete."
else
  echo "Aborted."
fi

echo ""
echo "=== Disk usage ==="
du -sh .worktrees/ 2>/dev/null || echo "No .worktrees directory"
```

## Safety

- Never removes the detected default branch or the current worktree
- Only removes branches merged into the detected default branch
- Asks confirmation before any deletion
- Cleans both git reference and physical directory

## Manual Force Remove (unmerged branch)

```bash
git worktree remove --force .worktrees/feature-name
git branch -D feature/name
git worktree prune
```
