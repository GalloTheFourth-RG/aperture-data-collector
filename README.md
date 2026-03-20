# Aperture Data Collector

> **Open-source data collection for Azure Virtual Desktop**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![PowerShell 7+](https://img.shields.io/badge/PowerShell-7%2B-5391FE?logo=powershell&logoColor=white)
![Azure](https://img.shields.io/badge/Azure-AVD-0078D4?logo=microsoftazure&logoColor=white)

Collects ARM resource inventory, Azure Monitor metrics, and Log Analytics (KQL) query results from your AVD deployment and exports them as a portable **collection pack** — a ZIP of JSON files you can feed into any tooling.

**No analysis, no scoring, no proprietary logic.** Just raw data, fully transparent.

---

## ⚡ Quick Install

Clone the repo:

```powershell
git clone https://github.com/GalloTheFourth-RG/aperture-data-collector.git
cd avd-data-collector
```

Or download the ZIP from GitHub: **Code** → **Download ZIP** → extract to a folder.

---

## 🚀 Quick Start

```powershell
# Dry run — preview what will be collected (no data leaves Azure)
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -DryRun

# Full collection — ARM + metrics + KQL
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -LogAnalyticsWorkspaceResourceIds @(
        "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"
    )

# Full collection with ALL extended data (cost, network, storage, images, etc.)
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -LogAnalyticsWorkspaceResourceIds @("/subscriptions/.../workspaces/<name>") `
    -IncludeAllExtended `
    -IncludeReservedInstances
```

Output: `Aperture-CollectionPack-YYYYMMDD-HHMMSS.zip`

---

## 📋 What It Collects

| Category | Data | API Source |
|----------|------|-----------|
| **Host Pools** | Configuration, load balancing, RDP settings | `Get-AzWvdHostPool` |
| **Session Hosts** | Status, agent version, health, active sessions | `Get-AzWvdSessionHost` |
| **Virtual Machines** | Size, OS, zones, disks, NICs, security profile, extensions | `Get-AzVM` |
| **VM Scale Sets** | VMSS config + individual instance details | `Get-AzVmss` |
| **Application Groups** | App group types, host pool assignments | `Get-AzWvdApplicationGroup` |
| **Scaling Plans** | Autoscale definitions, schedules, pool assignments | ARM API |
| **Metrics** | CPU, memory, disk IOPS per VM (configurable lookback) | `Get-AzMetric` |
| **Log Analytics** | 36 KQL queries — connections, errors, profiles, Shortpath, agent health | `Invoke-AzOperationalInsightsQuery` |
| **Capacity Reservations** | CRG utilization, allocated vs used capacity | ARM REST API |
| **Quota Usage** | Per-region vCPU quota (current / limit) | `Get-AzVMUsage` |
| **Reserved Instances** | RI orders, SKUs, terms, expiry, utilization | `Az.Reservations` |
| **Cost Data** ⁺ | Per-VM and infrastructure costs (last 30 days) | Cost Management API |
| **Network Topology** ⁺ | Subnets, VNets, NSG rules, private endpoints, NAT Gateway | `Az.Network` + ARM |
| **Image Analysis** ⁺ | Gallery image versions, marketplace freshness | ARM API |
| **Storage** ⁺ | FSLogix storage accounts, file shares, capacity | `Az.Storage` |
| **Orphaned Resources** ⁺ | Unattached disks, unused NICs, unassociated PIPs | ARM |
| **Diagnostics/Alerts** ⁺ | Diagnostic settings, alert rules, activity log | ARM REST API |
| **Governance** ⁺ | Policy assignments, resource tags | ARM REST API |

> ⁺ = Extended collection (opt-in via individual flags or `-IncludeAllExtended`)

---

## 🔒 Security & Privacy

This section documents the security posture of the Aperture Data Collector for review by information security, compliance, and risk teams.

### Security Guarantees

| Guarantee | Detail |
|-----------|--------|
| **Read-only** | Every API call is a `GET` or read-only cmdlet (`Get-AzVM`, `Get-AzWvdHostPool`, etc.). The script never creates, modifies, or deletes any Azure resource. |
| **No outbound data transfer** | All collected data is written to the local file system only. The script makes no calls to external services, telemetry endpoints, or third-party APIs. |
| **No credential storage** | The script does not write credentials, tokens, or secrets to output files. Authentication uses module-managed sessions (`Az.Accounts` and optional `Microsoft.Graph.Authentication` for `-IncludeIntune`). |
| **Transparent output** | All output is plain JSON — fully inspectable, filterable, and redactable before sharing. |
| **No executable code in output** | The collection pack ZIP contains only JSON data files and a metadata manifest. No scripts, binaries, or executable content. |
| **Signed & auditable** | The script is open source (MIT). Your security team can review every line of code before execution. |

### What the Script Accesses

> **Detailed setup guide:** See [docs/PERMISSIONS.md](docs/PERMISSIONS.md) for the full RBAC matrix, setup commands, custom role definitions, and troubleshooting.

| Azure Resource | Access Type | Required Role | Purpose |
|---------------|-------------|---------------|---------|
| Subscriptions | Read | Reader | Enumerate AVD resources |
| Host pools, session hosts, app groups | Read | Reader | AVD inventory |
| Virtual machines, NICs, disks | Read | Reader | VM configuration and sizing |
| Azure Monitor metrics | Read | Reader | CPU, memory, disk performance |
| Log Analytics workspaces | Query | Log Analytics Reader | Session, connection, and error telemetry |
| Cost Management API | Read | Cost Management Reader | Per-VM cost data (opt-in only) |
| Network resources | Read | Reader | Subnet, NSG, VNet topology (opt-in only) |
| Storage accounts | Read | Reader | FSLogix share analysis (opt-in only) |
| Reserved Instances | Read | Reservations Reader | RI utilization (opt-in only) |
| Intune managed devices | Read | Global Reader or Intune Administrator | Session host enrollment cross-reference (opt-in: `-IncludeIntune`, separate Graph sign-in) |

> **Intune note:** `-IncludeIntune` uses Microsoft Graph API with a **separate browser sign-in** (not Azure ARM). Requires the `Microsoft.Graph.Authentication` PowerShell module. See [docs/PERMISSIONS.md](docs/PERMISSIONS.md#intune-integration-separate-auth) for full setup details.

### What Is NOT Collected

The script does **not** access or collect:

- Passwords, secrets, certificates, or key vault contents
- File share contents, user files, or profile data
- Application data or database contents
- Azure AD/Entra ID user attributes beyond UPN (for session correlation)
- Network traffic or packet captures
- OS-level configuration (registry, local policies, Group Policy)
- Any data from on-premises or non-Azure systems

### Network Behaviour

The script communicates with Azure management plane APIs (`management.azure.com`, `api.loganalytics.io`) and, when `-IncludeIntune` is enabled, Microsoft Graph (`graph.microsoft.com`) using your authenticated module sessions. It does not:

- Open any listening ports
- Make DNS queries to non-Azure domains
- Establish outbound connections to any IP or domain not owned by Microsoft Azure
- Use WebSockets, SignalR, or persistent connections
- Download any external content or dependencies at runtime

### PII Scrubbing

Add `-ScrubPII` to anonymize all identifiable data **before** it is written to disk:

| Data Category | Example Before | Example After |
|--------------|---------------|---------------|
| VM names | `avd-prod-vm-001` | `Host-3F7C` |
| Host pool names | `HP-Finance-US` | `Pool-D4E5` |
| Usernames (UPN) | `jsmith@contoso.com` | `User-A1B2` |
| Subscription IDs | `12345678-abcd-...` | `Sub-F6A1` |
| Resource groups | `rg-avd-prod` | `RG-B2C3` |
| IP addresses | `10.0.1.50` | `IP-7D8E` |
| ARM resource IDs | `/subscriptions/12345.../rg-prod/...` | `/subscriptions/Sub-F6A1/resourceGroups/RG-B2C3/...` |
| Storage accounts | `stfslogixprod01` | `Storage-9A2B` |
| Subnet names | `snet-avd-prod` | `Subnet-C3D4` |

- Uses **SHA256 hashing** with a per-run random salt
- Same entity always maps to the same anonymous ID within a run (correlations preserved)
- Different runs produce different IDs (no cross-run linkability)
- Scrubbing occurs in memory before any file is written — the raw data never touches disk

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-sub-id") `
    -LogAnalyticsWorkspaceResourceIds @("/subscriptions/.../workspaces/your-ws") `
    -ScrubPII
```

### Inspect Before Sharing

The output ZIP contains only plain JSON files. Before sharing:

1. Unzip the collection pack
2. Open any JSON file in a text editor or VS Code
3. Search for any strings you are uncomfortable sharing
4. Delete or redact specific files, then re-zip

### HIPAA & Healthcare Environments

For healthcare organisations subject to HIPAA:

- The collector does **not** access, process, or store Protected Health Information (PHI)
- Session telemetry from Log Analytics contains UPN and connection metadata only — no clinical data
- Use `-ScrubPII` to anonymize all UPN fields before the data leaves the environment
- The output contains infrastructure configuration and performance metrics — no patient data, medical records, or clinical application data
- The script runs on an administrator workstation and does not interact with clinical systems, EHR databases, or medical devices
- Collection can be performed by your internal team and reviewed before sharing with external consultants

---

## 📦 Requirements

| Requirement | Details |
|-------------|---------|
| **PowerShell** | 7+ (`pwsh.exe`, not `powershell.exe`) |
| **Az Modules** | `Az.Accounts`, `Az.Compute`, `Az.DesktopVirtualization`, `Az.Monitor`, `Az.OperationalInsights`, `Az.Resources` |
| **Optional Modules** | `Az.Network` (network topology), `Az.Storage` (storage analysis), `Az.Reservations` (RI collection), `Microsoft.Graph.Authentication` (`-IncludeIntune`) |
| **Azure RBAC** | **Reader** on AVD subscriptions + **Log Analytics Reader** on workspaces |

Install the Az modules if you don't have them:

```powershell
Install-Module Az.Accounts, Az.Compute, Az.DesktopVirtualization, Az.Monitor, Az.OperationalInsights, Az.Resources -Scope CurrentUser
```

---

## ⚙️ Parameters

### Required

| Parameter | Description |
|-----------|-------------|
| `-TenantId` | Azure AD / Entra ID tenant ID |
| `-SubscriptionIds` | Array of subscription IDs containing AVD resources |

### Recommended

| Parameter | Description |
|-----------|-------------|
| `-LogAnalyticsWorkspaceResourceIds` | Workspace resource IDs for KQL queries |

### Collection Control

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SkipAzureMonitorMetrics` | `$false` | Skip CPU/memory/disk metric collection |
| `-SkipLogAnalyticsQueries` | `$false` | Skip all KQL queries |
| `-MetricsLookbackDays` | `7` | Days of metrics history (1–30) |
| `-MetricsTimeGrainMinutes` | `15` | Aggregation interval (5/15/30/60 min) |
| `-IncludeCapacityReservations` | `$false` | Collect capacity reservation group data |
| `-IncludeQuotaUsage` | `$false` | Collect per-region vCPU quota data |
| `-IncludeReservedInstances` | `$false` | Collect Azure Reserved Instances (requires Az.Reservations) |
| `-IncludeIntune` | `$false` | Collect Intune managed devices via Microsoft Graph (requires Microsoft.Graph.Authentication, reuses existing Graph context when possible, including across runs when CurrentUser context is available) |
| `-ScrubPII` | `$false` | Anonymize all identifiable data before export |

### Extended Collection (v1.1.0)

Use `-IncludeAllExtended` to enable all of these at once, or pick individually:

| Parameter | Description |
|-----------|-------------|
| `-IncludeCostData` | Azure Cost Management per-VM and infrastructure costs (30 days) |
| `-IncludeNetworkTopology` | VNet/subnet analysis, NSG rules, private endpoints, NAT Gateway |
| `-IncludeImageAnalysis` | Compute Gallery image versions, marketplace image freshness |
| `-IncludeStorageAnalysis` | FSLogix storage accounts, file share capacity and quotas |
| `-IncludeOrphanedResources` | Unattached disks, unused NICs, unassociated public IPs |
| `-IncludeDiagnosticSettings` | Host pool diagnostic log forwarding configuration |
| `-IncludeAlertRules` | Azure Monitor metric alerts and scheduled query rules |
| `-IncludeActivityLog` | Activity Log entries (last 7 days) per AVD resource group |
| `-IncludePolicyAssignments` | Azure Policy assignments and compliance state |
| `-IncludeResourceTags` | Tag extraction from VMs, host pools, storage accounts |

### Intune Device Enrollment

| Parameter | Description |
|-----------|-------------|
| `-IncludeIntune` | Cross-reference AVD session hosts against Intune managed devices to report enrollment status, compliance state, and encryption. Requires `Microsoft.Graph.Authentication` module and `DeviceManagementManagedDevices.Read.All` + `Policy.Read.All` Graph permissions. Reuses existing Graph context when tenant/scope already match, and requests `CurrentUser` context for cross-run reuse when supported by the Graph module. Not included in `-IncludeAllExtended` (separate Graph auth flow). |

### Incident Window

The incident window feature lets you collect a **second, focused set of Azure Monitor metrics and KQL query results** covering a specific past outage or performance event. This sits alongside your baseline data (default 7-day lookback) so your consultant can compare normal-state performance against the incident period side-by-side.

**When to use:** Users reported lag, disconnections, or login failures during a known time window and you want targeted data for root cause analysis.

| Parameter | Description |
|-----------|-------------|
| `-IncludeIncidentWindow` | Collect a second set of metrics and KQL queries for a specific incident period |
| `-IncidentWindowStart` | Start of incident window (datetime). Default: 14 days ago |
| `-IncidentWindowEnd` | End of incident window (datetime). Default: now |

The incident window produces a separate `metrics-incident.json` file and incident-prefixed KQL results (connections, peak concurrency, profile load times, errors, connection quality) that are analysed alongside baseline data in the evidence pack's **Incident Analysis** tab.

### Operational

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DryRun` | `$false` | Preview collection scope without running |
| `-SkipDisclaimer` | `$false` | Skip the interactive disclaimer prompt |
| `-DisconnectGraphOnExit` | `$false` | When `-IncludeIntune` is used, disconnect Microsoft Graph at the end instead of retaining context for reuse |
| `-OutputPath` | `.` | Directory for the output collection pack |

---

## 📊 Output

The collector produces a ZIP containing JSON data files:

```
Aperture-CollectionPack-20260225-120000/
├── collection-metadata.json         # Schema version, parameters, counts
├── host-pools.json                  # Host pool configurations
├── session-hosts.json               # Session host status & health
├── virtual-machines.json            # Full VM inventory
├── metrics-baseline.json            # Azure Monitor metric datapoints
├── metrics-incident.json            # Incident window metrics (if requested)
├── la-results.json                  # All KQL query results
├── diagnostic-readiness.json        # Diagnostic data availability per table group
├── scaling-plans.json               # Autoscale plan definitions
├── scaling-plan-assignments.json    # Plan-to-pool assignments
├── scaling-plan-schedules.json      # Schedule details per plan
├── app-groups.json                  # Application groups
├── vmss.json                        # VM Scale Set configurations
├── vmss-instances.json              # VMSS instance details
├── capacity-reservation-groups.json # CRG utilization (if requested)
├── quota-usage.json                 # vCPU quota (if requested)
├── reserved-instances.json          # Reserved Instance data (if requested)
├── actual-cost-data.json            # Per-VM daily costs (extended)
├── vm-actual-monthly-cost.json      # VM monthly cost lookup (extended)
├── infra-cost-data.json             # Infrastructure costs per RG (extended)
├── cost-access.json                 # Cost API access status (extended)
├── subnet-analysis.json             # Subnet details + NSG coverage (extended)
├── vnet-analysis.json               # VNet DNS, peering, topology (extended)
├── private-endpoint-findings.json   # Private endpoint status (extended)
├── nsg-rule-findings.json           # Risky NSG inbound rules (extended)
├── orphaned-resources.json          # Unattached disks, unused NICs (extended)
├── fslogix-storage-analysis.json    # Storage account analysis (extended)
├── fslogix-shares.json              # File share details (extended)
├── diagnostic-settings.json         # Host pool diagnostic config (extended)
├── alert-rules.json                 # Azure Monitor alerts (extended)
├── activity-log.json                # Activity log entries (extended)
├── policy-assignments.json          # Azure Policy assignments (extended)
├── gallery-analysis.json            # Compute Gallery images (extended)
├── gallery-image-details.json       # Gallery image version details (extended)
├── marketplace-image-details.json   # Marketplace image data (extended)
└── resource-tags.json               # Resource tags (extended)
```

---

## 🔍 KQL Queries (36)

All queries live in `queries/` and can be customized. Categories:

| Category | What It Captures |
|----------|-----------------|
| **Connections** | Summary, success rate, login time, session duration, peak & hourly concurrency |
| **Errors** | Error classification, connection failures, disconnect reasons |
| **Disconnects** | By host, heatmap, CPU correlation, reconnection loops |
| **Network** | RTT/bandwidth quality, cross-region, Shortpath usage/effectiveness/transport |
| **Performance** | Process CPU/memory consumption, CPU percentiles per host |
| **Profiles** | FSLogix profile load performance, checkpoint login decomposition |
| **Agent Health** | RD Agent status, version distribution, health check results |
| **Autoscale** | Scaling activity, detailed evaluation per host pool |
| **Environment** | Client OS, identity join type, table discovery |
| **Transport** | Multi-link transport negotiation and distribution |

---

## 🔗 Offline Analysis Workflow

The collection pack ZIP is designed for offline, disconnected analysis — no Azure credentials required after collection:

1. **Collect** — Run the collector against the customer's Azure environment
2. **Share** — Send the ZIP to the analyst (use `-ScrubPII` to anonymize before sharing)
3. **Analyse** — The analyst ingests the ZIP with their assessment tooling — no Azure access needed

This separation enables:
- **Delegated collection** — someone with Azure access runs the collector; the analyst works offline
- **Privacy control** — PII scrubbing ensures sensitive data never leaves the customer's control
- **Repeatability** — re-analyse the same data with updated tooling or different parameters
- **Archival** — keep collection packs for historical comparison across engagements

---

## ⏱️ Runtime Estimates

Azure Virtual Desktop supports up to **10,000 session hosts per host pool** and **25,000 VMs per subscription per region** ([Azure service limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/azure-subscription-service-limits)). The collector is designed to handle environments at these scales.

| Environment Size | VMs | Estimated Time |
|-----------------|-----|----------------|
| Small | ~50 | 3–5 min |
| Medium | ~200 | 8–15 min |
| Large | ~500 | 15–25 min |
| Very Large | ~1,500 | 30–60 min |
| Enterprise | ~3,000 | 60–90 min |
| Large Enterprise | 5,000+ | 90–150+ min |

**What drives runtime:**

| Collection Phase | Scales With | Impact |
|-----------------|-------------|--------|
| ARM resources (host pools, VMs, NICs) | Resource groups | Fast — bulk-fetched per RG |
| Azure Monitor metrics | VM count | **Primary time driver** — per-VM with parallel processing |
| Log Analytics (36 KQL queries) | Workspace count | Moderate — parallelized per workspace |
| Extended collection (costs, network, storage, orphans, diagnostics, alerts) | Subscription scope | Adds 5–15 min when enabled |

**Tips for large environments:**
- Use `-SkipAzureMonitorMetrics` for inventory-only runs (~2–5 min regardless of size)
- Tune `-MetricsParallel` (default 15) and `-KqlParallel` (default 5) for throttle-sensitive tenants
- Reduce `-MetricsLookbackDays` (default 7) to shorten the metrics window
- Use `-MetricsTimeGrainMinutes 60` (default 15) for coarser data with faster collection
- For 5,000+ VM environments, consider collecting during off-peak hours to avoid API throttling

---

## 📁 Project Structure

```
aperture-data-collector/
├── build.ps1                  # Build script (embeds KQL -> dist/)
├── src/                       # Source (edit here)
│   └── Collect-ApertureData.ps1
├── dist/                      # Built distributable (self-contained)
│   └── Collect-ApertureData.ps1
├── queries/                   # 36 KQL query files (customizable)
│   ├── kqlTableDiscovery.kql
│   ├── kqlWvdConnections.kql
│   ├── kqlConnectionErrors.kql
│   └── ...
├── docs/                      # Documentation
│   ├── QUERIES.md
│   ├── SCHEMA.md
│   └── USER-MANUAL.md
├── tools/                     # Development utilities
├── examples/                  # Usage examples
├── LICENSE                    # MIT License
├── CHANGELOG.md
└── CONTRIBUTING.md
```

---

## ⚠️ Disclaimer

This tool is provided as-is under the [MIT License](LICENSE). It is **not affiliated with, endorsed by, or supported by Microsoft**.

While the script performs only **read-only** operations against Azure APIs and does not create, modify, or delete any resources, you run it at your own risk. Always review scripts before executing them in production environments.

This tool is not a substitute for professional Azure consulting services or Microsoft support. No warranty or support guarantee is provided. See the [LICENSE](LICENSE) for full terms.

---

## 📜 License

[MIT](LICENSE) — use it however you want.

---

## 🤝 Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). PRs welcome for new KQL queries, bug fixes, and docs.
