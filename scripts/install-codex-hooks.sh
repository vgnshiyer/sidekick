#!/bin/sh
# Install Sidekick's Codex hooks, or remove them with --uninstall.
#
#   scripts/install-codex-hooks.sh [--uninstall]
#
# Copies bridge/codex-hooks/codex-hook to "$SIDEKICK_HOME/bin/codex-hook" (default
# ~/Library/Application Support/Sidekick) and merges the hooks from bridge/codex-hooks/hooks.json
# into "$CODEX_HOME/hooks.json" (default ~/.codex), keeping every other hook and backing the file
# up first. It never touches config.toml or the notify setting. Safe to run again.
set -eu

case "${1:-}" in
  "") mode=install ;;
  --uninstall) mode=uninstall ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
sidekick_home=${SIDEKICK_HOME:-$HOME/Library/Application Support/Sidekick}
codex_home=${CODEX_HOME:-$HOME/.codex}
hook="$sidekick_home/bin/codex-hook"

case "$hook" in
  *"'"*) echo "error: the hook path must not contain a single quote: $hook" >&2; exit 1 ;;
esac

# Install the script first, so hooks.json never points at a missing file.
if [ "$mode" = install ]; then
  [ -d "$sidekick_home" ] || mkdir -p -m 700 "$sidekick_home"
  mkdir -p "$sidekick_home/bin"
  if cmp -s "$repo/bridge/codex-hooks/codex-hook" "$hook"; then
    echo "Hook script: already up to date at $hook"
  else
    cp "$repo/bridge/codex-hooks/codex-hook" "$hook"
    echo "Hook script: installed $hook"
  fi
  chmod 755 "$hook"
fi

# Codex runs each command through the user's shell, so the path is single-quoted
# ("Application Support" has a space). This exact string identifies Sidekick's entries.
/usr/bin/python3 -I - "$mode" "$repo/bridge/codex-hooks/hooks.json" "$codex_home/hooks.json" "'$hook'" <<'PY'
import json, os, shutil, sys, tempfile, time

mode, template_path, link, command = sys.argv[1:5]
# Edit the file a symlinked hooks.json (e.g. from a dotfiles repo) points at, keeping the link.
target = os.path.realpath(link)

def ours(group):
    return any(h.get("command") == command for h in group.get("hooks", []) if isinstance(h, dict))

with open(template_path) as f:
    template = json.load(f)
for groups in template["hooks"].values():
    for group in groups:
        for handler in group["hooks"]:
            handler["command"] = command

if os.path.exists(target):
    with open(target) as f:
        try:
            config = json.load(f)
        except ValueError as error:
            sys.exit(f"error: {target} is not valid JSON ({error}); fix it first, nothing was changed")
else:
    config = {}
if not isinstance(config, dict) or not isinstance(config.setdefault("hooks", {}), dict):
    sys.exit(f"error: {target} has no \"hooks\" object; nothing was changed")
hooks = config["hooks"]

changes = []
for event, groups in template["hooks"].items():
    existing = hooks.get(event, [])
    if not isinstance(existing, list):
        sys.exit(f"error: hooks.{event} in {target} is not a list; nothing was changed")
    mine = [g for g in existing if isinstance(g, dict) and ours(g)]
    kept = [g for g in existing if g not in mine]
    wanted = kept if mode == "uninstall" else existing if mine == groups else kept + groups
    if wanted != existing:
        changes.append(event)
        if wanted:
            hooks[event] = wanted
        else:
            hooks.pop(event, None)

if not changes:
    state = "already has the" if mode == "install" else "has no"
    print(f"Codex hooks: {target} {state} Sidekick hooks; nothing changed")
    sys.exit(0)

if os.path.exists(target):
    backup = f"{target}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(target, backup)
    print(f"Codex hooks: backed up {target} to {backup}")

if mode == "uninstall" and config == {"hooks": {}} and not os.path.islink(link):
    os.remove(target)
    print(f"Codex hooks: removed {', '.join(changes)}; {target} held nothing else, so it was deleted")
    sys.exit(0)

os.makedirs(os.path.dirname(target), exist_ok=True)
fd, temp = tempfile.mkstemp(dir=os.path.dirname(target), prefix=".hooks.json.")
with os.fdopen(fd, "w") as f:
    json.dump(config, f, indent=2)
    f.write("\n")
if os.path.exists(target):
    shutil.copymode(target, temp)
else:
    os.chmod(temp, 0o644)
os.replace(temp, target)
print(f"Codex hooks: {'installed' if mode == 'install' else 'removed'} {', '.join(changes)} in {target}")
PY

if [ "$mode" = install ]; then
  cat <<EOF

One more step: Codex skips new or changed hooks until you trust them. Trust Sidekick's
hooks once, either in the Codex app (Settings > Hooks) or in the Codex CLI (type /hooks).
EOF
elif [ -e "$hook" ]; then
  rm -f "$hook"
  echo "Hook script: removed $hook"
fi
