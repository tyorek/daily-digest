# daily-digest

A once-a-day "morning digest" agent for the home lab. `run.sh` collects one snapshot file (Proxmox node, guest and storage status through a read-only API token, Technitium DNS stats and test queries, Unbound resolver probes, NAS health over a restricted SSH key, and the last 24 h of the wazuh-triage and mikrotik-audit reports), then an LLM turns it into a digest someone can read in a minute. Everything in the input is treated as untrusted data (see `CLAUDE.md`).

| File | Purpose |
|---|---|
| `run.sh` | collector + LLM call; `--collect-only` for testing |
| `collect-nas.sh`, `nas-update.sh` | NAS snapshot over a `command=`-restricted SSH key |
| `collect-unbound.sh`, `unbound-claude-section.txt` | Unbound resolver probes |
| `CLAUDE.md` | the agent's instructions |
| `viewer/` | `digest-viewer-setup.sh` (small static viewer, rrsync-only upload key) and Homepage CSS |

---

*Published from a home lab. Site identifiers are sanitized: public IPv4 uses the documentation ranges (203.0.113.0/24, 198.51.100.0/24), the delegated IPv6 prefix is `2001:db8::/32`, the ULA prefix is `fd12:3456:789a::/48`, domains are `example.com` / `home.arpa`, MAC addresses, Wi-Fi SSIDs, serials, keys and names are replaced. RFC 1918 addresses are left as they are so the layouts still read. Credentials are never in these files; scripts read them from `agent.env` or similar files that are not published.*
