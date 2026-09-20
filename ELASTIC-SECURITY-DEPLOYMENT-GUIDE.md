# ELASTIC SECURITY
# DEPLOYMENT & OPERATIONS GUIDE

> **Automated SIEM / EDR Infrastructure**

| Field | Value |
|---|---|
| **Version** | 9.5.0 |
| **Elastic Stack** | Elasticsearch, Kibana, Fleet Server, Elastic Agent |
| **Deployment model** | Docker Compose, automated via `elastic-container.sh` |
| **Platform** | Linux host (Docker) with Windows, Linux, macOS endpoint agents |

---

# About This Guide

This guide documents the complete deployment, configuration, endpoint enrollment, telemetry validation, detection-rule configuration, clean-rebuild recovery, and operational procedures for the Elastic Security SIEM/EDR infrastructure.

It is written for operators who need a single authoritative reference for standing up the stack from scratch, enrolling endpoints, verifying telemetry flow, configuring detection rules, performing clean rebuilds, and managing day-two operations including credential rotation and agent lifecycle.

The guide covers the core Elastic SIEM deployment plus optional integration points for Zeek (network security monitoring) and Velociraptor (DFIR/investigation).

---

# Quick Navigation

| Section | Description |
|---|---|
| [Quick Start](#quick-start) | Shortest path through the deployment workflow |
| [When to Use This Guide](#when-to-use-this-guide) | Scenarios and decision table |
| [Phase 0 — Prerequisites](#phase-0--prerequisites) | Pre-deployment checks |
| [Phase 1 — Destroy Old Stack](#phase-1--destroy-old-stack) | Tear down existing containers and volumes |
| [Phase 2 — Configure Fresh Environment](#phase-2--configure-fresh-environment) | Create and populate `.env` |
| [Phase 3 — Validate Configuration](#phase-3--validate-configuration) | Validate Docker Compose configuration |
| [Phase 4 — Start the Stack](#phase-4--start-the-stack) | Bring up Elasticsearch, Kibana, Fleet Server |
| [Phase 5 — Verify Deployment](#phase-5--verify-deployment) | Confirm all services are healthy |
| [Phase 6 — Deploy Windows Endpoint Agent](#phase-6--deploy-windows-endpoint-agent) | Enroll a Windows host |
| [Phase 7 — Deploy Linux & macOS Endpoint Agents](#phase-7--deploy-linux--macos-endpoint-agents) | Enroll Linux and macOS hosts |
| [Windows Host Prerequisites](#windows-host-prerequisites) | Sysmon, PowerShell logging, Defender, audit policy |
| [Linux Host Prerequisites](#linux-host-prerequisites) | Authentication logging, agent verification |
| [Detection Rules](#detection-rules) | Prebuilt rule enablement and telemetry chain |
| [Configuration Reference](#configuration-reference) | `.env` variable table |
| [Dependency Map](#dependency-map) | Variable dependency relationships |
| [Secret Rotation & Credential Management](#secret-rotation--credential-management) | Credential lifecycle and rotation procedures |
| [Agent Uninstallation](#uninstalling-an-elastic-agent) | Remove agents from endpoints |
| [External Security Components](#external-security-components--operator-setup) | Zeek and Velociraptor operator setup |
| [Deployment Order](#deployment-order) | End-to-end deployment flow diagram |
| [Topology Flexibility](#topology-flexibility) | Deployment architecture options |
| [Telemetry Validation](#telemetry-validation) | End-to-end telemetry verification procedures |

---

# Quick Start

> [!TIP]
> This section provides the shortest path through the deployment workflow. For full details on every step, refer to the detailed phases below.

**1. Clone the repository and enter it:**

```bash
git clone <repository-url> && cd elastic-security-infrastructure
```

**2. Create `.env` from the template:**

```bash
cp .env.example .env
```

**3. Generate a Kibana encryption key:**

```bash
openssl rand -hex 32
```

**4. Edit `.env` and set required values:**

```bash
nano .env
```

Set at minimum: `SIEM_IP`, `ELASTIC_PASSWORD`, `KIBANA_PASSWORD`, `KIBANA_ENCRYPTION_KEY`.

**5. Start the stack:**

```bash
./elastic-container.sh start
```

Wait for `READY SET GO!` output (2–5 minutes).

**6. Verify:**

```bash
./elastic-container.sh status
```

All three containers should show `Up (healthy)` or `Up`.

**7. Access Kibana:** Browse to `https://<YOUR_SIEM_IP>:5601`

> [!NOTE]
> The Quick Start skips prerequisite checks, certificate export, endpoint enrollment, telemetry verification, and detection-rule configuration. The full procedure in the detailed phases below covers all of these.

---

# When to Use This Guide

| Scenario | Action |
|---|---|
| **SIEM_IP changed** | Clean rebuild required (certificates contain the old IP in SANs) |
| **Credentials compromised** | Clean rebuild recommended |
| **Stack version upgrade** | Run `./elastic-container.sh update-version`, then clean rebuild |
| **Corrupt state / troubleshooting** | Clean rebuild |
| **Normal restart after reboot** | Use `./elastic-container.sh start` — NOT this guide |

## Clean Rebuild vs Normal Restart

**Normal restart** (`./elastic-container.sh start`):
- Preserves Docker volumes (Elasticsearch data, Kibana saved objects, certificates, Fleet state)
- Fleet Server agent state is reused via `fleet-entrypoint.sh` (no duplicate enrollment)
- Fleet automation is idempotent — repeated starts do not create duplicate policies or integrations
- Existing enrolled agents remain connected

**Clean rebuild** (`./elastic-container.sh destroy` then `start`):
- Destroys all containers and Docker volumes
- Removes Elasticsearch indices and data
- Removes Kibana saved objects (dashboards, alert rules, connectors)
- Removes all generated TLS certificates
- Removes Fleet Server enrollment state
- Stack is initialized from scratch on next `start`
- Previously enrolled agents must be re-enrolled (they will lose contact with the rebuilt Fleet Server)

---

# PHASE 0 — PREREQUISITES

## Step 0.1: Verify you are in the correct repository

```bash
pwd
```

> **What it does:** Shows your current directory.

> **Success:** Output should end with the repository directory name (e.g., `/home/<username>/elastic-security-infrastructure`).

> **If it fails:** You're in the wrong directory. `cd` to the repository.

---

## Step 0.2: Check git status

```bash
git status
```

> **What it does:** Shows tracked/untracked files and any modifications.

> **Success:** Should NOT show `.env` as tracked.

> [!WARNING]
> If `.env` is listed as tracked: **Stop.** That's a problem. `.env` contains credentials and should never be committed.

---

## Step 0.3: Verify .env is gitignored

```bash
git check-ignore .env
```

> **What it does:** Checks if `.env` is excluded from git.

> **Success:** Output should be `.env` (meaning it IS ignored).

> **If it outputs nothing:** `.env` is not gitignored. Run `echo ".env" >> .gitignore` before proceeding.

---

## Step 0.4: Back up your current .env

```bash
cp .env ~/env-backup-$(date +%Y%m%d-%H%M%S)
```

> **What it does:** Copies your current `.env` to your home directory with a timestamp.

> **Success:** File appears in `~/`. Example: `~/env-backup-20260812-153000`

> **Why:** If something goes wrong, you can restore your working config.

---

## Step 0.5: Verify .env.example exists

```bash
ls -la .env.example
```

> **What it does:** Confirms the template file is present.

> **Success:** Shows the file with its size and permissions.

---

# PHASE 1 — DESTROY OLD STACK

## Step 1.1: Stop all running containers

```bash
./elastic-container.sh stop
```

> **What it does:** Stops Elasticsearch, Kibana, and Fleet Server containers without deleting data.

> **Success:** Output says "Stopping running containers." Docker shows all containers as "Exited".

**Verify:**

```bash
docker ps -a --format "table {{.Names}}\t{{.Status}}"
```

All containers should show `Exited`.

---

## Step 1.2: Destroy everything (containers + volumes + network)

```bash
./elastic-container.sh destroy
```

> **What it does:**
> - Stops all containers
> - Removes containers
> - Removes the Docker network
> - Removes all volumes (certs, fleet-certs, kibana-certs, esdata01, kibanadata, fleetserverdata)
> - This DELETES all Elasticsearch data, Kibana saved objects, certificates, and Fleet state

> [!IMPORTANT]
> **Safety confirmation:** `destroy` now requires an explicit confirmation. You
> will be prompted to type `DESTROY` (all uppercase) before anything is removed.
> If you do not type the word exactly (or run it non-interactively without
> providing input), the command **aborts** and nothing is deleted. This prevents
> an accidental `destroy` from wiping the stack. Non-destructive commands
> (`start`, `stop`, `restart`, `status`, `preflight`) remain non-interactive.

> **Success:** Output says "Stopping and removing the containers, network, and volumes created."

**Verify:**

```bash
docker volume ls | grep elastic-container
```

Should return nothing (all volumes removed).

**Audit trail:** Every `start`, `destroy`, and `clear` run appends a timestamped
line to `.logs/actions.log` (owner-only, gitignored) on the SIEM host, e.g.:
`2026-08-14T18:15:33Z ./elastic-container.sh user=<your_username> action=start`. Host-side
administrative actions are therefore traceable even though the Elastic Stack's
BASIC license does not permit Elasticsearch security audit logging.

```bash
docker ps -a | grep ecp-
```

Should return nothing (all containers removed).

> **If it fails:** Run `docker compose down -v` manually in the repository directory.

---

## Step 1.3: Verify clean state

```bash
docker volume ls
docker ps -a | grep ecp-
```

> **Success:** No `elastic-container_*` volumes. No `ecp-*` containers.

---

# PHASE 2 — CONFIGURE FRESH ENVIRONMENT

## Step 2.1: Create fresh .env from template

```bash
cp .env.example .env
```

> **What it does:** Copies the generic template to create a new `.env`.

> **Success:** `.env` exists with placeholder values like `<SIEM_ISOLATED_IP>`, `changeme`.

---

## Step 2.2: Generate Kibana encryption key

```bash
openssl rand -hex 32
```

> **What it does:** Generates a random 64-character hexadecimal string.

> **Success:** Outputs something like: `a1b2c3d4e5f6...` (64 hex characters)

**Copy this output.** You'll paste it into `.env` in the next step.

---

## Step 2.3: Edit .env with your values

```bash
nano .env
```

> **What it does:** Opens the file for editing.

You need to set these values:

### SIEM_IP (REQUIRED)

```
SIEM_IP=<YOUR_SIEM_SERVER_IP>
```

> **What to put here:** The IP address of this SIEM server that endpoint agents will use to reach Fleet Server and Elasticsearch.

**How to find it:**

```bash
ip addr show | grep "inet " | grep -v 127.0.0.1
```

Pick the IP on the network your agents can reach.

**Example:** `SIEM_IP=10.10.20.10`

> [!IMPORTANT]
> This IP goes into the TLS certificate SANs. If you change it later, you must destroy and rebuild the stack (follow this guide again from Phase 1).

---

### SIEM_NAT_IP (OPTIONAL)

```
SIEM_NAT_IP=<YOUR_NAT_OR_MGMT_IP>
```

> **What to put here:** If your SIEM server has a second IP (e.g., NAT, management interface), put it here. It's added to certificate SANs so TLS works on both IPs.

**If not needed:** Leave as `<SIEM_NAT_IP>` or set to the same value as `SIEM_IP`.

**Example:** `SIEM_NAT_IP=192.168.1.50`

---

### SIEM_IFACE (OPTIONAL — for static IP setup)

```
SIEM_IFACE=<YOUR_NETWORK_INTERFACE>
```

> **What to put here:** The name of the network interface that has `SIEM_IP`. Used by `set-static-ip.sh` if you want to set a static IP.

**How to find it:**

```bash
ip link show
```

Look for the interface with your `SIEM_IP`.

**Example:** `SIEM_IFACE=ens192`

---

### SIEM_PREFIX

```
SIEM_PREFIX=24
```

> **What to put here:** The CIDR prefix for your subnet. `24` = 255.255.255.0 (most common). Leave as `24` unless your network is different.

---

### ELASTIC_USERNAME (OPTIONAL)

```
ELASTIC_USERNAME=elastic
```

> **What to put here:** The username for all administrative operations (Kibana login, Fleet API, detection engine). Defaults to `elastic`.

If set to a value other than `elastic`, the setup container automatically creates a custom superuser with this name and the `superuser` role, then disables the built-in `elastic` account.

**Example:** `ELASTIC_USERNAME=siem_admin`

> [!IMPORTANT]
> This is applied at first boot. Changing it in `.env` alone does NOT update running containers — you must destroy and rebuild the stack for the change to take effect.

---

### ELASTIC_PASSWORD (REQUIRED)

```
ELASTIC_PASSWORD=<YOUR_STRONG_PASSWORD>
```

> **What to put here:** Password for the administrative user (the value of `ELASTIC_USERNAME`; defaults to `elastic`). Minimum 12 characters.

**Example:** `ELASTIC_PASSWORD=MyStr0ngP@ssword!`

> [!IMPORTANT]
> This is set at first boot during the security setup. To change it on a running stack, you would need to use the Elasticsearch Change Password API or destroy and rebuild. Simply changing `.env` does not update running containers.

---

### KIBANA_USERNAME (OPTIONAL)

```
KIBANA_USERNAME=kibana_system
```

> **What to put here:** The username Kibana uses internally to connect to Elasticsearch. Defaults to `kibana_system` (a built-in Elasticsearch user).

If set to a custom value, the setup container creates this user with the `kibana_system` role.

**Most deployments should leave this as `kibana_system`.**

---

### KIBANA_PASSWORD (REQUIRED)

```
KIBANA_PASSWORD=<YOUR_STRONG_PASSWORD>
```

> **What to put here:** Password for the Kibana internal user (`KIBANA_USERNAME`). This is the Kibana ↔ Elasticsearch service credential, NOT the admin login password. Minimum 12 characters.

**Can be the same as `ELASTIC_PASSWORD`** for lab use.

**Example:** `KIBANA_PASSWORD=MyStr0ngP@ssword!`

---

### KIBANA_ENCRYPTION_KEY (REQUIRED)

```
KIBANA_ENCRYPTION_KEY=<PASTE_YOUR_GENERATED_KEY>
```

> **What to put here:** Paste the output from `openssl rand -hex 32` (Step 2.2).

**Example:** `KIBANA_ENCRYPTION_KEY=a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2`

---

### STACK_VERSION

```
STACK_VERSION=9.5.0
```

> **What to put here:** The Elastic Stack version tag. Must exist for `elasticsearch`, `kibana`, and `elastic-agent` on Docker Hub. Refresh automatically with `./elastic-container.sh update-version`.

---

### Detection Rule Flags (OPTIONAL)

```
WindowsDR=1
LinuxDR=0
MacOSDR=0
```

> **What they do:** Bulk-enable prebuilt detection rules by OS during first start. Prebuilt rules are always installed; these flags only control whether they are enabled.

Set to `1` to enable, `0` to leave disabled.

> [!NOTE]
> Detection rules consume telemetry. Enabling Windows detection rules is only useful if you have Windows agents enrolled and producing the relevant telemetry (Sysmon, PowerShell, etc.).

---

### Save and exit nano:
- Press `Ctrl+O` then `Enter` to save
- Press `Ctrl+X` to exit

---

## Step 2.4: Verify your .env

```bash
grep -E "^(SIEM_IP|SIEM_NAT_IP|ELASTIC_USERNAME|ELASTIC_PASSWORD|KIBANA_USERNAME|KIBANA_PASSWORD|KIBANA_ENCRYPTION_KEY|STACK_VERSION)" .env
```

> **Success:** Shows your configured values (not placeholders).

**Verify no placeholders remain:**

```bash
grep -E "changeme|<SIEM|<NETWORK" .env
```

Should return nothing (except the `changeme-generate-a-random-key` default if you didn't set the encryption key — that's a problem).

---

# PHASE 3 — VALIDATE CONFIGURATION

## Step 3.1: Validate Docker Compose configuration

```bash
docker compose config --quiet
```

> **What it does:** Parses `docker-compose.yml` and checks for syntax errors.

> **Success:** No output (exit code 0).

> **If it fails:** It will print an error. Common issues:
> - Missing `KIBANA_ENCRYPTION_KEY` in `.env`
> - Invalid YAML syntax
> - Missing required variables

**Fix:** Read the error, fix `.env`, and re-run.

---

# PHASE 4 — START THE STACK

## Step 4.1: Start everything

```bash
./elastic-container.sh start
```

> **What it does:**
> 1. Validates passwords are not `changeme` and encryption key is not the placeholder
> 2. Starts Docker containers via `docker compose up`
> 3. Setup container creates CA + TLS certificates with `SIEM_IP` and `SIEM_NAT_IP` in SANs
> 4. Setup container creates/verifies admin user (`ELASTIC_USERNAME`) and Kibana user (`KIBANA_USERNAME`)
> 5. Setup container stores bootstrap credentials for future recovery (`.admin_creds`)
> 6. Elasticsearch starts with TLS
> 7. Kibana starts with TLS
> 8. Fleet Server starts via `fleet-entrypoint.sh` (checks for existing enrollment before re-enrolling)
> 9. Detection Engine is enabled in Kibana
> 10. Prebuilt detection rules are installed; OS-specific rules are enabled per `WindowsDR`/`LinuxDR`/`MacOSDR`
> 11. Fleet output is configured (Elasticsearch URL, CA fingerprint, TLS mode)
> 12. Fleet Server host URL is configured for remote agent enrollment
> 13. Fleet agent policies are created (idempotent — existing policies are reused):
>     - **Windows Endpoint** (System + Elastic Defend + Windows integration)
>     - **Endpoint Baseline** (System + Elastic Defend)
>     - **Linux Endpoint** (System + Elastic Defend)

> **Success:** Output ends with:
> ```
> READY SET GO!
>
> Browse to https://localhost:5601
> ```

> [!IMPORTANT]
> **This takes 2–5 minutes.** Be patient.

> **If it fails:** Common errors and fixes:

| Error | Fix |
|---|---|
| `Set the ELASTIC_PASSWORD...` | Your `.env` still has `changeme`. Change it. |
| `Set KIBANA_ENCRYPTION_KEY...` | Your key is still the placeholder. Run `openssl rand -hex 32` and update `.env`. |
| `Kibana still loading...` loop | Normal during startup. Wait. If it loops 15 times, check `docker logs ecp-kibana`. |
| `Exceeded MAXTRIES` | Kibana didn't start. Check `docker logs ecp-kibana` for errors. |

> [!NOTE]
> **Idempotent behavior:** Running `./elastic-container.sh start` multiple times is safe. The Fleet automation performs query-first lookups before creating any policy or integration. If the policies already exist, they are reused. Two consecutive runs will produce the same Fleet state with no duplicates.

> [!NOTE]
> **Fleet Server persistence:** The `fleet-entrypoint.sh` script checks for an existing Fleet Server enrollment state (`fleet.enc`) in the agent data volume. If the agent was previously enrolled, re-enrollment is skipped to prevent duplicate Fleet Server agents in Kibana.

---

# PHASE 5 — VERIFY DEPLOYMENT

## Step 5.1: Check container status

```bash
./elastic-container.sh status
```

> **Success:** Shows three containers:
> ```
> ecp-elasticsearch    Up (healthy)
> ecp-kibana           Up (healthy)
> ecp-fleet-server     Up
> ```

> [!NOTE]
> Fleet Server may not have a healthcheck, so it shows "Up" without "(healthy)".

---

## Step 5.2: Verify Elasticsearch

```bash
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" https://127.0.0.1:9200/_cat/health?v
```

**Replace `<YOUR_PASSWORD>`** with your `ELASTIC_PASSWORD`.

If you are using the default `ELASTIC_USERNAME` (`elastic`), this simplifies to:

```bash
curl -sk -u "elastic:<YOUR_PASSWORD>" https://127.0.0.1:9200/_cat/health?v
```

> **Success:** Shows cluster status. `yellow` is normal for single-node (replicas can't be assigned).

---

## Step 5.3: Verify Kibana

```bash
curl -sk -I https://127.0.0.1:5601 | head -1
```

> **Success:** Shows `HTTP/2 302` (redirect to login page).

---

## Step 5.4: Verify Fleet Server

```bash
curl -sk https://127.0.0.1:8220/api/status
```

> **Success:** Returns JSON with fleet server status.

---

## Step 5.5: Verify certificates were generated

```bash
docker exec ecp-elasticsearch ls -la /usr/share/elasticsearch/config/certs/ca/
```

> **Success:** Shows `ca.crt` and `ca.key`.

```bash
docker exec ecp-elasticsearch ls -la /usr/share/elasticsearch/config/certs/elasticsearch/
```

> **Success:** Shows `elasticsearch.crt`, `elasticsearch.key`, `elasticsearch.chain.pem`.

---

## Step 5.6: Verify Fleet is configured

Open browser to `https://<YOUR_SIEM_IP>:5601`

Login with:
- **Username:** the value of `ELASTIC_USERNAME` in your `.env` (defaults to `elastic`)
- **Password:** your `ELASTIC_PASSWORD`

Navigate to **Fleet → Settings**. Verify:
- **Fleet Server hosts:** `https://<YOUR_SIEM_IP>:8220`
- **Elasticsearch output:** `https://<YOUR_SIEM_IP>:9200`

---

## Step 5.7: Verify Fleet agent policies

Navigate to **Fleet → Agent policies**. Verify the following four policies exist:

```
Fleet-Server-Policy
└── Fleet Server

Windows Endpoint
├── System
├── Elastic Defend (EDRComplete)
└── Windows (Sysmon/PowerShell/Defender winlog channels)

Endpoint Baseline
├── System
└── Elastic Defend (EDRComplete)

Linux Endpoint
├── System
└── Elastic Defend (EDRComplete)
```

**Why four policies?**

| Policy | Purpose |
|---|---|
| **Fleet-Server-Policy** | Manages the Fleet Server itself. Do not enroll endpoint agents here. |
| **Windows Endpoint** | For Windows hosts. Includes the Windows integration for Sysmon, PowerShell, and Defender telemetry. |
| **Endpoint Baseline** | A generic baseline policy with System monitoring and Elastic Defend. Can be used for hosts that don't need OS-specific integrations. |
| **Linux Endpoint** | For Linux hosts. Does NOT include the Windows integration — Linux has no use for winlog channels. |

> [!IMPORTANT]
> Do NOT manually add the Windows integration to the Linux Endpoint policy. The Windows integration contains winlog-based inputs (Sysmon, PowerShell, Defender) that are Windows-specific and have no function on Linux.

**API verification:**

```bash
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:5601/api/fleet/agent_policies?perPage=100" \
  -H "kbn-xsrf: kibana" | jq '.items[] | {name: .name, id: .id}'
```

```bash
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:5601/api/fleet/package_policies?perPage=200" \
  -H "kbn-xsrf: kibana" | jq '.items[] | {name: .name, package: .package.name, policy_id: .policy_id}'
```

---

# PHASE 6 — DEPLOY WINDOWS ENDPOINT AGENT

The stack is running and Fleet policies have been automatically created. This phase walks through enrolling a Windows host into the **Windows Endpoint** policy.

---

## Step 6.1 — Export the CA certificate to Windows

The SIEM stack uses internally generated TLS certificates. The Windows agent must trust the CA that signed them.

**On the SIEM server**, extract the CA certificate:

```bash
docker exec ecp-elasticsearch cat /usr/share/elasticsearch/config/certs/ca/ca.crt > ~/ca.crt
```

**Verify the file:**

```bash
openssl x509 -in ~/ca.crt -noout -subject -issuer
```

> **Success:** Shows the CA subject and issuer (self-signed, so they match).

**Transfer `ca.crt` to the Windows host.**

`ca.crt` is a PEM *text* file, so no special tooling and no inbound ports on Windows are required.

**Method A — Copy/paste (recommended, zero extra software):**

On the SIEM server, print the certificate contents:

```bash
cat ~/ca.crt
```

Copy the entire output (from `-----BEGIN CERTIFICATE-----` through
`-----END CERTIFICATE-----`). On the Windows host, open **Notepad**, paste the text, and
save it as `ca.crt` on the Desktop — in the Save As dialog, set "Save as type" to
**All files** so Notepad does not append a `.txt` extension.

**Method B — Temporary HTTP server (no inbound ports on Windows):**

On the SIEM server, serve the directory containing the cert:

```bash
cd ~ && python3 -m http.server 8000
```

On the Windows host, download it in a browser and save to
`C:\Users\<WINDOWS_USER>\Desktop\ca.crt`:

```
http://<SIEM_IP>:8000/ca.crt
```

Then stop the server with `Ctrl+C`. `ca.crt` is a public certificate, so serving it
briefly over HTTP is not a security risk — the private key is never served.

> [!CAUTION]
> Copy ONLY `ca.crt` (the public certificate). NEVER copy `ca.key` (the CA private key) to any endpoint. The private key must remain on the SIEM server. If `ca.key` is compromised, an attacker can forge trusted certificates for your entire deployment.

---

## Step 6.2 — Import the CA into the Windows certificate store

On the **Windows host**, open **PowerShell as Administrator** and import the CA certificate:

```powershell
Import-Certificate -FilePath "C:\Users\$env:USERNAME\Desktop\ca.crt" `
  -CertStoreLocation Cert:\LocalMachine\Root
```

> **What it does:** Adds the SIEM CA to the Windows machine-wide Trusted Root Certificate Authorities store. This allows the Elastic Agent (running as a system service) to trust TLS connections to Fleet Server and Elasticsearch.

**Why `LocalMachine\Root`?** The Elastic Agent runs as a Windows service under the SYSTEM account, which uses the machine-level certificate store — not the current user's store.

**Verify the import:**

```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -like "*elastic*" -or $_.Issuer -like "*elastic*" }
```

> **Success:** Shows the imported CA certificate with its thumbprint and subject.

**Verify TLS connectivity to Fleet Server from Windows:**

```powershell
Invoke-WebRequest -Uri "https://<SIEM_IP>:8220/api/status" -UseBasicParsing
```

Replace `<SIEM_IP>` with your SIEM server's IP address.

> **Success:** Returns a response (even if it's a JSON error about authentication — the important thing is that TLS completed without certificate errors).

> **If you get a certificate error:** The CA was not imported correctly, the certificate SANs don't include `SIEM_IP`, or you're connecting to the wrong IP. Verify:
> 1. The certificate was imported into `LocalMachine\Root` (not `CurrentUser`)
> 2. You are connecting to `https://<SIEM_IP>:8220` (NOT `https://localhost:8220` — localhost on Windows refers to the Windows machine itself)
> 3. `SIEM_IP` in `.env` matches the IP you are connecting to

---

## Step 6.3 — Verify Fleet policies are ready

The repository automatically creates and configures all endpoint policies during `./elastic-container.sh start`. You do NOT need to manually create the Windows Agent Policy or its integrations.

**Verify in Kibana:**

1. Open `https://<SIEM_IP>:5601` in a browser
2. Log in with your `ELASTIC_USERNAME` (defaults to `elastic`) and `ELASTIC_PASSWORD`
3. Navigate to **Fleet → Agent policies**
4. Confirm the **Windows Endpoint** policy exists and contains:

| Integration | Package | Purpose |
|---|---|---|
| System | `system` | Windows Application/Security/System event logs + system metrics |
| Elastic Defend | `endpoint` | EDRComplete — process, file, network, registry, security endpoint events + malware protection |
| Windows | `windows` | Sysmon/Operational, PowerShell/Operational, Windows Defender, classic PowerShell |

5. Confirm the **Linux Endpoint** policy contains only System + Elastic Defend (NO Windows integration)

**Why separate OS policies?**

The Windows integration collects telemetry from Windows-specific winlog channels (Sysmon, PowerShell, Defender). These event sources do not exist on Linux. Keeping them on separate policies ensures:
- Linux agents are not configured with unusable inputs
- Each OS receives only relevant integrations
- Enrollment tokens clearly identify which policy an endpoint should join

**API verification:**

```bash
# List package policies for each agent policy
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:5601/api/fleet/package_policies?perPage=200" \
  -H "kbn-xsrf: kibana" \
  | jq '[.items[] | {name, package: .package.name, policy_id}]'
```

---

## Step 6.4 — Download and install Elastic Agent on Windows

**Get the installation command from Kibana:**

1. In Kibana, navigate to **Fleet → Agents → Add agent**
2. Select the **Windows Endpoint** policy
3. Kibana displays the download URL and installation command for the correct version
4. Copy the commands shown for **Windows**

**On the Windows host**, open **PowerShell as Administrator** and follow the commands from Kibana. The general process is:

1. **Download** the Elastic Agent ZIP for Windows (version must match your `STACK_VERSION`)
2. **Extract** the archive
3. **Install** the agent as a Windows service:

```powershell
cd C:\path\to\elastic-agent-<VERSION>-windows-x86_64
.\elastic-agent.exe install
```

> [!NOTE]
> Always obtain the download URL and exact version from the Kibana Fleet UI (**Add agent** workflow) to ensure version compatibility. Do not use arbitrary download URLs.

**Verify the service is installed and running:**

```powershell
Get-Service elastic-agent
```

> **Success:** Shows `Status: Running`.

```powershell
sc.exe query elastic-agent
```

> **Success:** Shows `STATE: RUNNING`.

---

## Step 6.5 — Enroll the Windows agent

During the **Add agent** workflow in Kibana (Step 6.4), Kibana provides an enrollment command. The key parameters are:

- **`--enrollment-token`**: Must be the token for the **Windows Endpoint** policy. This token determines which Agent Policy the agent receives. Using the wrong token enrolls the agent into the wrong policy.
- **`--url`**: Must be `https://<SIEM_IP>:8220` — the Fleet Server URL reachable from the Windows host. Do NOT use `localhost` (which refers to the Windows machine itself, not the SIEM).

The enrollment command looks like:

```powershell
.\elastic-agent.exe enroll --url=https://<SIEM_IP>:8220 --enrollment-token=<TOKEN>
```

If the agent was installed with `install` (Step 6.4) and you provided the enrollment details during installation, enrollment happens automatically.

**Retrieve enrollment tokens via API (if needed):**

```bash
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:5601/api/fleet/enrollment_api_keys?perPage=100" \
  -H "kbn-xsrf: kibana" \
  | jq '.items[] | {policy_id, api_key, active}'
```

Match the `policy_id` to the Windows Endpoint policy ID to find the correct token.

**How enrollment tokens determine policy assignment:**

Fleet does NOT automatically detect the OS of the enrolling agent and assign a policy. The enrollment token is bound to a specific Agent Policy. Whichever token you use during enrollment determines which policy the agent receives:

| Token belongs to | Agent receives |
|---|---|
| Windows Endpoint | System + Elastic Defend + Windows integration |
| Linux Endpoint | System + Elastic Defend (no Windows) |
| Endpoint Baseline | System + Elastic Defend (no Windows) |

**Verify enrollment in Kibana:**

Navigate to **Fleet → Agents**. The Windows host should appear with:
- **Status:** `Healthy` / `Online`
- **Policy:** `Windows Endpoint`
- **Host name:** Your Windows hostname

**Expected agent status progression:**

| Status | Meaning |
|---|---|
| `Enrolling` | Agent is registering with Fleet Server |
| `Updating` | Agent is downloading and applying its policy |
| `Healthy` / `Online` | Agent is connected and reporting |
| `Offline` | Agent has stopped reporting (network issue, service stopped, or host shutdown) |
| `Unhealthy` | Agent is reporting errors |

**Common enrollment failures:**

| Symptom | Likely Cause | Fix |
|---|---|---|
| TLS certificate error | CA not imported into `LocalMachine\Root` | Repeat Step 6.2 |
| Connection refused / timeout | Fleet Server unreachable from Windows | Check firewall rules for port 8220, verify `SIEM_IP` is correct |
| `invalid enrollment token` | Wrong or expired token | Get the correct token from Kibana Fleet UI for the Windows Endpoint policy |
| Agent enrolls into wrong policy | Used wrong enrollment token | Unenroll agent, re-enroll with the correct token |
| `fleet server is not ready` | Fleet Server container is still starting | Wait 1–2 minutes. Check `docker logs ecp-fleet-server` on the SIEM. |
| Service not running | Agent not installed as a service | Re-run `elastic-agent.exe install` as Administrator |

**Diagnostic commands on Windows:**

```powershell
# Check agent service status
Get-Service elastic-agent

# View agent logs
Get-Content "C:\Program Files\Elastic\Agent\data\elastic-agent-*\logs\elastic-agent-*.ndjson" -Tail 50

# Test Fleet Server connectivity
Test-NetConnection -ComputerName <SIEM_IP> -Port 8220

# Test Elasticsearch connectivity
Invoke-WebRequest -Uri "https://<SIEM_IP>:9200" -UseBasicParsing
```

---

## Step 6.6 — Verify telemetry in Kibana

Once the Windows agent is enrolled and healthy, telemetry should begin arriving. Telemetry depends on the endpoint's local configuration and running services.

### System integration telemetry

The System integration provides baseline Windows telemetry:

| Data | Expected data stream |
|---|---|
| Windows Application log | `logs-system.application-*` |
| Windows Security log | `logs-system.security-*` |
| Windows System log | `logs-system.system-*` |
| System metrics (CPU, memory, etc.) | `metrics-system.*` |

**Verify in Kibana:** Navigate to **Discover** and search for `data_stream.dataset: "system.application"` or `data_stream.dataset: "system.security"`.

### Windows integration telemetry

The Windows integration provides Windows-specific log sources:

| Data | Expected data stream | Prerequisite |
|---|---|---|
| Sysmon events | `logs-windows.sysmon_operational-*` | Sysmon must be installed and running |
| PowerShell Operational (4103–4108) | `logs-windows.powershell_operational-*` | PowerShell Script Block Logging should be enabled |
| Windows Defender events | `logs-windows.windows_defender-*` | Defender is enabled (default on most Windows) |
| Classic PowerShell (400,403,600,800) | `logs-windows.powershell-*` | Classic PowerShell logging is on by default |

### Elastic Defend telemetry

Elastic Defend (EDRComplete) provides endpoint security telemetry:

| Data | Expected data stream |
|---|---|
| Process events | `logs-endpoint.events.process-*` |
| File events | `logs-endpoint.events.file-*` |
| Network events | `logs-endpoint.events.network-*` |
| Registry events | `logs-endpoint.events.registry-*` |
| Security events | `logs-endpoint.events.security-*` |
| Malware protection alerts | `logs-endpoint.alerts-*` |

### Understanding "stream exists" vs "documents arriving"

- **Data stream exists** = the integration/configuration is present and the agent is configured to collect this data
- **Documents arriving** = the endpoint is producing the relevant events and the agent is successfully shipping them

An empty data stream does not necessarily mean the integration is broken. For example:
- `logs-windows.sysmon_operational-*` will be empty if Sysmon is not installed on the Windows host
- `logs-windows.windows_defender-*` may be empty if Defender hasn't generated any events yet
- `logs-windows.powershell_operational-*` may contain no 4104 events if Script Block Logging is not enabled

### API-based telemetry verification

Check for data streams from the SIEM server:

```bash
# List all data streams from the Windows integration
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:9200/_data_stream/logs-windows.*" \
  | jq '.data_streams[] | {name, status}'

# List Elastic Defend data streams
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:9200/_data_stream/logs-endpoint.*" \
  | jq '.data_streams[] | {name, status}'

# List System integration data streams
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:9200/_data_stream/logs-system.*" \
  | jq '.data_streams[] | {name, status}'

# Count recent documents in Sysmon stream (last 15 minutes)
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:9200/logs-windows.sysmon_operational-*/_count" \
  -H "Content-Type: application/json" \
  -d '{"query":{"range":{"@timestamp":{"gte":"now-15m"}}}}'
```

### Kibana UI verification

1. **Discover:** Set the data view to `logs-*` and filter by `data_stream.dataset` to inspect specific streams
2. **Security → Hosts:** After telemetry arrives, the Windows host should appear in the hosts list
3. **Security → Alerts:** If detection rules are enabled (`WindowsDR=1`), alerts fire when matching telemetry is ingested

---

# PHASE 7 — DEPLOY LINUX AND macOS ENDPOINT AGENTS

The stack already created the **Linux Endpoint** policy (System + Elastic Defend, no
Windows integration) and the **Endpoint Baseline** policy (System + Elastic Defend).
Linux agents enroll with the **Linux Endpoint** enrollment token. macOS agents enroll
with the **Endpoint Baseline** enrollment token (there is no macOS-specific policy).

As with Windows, **an Agent Policy is not an agent** — you must install the Elastic Agent
on each host and enroll it with the matching token. No policy creation is needed; only the
manual steps below.

---

## Step 7.1 — Trust the SIEM CA on Linux / macOS

The agent must trust the SIEM CA. Either install the CA into the system trust store, or
pass `--certificate-authorities` at enrollment time (no system-wide change).

**Which CA file to use:** the one exported in Step 6.1 (`~/ca.crt`). If your home
directory also contains an older `elastic-ca.crt`, that is a **stale CA from a previous
stack build** — do NOT use it. If in doubt, compare fingerprints against the live CA:

```bash
docker exec ecp-elasticsearch openssl x509 -in /usr/share/elasticsearch/config/certs/ca/ca.crt -noout -fingerprint -sha256
openssl x509 -in ~/ca.crt -noout -fingerprint -sha256
```

> [!IMPORTANT]
> Merely having `ca.crt` in the home directory does NOT make the agent
> trust the Fleet Server. Elastic Agent does not read `~/`. You MUST either install the
> CA into the system trust store (Option A) or pass `--certificate-authorities` (Option B),
> otherwise enrollment fails with `x509: certificate signed by unknown authority`.

**Option A — system trust store (recommended):**

On **Debian/Ubuntu** Linux:

```bash
sudo cp ca.crt /usr/local/share/ca-certificates/elastic-ca.crt
sudo update-ca-certificates
```

On **RHEL/Fedora** Linux:

```bash
sudo cp ca.crt /etc/pki/ca-trust/source/anchors/elastic-ca.crt
sudo update-ca-trust
```

On **macOS**:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
```

**Option B — per-agent, no system change:**

Pass the CA file directly during enrollment (see Steps 7.4/7.6):

```
--certificate-authorities=/path/to/ca.crt
```

> [!CAUTION]
> Copy ONLY `ca.crt` (the public certificate). NEVER copy `ca.key` to any endpoint.

---

## Step 7.2 — Get the enrollment token

Use the same API as Windows, matching the `policy_id`:

> [!IMPORTANT]
> Policy IDs change on every clean rebuild. Do not rely on the
> values printed in older versions of this guide — read the current `policy_id`
> from the API below (or from **Fleet → Agent policies** in the UI). The ID you
> match on is the one that appears in the API output for the current stack.

| Target OS | Policy (name) |
|---|---|
| Linux | Linux Endpoint |
| macOS | Endpoint Baseline |

```bash
curl -sk -u "${ELASTIC_USERNAME:-elastic}:<YOUR_PASSWORD>" \
  "https://127.0.0.1:5601/api/fleet/enrollment_api_keys?perPage=100" \
  -H "kbn-xsrf: kibana" \
  | jq '.items[] | {policy_id, api_key, active}'
```

You can also get the exact commands from **Fleet → Agents → Add agent** and selecting the
appropriate policy — Kibana shows the download URL and install command for the correct
version.

---

## Step 7.3 — Download and install Elastic Agent on Linux

On the **Linux host**, run the following (version must match your `STACK_VERSION`):

```bash
curl -L -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-<VERSION>-linux-x86_64.tar.gz"
tar -xzf elastic-agent-<VERSION>-linux-x86_64.tar.gz
cd elastic-agent-<VERSION>-linux-x86_64
```

> [!NOTE]
> Prefer the download URL and exact version shown in the Kibana Fleet UI
> (**Add agent** → **Linux** tab) to guarantee version compatibility.

---

## Step 7.4 — Enroll and install the Linux agent

Run as root (or via `sudo`). Enrollment happens automatically at install when the
arguments are supplied:

```bash
sudo ./elastic-agent install \
  --url=https://<SIEM_IP>:8220 \
  --enrollment-token=<TOKEN> \
  --certificate-authorities=/path/to/ca.crt
```

- `<SIEM_IP>` = your SIEM IP (e.g., `10.10.20.10`) — do NOT use `localhost`.
- `<TOKEN>` = the **Linux Endpoint** enrollment token from Step 7.2.
- If you installed the CA into the system store (Step 7.1 Option A), omit
  `--certificate-authorities`.

**Verify the service:**

```bash
sudo systemctl status elastic-agent
sudo /opt/Elastic/Agent/elastic-agent status
```

> **Success:** `active (running)` and agent status `healthy`.

---

## Step 7.5 — Download and install Elastic Agent on macOS

On the **macOS host**, download the matching archive:

```bash
# Apple Silicon (M1/M2/M3/M4)
curl -L -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-<VERSION>-darwin-aarch64.tar.gz"
# Intel
curl -L -O "https://artifacts.elastic.co/downloads/beats/elastic-agent/elastic-agent-<VERSION>-darwin-x86_64.tar.gz"

tar -xzf elastic-agent-<VERSION>-darwin-*.tar.gz
cd elastic-agent-<VERSION>-darwin-*
```

---

## Step 7.6 — Enroll and install the macOS agent

```bash
sudo ./elastic-agent install \
  --url=https://<SIEM_IP>:8220 \
  --enrollment-token=<TOKEN> \
  --certificate-authorities=/path/to/ca.crt
```

- `<TOKEN>` = the **Endpoint Baseline** enrollment token from Step 7.2 (the baseline
  policy has System + Elastic Defend, no OS-specific integration).
- If you imported the CA via Keychain (Step 7.1 Option A), omit
  `--certificate-authorities`.

---

## Step 7.7 — Verify enrollment and telemetry

1. In Kibana, **Fleet → Agents** should now show the Linux/macOS host as **Healthy/Online**
   with the correct policy (Linux Endpoint or Endpoint Baseline).
2. Linux System metrics + logs appear in `metrics-system.*` / `logs-system.*`; Elastic
   Defend events in `logs-endpoint.*`. Verify as in Step 6.6.
3. Detection rules: Linux rules require `LinuxDR=1` in `.env`; macOS rules require
   `MacOSDR=1`. These are applied at first stack start, so enabling them now requires a
   rebuild (or manually enabling rules in Kibana).

**Common enrollment failures:** reuse the troubleshooting table in Step 6.5 — the same
causes apply (TLS/CA trust, wrong token, Fleet Server not reachable on port `8220`).

---

## Step 7.8 — Should the SIEM / Fleet Server host itself run an agent?

Monitoring the management plane is valuable — if the SIEM box itself is compromised you
want host-level telemetry (auth logs, process/audit events, Elastic Defend) for that host.

- **Lab / development:** acceptable to enroll the SIEM host's own agent (e.g., into the
  Linux Endpoint or Endpoint Baseline policy). It is a big improvement over no coverage.
- **Production / enterprise:** it is technically supported but NOT recommended as the only
  control. An agent that reports *into the very stack running on the same host* can be
  suppressed, altered, or killed by an attacker who owns that host — so on-host monitoring
  does not guarantee you get notified. For enterprise hardening, also ship the SIEM host's
  security logs (auth.log / auditd / alerts) to an **independent, out-of-band** destination
  that survives a compromise of the SIEM itself. Keep the SIEM host otherwise dedicated to
  running the stack; endpoint agents belong on separate monitored hosts.

---

# WINDOWS HOST PREREQUISITES

The Windows integration and detection rules only produce results if the Windows host is properly configured.

## Sysmon

**Required for:** `logs-windows.sysmon_operational-*` data stream and Sysmon-based detection rules.

Sysmon must be installed and running on the Windows host. The Elastic Windows integration reads from the `Microsoft-Windows-Sysmon/Operational` event log — if Sysmon is not installed, this log does not exist and no events are collected.

**Verify Sysmon is running:**

```powershell
sc.exe query Sysmon
```

or for 64-bit:

```powershell
sc.exe query Sysmon64
```

> **Success:** Shows `STATE: RUNNING`.

> **If Sysmon is not installed:** Download from [Microsoft Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/sysmon) and install with a configuration that suits your detection needs.

## PowerShell Script Block Logging

**Required for:** Event ID 4104 (Script Block Logging) in `logs-windows.powershell_operational-*`.

Merely enabling the PowerShell Operational stream in the Elastic Windows integration does NOT create 4104 events. Windows itself must have Script Block Logging enabled.

**Verify:**

```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name EnableScriptBlockLogging -ErrorAction SilentlyContinue
```

> **Success:** `EnableScriptBlockLogging` is `1`.

**Enable via Group Policy:**

Computer Configuration → Administrative Templates → Windows Components → Windows PowerShell → Turn on PowerShell Script Block Logging → Enabled

**Enable via registry (local machine):**

```powershell
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" -Name "EnableScriptBlockLogging" -Value 1
```

## Windows Defender

**Required for:** `logs-windows.windows_defender-*` data stream.

Windows Defender telemetry depends on Defender being active and generating events (detections, scans, updates). An empty Defender event stream does not mean the integration is broken — it means Defender has not produced events during the collection period.

## Classic PowerShell Logging

**Required for:** Event IDs 400, 403, 600, 800 in `logs-windows.powershell-*`.

Classic PowerShell (Windows PowerShell) logging is generally enabled by default. These events are recorded in the `Windows PowerShell` event log when PowerShell sessions start and stop.

## Windows DC Audit Policy

**Required for:** Account management and directory service events that detect GenericAll, group membership changes, and SID History abuse.

The Windows Advanced Audit Policy on the Domain Controller must have specific subcategories enabled. **The repository does not configure these** — the AD/domain administrator must enable them via GPO or local policy.

**Required subcategories:**

| Subcategory | Event IDs | What It Detects |
|---|---|---|
| Security Group Management | 4728, 4732, 4735, 4755, 4756 | Users added to security groups |
| User Account Management | 4738, 4741, 4742, 4743 | User account modifications |
| Directory Service Changes | 5136 | Directory attribute changes |

**Enable via auditpol (on the DC):**

```cmd
auditpol /set /subcategory:"Security Group Management" /success:enable /failure:enable
auditpol /set /subcategory:"User Account Management" /success:enable /failure:enable
auditpol /set /subcategory:"Directory Service Changes" /success:enable /failure:enable
```

Or apply via GPO linked to the Domain Controllers OU. No reboot required.

**Verify:**

```cmd
auditpol /get /subcategory:"Security Group Management"
```

## Sysmon Event 10 (ProcessAccess)

**Required for:** LSASS/process-access detection rules.

Sysmon is installed and configured independently. Event ID 10 logs when a process opens a handle to another process (critical for detecting Mimikatz, credential dumping).

**If Event 10 is absent**, these rules will never fire:

- LSASS Process Access via Windows API
- Potential LSASS Memory Dump via PssCaptureSnapShot
- Suspicious Lsass Process Access
- LSASS Memory Dump Handle Access
- Suspicious Module Loaded by LSASS

**Enabling Event 10 requires** appropriate Sysmon XML configuration with `<ProcessAccess>` rules and process filters to manage telemetry volume.

> [!IMPORTANT]
> Event 10 is high-volume. The Windows endpoint administrator
> must tune the Sysmon configuration with exclude filters for known-good
> processes (e.g., svchost.exe, monitoring agents).

**Verify Event 10 is present:**

```powershell
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-Sysmon/Operational'; Id=10; StartTime=(Get-Date).AddHours(-1)} -MaxEvents 5
```

---

# LINUX HOST PREREQUISITES

## Authentication Logging

**Required for:** `system.auth` and `system.syslog` data streams.

The System integration's `logfile` input reads `/var/log/auth.log*`, `/var/log/syslog*`, `/var/log/secure`. Hosts running **journald without rsyslog** (common on minimal Ubuntu 22.04+) never create these files, so Linux authentication telemetry remains empty.

**This is an endpoint logging issue, not a repository defect.**

**Operator choices:**

| Option | Action | Trade-off |
|---|---|---|
| Install rsyslog | `sudo apt install rsyslog && sudo systemctl enable --now rsyslog` | Simplest; creates `/var/log/auth.log` |
| Configure journald input | Modify Linux Endpoint policy in Fleet UI | No extra packages; requires Fleet UI changes |
| Accept the gap | No action | Linux auth events will not be collected |

**Verify auth logging:**

```bash
# Check if auth.log exists
ls /var/log/auth.log

# Check journald has auth events
sudo journalctl _SYSTEMD_UNIT=sshd.service --since "1 hour ago" | tail 5

# Check Elasticsearch has data
curl -sk -u "elastic:<PASSWORD>" "https://127.0.0.1:9200/logs-system.auth-*/_count"
```

## Elastic Agent

The Linux agent must be enrolled into the `Linux Endpoint` policy (System + Elastic Defend). No Windows integration is added to Linux policies.

**Verify agent health:**

```bash
sudo systemctl status elastic-agent
```

In Kibana: **Fleet → Agents** shows the host as **Healthy** on the `Linux Endpoint` policy.

---

# DETECTION RULES

The repository can bulk-enable prebuilt Elastic detection rules at first start, controlled by flags in `.env`:

| Flag | Effect |
|---|---|
| `WindowsDR=1` | Enables prebuilt rules tagged `Windows` or `OS: Windows` |
| `LinuxDR=1` | Enables prebuilt rules tagged `Linux` or `OS: Linux` |
| `MacOSDR=1` | Enables prebuilt rules tagged `macOS` or `OS: macOS` |

**Detection rules do NOT collect telemetry.** They consume telemetry provided by integrations. The chain is:

```
Integration → Agent collects data → Data stream in Elasticsearch → Detection rule queries data → Alert
```

For example:
- Sysmon detection rules require Sysmon telemetry → requires the Windows integration on the agent policy AND Sysmon installed on the Windows host
- PowerShell detection rules targeting Event ID 4104 require Script Block Logging enabled on Windows AND the PowerShell Operational stream ingested via the Windows integration
- Endpoint detection rules require Elastic Defend telemetry → requires the Elastic Defend integration on the agent policy

Enabling a detection rule without the corresponding telemetry pipeline simply means the rule will never fire (no matching data to trigger on).

---

# CONFIGURATION REFERENCE

## Quick Reference: .env Values

| Variable | Required | Default | Where it's used |
|---|---|---|---|
| `SIEM_IP` | **Yes** | — | TLS certificate SANs, Fleet Server URL, ES output URL, Kibana Fleet settings |
| `SIEM_NAT_IP` | No | — | Additional TLS certificate SAN (optional second IP) |
| `SIEM_IFACE` | No | — | Static IP setup script |
| `SIEM_PREFIX` | No | `24` | Subnet mask for static IP setup |
| `ELASTIC_USERNAME` | No | `elastic` | Elasticsearch administrative user, Kibana login, Fleet/Kibana API auth |
| `ELASTIC_PASSWORD` | **Yes** | — | Password for `ELASTIC_USERNAME` |
| `KIBANA_USERNAME` | No | `kibana_system` | Kibana ↔ Elasticsearch internal service credential |
| `KIBANA_PASSWORD` | **Yes** | — | Password for `KIBANA_USERNAME` |
| `KIBANA_ENCRYPTION_KEY` | **Yes** | — | Kibana saved object encryption (alert rules, connectors, etc.) |
| `STACK_VERSION` | No | `9.5.0` | Elasticsearch / Kibana / Elastic Agent image version |
| `WindowsDR` | No | `1` | Enable Windows detection rules at first start |
| `LinuxDR` | No | `0` | Enable Linux detection rules at first start |
| `MacOSDR` | No | `0` | Enable macOS detection rules at first start |

### Authentication overview

| Credential | Used for |
|---|---|
| `ELASTIC_USERNAME` + `ELASTIC_PASSWORD` | All administrative operations: Kibana login, Fleet API, detection engine, Elasticsearch API. This is the admin user. |
| `KIBANA_USERNAME` + `KIBANA_PASSWORD` | Internal service credential. Kibana uses this to connect to Elasticsearch. You do NOT log into Kibana with this. |

---

# DEPENDENCY MAP

```
SIEM_IP
  ├── TLS certificate SANs (all services)
  ├── Fleet Server host URL
  ├── Windows/Linux Agent enrollment URL
  ├── Elasticsearch output URL
  └── Kibana / Fleet configuration

SIEM_NAT_IP
  └── Optional additional certificate SAN

ELASTIC_USERNAME
  ├── Elasticsearch administrative authentication
  └── Kibana / Fleet administrative API operations

ELASTIC_PASSWORD
  └── Elasticsearch administrative authentication

KIBANA_USERNAME
  └── Kibana ↔ Elasticsearch internal service authentication

KIBANA_PASSWORD
  └── Kibana ↔ Elasticsearch internal service authentication

KIBANA_ENCRYPTION_KEY
  └── Kibana encrypted saved objects (alert rules, connectors, etc.)

STACK_VERSION
  └── Elastic component / package version alignment

WindowsDR
  └── Windows detection-rule enablement

LinuxDR
  └── Linux detection-rule enablement

MacOSDR
  └── macOS detection-rule enablement
```

> [!WARNING]
> **Critical:** If you change `SIEM_IP` after first boot, you must `destroy` + `start` (clean rebuild) to regenerate certificates with the new IP in SANs.

> [!IMPORTANT]
> Changing values in `.env` does NOT immediately update running containers. Docker Compose loads `.env` at container creation time. To apply changes, you must recreate the affected containers (`destroy` + `start` for credential/IP changes, or at minimum restart the stack).

---

# SECRET ROTATION & CREDENTIAL MANAGEMENT

This deployment stores secrets in the following places. Rotate them deliberately
and never print them to logs.

| Secret | Where it lives | Persists across `start` | Removed by `destroy` |
|---|---|---|---|
| `ELASTIC_PASSWORD` / `KIBANA_PASSWORD` | `.env` (600, gitignored) | Yes | No (file is outside Docker) |
| Admin credentials fallback | `certs` volume, `.admin_creds` at the volume root (600) | Yes | Yes |
| Fleet Server service token | `fleet-certs` volume, `service-token` (600) | Yes | Yes |
| Fleet Server / ES / Kibana TLS private keys | `certs` / `fleet-certs` volumes | Yes | Yes |
| Fleet enrollment tokens | Kibana → Elasticsearch (Fleet indices) | Yes | Yes |
| Elastic API keys (agent outputs) | Elasticsearch (Fleet-managed) | Yes | Yes |

**Rotation procedures:**

- **`.env` passwords (`ELASTIC_PASSWORD`, `KIBANA_PASSWORD`):** These are set at
  first boot and stored in ES security. To change on a running stack, use the
  Elasticsearch Change Password API (`POST /_security/user/<user>/_password`) and
  update `.env`, then `restart`. For a full rotate-everything, edit `.env` and run
  a clean rebuild (`destroy` + `start`).
- **Fleet Server service token:** Held in `fleet-certs/service-token` (600) and in
  ES (`.security-7`). The setup container rotates it automatically if the file is
  missing but the ES token still exists (DELETE + recreate). To force a rotation
  manually: `docker compose exec elasticsearch ... DELETE
  /_security/service/elastic/fleet-server/credential/token/fleet-server-token`,
  then remove the `service-token` file and restart. This does not invalidate
  already-enrolled agents (they use their own API keys); only re-enrollment of a
  *new* Fleet Server uses the token.
- **Fleet enrollment tokens:** Created per policy by Kibana (Fleet → Enrollment
  Tokens). Revoke/rotate them there. Revoking a token does not disconnect an
  enrolled agent; it only blocks new enrollments using that token.
- **Certificates / CA:** Rebuild to rotate (`destroy` + `start` regenerates the CA
  and all node certs). Agents trust the SIEM CA, so a CA rotation requires agents
  to trust the new CA.
- **Stale credentials after rebuild:** `destroy -v` removes the `certs`,
  `fleet-certs`, `esdata01`, `kibanadata`, and `fleetserverdata` volumes, so old
  service tokens, API keys, enrollment tokens, and stored admin credentials are
  wiped with them. The `.env` file (host-side) is the only secret that survives a
  rebuild — that is intentional and required for the rebuild to bootstrap.

---

# UNINSTALLING AN ELASTIC AGENT

If you want to uninstall an Elastic Agent from an endpoint — for example, to replace a
broken install, re-enroll into a different policy, or clean up a host after a rebuild —
use the appropriate command below. You do not need to do this during a normal deployment.

**On Windows**, run PowerShell as Administrator and use the *installed* binary (no need
to `cd` into the extracted folder):

```powershell
& "C:\Program Files\Elastic\Agent\elastic-agent.exe" uninstall
```

If the agent was never installed as a service, this reports "not installed" — that is
expected and there is nothing else to do.

Alternatively, from the extracted directory (replace `<VERSION>` with your real
`STACK_VERSION`, e.g. `9.5.0`):

```powershell
cd C:\path\to\elastic-agent-<VERSION>-windows-x86_64
.\elastic-agent.exe uninstall
```

**On Linux:**

```bash
sudo /opt/Elastic/Agent/elastic-agent uninstall
```

**What `uninstall` does:** stops and removes the service, deletes local agent state
(`fleet.enc`), and unenrolls the agent from Fleet. If the agent shows as `offline` or
`unhealthy` in **Fleet → Agents**, you can also remove the stale entry there via
**Actions → Unenroll agent / Delete**.

**Reinstalling after a failed install:** if an earlier attempt failed (e.g., enrollment
was rejected) but left the agent installed, re-running `install` errors with
`Error: already installed at: /opt/Elastic/Agent`. Uninstall first (force flag clears a
half-enrolled install), then reinstall:

```bash
sudo /opt/Elastic/Agent/elastic-agent uninstall -f
sudo ./elastic-agent install --url=https://<SIEM_IP>:8220 --enrollment-token=<TOKEN>
```

> [!NOTE]
> After a clean rebuild (`./elastic-container.sh destroy` + `start`), the Fleet
> Server enrollment state is recreated. Any endpoint agent installed *before* the rebuild
> will lose contact with Fleet and must be uninstalled and re-enrolled (Steps 6.4–6.5).

---

# EXTERNAL SECURITY COMPONENTS — OPERATOR SETUP

Zeek (network security monitoring) and Velociraptor (DFIR/forensic investigation) are
**external security components** that extend the Elastic SIEM stack. They are intentionally
**not** installed or administered automatically by `elastic-container.sh`.

**Why these are separate:**

- Infrastructure topology varies between deployments (dedicated servers, shared hosts, cloud)
- Network visibility (SPAN/TAP/mirror) is environment-specific and requires network-team coordination
- Endpoint deployment requires organizational authorization and change management
- DFIR actions must remain analyst-controlled — automatic evidence collection is a security and legal risk
- Velociraptor and Zeek have their own update cycles, configuration, and operational requirements

The repository automates the **Elastic/Fleet side** of the integration. All other steps are
operator-controlled.

---

# ZEEK — NETWORK SECURITY MONITORING OPERATOR SETUP

Zeek provides network traffic analysis and generates structured logs (connection, DNS, HTTP,
SSL, SSH, etc.) that can be ingested into Elastic for SIEM correlation and detection.

### Zeek Host

Zeek runs on a Linux host. It may be:

- **A dedicated Zeek server** — dedicated to network monitoring
- **An existing security host** — shared with other security tooling (e.g., the SIEM host itself, if resources permit)

A dedicated server is **not** mandatory. The repository supports both topologies.

**Resource considerations:** Sizing depends on network traffic volume, the number of Zeek
log types enabled, and the deployment environment. Consult the
[Zeek documentation](https://docs.zeek.org/en/current/) for guidance on CPU, RAM, and disk
requirements for your traffic profile.

### Network Visibility

Zeek can only analyze traffic that reaches its monitoring interface. The operator must ensure
appropriate network visibility through one or more of:

- **SPAN / port mirroring** — switch copies traffic from one port to another
- **Network TAP** — passive hardware device that captures traffic inline
- **Direct inline placement** — Zeek host sits on the network path (monitoring interface in promiscuous mode)
- **Virtual network tapping** — for virtualized or cloud environments

**This is the operator's responsibility.** `elastic-container.sh` does NOT configure:

- Network mirroring, SPAN, or TAP
- Switch or router configuration
- Routing or firewall rules
- Monitoring interface selection

### Install Zeek

**Operator installation procedure — environment-specific.**

Zeek is installed on the Linux host using the distribution's package manager or from source.
Refer to the official [Zeek installation guide](https://docs.zeek.org/en/current/install.html)
for your specific OS and deployment method.

Typical steps:

1. Add the Zeek repository for your Linux distribution
2. Install Zeek packages
3. Verify the installation: `zeek --version`

### Configure Zeek

The operator must configure Zeek to:

- Bind to the correct monitoring interface
- Run as a service
- Generate the required log types
- **Enable JSON output** — the Elastic Zeek integration requires JSON-formatted logs

To enable JSON logging, add the following to `local.zeek` (typically at
`/usr/share/zeek/site/local.zeek` or `/opt/zeek/share/zeek/site/local.zeek`):

```
@load tuning/json-logs
```

Or, depending on your Zeek version:

```
@load policy/tuning/json-logs
```

After configuration, restart the Zeek service and verify JSON logs are being written to the
log directory (default: `/opt/zeek/logs/current`).

### Elastic Agent on the Zeek Host

The Elastic Agent must be installed on the Zeek host **by the operator**. The repository does
NOT remotely install Elastic Agent on any host.

**Operator steps:**

1. **Install Elastic Agent** matching the `STACK_VERSION` of your Elastic deployment
2. **Enroll the agent** into Fleet using the Zeek policy enrollment token
3. **Ensure the agent can read** the Zeek log directory (file permissions)
4. **Verify connectivity** from the Zeek host to Fleet Server (port `8220`) and Elasticsearch (port `9200`)

Enrollment command (run on the Zeek host):

```bash
sudo ./elastic-agent install \
  --url="https://<SIEM_IP>:8220" \
  --enrollment-token="<Zeek policy token>"
```

The enrollment token is obtained from Kibana: **Fleet → Agent policies → Zeek → Enrollment
tokens** (or via the Fleet API).

### Elastic/Fleet Side (Automated)

The repository automates the Elastic/Fleet configuration when `ZEEK_ENABLED=1`:

```
Zeek
 ↓
Zeek JSON logs (conn.log, dns.log, http.log, ssl.log, files.log, ssh.log, weird.log)
 ↓
Elastic Agent (on Zeek host, operator-installed)
 ↓
Fleet Zeek Integration (automated by elastic-container.sh)
 ↓
Elasticsearch (logs-zeek.* data streams)
 ↓
Kibana (Discover, dashboards)
 ↓
Detection Engine (future phase)
```

**Configuration in `.env`:**

```bash
ZEEK_ENABLED=1
ZEEK_LOG_DIR=/opt/zeek/logs/current    # optional, this is the default
```

When `ZEEK_ENABLED=0` (default), no Zeek operations occur and the existing deployment is
unchanged.

### Telemetry Verification

End-to-end telemetry must be validated after deployment. This has NOT been validated in a
live environment during this implementation cycle.

**Verification steps (operator performs after deployment):**

1. **Zeek is running:** `systemctl status zeek` (or your service manager)
2. **JSON logs exist:** `ls /opt/zeek/logs/current/conn.log` — file should exist and contain JSON
3. **Elastic Agent is healthy:** In Kibana, **Fleet → Agents** shows the Zeek host as **Healthy**
4. **Agent is enrolled:** Agent policy shows "Zeek" in **Fleet → Agent policies**
5. **Zeek documents in Elasticsearch:**

   ```bash
   curl -sk -u "elastic:<PASSWORD>" \
     "https://127.0.0.1:9200/logs-zeek.connection-*/_count" \
     -H "Content-Type: application/json" \
     -d '{"query":{"range":{"@timestamp":{"gte":"now-15m"}}}}'
   ```

   A count > 0 confirms Zeek connection logs are being ingested.

6. **Zeek data in Kibana:** **Discover** → set data view to `logs-zeek.*` → verify documents
   with expected fields (source IP, destination IP, source port, destination port, protocol,
   timestamp)

> [!NOTE]
> **Status:** PARTIAL — Fleet integration is configured; live telemetry requires a running
> Zeek sensor with network visibility and an enrolled Elastic Agent.

---

# VELOCIRAPTOR — DFIR OPERATOR SETUP

Velociraptor is an advanced endpoint visibility and DFIR (Digital Forensics and Incident
Response) tool. It is **intentionally separate** from the Elastic SIEM deployment and is
NOT installed or administered by `elastic-container.sh`.

### Velociraptor Server

**Operator installation procedure — environment-specific.**

The Velociraptor server provides centralized management for endpoint investigation and
evidence collection. Refer to the official
[Velociraptor documentation](https://docs.velociraptor.app/) for current installation
instructions.

**Operator steps:**

1. **Prepare the server host** — Linux server with appropriate resources
2. **Install Velociraptor** — follow the official installation guide for your environment
3. **Initial configuration** — generate server configuration, set admin credentials
4. **TLS/certificates** — Velociraptor uses TLS for server-client communication
5. **Authentication** — configure admin access (username/password or SSO)
6. **Service operation** — run Velociraptor as a systemd service or equivalent
7. **Network access** — ensure the server is reachable from authorized endpoints
8. **Permissions** — configure appropriate file system and network permissions

### Velociraptor Client

**Operator deployment — environment-specific.**

Velociraptor clients are deployed to endpoints that require DFIR capability. Client deployment
requires **explicit authorization** — not all endpoints should receive a Velociraptor client.

**Operator steps:**

1. **Prepare client packages** — generate from the Velociraptor server UI or CLI
2. **Deploy to authorized endpoints** — via package manager, GPO, or manual installation
3. **Client enrollment** — clients connect to the Velociraptor server on first run
4. **Verify connectivity** — in the Velociraptor server UI, confirm clients appear as online
5. **Endpoint authorization** — configure which artifacts each client can run
6. **Least-privilege** — restrict client permissions to only what is required for DFIR operations

### DFIR Workflow

The intended workflow for incident response uses Velociraptor as the analyst-controlled
investigation tool:

```
Elastic Alert (from Detection Engine)
    ↓
L1 Analyst (triage, initial assessment)
    ↓
Case / Escalation (determine severity and scope)
    ↓
Analyst determines DFIR is required
    ↓
Velociraptor (controlled forensic investigation)
    ↓
Evidence handling / investigation results
```

**This is intentional.** Velociraptor is NOT automatically triggered by Elastic alerts.
Evidence collection requires:

- Analyst authorization
- Proper chain-of-custody procedures
- Organizational approval for endpoint investigation
- Documented scope of investigation

---

# AUTOMATED VS MANUAL TASKS

### Automated by elastic-container.sh

| Task | Condition |
|---|---|
| Elastic SIEM deployment (Elasticsearch, Kibana, Fleet Server) | Always |
| Fleet Server configuration and output | Always |
| Fleet agent policy creation (Windows, Linux, Baseline) | First start |
| Zeek integration package installation | `ZEEK_ENABLED=1` |
| Zeek Fleet policy creation | `ZEEK_ENABLED=1` |
| Zeek integration attachment to policy | `ZEEK_ENABLED=1` |
| Configuration validation (IP, ports, passwords) | Always |
| Idempotent policy/integration setup | Always |
| Certificate generation and TLS | Always |

### Manual / Operator-Controlled

| Task | Responsible Party |
|---|---|
| Zeek installation and configuration | Operator |
| Zeek JSON logging setup | Operator |
| Zeek monitoring interface configuration | Operator / Network team |
| SPAN / TAP / network visibility | Network team |
| Elastic Agent installation on Zeek host | Operator |
| Elastic Agent enrollment on Zeek host | Operator |
| Velociraptor Server installation | Operator |
| Velociraptor Server configuration | Operator |
| Velociraptor Client deployment | Operator |
| Velociraptor Client authorization | Operator / SOC lead |
| DFIR investigation | SOC analyst |
| Evidence collection and handling | DFIR team |
| Enterprise firewall / network changes | Network team |

---

# DEPLOYMENT ORDER

The following sequence shows the end-to-end deployment flow. Phases marked **(automated)**
are handled by `elastic-container.sh`. Phases marked **(manual)** are operator-controlled.

```
PHASE 1 — Deploy Elastic SIEM         (automated)
    ./elastic-container.sh start
        ↓
PHASE 2 — Verify stack health          (automated + manual verification)
    Elasticsearch / Kibana / Fleet / agents
        ↓
PHASE 3 — Prepare Zeek host            (manual)
    Linux host, resources, network interface
        ↓
PHASE 4 — Configure Zeek               (manual)
    JSON logging, monitoring interface, service
        ↓
PHASE 5 — Install Elastic Agent        (manual)
    On Zeek host, enroll into Fleet
        ↓
PHASE 6 — Enable Zeek integration      (automated)
    ZEEK_ENABLED=1, ./elastic-container.sh start
        ↓
PHASE 7 — Verify Zeek telemetry        (manual)
    Elasticsearch documents, Kibana Discover
        ↓
PHASE 8 — Prepare Velociraptor         (manual)
    Server installation, configuration
        ↓
PHASE 9 — Deploy Velociraptor clients  (manual)
    Authorized endpoints, enrollment
        ↓
PHASE 10 — DFIR workflow               (manual)
    Alert → Case → Analyst → Velociraptor investigation
```

---

# TOPOLOGY FLEXIBILITY

The repository supports multiple deployment topologies. Zeek and Velociraptor are NOT
required and do NOT need dedicated servers.

### Option A — Dedicated Zeek Host

```
SIEM Host                     Zeek Host
┌─────────────────┐          ┌─────────────────┐
│ Elasticsearch   │          │ Zeek            │
│ Kibana          │          │ Elastic Agent   │
│ Fleet Server    │◄─────────│ (reads logs)    │
│ Elastic Agent   │          └─────────────────┘
└─────────────────┘
```

The Zeek host runs Zeek with network visibility and an Elastic Agent that ships logs
to the SIEM's Fleet Server.

### Option B — Shared Security Host

```
Shared Security Host
┌─────────────────────────┐
│ Zeek                    │
│ Elastic Agent           │
│ (optional: other tools) │
└────────────┬────────────┘
             │
             ▼
┌─────────────────┐
│ SIEM Host       │
│ Elasticsearch   │
│ Kibana          │
│ Fleet Server    │
└─────────────────┘
```

Zeek and Elastic Agent run on an existing security host. The Elastic Agent enrolls
into the SIEM's Fleet Server remotely.

### Option C — Zeek Not Enabled

```
SIEM Host
┌─────────────────┐
│ Elasticsearch   │
│ Kibana          │
│ Fleet Server    │
│ Elastic Agent   │
└─────────────────┘
```

`ZEEK_ENABLED=0` (default). The Elastic SIEM operates without Zeek network telemetry.
Endpoint agents (Windows, Linux) still provide host-level telemetry.

**The repository does NOT require a dedicated Zeek server.** The operator chooses the
deployment topology that fits their infrastructure.

---

# VELOCIRAPTOR SEPARATION

> [!WARNING]
> Velociraptor is intentionally outside the automation boundary of this repository.

`elastic-container.sh` does **NOT**:

- SSH to Velociraptor hosts
- Install Velociraptor Server
- Configure Velociraptor Server
- Install Velociraptor Clients
- Enroll Velociraptor Clients
- Execute VQL queries
- Collect forensic evidence
- Automatically trigger DFIR from Elastic alerts

This is **intentional** and must remain documented. Velociraptor is an independent tool
that provides DFIR capability under analyst control. The Elastic SIEM and Velociraptor
complement each other but operate through separate automation boundaries.

---

# SECURITY & OPERATIONAL NOTES

### Endpoint Authorization

Velociraptor client deployment requires explicit organizational authorization. Not all
endpoints should receive a Velociraptor client. Only endpoints approved for DFIR
investigation should have the client installed.

### Least Privilege

- Fleet agents use dedicated service tokens (not the `elastic` superuser)
- Velociraptor clients should be configured with minimal required artifact permissions
- Zeek host Elastic Agent only needs read access to Zeek log directories

### TLS

All components use TLS:

- Elasticsearch: TLS on ports 9200 (HTTP) and 9300 (transport)
- Kibana: TLS on port 5601
- Fleet Server: TLS on port 8220
- Velociraptor: TLS for server-client communication (operator-configured)
- Zeek host → SIEM: TLS-verified connection (CA must be trusted)

### Credential Protection

- `.env` contains passwords and is set to `0600` permissions
- Fleet enrollment tokens are per-policy and can be revoked
- Velociraptor credentials are managed independently by the Velociraptor server
- No credentials are exposed in documentation or command lines

### Network Exposure

- Elasticsearch port `9200` is published for Fleet agent telemetry routing
- Fleet Server port `8220` is published for agent enrollment
- Kibana port `5601` is published for administrator access
- Velociraptor server port is operator-configured
- Firewall rules for all ports are the operator's responsibility

### Evidence Handling

Velociraptor evidence collection is analyst-initiated and requires:

- Documented authorization
- Chain-of-custody procedures
- Secure storage for collected artifacts
- Compliance with organizational policies

### DFIR Authorization

DFIR investigations through Velociraptor require analyst authorization. The workflow is:

1. Elastic Alert fires
2. L1 Analyst triages
3. Case is created / escalated
4. Analyst determines DFIR is required
5. Analyst uses Velociraptor to investigate
6. Evidence is collected under proper authorization

Automatic evidence collection is NOT implemented and must NOT be implemented through
this repository.

---

# TELEMETRY VALIDATION

After deploying the stack and enrolling agents, use these checks to verify
telemetry is flowing correctly.

## Linux Telemetry Validation

```bash
# 1. Agent is healthy
sudo systemctl status elastic-agent

# 2. Auth logging is available
ls /var/log/auth.log    # exists if rsyslog is installed

# 3. Journald has auth events
sudo journalctl _SYSTEMD_UNIT=sshd.service --since "1 hour ago" | tail 5

# 4. Elasticsearch has Linux auth data
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/logs-system.auth-*/_count" \
  -H "Content-Type: application/json" \
  -d '{"query":{"range":{"@timestamp":{"gte":"now-1h"}}}}'

# 5. Process/file/network events from Elastic Defend
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/logs-endpoint.events.process-*/_count" \
  -H "Content-Type: application/json" \
  -d '{"query":{"range":{"@timestamp":{"gte":"now-1h"}}}}'
```

## Windows Telemetry Validation

```powershell
# 1. Agent is healthy
Get-Service elastic-agent

# 2. Sysmon is running
sc.exe query Sysmon

# 3. Sysmon Event 10 is present (if configured)
Get-WinEvent -FilterHashtable @{
    LogName='Microsoft-Windows-Sysmon/Operational'
    Id=10
    StartTime=(Get-Date).AddHours(-1)
} -MaxEvents 5 -ErrorAction SilentlyContinue

# 4. Security log has events
Get-WinEvent -FilterHashtable @{
    LogName='Security'
    Id=4624,4625,4688
    StartTime=(Get-Date).AddHours(-1)
} -MaxEvents 5

# 5. Audit policy is configured
auditpol /get /subcategory:"Security Group Management"
auditpol /get /subcategory:"User Account Management"
```

## Elasticsearch Validation (from SIEM host)

```bash
# List all data streams
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/_data_stream/logs-*" \
  | jq '.data_streams[] | {name, status}' | head -30

# Check Windows Security events
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/logs-system.security-*/_count"

# Check Sysmon events
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/logs-windows.sysmon_operational-*/_count"

# Check endpoint events (Elastic Defend)
curl -sk -u "elastic:<PASSWORD>" \
  "https://127.0.0.1:9200/logs-endpoint.events.*/_count"
```

## Kibana UI Validation

1. **Discover** — set data view to `logs-*`, filter by `data_stream.dataset` to
   inspect specific streams
2. **Fleet → Agents** — all agents should show **Healthy**
3. **Security → Alerts** — if detection rules are enabled, alerts should appear
   when matching telemetry arrives
