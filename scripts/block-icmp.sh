#!/usr/bin/env bash
#
# Blocks (or unblocks) outbound ICMP, so ping and traceroute cannot leak this
# Mac's real address while the bridge is up.
#
#   sudo ./scripts/block-icmp.sh on
#   sudo ./scripts/block-icmp.sh off
#   ./scripts/block-icmp.sh status
#
# WHY THIS IS A SCRIPT AND NOT PART OF THE APP
#
# NETransparentProxyProvider intercepts TCP and UDP flows only; ICMP never
# reaches it. Blocking ICMP therefore needs a packet-filter rule, and pf only
# evaluates rules in an anchor if the MAIN ruleset references that anchor —
# which means editing /etc/pf.conf. An app that rewrites the system firewall as
# root, on every connect and disconnect, can break all networking on the machine
# if it gets it wrong or is killed halfway. That risk is worse than the leak it
# prevents, so this is an explicit, reversible, auditable step you run yourself.
#
# The leak it closes is narrow but real: with the bridge up, `ping example.com`
# still goes out over the Mac's own interface and reveals its address to that
# host. Nothing else on the machine routinely uses ICMP.
#
set -euo pipefail

ANCHOR="uplink"
ANCHOR_FILE="/etc/pf.anchors/com.uplink"
PF_CONF="/etc/pf.conf"
MARKER="# added by UpLink"

green() { printf '\033[0;32m%s\033[0m\n' "$1"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$1"; }
blue()  { printf '\033[0;34m%s\033[0m\n' "$1"; }

status() {
  if pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -q 'proto icmp'; then
    green "ICMP is BLOCKED — ping cannot leak this Mac's address."
    pfctl -a "$ANCHOR" -sr 2>/dev/null | sed 's/^/    /'
  else
    red "ICMP is NOT blocked — ping and traceroute bypass the bridge."
    echo "    Enable with: sudo $0 on"
  fi
}

case "${1:-status}" in
status)
  status
  ;;

on)
  [[ $EUID -eq 0 ]] || { red "Needs root: sudo $0 on"; exit 1; }

  cat > "$ANCHOR_FILE" <<'RULES'
# UpLink: stop ICMP from bypassing the bridge.
# The transparent proxy carries TCP and UDP; ICMP has no path through it, so it
# would otherwise exit via this Mac's own interface and reveal its address.
# Loopback stays open so local diagnostics still work.
block drop out quick proto icmp from any to !127.0.0.0/8
block drop out quick proto ipv6-icmp from any to !::1
RULES

  # Reference the anchor from the main ruleset, exactly once, marked so it can
  # be removed again cleanly.
  if ! grep -q "$MARKER" "$PF_CONF"; then
    cp "$PF_CONF" "$PF_CONF.uplink-backup"
    printf '\nanchor "%s" %s\nload anchor "%s" from "%s" %s\n' \
      "$ANCHOR" "$MARKER" "$ANCHOR" "$ANCHOR_FILE" "$MARKER" >> "$PF_CONF"
    blue "Backed up $PF_CONF to $PF_CONF.uplink-backup"
  fi

  pfctl -f "$PF_CONF" 2>/dev/null || true
  pfctl -E 2>/dev/null || true
  echo
  status
  ;;

off)
  [[ $EUID -eq 0 ]] || { red "Needs root: sudo $0 off"; exit 1; }

  pfctl -a "$ANCHOR" -F rules 2>/dev/null || true
  if grep -q "$MARKER" "$PF_CONF"; then
    grep -v "$MARKER" "$PF_CONF" > "$PF_CONF.tmp" && mv "$PF_CONF.tmp" "$PF_CONF"
  fi
  rm -f "$ANCHOR_FILE"
  pfctl -f "$PF_CONF" 2>/dev/null || true
  echo
  status
  ;;

*)
  echo "usage: $0 [on|off|status]"
  exit 1
  ;;
esac
