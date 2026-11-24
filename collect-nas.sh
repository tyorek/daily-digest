#!/bin/bash
# daily-digest/collect-nas.sh -- prints the NAS section of the digest input.
# Reads each NAS's hourly health snapshot over SSH. The NAS side only lets the agent's key run
# `cat /var/lib/nas-health/status.txt` (see nas-health-setup.sh), so whatever command is sent is ignored.
# NAS_HOSTS in agent.env: space-separated name:ip pairs, e.g. "pibox:192.168.5.5 nas:192.168.5.x"

set -uo pipefail
source /home/agent/.config/agent.env
KEY="/home/agent/.ssh/id_ed25519"

echo "## NAS (OpenMediaVault health snapshots, refreshed every 5 minutes on each box)"
if [ -z "${NAS_HOSTS:-}" ]; then
    echo "ERROR: NAS_HOSTS not set in agent.env"
    exit 0
fi
for entry in $NAS_HOSTS; do
    name=${entry%%:*}; ip=${entry#*:}
    echo "### $name ($ip)"
    echo '```'
    if out=$(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
            "agent@${ip}" status 2>&1) && [ -n "$out" ]; then
        head -c 8000 <<<"$out"
    else
        echo "ERROR: could not read the health snapshot from $name over SSH:"
        tail -n 3 <<<"$out"
    fi
    echo '```'
done
echo
