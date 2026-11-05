#!/usr/bin/env bash
# fix_network.sh - makes DNS survive systemd-resolved losing the per-link DNS servers
# (incident 2026-10-13: link, routes, ping and `dig @1.1.1.1` were fine, but resolved had no
#  servers for the interface -> every name lookup failed with SERVFAIL until reboot).
#
# What it does (idempotent, safe to re-run):
#   1. writes /etc/systemd/resolved.conf.d/90-fallback-dns.conf with FallbackDNS=...
#      resolved uses those servers ONLY when no link/global DNS server is known - exactly that failure.
#   2. restarts systemd-resolved if the config changed
#   3. if the interface currently has no DNS servers: asks NetworkManager to push them again
#   4. verifies name resolution
#
# Usage:   sudo ./fix_network.sh
#          sudo FALLBACK_DNS="192.168.178.1 9.9.9.9" ./fix_network.sh
#          sudo ./fix_network.sh --remove      (undo step 1)
#
# netwatch.sh still reports the underlying problem (probe linkdns=FAIL) even when the fallback hides it.

set -u
[ "$(id -u)" -eq 0 ] || exec sudo IFACE="${IFACE:-}" FALLBACK_DNS="${FALLBACK_DNS:-}" bash "$0" "$@"

CONF_DIR=/etc/systemd/resolved.conf.d
CONF="$CONF_DIR/90-fallback-dns.conf"
TEST_NAME="${TEST_NAME:-example.com}"

IFACE="${IFACE:-$(ip route show default 2>/dev/null | awk '/default/{for(n=1;n<=NF;n++) if($n=="dev"){print $(n+1); exit}}')}"
GW4="$(ip -4 route show default 2>/dev/null | awk '/default/{print $3; exit}')"
# router first (local names like fritz.box keep working), then public resolvers
FALLBACK_DNS="${FALLBACK_DNS:-${GW4:+$GW4 }1.1.1.1 9.9.9.9 2606:4700:4700::1111}"

say()      { echo "[fix_network] $*"; }
link_dns() { resolvectl dns "$IFACE" 2>/dev/null | sed 's/^[^:]*: *//'; }

if [ "${1:-}" = --remove ]; then
  if [ -f "$CONF" ]; then rm -f "$CONF"; systemctl restart systemd-resolved; say "removed $CONF, resolved restarted"
  else say "nothing to remove"; fi
  exit 0
fi

# ---- 1+2: fallback DNS ---------------------------------------------------------------------------
want="# managed by fix_network.sh - used only when no other DNS server is known
[Resolve]
FallbackDNS=$FALLBACK_DNS"
if [ "$(cat "$CONF" 2>/dev/null)" = "$want" ]; then
  say "fallback already configured: $FALLBACK_DNS"
else
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$want" > "$CONF"
  say "wrote $CONF (FallbackDNS=$FALLBACK_DNS)"
  systemctl restart systemd-resolved && say "systemd-resolved restarted"
  sleep 2   # NetworkManager re-pushes its DNS config when resolved reappears on the bus
fi

# ---- 3: restore the link's own DNS servers if they are gone ---------------------------------------
if [ -n "$IFACE" ] && [ -z "$(link_dns)" ]; then
  say "$IFACE has no DNS servers in resolved -> asking NetworkManager to push them again"
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload dns-full 2>/dev/null; sleep 2
    [ -z "$(link_dns)" ] && { say "reload not enough -> nmcli device reapply $IFACE"; nmcli device reapply "$IFACE"; sleep 3; }
  fi
fi

# ---- 4: verify -----------------------------------------------------------------------------------
echo
say "link DNS ($IFACE): ${IFACE:+$(link_dns)}"
say "fallback DNS:      $(resolvectl status 2>/dev/null | awk -F': ' '/Fallback DNS Servers/{print $2; exit}')"
if resolvectl query "$TEST_NAME" >/dev/null 2>&1; then
  say "OK: $TEST_NAME resolves"
else
  say "FAIL: $TEST_NAME still does not resolve - run: sudo NETWATCH_DIR=\$PWD/netwatch bash netwatch.sh snapshot"
  exit 1
fi
