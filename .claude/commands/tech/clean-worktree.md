---
model: haiku
description: Clean stale worktrees (interactive)
---

# Clean Worktree (Interactive)

Audit and clean obsolete worktrees interactively: merged, pruned, orphaned branches.

**vs `/tech:clean-worktrees`**:
- `/tech:clean-worktree`: Interactive, asks confirmation before deletion
- `/tech:clean-worktrees`: Automatic, no interaction (merged branches only)

## Usage

```bash
/tech:clean-worktree
```

## Implementation

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

echo "=== Worktrees Status ==="
git worktree list
echo ""

echo "=== Pruning stale references ==="
git worktree prune
echo ""

DEFAULT_BRANCH="$(detect_default_branch)"
DEFAULT_BRANCH_REF="$(resolve_branch_ref "$DEFAULT_BRANCH")"
CURRENT_DIR="$(git rev-parse --show-toplevel)"

echo "=== Merged branches (safe to delete) ==="
echo "Default branch: $DEFAULT_BRANCH"
while IFS= read -r line; do
    branch="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    [ -z "$branch" ] && continue
    is_protected_branch "$branch" && continue
    [ "$path" = "$CURRENT_DIR" ] && continue

    if git merge-base --is-ancestor "$branch" "$DEFAULT_BRANCH_REF" 2>/dev/null; then
        echo "  - $branch (at $path) - MERGED"
    fi
done < <(list_branch_worktrees)
echo ""

echo "=== Clean merged worktrees? [y/N] ==="
read -r confirm
if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    while IFS= read -r line; do
        branch="${line%%$'\t'*}"
        path="${line#*$'\t'}"
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
        fi
    done < <(list_branch_worktrees)
    echo "Done."
else
    echo "Aborted."
fi

echo ""
echo "=== Disk usage ==="
du -sh .worktrees/ 2>/dev/null || echo "No .worktrees directory"
```

## Safety

- **Never** removes the detected default branch or the current worktree
- **Only** removes branches merged into the detected default branch
- **Asks confirmation** before deletion
- Cleans both worktree reference AND physical directory

## Manual Override

Force remove an unmerged worktree:

```bash
git worktree remove --force <path>
git branch -D <branch_name>
```
