#!/usr/bin/env bash
# netwatch.sh - passive network/DNS watchdog. Read-only: it NEVER changes or restarts anything.
# It probes every INTERVAL seconds and, when DNS or connectivity breaks, saves a full
# diagnostic snapshot so the cause can be analysed afterwards (even after you restart the network).
#
# Usage:   ./netwatch.sh                (foreground)
#          nohup ./netwatch.sh &        (background)
#          IFACE=enp4s0 INTERVAL=20 ./netwatch.sh
# Output:  ~/netwatch/netwatch.log      one line per probe round (OK / FAIL + which probes)
#          ~/netwatch/counters.csv      NIC error counters every 5 min (to spot growth over time)
#          ~/netwatch/incidents/<ts>/   full snapshot per incident (+ one more at recovery)
#
# Before you restart the network after a failure: check that an incident folder exists
# (ls ~/netwatch/incidents). Then give me that folder (or the newest one) for analysis.

IFACE="${IFACE:-enp4s0}"
INTERVAL="${INTERVAL:-30}"
TEST_NAME="${TEST_NAME:-example.com}"
PUBLIC_V4="${PUBLIC_V4:-1.1.1.1}"
PUBLIC_V6="${PUBLIC_V6:-2606:4700:4700::1111}"
FAILS_BEFORE_SNAPSHOT="${FAILS_BEFORE_SNAPSHOT:-2}"
RESNAPSHOT_EVERY="${RESNAPSHOT_EVERY:-300}"   # seconds between snapshots during one long incident

BASE="$HOME/netwatch"
LOG="$BASE/netwatch.log"
CSV="$BASE/counters.csv"
INC="$BASE/incidents"
mkdir -p "$INC"

have() { command -v "$1" >/dev/null 2>&1; }
ts()   { date '+%Y-%m-%d %H:%M:%S%z'; }
log()  { echo "$(ts) $*" >> "$LOG"; }

# ---- probes: each returns 0 = ok, 1 = fail -------------------------------------------------
p_sysdns()  { timeout 6 getent ahosts "$TEST_NAME" >/dev/null 2>&1; }          # full system path (NSS -> resolved)
p_stub()    { have dig && timeout 6 dig +time=3 +tries=1 +short @127.0.0.53 "$TEST_NAME" 2>/dev/null | grep -q .; }
p_direct()  { have dig && timeout 6 dig +time=3 +tries=1 +short @"$1" "$TEST_NAME" 2>/dev/null | grep -q .; }
p_ping4()   { ping -4 -n -c1 -W3 "$1" >/dev/null 2>&1; }
p_ping6()   { case "$1" in fe80:*) set -- "$1%$IFACE";; esac; ping -6 -n -c1 -W3 "$1" >/dev/null 2>&1; }

dns_servers()  { resolvectl dns "$IFACE" 2>/dev/null | sed -E 's/^Link [0-9]+ \([^)]*\): *//' | tr ' ' '\n' | grep -v '^$' ; }
gw4()          { ip -4 route show default dev "$IFACE" 2>/dev/null | awk '/default/{print $3; exit}'; }
gw6()          { ip -6 route show default dev "$IFACE" 2>/dev/null | awk '/default/{print $3; exit}'; }

run_probes() {
  RESULT=""; FAILED=0
  chk() { # name, command...
    local n="$1"; shift
    if "$@"; then RESULT+="$n=ok "; else RESULT+="$n=FAIL "; [ "$n" = sysdns ] && FAILED=1; FAILCOUNT=$((FAILCOUNT+1)); fi
  }
  FAILCOUNT=0
  chk sysdns   p_sysdns
  chk stub     p_stub
  local s
  for s in $(dns_servers); do chk "dns[$s]" p_direct "$s"; done
  chk "dns[$PUBLIC_V4]" p_direct "$PUBLIC_V4"
  chk "ping4[$PUBLIC_V4]" p_ping4 "$PUBLIC_V4"
  chk "ping6[$PUBLIC_V6]" p_ping6 "$PUBLIC_V6"
  local g; g="$(gw4)"; [ -n "$g" ] && chk "gw4[$g]" p_ping4 "$g"
  g="$(gw6)";          [ -n "$g" ] && chk "gw6[$g]" p_ping6 "$g"
  # an incident = system DNS broken OR any connectivity probe broken
  [ "$FAILCOUNT" -gt 0 ] && FAILED=1
}

# ---- snapshot ---------------------------------------------------------------------------------
snapshot() { # $1 = label
  local d="$INC/$(date +%Y%m%d-%H%M%S)-$1"
  mkdir -p "$d"
  log "SNAPSHOT $1 -> $d"
  {
    echo "### probes: $RESULT"
    echo; echo "### date"; date; uptime
    echo; echo "### uname"; uname -a
  } > "$d/00-summary.txt" 2>&1

  # link / address / routes / neighbours (IPv6 ND and RA state are the prime suspects)
  { ip -s link show "$IFACE"; echo; ip -d link show "$IFACE"; } > "$d/10-link.txt" 2>&1
  { ip -4 addr show; echo; ip -6 addr show; } > "$d/11-addr.txt" 2>&1
  { ip -4 route show table all; echo; ip -6 route show table all; echo; ip rule; ip -6 rule; } > "$d/12-routes.txt" 2>&1
  { ip -4 neigh show; echo; ip -6 neigh show; } > "$d/13-neigh.txt" 2>&1

  # DNS state
  { resolvectl status; echo; resolvectl statistics; echo; resolvectl show-cache 2>/dev/null | head -50; } > "$d/20-resolved.txt" 2>&1
  cat /etc/resolv.conf > "$d/21-resolv.conf" 2>&1
  { resolvectl query "$TEST_NAME"; echo "exit=$?"; } > "$d/22-resolvectl-query.txt" 2>&1
  { for s in $(dns_servers) "$PUBLIC_V4"; do
      echo "=== dig @$s"; timeout 8 dig +time=3 +tries=1 @"$s" "$TEST_NAME" 2>&1; echo "exit=$?"
    done; } > "$d/23-dig-direct.txt" 2>&1
  { echo "=== dig AAAA"; timeout 8 dig +time=3 +tries=1 AAAA "$TEST_NAME" 2>&1
    echo "=== dig A";    timeout 8 dig +time=3 +tries=1 A "$TEST_NAME" 2>&1; } > "$d/24-dig-system.txt" 2>&1
  { ss -ulpn 2>/dev/null | grep -E ':53\b'; ss -tulpn 2>/dev/null | grep -E ':53\b'; } > "$d/25-port53-listeners.txt" 2>&1

  # NIC / driver state (r8169: look at errors, resets, link flaps, EEE, ASPM)
  { ethtool "$IFACE"; echo; ethtool -i "$IFACE"; echo; ethtool -S "$IFACE"; echo; ethtool --show-eee "$IFACE"; echo; ethtool -k "$IFACE"; echo; ethtool -g "$IFACE"; echo; ethtool -a "$IFACE"; } > "$d/30-ethtool.txt" 2>&1
  { cat "/sys/class/net/$IFACE/carrier_changes"; cat "/sys/class/net/$IFACE/carrier_up_count"; cat "/sys/class/net/$IFACE/carrier_down_count"; cat "/sys/class/net/$IFACE/operstate"; } > "$d/31-carrier.txt" 2>&1
  { cat /proc/net/dev; echo; cat /proc/net/snmp | grep -E '^(Ip|Icmp|Udp):'; echo; cat /proc/net/snmp6 | grep -E 'Ip6(In|Out)|Icmp6|Udp6'; } > "$d/32-netstats.txt" 2>&1
  { local pci; pci="$(basename "$(readlink -f /sys/class/net/$IFACE/device)")"
    echo "pci=$pci"; lspci -vvv -s "$pci" 2>&1 | grep -E 'Ethernet|LnkCtl|LnkSta|ASPM|Kernel|Status|Error|Power'
    echo; cat "/sys/bus/pci/devices/$pci/power/control" 2>&1; cat "/sys/bus/pci/devices/$pci/power/runtime_status" 2>&1
    echo; cat /sys/module/pcie_aspm/parameters/policy 2>&1; } > "$d/33-pci.txt" 2>&1

  # logs (the important part: what happened just before)
  journalctl -k --no-pager --since "-30min" > "$d/40-kernel-30min.log" 2>&1
  journalctl -u systemd-resolved --no-pager --since "-30min" > "$d/41-resolved-30min.log" 2>&1
  journalctl -u NetworkManager -u systemd-networkd --no-pager --since "-30min" > "$d/42-netmgr-30min.log" 2>&1
  journalctl -u systemd-timesyncd -u avahi-daemon --no-pager --since "-30min" > "$d/43-misc-30min.log" 2>&1
  dmesg --ctime 2>/dev/null | grep -i -E 'r8169|enp4s0|eth0|link is|reset|timeout|watchdog|NETDEV|pcie|aer' | tail -100 > "$d/44-dmesg-filtered.log"

  # who else uses the network / load (docker, llama-server, conntrack exhaustion)
  { ss -s; echo; cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>&1; } > "$d/50-sockets.txt" 2>&1
  { docker ps 2>&1 | head -20; echo; iptables -S 2>&1 | head -60; } > "$d/51-docker-fw.txt" 2>&1
  { free -h; echo; uptime; echo; ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -10; } > "$d/52-load.txt" 2>&1
  { nmcli -g all device show "$IFACE" 2>&1; nmcli connection show --active 2>&1; } > "$d/53-nm.txt" 2>&1
}

counters_line() {
  [ -f "$CSV" ] || echo "time,rx_errors,tx_errors,rx_dropped,tx_dropped,carrier_changes,rx_packets,tx_packets" > "$CSV"
  local s="/sys/class/net/$IFACE/statistics" c="/sys/class/net/$IFACE/carrier_changes"
  echo "$(ts),$(cat $s/rx_errors),$(cat $s/tx_errors),$(cat $s/rx_dropped),$(cat $s/tx_dropped),$(cat $c),$(cat $s/rx_packets),$(cat $s/tx_packets)" >> "$CSV"
}

# ---- main -------------------------------------------------------------------------------------
for t in dig ethtool resolvectl; do have "$t" || log "WARN: '$t' not installed, some probes/snapshot parts will be empty (sudo apt install dnsutils ethtool)"; done
[ "$(id -u)" -ne 0 ] && log "NOTE: not running as root; ethtool -S / lspci -vvv may be incomplete (run with sudo for full data)"
log "START iface=$IFACE interval=${INTERVAL}s"
RESULT="baseline"; snapshot baseline

consec=0; in_incident=0; last_snap=0; last_counter=0
while true; do
  run_probes
  now=$(date +%s)

  if [ "$FAILED" -eq 1 ]; then
    consec=$((consec+1))
    log "FAIL ($consec) $RESULT"
    if [ "$consec" -ge "$FAILS_BEFORE_SNAPSHOT" ] && [ $((now-last_snap)) -ge "$RESNAPSHOT_EVERY" ]; then
      snapshot incident; last_snap=$now; in_incident=1
    fi
  else
    if [ "$in_incident" -eq 1 ]; then
      log "RECOVERED after $consec failed rounds $RESULT"
      snapshot recovered; in_incident=0; last_snap=0
    else
      log "OK $RESULT"
    fi
    consec=0
  fi

  if [ $((now-last_counter)) -ge 300 ]; then counters_line; last_counter=$now; fi
  sleep "$INTERVAL"
done
