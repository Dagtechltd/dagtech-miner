#!/bin/bash
# DagTech Mac Miner — uninstaller
# Usage: curl -fsSL https://miner.dagtech.network/mac/uninstall.sh | bash
set -uo pipefail

INSTALL_DIR="$HOME/.dagtech-miner"
PLIST_LABEL="network.dagtech.miner"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
PLIST_DASH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.dashboard.plist"

OK=$(printf '\033[38;5;46m')
MUTE=$(printf '\033[38;5;245m')
RESET=$(printf '\033[0m')

echo
echo "  Stopping DagTech Mac Miner…"
launchctl unload "$PLIST_PATH"  2>/dev/null && echo "  ${OK}✓${RESET} miner unloaded" || echo "  ${MUTE}miner was not running${RESET}"
launchctl unload "$PLIST_DASH" 2>/dev/null && echo "  ${OK}✓${RESET} dashboard unloaded" || echo "  ${MUTE}dashboard was not running${RESET}"

echo
echo "  Removing launch agents…"
rm -f "$PLIST_PATH" "$PLIST_DASH"
echo "  ${OK}✓${RESET} launch agents removed"

echo
read -r -p "  Remove $INSTALL_DIR (config, logs)? [y/N] " yn </dev/tty
if [[ "$yn" =~ ^[Yy]$ ]]; then
  rm -rf "$INSTALL_DIR"
  echo "  ${OK}✓${RESET} install directory removed"
else
  echo "  ${MUTE}kept (config and logs preserved at $INSTALL_DIR)${RESET}"
fi

echo
echo "  ${OK}Uninstall complete.${RESET}"
echo "  ${MUTE}Homebrew and openssl@3 were left installed (other apps may need them).${RESET}"
echo
