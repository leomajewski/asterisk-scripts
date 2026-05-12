# asterisk-scripts

Utility shell scripts for Asterisk PBX administration.

---

## check_pjsip_group.sh

A diagnostic tool that measures real **Layer-7 SIP latency** for all PJSIP endpoints in a named group, using Asterisk's own SIP stack to send the probes.

### Why not just use `ping`?

`ping` operates at **Layer 3 (ICMP)**. In VoIP environments, ICMP is frequently blocked by firewalls, NAT devices, or ISP policies — especially at remote sites. A successful `ping` tells you the IP path is alive, but says nothing about whether the SIP service itself is reachable or how it performs under real conditions.

`pjsip qualify` sends an **OPTIONS request** — a standard SIP message — through the same socket, ports, and NAT traversal logic that actual calls use. If `qualify` reaches the endpoint, a real call will too. If it can't, no amount of successful pings will fix it.

This makes `pjsip qualify` a **Layer-7 ping**: it probes the application layer, not just the network layer.

### Why Asterisk native instead of an external SIP tool?

External SIP tools (like `sipsak` or `sngrep`) send probes from a generic source. Remote endpoints behind firewalls or SBCs typically only respond to traffic coming from a known, registered SIP peer — the PBX itself.

By running probes through `asterisk -rx`, this script uses the same registered identity and NAT-keepalive session that the PBX already maintains with each endpoint. This means:

- Firewalls let the probe through (it looks like normal PBX traffic)
- The RTT measured is the actual round-trip experienced by SIP signaling
- No additional ports or credentials needed

### What the script does

1. Reads the PJSIP config file and finds all endpoints belonging to the specified group (identified by a `named_call_group` tag or similar field).
2. Spawns a background worker for each endpoint in parallel to avoid multiplying the wait time.
3. Each worker fires `pjsip qualify` N times (default: 10), waits between probes, then reads the RTT from `pjsip show endpoint` output.
4. RTT samples are averaged and classified into quality tiers.
5. Results are collected from a temp directory and printed as a formatted table once all workers finish.

### Quality classification

| Status | Condition |
|---|---|
| `EXCELLENT` | Average RTT < 100 ms |
| `SLOW` | Average RTT between 100–200 ms |
| `CRITICAL` | Average RTT > 200 ms |
| `UNSTABLE` | One or more probes failed (packet loss) |
| `OFFLINE` | All probes failed — endpoint unreachable |

> **Note on thresholds:** SIP signaling tolerates higher latency than RTP audio. However, delays above ~150 ms are noticeable in call setup time, and above 200 ms they typically indicate a connectivity problem worth investigating. Adjust `THRESHOLD_SLOW` and `THRESHOLD_CRITICAL` to match your SLA.

### Features

- Parallel execution — all endpoints tested simultaneously, total wait time = N samples × interval (not multiplied by endpoint count)
- Averaged RTT over N probes — reduces noise from transient spikes
- Color-coded output: green / yellow / red based on quality tier
- Auto-discovers available groups from the PJSIP config file (`--help`)
- Extracts public IP from the registered Contact URI

### Requirements

- Asterisk with PJSIP (`chan_pjsip`)
- User running the script must have permission to execute `asterisk -rx`

### Configuration

Edit the variables at the top of the script:

```bash
CONF_FILE="/etc/asterisk/pjsip.conf"   # Path to your PJSIP config
GROUP_FIELD="named_call_group"          # Field used to assign endpoints to groups
ENDPOINT_PATTERN="^\[[0-9]\{4\}\]"     # Regex matching endpoint section headers
NUM_SAMPLES=10                          # Qualify probes per endpoint
INTERVAL=1                             # Seconds between probes
THRESHOLD_CRITICAL=200                 # ms — above this: CRITICAL
THRESHOLD_SLOW=100                     # ms — above this: SLOW
```

### Usage

```bash
# List available groups and status legend
./check_pjsip_group.sh --help

# Test all endpoints in a group
./check_pjsip_group.sh <GROUP_NAME>
```

### Example Output

```
----------------------------------------------------------------------------------------------------
LATENCY REPORT (N=10 samples) — Group: branch-east
----------------------------------------------------------------------------------------------------
Collecting 10 samples per endpoint (wait ~12s): [ ............ ]
----------------------------------------------------------------------------------------------------
ENDPOINT     STATUS     AVG(10)        QUALITY                        PUBLIC IP              SEEN AT
1001         ONLINE     45ms           EXCELLENT                      203.0.113.10           14:32:01
1002         ONLINE     187ms          SLOW                           203.0.113.11           14:32:01
1003         OFFLINE    ---            ---                            ---                    ---
----------------------------------------------------------------------------------------------------
Total Endpoints: 3 | Online: 2
Overall Average Latency: 116ms
----------------------------------------------------------------------------------------------------
```

---

## capture_pjsip_traffic.sh

Captures live SIP/RTP traffic for a single PJSIP endpoint or an entire named group, saving rotating `.pcap` files to disk. Designed for long-running captures (up to 7 days) without manual intervention.

### How it works

The script resolves endpoint IPs **at runtime** using `pjsip show endpoint`, rather than reading them from a static config. This ensures the capture follows the current registered contact, which is important in dynamic NAT environments where public IPs can change between registrations.

For group captures, all endpoint IPs are deduplicated before building the tcpdump filter — multiple endpoints behind the same NAT gateway share one public IP, so capturing it once is enough to cover the whole group.

The tcpdump process runs in the background. The foreground loop shows a live countdown and lists the generated files, and can be stopped at any time by pressing `S`.

### Features

- **Two modes:** single endpoint (numeric argument) or group (string argument)
- **Live IP resolution** via `pjsip show endpoint` — no stale config IPs
- **IP deduplication** for groups — avoids redundant capture filters
- **Rotating files** — new `.pcap` every 24 hours (configurable), keeping individual files manageable
- **7-day auto-stop** — safe to leave running unattended
- **Press S to stop** — clean shutdown flushes and closes the current file

### Requirements

- `tcpdump` installed and executable by the script user
- Asterisk with PJSIP (`chan_pjsip`)
- Write permission to `OUTPUT_DIR`

### Configuration

```bash
OUTPUT_DIR="/var/log/voip-captures"   # Where .pcap files are saved
CONF_FILE="/etc/asterisk/pjsip.conf"  # PJSIP config (group lookups only)
GROUP_FIELD="named_call_group"         # Field used to assign endpoints to groups
ENDPOINT_PATTERN="^\[[0-9]\{4\}\]"    # Regex matching endpoint section headers
MAX_DURATION=$((7 * 24 * 60 * 60))    # Auto-stop after 7 days
ROTATE_INTERVAL=86400                  # New file every N seconds (default: 1 day)
```

### Usage

```bash
# Capture traffic for a single endpoint
./capture_pjsip_traffic.sh 1001

# Capture traffic for all endpoints in a group
./capture_pjsip_traffic.sh branch-east
```

### Example Output

```
Looking up endpoints in group 'branch-east'...

  Endpoints found: 3

  Resolving registered IPs...
  OK  endpoint 1001     -> 203.0.113.10
  OK  endpoint 1002     -> 203.0.113.10
  --  endpoint 1003     -> not registered (skipped)

  Unique IPs to capture: 1
    -> 203.0.113.10

Capture started (new file every 24h, auto-stop after 7 days)
Group: branch-east | IPs: 203.0.113.10 | Session: 20240601_143201
Press [S] to stop early.
----------------------------------------------------------------------
Time remaining: 06 days 23h:59m:45s

Files in this session:
  /var/log/voip-captures/capture_branch-east_20240601_143201_20240601_143201.pcap  1.2M
```
