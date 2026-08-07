#!/bin/bash
# fand installer — build release binaries, install them, register the launchd service.
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-install}" in
  install)
    echo "==> building release binaries"
    swift build -c release

    echo "==> installing /usr/local/bin/fand and /usr/local/bin/fanctl"
    sudo install -m 0755 .build/release/fand /usr/local/bin/fand
    sudo install -m 0755 .build/release/fanctl /usr/local/bin/fanctl

    echo "==> registering launchd service (com.fand.daemon)"
    sudo /usr/local/bin/fanctl install

    echo "==> done."
    echo "    control:  fanctl status | set <rpm|auto> [fan] | auto"
    echo "    logs:     /var/log/fand.log"
    echo "    remove:   sudo ./install.sh uninstall"
    ;;
  uninstall)
    echo "==> removing launchd service"
    sudo /usr/local/bin/fanctl uninstall || true
    echo "==> done (binaries left at /usr/local/bin — remove manually if desired)"
    ;;
  *)
    echo "usage: $0 [install|uninstall]" >&2
    exit 1
    ;;
esac
