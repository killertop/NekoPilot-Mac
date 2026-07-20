#!/usr/bin/env bash
# Run `cargo check` in an isolated worktree on the Linux VM. The VM's normal
# checkout is never reset, cleaned, switched, or patched.

set -euo pipefail

VM_HOST="${NEKOPILOT_LINUX_VM:-${ONEBOX_LINUX_VM:-root@100.91.1.95}}"
VM_REPOSITORY="${NEKOPILOT_LINUX_VM_PATH:-${ONEBOX_LINUX_VM_PATH:-/home/z/Desktop/OneBox}}"
SSH_OPTS=(-o ConnectTimeout=3 -o BatchMode=yes)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m %s\n' "$*"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }

if ! ssh "${SSH_OPTS[@]}" "$VM_HOST" true 2>/dev/null; then
  fail "Cannot reach $VM_HOST"
  echo "Start the dedicated Linux VM and retry, or set NEKOPILOT_LINUX_VM=<user@host>."
  exit 1
fi
ok "VM reachable: $VM_HOST"

LOCAL_HEAD=$(git rev-parse HEAD)
LOCAL_SHORT=$(git rev-parse --short HEAD)
bold "→ Creating isolated VM worktree for $LOCAL_SHORT"

REMOTE_WORKTREE=$(
  ssh "${SSH_OPTS[@]}" "$VM_HOST" bash -s -- "$VM_REPOSITORY" "$LOCAL_HEAD" <<'REMOTE'
set -euo pipefail
repository=$1
commit=$2
git -C "$repository" fetch origin --quiet
if ! git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null; then
  echo "commit $commit is unavailable after fetch; push it first or verify the VM remote" >&2
  exit 1
fi
worktree=$(mktemp -d /tmp/nekopilot-linux-check.XXXXXX)
rmdir "$worktree"
git -C "$repository" worktree add --detach "$worktree" "$commit" --quiet
if [ -d "$repository/src-tauri/binaries" ]; then
  ln -s "$repository/src-tauri/binaries" "$worktree/src-tauri/binaries"
fi
printf '%s\n' "$worktree"
REMOTE
)

case "$REMOTE_WORKTREE" in
  /tmp/nekopilot-linux-check.*) ;;
  *) fail "Refusing unexpected remote worktree path: $REMOTE_WORKTREE"; exit 1 ;;
esac

cleanup() {
  ssh "${SSH_OPTS[@]}" "$VM_HOST" bash -s -- "$VM_REPOSITORY" "$REMOTE_WORKTREE" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
repository=$1
worktree=$2
case "$worktree" in
  /tmp/nekopilot-linux-check.*) ;;
  *) exit 1 ;;
esac
git -C "$repository" worktree remove --force "$worktree" || true
git -C "$repository" worktree prune
REMOTE
}
trap cleanup EXIT INT TERM
ok "VM worktree: $REMOTE_WORKTREE"

if git diff HEAD --quiet --ignore-submodules; then
  ok "No tracked local WIP to patch"
else
  DIFF_STAT=$(git diff HEAD --shortstat --ignore-submodules)
  bold "→ Applying tracked local WIP:$DIFF_STAT"
  if ! git diff HEAD --binary --ignore-submodules | \
    ssh "${SSH_OPTS[@]}" "$VM_HOST" \
      "git -C '$REMOTE_WORKTREE' apply --whitespace=nowarn"; then
    fail "git apply in isolated VM worktree failed"
    exit 1
  fi
  ok "Tracked patch applied"
fi

UNTRACKED=$(git ls-files --others --exclude-standard)
if [ -n "$UNTRACKED" ]; then
  warn "Untracked files are not copied to the VM worktree:"
  printf '%s\n' "$UNTRACKED" | sed 's/^/  /'
fi

bold "→ cargo check on VM"
ssh "${SSH_OPTS[@]}" "$VM_HOST" bash -s -- "$REMOTE_WORKTREE" <<'REMOTE' | sed 's/^/  /'
set -euo pipefail
worktree=$1
export PATH="$HOME/.cargo/bin:$PATH"
cd "$worktree/src-tauri"
cargo check --workspace --all-targets --locked 2>&1
REMOTE
ok "Linux cargo check passed"
