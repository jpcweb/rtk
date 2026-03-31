---
model: haiku
description: Auto-clean all stale worktrees (merged branches)
---

# Clean Worktrees (Automatic)

Automatically clean all stale worktrees: merged branches and orphaned git references.

**vs `/tech:clean-worktree`**:
- `/tech:clean-worktree`: Interactive, asks confirmation
- `/tech:clean-worktrees`: **Automatic**, no interaction (safe: merged only)

## Usage

```bash
/tech:clean-worktrees           # Clean all merged worktrees
/tech:clean-worktrees --dry-run # Preview what would be deleted
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

DRY_RUN=false
if [[ "${ARGUMENTS:-}" == *"--dry-run"* ]]; then
  DRY_RUN=true
fi

DEFAULT_BRANCH="$(detect_default_branch)"
DEFAULT_BRANCH_REF="$(resolve_branch_ref "$DEFAULT_BRANCH")"
CURRENT_DIR="$(git rev-parse --show-toplevel)"

echo "🧹 Cleaning Worktrees"
echo "====================="
echo ""
echo "Default branch: $DEFAULT_BRANCH"
echo ""

# Step 1: Prune stale git references
echo "1️⃣  Pruning stale git references..."
PRUNED=$(git worktree prune -v 2>&1)
if [ -n "$PRUNED" ]; then
  echo "$PRUNED"
  echo "✅ Stale references pruned"
else
  echo "✅ No stale references found"
fi
echo ""

# Step 2: Find merged worktrees
echo "2️⃣  Finding merged worktrees..."
MERGED_COUNT=0
MERGED_BRANCHES=()

while IFS=$'\t' read -r branch path; do
  [ -z "$branch" ] && continue
  is_protected_branch "$branch" && continue
  [ "$path" = "$CURRENT_DIR" ] && continue

  if git merge-base --is-ancestor "$branch" "$DEFAULT_BRANCH_REF" 2>/dev/null; then
    MERGED_COUNT=$((MERGED_COUNT + 1))
    MERGED_BRANCHES+=("$branch|$path")
    echo "  ✓ $branch (merged)"
  fi
done < <(list_branch_worktrees)

if [ $MERGED_COUNT -eq 0 ]; then
  echo "✅ No merged worktrees found"
  echo ""
  echo "📊 Current worktrees:"
  git worktree list
  exit 0
fi

echo ""
echo "📋 Found $MERGED_COUNT merged worktree(s)"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "🔍 DRY RUN MODE - No changes will be made"
  echo ""
  echo "Would delete:"
  for item in "${MERGED_BRANCHES[@]}"; do
    branch=$(echo "$item" | cut -d'|' -f1)
    path=$(echo "$item" | cut -d'|' -f2)
    echo "  - $branch"
    echo "    Path: $path"
  done
  echo ""
  echo "Run without --dry-run to actually delete"
  exit 0
fi

# Step 3: Remove merged worktrees
echo "3️⃣  Removing merged worktrees..."
REMOVED_COUNT=0
FAILED_COUNT=0

for item in "${MERGED_BRANCHES[@]}"; do
  branch=$(echo "$item" | cut -d'|' -f1)
  path=$(echo "$item" | cut -d'|' -f2)

  echo ""
  echo "🗑️  Removing: $branch"

  if safe_remove_worktree "$path"; then
    echo "  ✅ Worktree removed"
  else
    echo "  ❌ Safe removal failed"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  if git branch -d "$branch" 2>/dev/null; then
    echo "  ✅ Local branch deleted"
  else
    echo "  ⚠️  Local branch already deleted"
  fi

  if git ls-remote --heads origin "$branch" 2>/dev/null | grep -q "$branch"; then
    echo "  🌐 Remote branch exists: $branch"
    echo "     (Skipping auto-delete - use /tech:remove-worktree for manual removal)"
  fi

  REMOVED_COUNT=$((REMOVED_COUNT + 1))
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Cleanup Complete!"
echo ""
echo "📊 Summary:"
echo "  - Removed: $REMOVED_COUNT worktree(s)"
if [ $FAILED_COUNT -gt 0 ]; then
  echo "  - Failed: $FAILED_COUNT worktree(s)"
fi
echo ""
echo "📂 Remaining worktrees:"
git worktree list
echo ""

WORKTREES_SIZE=$(du -sh .worktrees/ 2>/dev/null | awk '{print $1}' || echo "N/A")
echo "💾 Worktrees disk usage: $WORKTREES_SIZE"
```

## Safety Features

- ✅ **Only merged branches**: Never touches unmerged work
- ✅ **Protected branches**: Skips the detected default branch and common aliases
- ✅ **Main repo**: Never removes current working directory
- ✅ **Remote branches**: Reports but doesn't auto-delete
- ✅ **Dry-run mode**: Preview before deletion
- ✅ **Safe removal only**: Uses `git worktree remove` / `--force`, never `rm -rf`

## When to Use

- After merging PRs into the default branch
- Weekly maintenance
- Before creating new worktrees (keep things clean)

For unmerged branches: use `/tech:remove-worktree <branch>` (confirms deletion).
