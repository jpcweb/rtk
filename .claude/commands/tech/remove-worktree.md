---
model: haiku
description: Remove a specific worktree (directory + git reference + branch)
---

# Remove Worktree

Remove a specific worktree, cleaning up directory, git references, and optionally the branch.

## Usage

```bash
/tech:remove-worktree feature/new-filter
/tech:remove-worktree fix/session-bug
```

## Implementation

Execute this script with branch name from `$ARGUMENTS`:

```bash
#!/bin/bash
set -euo pipefail

BRANCH_NAME="${ARGUMENTS:-}"

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

DEFAULT_BRANCH="$(detect_default_branch)"
DEFAULT_BRANCH_REF="$(resolve_branch_ref "$DEFAULT_BRANCH")"
CURRENT_WORKTREE="$(git rev-parse --show-toplevel)"

if [ -z "$BRANCH_NAME" ]; then
  echo "❌ Usage: /tech:remove-worktree <branch-name>"
  echo ""
  echo "Example:"
  echo "  /tech:remove-worktree feature/new-filter"
  exit 1
fi

echo "🔍 Checking worktree: $BRANCH_NAME"
echo "🌿 Default branch: $DEFAULT_BRANCH"
echo ""

# Safety check: never remove default branch aliases
if [ "$BRANCH_NAME" = "$DEFAULT_BRANCH" ] || [ "$BRANCH_NAME" = "main" ] || [ "$BRANCH_NAME" = "master" ]; then
  echo "❌ Cannot remove protected branch: $BRANCH_NAME"
  exit 1
fi

# Resolve worktree path from porcelain output with exact branch match
WORKTREE_FULL_PATH=$(git worktree list --porcelain | awk -v branch="refs/heads/$BRANCH_NAME" '
  $1 == "worktree" { path = substr($0, 10) }
  $1 == "branch" && $2 == branch { print path; exit }
')

if [ -z "$WORKTREE_FULL_PATH" ]; then
  echo "❌ Worktree not found: $BRANCH_NAME"
  echo ""
  echo "Available worktrees:"
  git worktree list
  exit 1
fi

# Safety check: never remove current worktree
if [ "$WORKTREE_FULL_PATH" = "$CURRENT_WORKTREE" ]; then
  echo "❌ Cannot remove main repository worktree"
  exit 1
fi

echo "📂 Worktree path: $WORKTREE_FULL_PATH"
echo "🌿 Branch: $BRANCH_NAME"
echo ""

# Check if branch is merged into detected default branch
IS_MERGED=false
if git merge-base --is-ancestor "$BRANCH_NAME" "$DEFAULT_BRANCH_REF" 2>/dev/null; then
  IS_MERGED=true
  echo "✅ Branch is merged into $DEFAULT_BRANCH (safe to delete)"
else
  echo "⚠️  Branch is NOT merged into $DEFAULT_BRANCH"
fi
echo ""

# Ask confirmation if not merged
if [ "$IS_MERGED" = false ]; then
  echo "⚠️  This will DELETE unmerged work. Continue? [y/N]"
  read -r confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# Remove worktree
echo "🗑️  Removing worktree..."
if git worktree remove "$WORKTREE_FULL_PATH" 2>/dev/null; then
  echo "✅ Worktree removed: $WORKTREE_FULL_PATH"
elif git worktree remove --force "$WORKTREE_FULL_PATH" 2>/dev/null; then
  echo "✅ Worktree force-removed safely: $WORKTREE_FULL_PATH"
else
  echo "❌ Unable to remove worktree safely."
  echo "   Resolve manually with: git worktree remove --force \"$WORKTREE_FULL_PATH\""
  exit 1
fi

# Delete branch
echo ""
echo "🌿 Deleting branch..."
if [ "$IS_MERGED" = true ]; then
  if git branch -d "$BRANCH_NAME" 2>/dev/null; then
    echo "✅ Branch deleted (local): $BRANCH_NAME"
  else
    echo "⚠️  Local branch already deleted or not found"
  fi
else
  if git branch -D "$BRANCH_NAME" 2>/dev/null; then
    echo "✅ Branch force-deleted (local): $BRANCH_NAME"
  else
    echo "⚠️  Local branch already deleted or not found"
  fi
fi

# Delete remote branch (if exists)
echo ""
echo "🌐 Checking remote branch..."
if git ls-remote --heads origin "$BRANCH_NAME" | grep -q "$BRANCH_NAME"; then
  echo "⚠️  Remote branch exists. Delete it? [y/N]"
  read -r confirm_remote
  if [ "$confirm_remote" = "y" ] || [ "$confirm_remote" = "Y" ]; then
    if git push origin --delete "$BRANCH_NAME" 2>/dev/null; then
      echo "✅ Remote branch deleted: $BRANCH_NAME"
    else
      echo "❌ Failed to delete remote branch (may require permissions)"
    fi
  else
    echo "⏭️  Skipped remote branch deletion"
  fi
else
  echo "ℹ️  No remote branch found"
fi

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "📊 Remaining worktrees:"
git worktree list
```

## Safety Features

- ✅ Never removes the detected default branch (`main`, `master`, or another protected branch)
- ✅ Asks confirmation for unmerged branches
- ✅ Resolves the worktree path via exact `git worktree list --porcelain` matching
- ✅ Cleans git references, directory, and branch
- ✅ Optional remote branch deletion
- ✅ Falls back to `git worktree remove --force`, never `rm -rf`

## Manual Override

```bash
git worktree remove --force <path>
git branch -D <branch>
git push origin --delete <branch>
```
