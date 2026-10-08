#!/bin/sh
# Install the sidekick-bridge Claude Code plugin at user scope, or remove it with --uninstall.
#
#   scripts/install-claude-bridge.sh [--uninstall]
#
# Adds <repo>/bridge as the local marketplace "sidekick-local" and installs sidekick-bridge from it.
# Everything goes through the claude CLI, so CLAUDE_CONFIG_DIR is honoured. Safe to run again.
set -eu

case "${1:-}" in
  "") mode=install ;;
  --uninstall) mode=uninstall ;;
  *) echo "usage: $0 [--uninstall]" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "$0")/.." && pwd)
marketplace=sidekick-local
plugin=sidekick-bridge@sidekick-local
echo "Claude Code config: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Prints the entry's `enabled` flag ("True"/"False", or "None" when absent) if `claude plugin <list
# command> --json` lists one whose `field` equals `value`, and fails otherwise.
listed() {
  claude plugin $1 --json | /usr/bin/python3 -I -c '
import json, sys
field, value = sys.argv[1], sys.argv[2]
found = [entry for entry in json.load(sys.stdin) if entry.get(field) == value]
print(found[0].get("enabled") if found else "")
sys.exit(0 if found else 1)
' "$2" "$3"
}

if [ "$mode" = install ]; then
  if listed "marketplace list" name "$marketplace" >/dev/null; then
    echo "Marketplace $marketplace: already added"
  else
    claude plugin marketplace add "$repo/bridge" >/dev/null
    echo "Marketplace $marketplace: added $repo/bridge"
  fi
  if ! enabled=$(listed list id "$plugin"); then
    claude plugin install "$plugin" --scope user >/dev/null
    echo "Plugin $plugin: installed at user scope (new Claude Code sessions load it)"
  elif [ "$enabled" = False ]; then
    claude plugin enable "$plugin" --scope user >/dev/null
    echo "Plugin $plugin: enabled"
  else
    echo "Plugin $plugin: already installed"
  fi
else
  if listed list id "$plugin" >/dev/null; then
    claude plugin uninstall "$plugin" --scope user >/dev/null
    echo "Plugin $plugin: uninstalled"
  else
    echo "Plugin $plugin: not installed"
  fi
  if listed "marketplace list" name "$marketplace" >/dev/null; then
    claude plugin marketplace remove "$marketplace" >/dev/null
    echo "Marketplace $marketplace: removed"
  else
    echo "Marketplace $marketplace: not added"
  fi
fi
