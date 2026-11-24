#!/bin/bash
# daily-digest/collect-unbound.sh -- prints the Unbound section: the latest results of the DNS probes
# that run every minute on the Homepage container (192.168.99.8) and are served at :8090/dns.json.
set -uo pipefail
echo "## Unbound resolvers (probe results from the Homepage container, refreshed every minute)"
if out=$(curl -fsS -m 10 http://192.168.99.8:8090/dns.json 2>&1); then
    echo '```json'
    jq . <<<"$out" 2>/dev/null || echo "$out"
    echo '```'
else
    echo "ERROR: could not read http://192.168.99.8:8090/dns.json: $out"
fi
echo
