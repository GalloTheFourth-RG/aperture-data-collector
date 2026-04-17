# Aperture Data Collector — User Manual

**Open-source data collection for Azure Virtual Desktop**

> Version 1.6.2 | For PowerShell 7.0+

---

## Table of Contents

1. [What Is This Tool?](#1-what-is-this-tool)
2. [Permissions You'll Need](#2-permissions-youll-need)
3. [Before You Start](#3-before-you-start)
4. [Installation](#4-installation)
5. [Running Your First Collection](#5-running-your-first-collection)
6. [What Gets Collected](#6-what-gets-collected)
7. [Common Scenarios](#7-common-scenarios)
8. [Parameter Reference](#8-parameter-reference)
9. [Privacy and Security](#9-privacy-and-security)
10. [Understanding the Output](#10-understanding-the-output)
11. [KQL Queries](#11-kql-queries)
12. [Troubleshooting](#12-troubleshooting)
13. [Frequently Asked Questions](#13-frequently-asked-questions)

---

## 1. What Is This Tool?

The Aperture Data Collector is a PowerShell script that gathers data from your Azure Virtual Desktop environment and packages it into a portable ZIP file — a **collection pack**.

The collection pack contains raw data only: host pool configurations, VM inventory, performance metrics, and Log Analytics query results. **No analysis, scoring, or recommendations** — just the facts, in plain JSON format.

### What It's For

- **Consultant workflow** — your consultant asks you to run the collector and send the ZIP. They analyze it offline using their own tools, without needing access to your Azure environment.
- **Archival** — capture a point-in-time snapshot of your AVD environment for historical records.
- **Transparency** — everything collected is plain JSON. You can inspect, filter, or redact anything before sharing.

### What It Doesn't Do

- It does **not** modify your Azure environment (read-only operations only)
- It does **not** send data to any external service (everything stays on your machine)
- It does **not** analyze or score your environment (that's done separately)
- It does **not** require any paid licenses

---

## 2. Permissions You'll Need

Before running the collector, make sure whoever runs it (a user account or service principal) has the roles below. This is the **#1 thing to check with your Azure admin** — missing permissions is the most common reason a collection pack comes back incomplete.

### The Short Version

For a standard assessment, you need **two read-only roles**:

| Role | Where | What it unlocks |
|------|-------|-----------------|
| **Reader** | Each subscription that contains AVD resources | Host pools, session hosts, VMs, networks, metrics |
| **Log Analytics Reader** | Each Log Analytics workspace your host pools send data to | Connection logs, disconnect reasons, profile load times, Shortpath stats (38 KQL queries) |

That's it for the core assessment. Both are **read-only** — neither role can change, create, or delete anything in Azure.

### Optional Roles (only if you enable the matching feature)

If your consultant asks for cost analysis, reserved instance utilization, or Intune enrollment data, add one or more of these:

| Role | Where | Needed for |
|------|-------|------------|
| **Cost Management Reader** | Each subscription | `-IncludeCostData` -- per-VM actual spend |
| **Reservations Reader** | Tenant or enrollment account | `-IncludeReservedInstances` -- RI utilization and savings |
| **Intune Service Administrator** *(or)* **Intune Service Reader** | Microsoft Entra (Intune) | `-IncludeIntune` -- Intune device enrollment and compliance |

All optional roles are also read-only.

### How Your Admin Assigns These

In the Azure portal:

1. Go to the subscription -> **Access control (IAM)** -> **Add role assignment**
2. Select the role (e.g., **Reader**)
3. Assign it to the user or service principal who will run the collector
4. Repeat for each subscription that contains AVD host pools or VMs
5. For Log Analytics, go to each **Log Analytics workspace** -> **Access control (IAM)** and assign **Log Analytics Reader**

Or via PowerShell:

```powershell
# Reader on a subscription
New-AzRoleAssignment -SignInName user@contoso.com `
    -RoleDefinitionName 'Reader' `
    -Scope '/subscriptions/<subscription-id>'

# Log Analytics Reader on a specific workspace
New-AzRoleAssignment -SignInName user@contoso.com `
    -RoleDefinitionName 'Log Analytics Reader' `
    -Scope '/subscriptions/<subscription-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

### How the Collector Helps You Validate Permissions

Run the collector once with `-DryRun` **before** your full collection:

```powershell
./Collect-ApertureData.ps1 -TenantId <tenant-id> -SubscriptionIds <sub-id> -DryRun
```

It performs live permission probes and prints a matrix showing exactly which features will work, which will skip, and what role is missing. No data is collected in dry-run mode -- it's purely a permission check.

### Common Permission Gotchas

- **Workspace access control mode.** If a Log Analytics workspace is set to *"Require workspace permissions,"* subscription-level Reader is not enough -- the account needs **Log Analytics Reader** directly on the workspace. This is the single most common cause of missing KQL data.
- **Cross-subscription workspaces.** If host pools are in subscription A but their Log Analytics workspace is in subscription B, the account needs **Reader on both subscriptions** (so the collector can switch context), plus Log Analytics Reader on the workspace.
- **Custom "Reader" roles.** Some organisations use a custom role called "Reader" that does not include all of the `*/read` actions the built-in Reader has. If probes fail despite an apparent Reader assignment, ask your admin to confirm it's the built-in **Reader** or use `-DryRun` to see which specific action failed.
- **Intune sign-in is separate.** `-IncludeIntune` authenticates to Microsoft Graph independently of Azure. The collector re-uses the existing Azure sign-in when possible (no second browser prompt), but the signed-in account still needs an Intune read role in Entra.

For the full role-by-feature matrix, see [PERMISSIONS.md](PERMISSIONS.md).

---

## 3. Before You Start

### Requirements

| Requirement | Details |
|-------------|---------|
| **PowerShell** | Version 7 or later (`pwsh.exe`) |
| **Az PowerShell Modules** | Az.Accounts, Az.Compute, Az.DesktopVirtualization, Az.Monitor, Az.OperationalInsights, Az.Resources |
| **Azure Permissions** | See [Section 2 -- Permissions You'll Need](#2-permissions-youll-need). Minimum: **Reader** on AVD subscriptions + **Log Analytics Reader** on workspaces |
| **Memory** | 2 GB free for typical environments; 4 GB+ recommended for 3,000+ VMs with full extended collection |

### Optional Modules (for extended collection)

| Module | What It Enables |
|--------|----------------|
| Az.Network | Network topology collection (subnets, NSGs, VNets, private endpoints) |
| Az.Storage | FSLogix storage account and file share analysis |
| Az.Reservations | Reserved Instance data collection |
| Microsoft.Graph.Authentication | Intune device enrollment (`-IncludeIntune`) |

### Check Your PowerShell Version

```powershell
$PSVersionTable.PSVersion
```

If you see `5.x`, you need PowerShell 7. Install it:

```powershell
winget install Microsoft.PowerShell
```

Or download from: https://aka.ms/powershell-release?tag=stable

### Install Required Modules

```powershell
Install-Module Az.Accounts, Az.Compute, Az.DesktopVirtualization, Az.Monitor, Az.OperationalInsights, Az.Resources -Scope CurrentUser
```

For extended collection features:

```powershell
Install-Module Az.Network, Az.Storage -Scope CurrentUser
```

---

## 4. Installation

### Option A: Clone the Repository (Recommended)

```powershell
git clone https://github.com/GalloTheFourth-RG/aperture-data-collector.git
cd aperture-data-collector
```

### Option B: Manual Download

1. Go to https://github.com/GalloTheFourth-RG/aperture-data-collector
2. Click **Code** → **Download ZIP**
3. Extract the ZIP to a folder of your choice
4. Open PowerShell 7 and navigate to the extracted folder

---

## 5. Running Your First Collection

### Step 1: Find Your Azure IDs

You need three pieces of information:

**Tenant ID:**
```powershell
Connect-AzAccount
(Get-AzContext).Tenant.Id
```

**Subscription ID(s):**
```powershell
Get-AzSubscription | Select-Object Name, Id
```

**Log Analytics Workspace Resource ID(s):**
```powershell
Get-AzOperationalInsightsWorkspace | Select-Object Name, ResourceId
```

The workspace resource ID looks like:
```
/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/avd-workspace
```

> **Not sure which workspace?** Check your host pool's diagnostic settings in the Azure Portal: Host Pool → Diagnostic settings → check where logs are being sent.

### Step 2: Preview (Optional but Recommended)

Run a dry run to see what will be collected without actually collecting anything:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-subscription-id") `
    -DryRun
```

This shows you the VM count, estimated runtime, and which features will run. Takes about 30 seconds.

### Step 3: Run the Collection

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId "your-tenant-id" `
    -SubscriptionIds @("your-subscription-id") `
    -LogAnalyticsWorkspaceResourceIds @(
        "/subscriptions/your-sub-id/resourceGroups/your-rg/providers/Microsoft.OperationalInsights/workspaces/your-workspace"
    )
```

The script shows progress as it runs. A disclaimer prompt appears at the start — read it and type `Y` to proceed.

### Step 4: Wait for Completion

| Environment Size | VMs | Approximate Time |
|-----------------|-----|------------------|
| Small | ~50 | 3–5 minutes |
| Medium | ~200 | 8–15 minutes |
| Large | ~500 | 15–25 minutes |
| Very Large | 1,500+ | 30–60 minutes |

Metrics collection (CPU, memory, disk) is the main time driver. Everything else is fast.

### Step 5: Find Your Output

The collector creates a ZIP file in the current directory:

```
Aperture-CollectionPack-20260301-143022.zip    (typically 1–5 MB)
```

That's the file to send to your consultant. Done!

---

## 6. What Gets Collected

### Core Data (Always Collected)

| Category | What | Source |
|----------|------|--------|
| **Host Pools** | Configuration, load balancing, RDP settings, MaxSessionLimit | `Get-AzWvdHostPool` |
| **Session Hosts** | Status, agent version, health, active sessions, drain mode | `Get-AzWvdSessionHost` |
| **Virtual Machines** | Size, OS, zones, disks, NICs, security profile, extensions, tags | `Get-AzVM` |
| **VM Scale Sets** | VMSS config + individual instance details | `Get-AzVmss` |
| **Application Groups** | App group types, host pool assignments | `Get-AzWvdApplicationGroup` |
| **Scaling Plans** | Autoscale definitions, schedules, pool assignments | ARM API |
| **Metrics** | CPU, memory, disk IOPS per VM (7 days by default) | `Get-AzMetric` |
| **Log Analytics** | 38 KQL queries -- connections, errors, profiles, Shortpath, agent health, client connection health | `Invoke-AzOperationalInsightsQuery` |

### Extended Data (Opt-In)

Enable all at once with `-IncludeAllExtended`, or pick individually:

| Flag | What It Collects |
|------|-----------------|
| `-IncludeCostData` | Per-VM and infrastructure costs (last 30 days) from Cost Management API |
| `-IncludeNetworkTopology` | Subnets, VNets, NSG rules, NAT Gateway, private endpoints |
| `-IncludeImageAnalysis` | Azure Compute Gallery versions, marketplace image freshness |
| `-IncludeStorageAnalysis` | FSLogix storage accounts, file share capacity and quotas |
| `-IncludeOrphanedResources` | Unattached disks, unused NICs, unassociated public IPs |
| `-IncludeDiagnosticSettings` | Host pool diagnostic log forwarding configuration |
| `-IncludeAlertRules` | Azure Monitor alert rules scoped to AVD resource groups |
| `-IncludeActivityLog` | Activity Log entries (last 7 days) showing changes and errors |
| `-IncludePolicyAssignments` | Azure Policy assignments and compliance state |
| `-IncludeResourceTags` | Tags from VMs, host pools, and storage accounts |
| `-IncludeCapacityReservations` | Capacity reservation group utilization |
| `-IncludeQuotaUsage` | Per-region vCPU quota (current usage vs. limit) |

### Separate Opt-In

| Flag | What It Collects | Extra Requirements |
|------|------------------|--------------------|
| `-IncludeReservedInstances` | Reserved Instance orders, SKUs, terms, utilization | `Az.Reservations` module + Reservations Reader role |

> **For the most complete analysis, use `-IncludeAllExtended`.** This enables all extended data (except Reserved Instances, which needs an extra module and role).

---

## 7. Common Scenarios

### Basic Collection (Core Data Only)

ARM inventory + metrics + Log Analytics. Good for a quick run:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -LogAnalyticsWorkspaceResourceIds @($workspaceId)
```

### Comprehensive Collection (Recommended)

Everything your consultant needs for a full assessment:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -LogAnalyticsWorkspaceResourceIds @($workspaceId) `
    -IncludeAllExtended
```

### Comprehensive + Reserved Instances

Add RI data for reservation coverage analysis:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -LogAnalyticsWorkspaceResourceIds @($workspaceId) `
    -IncludeAllExtended `
    -IncludeReservedInstances
```

### Multiple Subscriptions

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @("sub-id-1", "sub-id-2", "sub-id-3") `
    -LogAnalyticsWorkspaceResourceIds @("workspace-id-1", "workspace-id-2") `
    -IncludeAllExtended
```

### Fast Inventory-Only (No Metrics)

Skip Azure Monitor metrics for a quick 2–5 minute run:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -SkipAzureMonitorMetrics
```

### With PII Scrubbing

Anonymize all identifiable data before the files are written:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -LogAnalyticsWorkspaceResourceIds @($workspaceId) `
    -IncludeAllExtended `
    -ScrubPII
```

### With Incident Window

The incident window lets you collect a **second, focused set of metrics and KQL queries** for a specific past outage, performance event, or user-reported issue.

This is useful when users reported problems during a known time window (e.g., "sessions were laggy between 2-4 PM on Tuesday"). The incident window data sits alongside your normal baseline data so your consultant can compare normal-state performance against the incident period side-by-side.

The incident window produces:
- `metrics-incident.json` — CPU, memory, and disk metrics scoped to the incident period
- Incident-prefixed KQL results — connections, peak concurrency, profile load times, errors, and connection quality for the incident window

Example — collect incident data for a 2-hour outage:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -LogAnalyticsWorkspaceResourceIds @($workspaceId) `
    -IncludeIncidentWindow `
    -IncidentWindowStart (Get-Date "2026-02-10 14:00") `
    -IncidentWindowEnd (Get-Date "2026-02-10 16:00")
```

> **Note:** Azure Monitor retains metrics for up to 30 days. The incident window start must be within the last 30 days.

### Longer Metrics History

Collect 14 or 30 days of metrics instead of the default 7:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -MetricsLookbackDays 14
```

### Resume an Interrupted Run

If the script was interrupted, resume from where it stopped:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -ResumeFrom "Aperture-CollectionPack-20260301-143022"
```

### Save Output to a Specific Folder

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -OutputPath "C:\assessments"
```

---

## 8. Parameter Reference

### Required

| Parameter | Type | Description |
|-----------|------|-------------|
| `-TenantId` | String | Your Azure AD / Entra ID tenant ID |
| `-SubscriptionIds` | String[] | Array of subscription IDs containing AVD resources |

### Recommended

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-LogAnalyticsWorkspaceResourceIds` | String[] | None | Full resource IDs of Log Analytics workspace(s). Enables session/connection/error analytics. |

### Collection Scope

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-MetricsLookbackDays` | Int | 7 | Days of Azure Monitor metrics to collect (1–30) |
| `-MetricsTimeGrainMinutes` | Int | 15 | Metrics aggregation interval (5, 15, 30, or 60 minutes) |
| `-SkipAzureMonitorMetrics` | Switch | Off | Skip CPU/memory/disk metrics. Inventory only. |
| `-SkipLogAnalyticsQueries` | Switch | Off | Skip all 38 KQL queries |

### Extended Collection

| Parameter | Type | Description |
|-----------|------|-------------|
| `-IncludeAllExtended` | Switch | Enable ALL extended collection flags at once (recommended) |
| `-IncludeCostData` | Switch | Azure Cost Management per-VM costs (30 days) |
| `-IncludeNetworkTopology` | Switch | Subnets, VNets, NSGs, NAT Gateway, private endpoints |
| `-IncludeImageAnalysis` | Switch | Compute Gallery versions, marketplace staleness |
| `-IncludeStorageAnalysis` | Switch | FSLogix storage accounts and file shares |
| `-IncludeOrphanedResources` | Switch | Unattached disks, unused NICs, unassociated public IPs |
| `-IncludeDiagnosticSettings` | Switch | Host pool diagnostic log forwarding |
| `-IncludeAlertRules` | Switch | Azure Monitor alert rules for AVD resource groups |
| `-IncludeActivityLog` | Switch | Activity Log entries (last 7 days) |
| `-IncludePolicyAssignments` | Switch | Azure Policy assignments and compliance |
| `-IncludeResourceTags` | Switch | Resource tags from VMs, host pools, storage |
| `-IncludeCapacityReservations` | Switch | Capacity reservation group utilization |
| `-IncludeQuotaUsage` | Switch | Per-region vCPU quota usage |
| `-IncludeReservedInstances` | Switch | Reserved Instance data (needs Az.Reservations + Reservations Reader) |

### Intune Integration

| Parameter | Type | Description |
|-----------|------|-------------|
| `-IncludeIntune` | Switch | Collect Intune managed device data via Microsoft Graph API. Requires `Microsoft.Graph.Authentication` module and `DeviceManagementManagedDevices.Read.All` + `Policy.Read.All` scopes. The collector reuses the existing Azure sign-in by handing off an Az-issued Graph access token to `Connect-MgGraph -AccessToken` -- no second browser prompt, no device code flow. It falls back to an interactive browser sign-in only if token handoff is unavailable. Not included in `-IncludeAllExtended` -- requires separate Graph authorization scopes |

### Incident Window

The incident window collects a second, focused set of Azure Monitor metrics and KQL query results covering a specific past event. This enables side-by-side comparison of normal-state performance vs. incident-period performance in the evidence pack's Incident Analysis tab.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IncludeIncidentWindow` | Switch | Off | Collect a second set of metrics and KQL queries for a past incident period |
| `-IncidentWindowStart` | DateTime | 14 days ago | Start of incident window (must be within last 30 days) |
| `-IncidentWindowEnd` | DateTime | Now | End of incident window |

### Privacy

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ScrubPII` | Switch | Off | Anonymize all identifiable data before writing to disk |

### Operational

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DryRun` | Switch | Off | Preview what will be collected without running |
| `-SkipDisclaimer` | Switch | Off | Skip the interactive disclaimer prompt |
| `-DisconnectGraphOnExit` | Switch | Off | When `-IncludeIntune` is used, disconnect Graph at the end instead of retaining context for reuse |
| `-ResumeFrom` | String | None | Path to a partial output folder to resume from |
| `-OutputPath` | String | Current dir | Directory where the collection pack ZIP is saved |
| `-MetricsParallel` | Int | 5 | Parallel threads for metrics collection |
| `-KqlParallel` | Int | 5 | Parallel threads for KQL queries |

---

## 9. Privacy and Security

This section is designed to satisfy the review requirements of information security, compliance, and risk teams — including those in healthcare (HIPAA) and financial services environments.

### Read-Only Operations

The collector only uses read operations (`Get-*` cmdlets and `GET` REST calls). It does not create, modify, or delete any Azure resources. Every API call is auditable in your Azure Activity Log.

### No External Network Calls

The script communicates with Azure management plane APIs (`management.azure.com`, `api.loganalytics.io`) and, when `-IncludeIntune` is enabled, Microsoft Graph (`graph.microsoft.com`) using your authenticated module sessions. It does not:

- Open any listening ports
- Make DNS queries to non-Azure domains
- Establish outbound connections to any IP or domain not owned by Microsoft Azure
- Download any external content or dependencies at runtime
- Send telemetry, analytics, or usage data to any service

### No Credential Storage

The script does not write credentials, tokens, or secrets to output files. Authentication uses module-managed sessions (`Az.Accounts` and optional `Microsoft.Graph.Authentication` for `-IncludeIntune`).

### What Is NOT Collected

The script does **not** access or collect:

- Passwords, secrets, certificates, or key vault contents
- File share contents, user files, or profile data
- Application data or database contents
- Azure AD/Entra ID user attributes beyond UPN (for session correlation)
- Network traffic or packet captures
- OS-level configuration (registry, local policies, Group Policy)
- Any data from on-premises or non-Azure systems
- Patient data, medical records, or clinical application data

### Inspect Before Sharing

The output ZIP contains plain JSON files. You can:

1. Unzip the collection pack
2. Open any JSON file in a text editor or VS Code
3. Search for anything you're uncomfortable sharing
4. Delete or redact specific files before re-zipping

### PII Scrubbing

Add `-ScrubPII` to anonymize all identifiable data **before** it's written to disk:

| Data Category | Example Before | Example After |
|--------------|---------------|---------------|
| VM names | `avd-prod-vm-001` | `Host-3F7C` |
| Host pool names | `HP-Finance-US` | `Pool-D4E5` |
| Usernames (UPN) | `jsmith@contoso.com` | `User-A1B2` |
| Subscription IDs | `12345678-...` | `Sub-F6A1` |
| Resource groups | `rg-avd-prod` | `RG-B2C3` |
| IP addresses | `10.0.1.50` | `IP-7D8E` |
| ARM resource IDs | `/subscriptions/12345.../rg-prod/...` | `/subscriptions/Sub-F6A1/resourceGroups/RG-B2C3/...` |
| Storage accounts | `stfslogixprod01` | `Storage-9A2B` |
| Subnet names | `snet-avd-prod` | `Subnet-C3D4` |

- Uses **SHA256 hashing** with a per-run random salt
- Same entity always maps to the same anonymous ID within a run (correlations preserved)
- Different runs produce different IDs (no cross-run linkability)
- Scrubbing occurs in memory before any file is written — the raw data never touches disk

### HIPAA & Healthcare Environments

For healthcare organizations subject to HIPAA:

- The collector does **not** access, process, or store Protected Health Information (PHI)
- Session telemetry from Log Analytics contains UPN and connection metadata only — no clinical data
- Use `-ScrubPII` to anonymize all UPN fields before the data leaves the environment
- The output contains infrastructure configuration and performance metrics — no patient data, medical records, or clinical application data
- The script runs on an administrator workstation and does not interact with clinical systems, EHR databases, or medical devices
- Collection can be performed by your internal team and the output reviewed before sharing with external consultants

### What Your Consultant Receives

With a standard (non-scrubbed) collection pack, your consultant can see:

- VM names, sizes, and configurations
- Host pool names and settings
- Azure region and zone placement
- Performance metrics (CPU, memory, disk)
- Session connection data from Log Analytics
- Network topology (if extended collection enabled)
- Cost data (if extended collection enabled)

They **cannot** see: passwords, secrets, file share contents, user data, application data, or anything beyond Azure resource configuration and telemetry.

---

## 10. Understanding the Output

The collector produces a single ZIP file containing JSON data files:

```
Aperture-CollectionPack-20260301-143022/
├── collection-metadata.json          ← Run metadata, schema version, counts
├── host-pools.json                   ← Host pool configurations
├── session-hosts.json                ← Session host status & health
├── virtual-machines.json             ← Full VM inventory
├── metrics-baseline.json             ← CPU/memory/disk metrics (7 days)
├── la-results.json                   ← All 38 KQL query results
├── scaling-plans.json                ← Autoscale plan definitions
├── scaling-plan-assignments.json     ← Plan-to-pool mappings
├── scaling-plan-schedules.json       ← Schedule details per plan
├── app-groups.json                   ← Application groups
├── vmss.json                         ← VM Scale Set configurations
├── vmss-instances.json               ← VMSS instance details
├── diagnostic-readiness.json         ← Which Log Analytics tables have data
```

### With Extended Collection (`-IncludeAllExtended`)

Additional files appear:

```
├── actual-cost-data.json             ← Per-VM daily costs (30 days)
├── vm-actual-monthly-cost.json       ← VM monthly cost lookup
├── infra-cost-data.json              ← Infrastructure costs per RG
├── cost-access.json                  ← Cost API access status
├── subnet-analysis.json              ← Subnet details + NSG coverage
├── vnet-analysis.json                ← VNet DNS, peering, topology
├── private-endpoint-findings.json    ← Private endpoint status
├── nsg-rule-findings.json            ← Risky NSG inbound rules
├── orphaned-resources.json           ← Unattached disks, unused NICs
├── fslogix-storage-analysis.json     ← Storage account analysis
├── fslogix-shares.json               ← File share details
├── diagnostic-settings.json          ← Host pool diagnostic config
├── alert-rules.json                  ← Azure Monitor alerts
├── activity-log.json                 ← Activity log entries (7 days)
├── policy-assignments.json           ← Azure Policy assignments
├── gallery-analysis.json             ← Compute Gallery images
├── gallery-image-details.json        ← Gallery image version details
├── marketplace-image-details.json    ← Marketplace image data
├── resource-tags.json                ← Resource tags
```

### With Incident Window (`-IncludeIncidentWindow`)

```
├── metrics-incident.json             ← Metrics for the incident period
```

### With Reserved Instances (`-IncludeReservedInstances`)

```
├── reserved-instances.json           ← RI orders, SKUs, utilization
```

### With Capacity/Quota

```
├── capacity-reservation-groups.json  ← CRG utilization
├── quota-usage.json                  ← Per-region vCPU quota
```

### Schema Versioning

The `collection-metadata.json` file includes a schema version. Consumer tools check this for compatibility. Current schema version: **2.0**.

---

## 11. KQL Queries

The collector runs 38 pre-built KQL queries against your Log Analytics workspace(s). These queries target AVD diagnostic tables and provide session-level telemetry that isn't available from ARM APIs.

### Prerequisites

Your workspace needs AVD Diagnostics configured. To check:
1. Azure Portal → your host pool → Diagnostic settings
2. Verify logs are being sent to your Log Analytics workspace
3. Key tables: `WVDConnections`, `WVDErrors`, `WVDConnectionNetworkData`, `WVDCheckpoints`

The collector runs a `TableDiscovery` query first to check which tables are available. Queries targeting missing tables are skipped gracefully.

### Query Categories

| Category | Queries | What They Capture |
|----------|---------|-------------------|
| **Connections** | 7 | Connection summary, success rates, login times, session duration, peak/hourly concurrency, client environment |
| **Errors & Disconnects** | 8 | Error codes, disconnect reasons by host, heatmaps, CPU correlation, reconnection loops |
| **Network & Shortpath** | 8 | RTT/bandwidth quality, cross-region latency, Shortpath usage/effectiveness, transport types |
| **Performance** | 4 | Per-process CPU/memory, CPU percentiles per host with spike analysis |
| **Profiles** | 2 | FSLogix profile load times, login phase decomposition |
| **Agent Health** | 3 | Agent status, version distribution, health check pass/fail rates |
| **Autoscale** | 2 | Scaling activity summary, per-pool evaluations |
| **Discovery** | 1 | Table availability check |
| **Transport** | 1 | Multi-link transport negotiation |

### Customizing Queries

All queries are plain `.kql` files in the `queries/` folder. You can:

- **Edit** existing queries to adjust filters, time ranges, or aggregation
- **Add** new queries — create a `.kql` file and add a dispatch entry in `src/Collect-ApertureData.ps1`
- **Remove** queries — delete the `.kql` file; the collector skips missing queries automatically

---

## 12. Troubleshooting

### "Too Many Requests" / API Throttling

**Cause:** Azure is rate-limiting your API calls.

**Solutions:**
1. Reduce `-MetricsLookbackDays` to 2–3 days
2. Run during off-peak hours (evenings, weekends)
3. Ensure you're using PowerShell 7 (better throttle handling)

### Script Appears to Hang

**Cause:** Collecting metrics for a large number of VMs. This is normal.

**What to do:** Wait. The script shows batch progress. For a faster test run, use `-SkipAzureMonitorMetrics` to skip metrics (2-5 minutes regardless of VM count).

### Terminal Closes / Process Killed (Large Environments)

**Cause:** The PowerShell process ran out of memory and the OS terminated it. This can happen with 3,000+ VMs, especially when combined with `-IncludeAllExtended` or `-IncludeCostData` on enterprise subscriptions with high billing cardinality.

**How to tell:** The terminal window closes abruptly with no error message, or the process silently disappears from Task Manager.

**Solutions (in order of impact):**

1. **Update to the latest collector version** (v1.3.13+) -- major memory optimizations reduce peak usage by up to 90%
2. **Run with `-SkipAzureMonitorMetrics` first** to test ARM collection alone, then run again with metrics
3. **Use `-ResumeFrom`** to continue after a crash -- each step checkpoints to disk, so you don't lose progress:
   ```powershell
   .\Collect-ApertureData.ps1 -TenantId $t -SubscriptionIds $s `
       -ResumeFrom "Aperture-CollectionPack-20260320-093000"
   ```
4. **Reduce metrics scope**: `-MetricsLookbackDays 3` uses ~60% less memory than the default 7 days
5. **Skip cost data initially**: `-IncludeCostData` on large enterprise subscriptions can produce millions of billing rows. Collect core + metrics first, then run a second pass with only cost data
6. **Monitor memory**: Look for `[MEM]` lines in the output showing working set at each checkpoint. If memory grows above 3-4 GB before Step 2, consider splitting the collection across fewer subscriptions

**Memory profile by environment size (v1.3.13+):**

| VMs | Estimated Peak Memory |
|-----|----------------------|
| 500 | ~500 MB |
| 1,500 | ~800 MB |
| 3,000 | ~1.2 GB |
| 5,000 | ~1.8 GB |
| 10,000+ | ~3 GB (4 GB+ with full extended collection) |

> **Note:** These estimates assume default settings. Adding `-IncludeCostData` on subscriptions with many resource types and pricing models can increase memory significantly due to billing row volume.

### "WorkspaceNotFound" Errors

**Cause:** The Log Analytics workspace is in a different subscription than your AVD resources.

**Solution:** Ensure your identity has **Reader** or **Log Analytics Reader** on the workspace's subscription — not just the AVD subscription. The collector handles the subscription context switch automatically.

### Missing Az Modules

**Error:** `The term 'Get-AzVM' is not recognized...`

**Solution:**
```powershell
Install-Module Az -AllowClobber -Scope CurrentUser
```

### Wrong PowerShell Version

**Error:** Various syntax errors or module failures.

**Check:**
```powershell
$PSVersionTable.PSVersion
```

If it shows `5.x`, you're running Windows PowerShell. Use `pwsh.exe` (PowerShell 7) instead:
```powershell
winget install Microsoft.PowerShell
```

Then launch `pwsh` and re-run the collector.

### Permission Errors

**Error:** `Authorization failed` or `does not have authorization to perform action`

**Causes and fixes:**

| What You're Trying | Required Role |
|--------------------|---------------|
| Core collection | **Reader** on each subscription |
| Log Analytics queries | **Reader** or **Log Analytics Reader** on workspace |
| Cost data | **Cost Management Reader** on subscription |
| Reserved Instances | **Reservations Reader** at tenant level |

### No KQL Data Returned

**Symptoms:** `la-results.json` contains `NoRowsReturned` or `QueryFailed` entries.

**Common causes:**

| Issue | Fix |
|-------|-----|
| AVD Insights not configured | Enable diagnostic settings on your host pools to send to Log Analytics |
| Workspace is fresh | Wait 24–48 hours for data to accumulate |
| Wrong workspace | Check your host pool's diagnostic settings to confirm the correct workspace |
| Performance counters missing | Create a Data Collection Rule with Process counters for session stability data |

### Script Interrupted

Use `-ResumeFrom` to continue from where it stopped:

```powershell
.\Collect-ApertureData.ps1 `
    -TenantId $tenantId `
    -SubscriptionIds @($subId) `
    -ResumeFrom "Aperture-CollectionPack-20260301-143022"
```

The script detects which steps already completed and skips them.

---

## 13. Frequently Asked Questions

### Does this script change anything in my Azure environment?

No. Every API call is a read operation. The collector does not create, modify, or delete any Azure resources.

### What is the minimum Azure permission I need?

**Reader** on each subscription containing AVD resources. That's it for the basic collection.

For Log Analytics queries, you also need **Reader** or **Log Analytics Reader** on the workspace. For cost data with `-IncludeCostData`, you need **Cost Management Reader**.

### How large is the output file?

Typically 1–5 MB for most environments. Very large environments (1,500+ VMs) with extended collection may produce 5–10 MB.

### Can I inspect the data before sending it?

Yes. The ZIP contains plain JSON files. Unzip it and open any file in a text editor. You can search for specific strings, redact anything you're uncomfortable with, or remove entire files before re-zipping.

### Can I anonymize the data?

Yes. Use `-ScrubPII` to replace all VM names, host pool names, usernames, IPs, subscription IDs, and resource group names with anonymous identifiers before the data is written to disk. The output ZIP never contains real names.

### How long does it take to run?

Most of the time is spent collecting Azure Monitor metrics. Rough estimates:

| VMs | Time (with metrics) | Time (without metrics) |
|-----|--------------------|-----------------------|
| 50 | 3-5 min | 2 min |
| 200 | 8-15 min | 3 min |
| 500 | 15-25 min | 5 min |
| 1,500 | 30-45 min | 5 min |
| 3,000+ | 45-90 min | 8 min |

### When should I run it?

**During business hours** for the most accurate picture. Metrics and session data captured during peak usage give the best representation of your environment. If you run during off-peak hours when scaling plans have stopped VMs, the data will show many hosts as unavailable — which is normal but may not reflect your typical operating state.

### How many days of metrics should I collect?

The default is 7 days, which covers a full work week. This is usually sufficient. Use 14 days for more representative data, or 30 days to capture monthly patterns. Use 1–2 days for a quick test.

### Can I collect from multiple subscriptions?

Yes. Pass all subscription IDs as an array:

```powershell
-SubscriptionIds @("sub-1", "sub-2", "sub-3")
```

### What if my workspace is in a different subscription?

The collector handles cross-subscription workspace access automatically. Just make sure you have Reader access on the workspace's subscription.

### Can I run this on a schedule?

Yes. Use `-SkipDisclaimer` to bypass the interactive prompt:

```powershell
.\Collect-ApertureData.ps1 -TenantId $t -SubscriptionIds $s -SkipDisclaimer
```

### What's the difference between this and Aperture?

| | Aperture Data Collector (this tool) | Aperture |
|---|---|---|
| **Purpose** | Collects raw data | Analyzes data and produces recommendations |
| **Output** | JSON files in a ZIP | HTML dashboard + 75+ CSVs + executive summary |
| **License** | MIT (open source) | Private |
| **Azure access** | Required | Optional (can use collection pack) |
| **Analysis** | None | Right-sizing, security scoring, cost optimization, UX scoring |

The typical workflow: you run the collector → send the ZIP → your consultant runs Aperture against it → you get back an HTML report with findings.

### I got an error not listed here. What should I do?

1. Note the full error message
2. Check what command you ran (redact your tenant/subscription IDs)
3. Check your PowerShell version: `$PSVersionTable.PSVersion`
4. Check which Az modules you have: `Get-Module Az.* -ListAvailable | Select-Object Name, Version`
5. Send this information to your consultant or open an issue on GitHub

---

*For the collection pack schema reference, see [docs/SCHEMA.md](SCHEMA.md). For KQL query details, see [docs/QUERIES.md](QUERIES.md).*
