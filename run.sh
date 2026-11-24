#!/bin/bash
# daily-digest/run.sh
# Once a day: collects Proxmox health, DNS resolver health (Technitium stats,
# direct probes, the router's DNS fallback state) and the last 24 hours of the
# other agents' reports and run logs into one input file, then has Claude write
# a single morning digest. Each collector fails independently: a failure is
# written into the input as an ERROR line instead of stopping the script, so
# the digest reports the gap.
#
# Deploy as /home/agent/agents/daily-digest/run.sh (chmod +x, owned by agent).
# Expects in /home/agent/.config/agent.env:
#   PROXMOX_URL, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET  (PVEAuditor token, privsep)
#   TECHNITIUM_BUAUTH_TOKEN, TECHNITIUM_PRIMENODE_TOKEN (view-only dashboard users)
#   MIKROTIK_HOST                                       (router, for DNS fallback state)
#   NAS_HOSTS          ("pibox:ip nas:ip", read by collect-nas.sh in this folder)
# Also runs collect-unbound.sh (reads http://192.168.99.8:8090/dns.json). run.sh --collect-only prints
# the snapshot without calling Claude or pushing a Kuma heartbeat (used by the supervisor chat).
#   DIGEST_PUSH_TARGET (optional, e.g. digest@192.168.99.8: publish to the Homepage viewer)
# Needs: curl, jq, dig (bind9-dnsutils), ssh, and the agent's existing SSH key.
# The digest is written by the local model on the LLM container through
# /home/agent/agents/bin/llm-report, with Claude as the fallback (2026-10-30).
# LLM_MODE=claude in agent.env restores Claude-only.

set -uo pipefail
source /home/agent/.config/agent.env
# Uptime Kuma heartbeat: on every exit, report up (exit 0) or down (anything
# else) to this agent's push monitor. The URL comes from agent.env, named after
# the agent's folder, e.g. KUMA_PUSH_WAZUH_TRIAGE. A failed push never changes
# the agent's own exit status.
KUMA_VAR="KUMA_PUSH_$(basename "$(dirname "$(readlink -f "$0")")" | tr 'a-z-' 'A-Z_')"
kuma_push() {
    local rc=$?
    local url="${!KUMA_VAR:-}"
    [ -n "$url" ] || return 0
    local status=up
    [ "$rc" -eq 0 ] || status=down
    curl -fsS -m 10 -o /dev/null "${url}?status=${status}&msg=exit%20${rc}" || true
}
trap kuma_push EXIT
cd "$(dirname "$0")"
mkdir -p reports logs

AGENTS_DIR="/home/agent/agents"
KEY="/home/agent/.ssh/id_ed25519"
TODAY=$(date +%Y-%m-%d)
REPORT="reports/digest-${TODAY}.md"
INPUT="/tmp/daily-digest-input.md"

# Technitium servers: name  ip  token-variable-in-agent.env
TECHNITIUM=(
    "buauth 10.20.0.9 TECHNITIUM_BUAUTH_TOKEN"
    "primenodetls 192.168.15.9 TECHNITIUM_PRIMENODE_TOKEN"
)

# Direct DNS probes from the agent box: resolver-ip  name.
# Edit to taste; CLAUDE.md says what result each one should give.
PROBES=(
    "192.168.15.9 example.com"
    "192.168.15.9 dc01.home.arpa"
    "10.20.0.9 example.com"
)

collect() {
echo "# Daily digest input -- collected $(date -Is)"
echo

# ---------------------------------------------------------------- Proxmox
echo "## Proxmox"
local res
# -k: Proxmox serves its self-signed certificate on the management VLAN.
if res=$(curl -sk -m 20 -f \
        -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}" \
        "${PROXMOX_URL}/api2/json/cluster/resources"); then
    echo "### Node"
    echo '```'
    jq -r '.data[] | select(.type=="node")
        | [.node, .status,
           "cpu=\((.cpu//0)*100|floor)%",
           "mem=\((.mem//0)/1073741824|floor)/\((.maxmem//0)/1073741824|floor)GiB",
           "rootfs=\((.disk//0)/1073741824|floor)/\((.maxdisk//0)/1073741824|floor)GiB",
           "uptime_days=\((.uptime//0)/86400|floor)"] | @tsv' <<<"$res"
    echo '```'
    echo "### Guests (VMs and containers)"
    echo '```'
    jq -r '.data[] | select(.type=="qemu" or .type=="lxc")
        | [.vmid, .type, .name, .status,
           "cpu=\((.cpu//0)*100|floor)%",
           "mem=\(((.mem//0)/1073741824*10|floor)/10)/\(((.maxmem//0)/1073741824*10|floor)/10)GiB",
           "disk=\(if (.maxdisk//0) > 0 then "\((.disk//0)*100/.maxdisk|floor)%" else "n/a" end)",
           "uptime_hours=\((.uptime//0)/3600|floor)"] | @tsv' <<<"$res" | sort -n
    echo '```'
    echo "### Storage"
    echo '```'
    jq -r '.data[] | select(.type=="storage")
        | [.storage, .status,
           "used=\(if (.maxdisk//0) > 0 then "\((.disk//0)*100/.maxdisk|floor)%" else "n/a" end)",
           "size=\((.maxdisk//0)/1073741824|floor)GiB"] | @tsv' <<<"$res"
    echo '```'
else
    echo "ERROR: Proxmox API request failed (curl exit $?)"
fi
echo

# ---------------------------------------------------------------- DNS
echo "## DNS"
echo "### Technitium stats (last 24 hours)"
local entry name ip tokvar tok status
for entry in "${TECHNITIUM[@]}"; do
    read -r name ip tokvar <<<"$entry"
    tok="${!tokvar:-}"
    echo "#### $name ($ip)"
    if [ -z "$tok" ]; then
        echo "ERROR: $tokvar not set in agent.env"
        continue
    fi
    if res=$(curl -s -m 20 -f "http://${ip}:5380/api/dashboard/stats/get?token=${tok}&type=LastDay"); then
        status=$(jq -r '.status // "unparseable"' <<<"$res" 2>/dev/null || echo unparseable)
        if [ "$status" = "ok" ]; then
            echo '```json'
            jq '.response | {stats,
                topClients: ((.topClients // [])[:5]),
                topDomains: ((.topDomains // [])[:10]),
                topBlockedDomains: ((.topBlockedDomains // [])[:10])}' <<<"$res"
            echo '```'
        else
            echo "ERROR: Technitium API returned status: $status"
        fi
    else
        echo "ERROR: Technitium API request failed (curl exit $?)"
    fi
done
echo

echo "### Direct probes from the agent box (A record, 2 s timeout, 1 try)"
echo '```'
if command -v dig >/dev/null; then
    local p server qname out answers qtime
    for p in "${PROBES[@]}"; do
        read -r server qname <<<"$p"
        out=$(dig @"$server" "$qname" A +time=2 +tries=1 2>&1)
        status=$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$out" | head -n1)
        answers=$(sed -n 's/.*ANSWER: \([0-9]*\).*/\1/p' <<<"$out" | head -n1)
        qtime=$(sed -n 's/.*Query time: \([0-9]*\) msec.*/\1/p' <<<"$out" | head -n1)
        printf '%s\t%s\tstatus=%s\tanswers=%s\ttime_ms=%s\n' \
            "$server" "$qname" "${status:-NO_RESPONSE}" "${answers:--}" "${qtime:--}"
    done
else
    echo "ERROR: dig is not installed on the agent box; probes skipped"
fi
echo '```'
echo

echo "### Router DNS fallback state (print terse; an X flag means disabled)"
echo '```'
if out=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "agent@${MIKROTIK_HOST}" \
        '/ip firewall nat print terse where comment~"DNS redirect"; /ipv6 firewall nat print terse where comment~"DNS redirect"; /ip firewall filter print terse where comment~"DNS fallback block"; /ipv6 firewall filter print terse where comment~"DNS fallback block"' 2>&1); then
    tr -d '\r' <<<"$out"
else
    echo "ERROR: could not read the router over SSH:"
    tr -d '\r' <<<"$out" | tail -n 3
fi
echo '```'
echo

# ---------------------------------------------------------------- other agents
echo "## Other agents (last 24 hours)"
local agent f found
for agent in wazuh-triage mikrotik-audit; do
    echo "### $agent"
    echo "#### Run log (last 8 lines of logs/cron.log)"
    echo '```'
    tail -n 8 "$AGENTS_DIR/$agent/logs/cron.log" 2>&1
    echo '```'
    found=0
    while IFS= read -r f; do
        found=1
        echo "#### Report: $(basename "$f")"
        echo '````'
        head -c 6000 "$f"
        echo
        echo '````'
    done < <(find "$AGENTS_DIR/$agent/reports" -maxdepth 1 -name '*.md' -mmin -1440 2>/dev/null | sort)
    [ "$found" -eq 0 ] && echo "No reports written in the last 24 hours."
    echo
done
}

if [ "${1:-}" = "--collect-only" ]; then trap - EXIT; ./collect-nas.sh; ./collect-unbound.sh; collect; exit 0; fi
{ collect; ./collect-nas.sh; ./collect-unbound.sh; } > "$INPUT"

echo "$(date -Is): collected $(wc -c < "$INPUT") bytes of input, writing ${REPORT}"
# Local model first. The digest's flags come from fixed thresholds in CLAUDE.md,
# so "Needs attention" stays local; only a local failure (or an input too big
# for its context) falls back to Claude. See llm-report.
/home/agent/agents/bin/llm-report \
  --input "$INPUT" \
  --report "$REPORT" \
  --task "Write today's daily digest (${TODAY}) per CLAUDE.md from the collected input." \
  --ok-verdict "All clear" \
  --no-escalate-on-flag

if [ -s "$REPORT" ]; then
    echo "$(date -Is): digest written to ${REPORT}"
else
    echo "$(date -Is): no digest written, see logs/run.log" >&2
    exit 1
fi

# Publish the digest to the Homepage container's viewer (write-only rrsync account).
if [ -n "${DIGEST_PUSH_TARGET:-}" ]; then
    if rsync -t --chmod=F644 -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new" \
            "$REPORT" "${DIGEST_PUSH_TARGET}:digest.md" 2>>logs/run.log; then
        echo "$(date -Is): published to ${DIGEST_PUSH_TARGET}"
    else
        echo "$(date -Is): WARNING: could not publish the digest to ${DIGEST_PUSH_TARGET}, see logs/run.log" >&2
    fi
fi
