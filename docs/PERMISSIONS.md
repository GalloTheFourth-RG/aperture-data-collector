# Permissions & RBAC Guide

This document lists every Azure RBAC role needed to run the Aperture Data Collector, organized by collection step. Use this to prepare role assignments **before** running the collector — incomplete permissions are the #1 cause of partial data and low-quality assessment reports.

---

## Quick Setup — Minimum Viable Permissions

For the best assessment results, the user or service principal running the collector needs:

| Role | Scope | Purpose |
|------|-------|---------|
| **Reader** | Each target subscription | ARM resources, VMs, host pools, metrics |
| **Log Analytics Reader** | Each Log Analytics workspace | KQL queries (connections, errors, profiles, Shortpath) |

These two roles cover the core collection. Everything below is optional but unlocks richer analysis.

---

## Recommended — Full Data Collection

For the richest possible assessment, add these roles to the core set:

| Role | Scope | Purpose | Flag |
|------|-------|---------|------|
| **Cost Management Reader** | Each target subscription | Per-VM cost data, infrastructure costs | `-IncludeCostData` |
| **Reservations Reader** | Tenant or enrollment level | Reserved Instance utilization and savings | `-IncludeReservedInstances` |

> **Tip:** Use `-IncludeAllExtended` to enable all optional data in a single flag.

---

## Full Permission Matrix

### Core Collection (always runs)

| Step | What's Collected | API / Cmdlet | Required Role | Scope |
|------|-----------------|--------------|---------------|-------|
| Auth | Tenant validation, subscription access | `Connect-AzAccount`, `Get-AzSubscription` | Any Azure login | Tenant |
| Host Pools | AVD pool config, RDP properties, load balancing | `Get-AzWvdHostPool` | Reader | Subscription |
| Session Hosts | Agent version, status, health, sessions | `Get-AzWvdSessionHost` | Reader | Subscription |
| VMs | Size, OS, zones, disks, NICs, security profile | `Get-AzVM`, `Get-AzDisk`, `Get-AzNetworkInterface` | Reader | Subscription |
| App Groups | Application group assignments | `Get-AzWvdApplicationGroup` | Reader | Subscription |
| Scaling Plans | Autoscale config, schedules, pool assignments | ARM REST API | Reader | Subscription |
| VMSS | Scale set config and instance details | `Get-AzVmss`, `Get-AzVmssVM` | Reader | Subscription |
| Metrics | CPU, memory, disk IOPS per VM | `Get-AzMetric` | Reader or Monitoring Reader | Subscription |

### Log Analytics Queries (skippable via `-SkipLogAnalyticsQueries`)

| Step | What's Collected | API / Cmdlet | Required Role | Scope |
|------|-----------------|--------------|---------------|-------|
| KQL Queries | 37 queries: connections, disconnects, errors, profiles, Shortpath, agent health, process CPU/memory, client connection health | `Invoke-AzOperationalInsightsQuery` | **Log Analytics Reader** | Each workspace |

**Cross-subscription workspaces:** If your Log Analytics workspace is in a different subscription than your AVD resources, the user needs Reader on the workspace's subscription too (for context switching).

**Common issue:** If the workspace is configured with Access Control Mode = "Require workspace permissions," then subscription-level Reader alone is not enough — the user must have explicit Log Analytics Reader on the workspace resource.

### Extended Collection (opt-in)

Each of these is enabled by its own flag, or all at once with `-IncludeAllExtended`.

| Step | Flag | API / Cmdlet | Required Role | Scope | Module Required |
|------|------|--------------|---------------|-------|-----------------|
| Cost Data | `-IncludeCostData` | Cost Management REST API | **Cost Management Reader** | Subscription | — |
| Network Topology | `-IncludeNetworkTopology` | `Get-AzVirtualNetwork`, `Get-AzNetworkSecurityGroup`, `Get-AzPrivateEndpointConnection` | Reader | Subscription | **Az.Network** |
| Storage Analysis | `-IncludeStorageAnalysis` | `Get-AzStorageAccount`, `Get-AzRmStorageShare` | Reader | Subscription | **Az.Storage** |
| Image Analysis | `-IncludeImageAnalysis` | `Get-AzVMImage`, `Get-AzGalleryImageVersion` | Reader | Subscription | — |
| Orphaned Resources | `-IncludeOrphanedResources` | `Get-AzDisk`, `Get-AzNetworkInterface`, `Get-AzPublicIpAddress` | Reader | Subscription | — |
| Diagnostic Settings | `-IncludeDiagnosticSettings` | ARM REST: `Microsoft.Insights/diagnosticSettings` | Reader or Monitoring Reader | Host pool resources | — |
| Alert Rules | `-IncludeAlertRules` | ARM REST: `metricAlerts`, `scheduledQueryRules`, `activityLogAlerts` | Reader or Monitoring Reader | Subscription | — |
| Activity Log | `-IncludeActivityLog` | `Get-AzActivityLog` | Reader or Monitoring Reader | Subscription | — |
| Policy Assignments | `-IncludePolicyAssignments` | ARM REST: `Microsoft.Authorization/policyAssignments` | Reader or Resource Policy Reader | Subscription | — |
| Resource Tags | `-IncludeResourceTags` | (No extra API — uses already-collected data) | — (no extra role) | — | — |
| Capacity Reservations | `-IncludeCapacityReservations` | ARM REST: `capacityReservationGroups` | Reader | Subscription | — |
| Quota Usage | `-IncludeQuotaUsage` | `Get-AzVMUsage` | Reader | Subscription | — |
| Reserved Instances | `-IncludeReservedInstances` | `Get-AzReservationOrder`, `Get-AzReservation` | **Reservations Reader** | Tenant / enrollment | **Az.Reservations** |

### Intune Integration (separate auth)

`-IncludeIntune` collects Intune managed device data via **Microsoft Graph API** — this is completely separate from the Azure ARM authentication used for the rest of the collection. The customer will see a **second sign-in prompt** (browser-based) specifically for Graph.

| Step | Flag | API | Required Scope | Auth | Module Required |
|------|------|-----|----------------|------|-----------------|
| Intune Devices | `-IncludeIntune` | `GET /deviceManagement/managedDevices` | `DeviceManagementManagedDevices.Read.All`, `Policy.Read.All` | Microsoft Graph (interactive browser sign-in) | **Microsoft.Graph.Authentication** |

#### What the customer needs

1. **Install the module** (one-time):
   ```powershell
   Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
   ```

2. **Account with read access to Intune** — either:
   - **Global Reader** or **Intune Administrator** directory role (simplest), OR
   - An account with `DeviceManagementManagedDevices.Read.All` and `Policy.Read.All` delegated permissions

3. **Tenant consent** — when `Connect-MgGraph` runs, a browser consent prompt appears. If the tenant restricts user consent, a Global Admin must approve the permissions first (via the Entra admin center or by running the script once themselves).

#### How auth works

- The script calls `Connect-MgGraph` with the required scopes, triggering an interactive browser sign-in.
- If an existing Graph session already matches the target tenant and has the required scopes, it is **reused automatically** — no second prompt.
- The script requests `CurrentUser` context scope (when the Graph module supports it) so the session persists across repeated runs.
- Use `-DisconnectGraphOnExit` if you want the script to sign out of Graph at the end of the run.

#### Important notes

- `-IncludeIntune` is **NOT** included in `-IncludeAllExtended` because it uses a separate authentication flow.
- All permissions are **read-only** — the script never creates, modifies, or deletes any Intune resources.
- If the module is not installed or Graph auth fails, the script continues without Intune data and logs a warning.

#### Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Microsoft.Graph.Authentication not installed` | Module missing | `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` |
| `Graph authentication failed` | Sign-in cancelled or wrong account | Re-run the script and complete the browser sign-in |
| `403 Forbidden` on managed devices | Insufficient permissions | Assign Global Reader or Intune Administrator role to the account |
| Consent prompt blocked | Tenant restricts user consent | Global Admin must grant admin consent in Entra admin center |

---

## Setting Up Permissions

### Option A: Single User (Interactive)

For a consultant running the collector interactively:

```powershell
# 1. Assign Reader on the AVD subscription(s)
az role assignment create \
  --assignee "user@domain.com" \
  --role "Reader" \
  --scope "/subscriptions/<sub-id>"

# 2. Assign Log Analytics Reader on each workspace
az role assignment create \
  --assignee "user@domain.com" \
  --role "Log Analytics Reader" \
  --scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"

# 3. (Optional) Cost Management Reader for cost data
az role assignment create \
  --assignee "user@domain.com" \
  --role "Cost Management Reader" \
  --scope "/subscriptions/<sub-id>"
```

### Option B: Service Principal (Automation)

For scheduled or automated collection:

```powershell
# Create a service principal with Reader role
$sp = New-AzADServicePrincipal -DisplayName "Aperture-Collector" -Role "Reader" -Scope "/subscriptions/<sub-id>"

# Add Log Analytics Reader
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName "Log Analytics Reader" `
  -Scope "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>"
```

### Option C: Custom Role (Least Privilege)

If your security team requires a custom role instead of built-in Reader:

```json
{
  "Name": "Aperture Data Collector",
  "Description": "Read-only access for AVD data collection",
  "Actions": [
    "Microsoft.DesktopVirtualization/*/read",
    "Microsoft.Compute/virtualMachines/read",
    "Microsoft.Compute/virtualMachines/instanceView/read",
    "Microsoft.Compute/virtualMachineScaleSets/*/read",
    "Microsoft.Compute/disks/read",
    "Microsoft.Network/networkInterfaces/read",
    "Microsoft.Network/virtualNetworks/read",
    "Microsoft.Network/networkSecurityGroups/read",
    "Microsoft.Network/publicIPAddresses/read",
    "Microsoft.Network/privateEndpoints/read",
    "Microsoft.Insights/metrics/read",
    "Microsoft.Insights/diagnosticSettings/read",
    "Microsoft.Insights/metricAlerts/read",
    "Microsoft.Insights/scheduledQueryRules/read",
    "Microsoft.Insights/activityLogAlerts/read",
    "Microsoft.Insights/eventtypes/values/read",
    "Microsoft.AlertsManagement/alerts/read",
    "Microsoft.OperationalInsights/workspaces/query/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.Authorization/policyAssignments/read",
    "Microsoft.CostManagement/query/action",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/fileServices/shares/read",
    "Microsoft.Compute/galleries/images/versions/read",
    "Microsoft.Compute/locations/usages/read",
    "Microsoft.Compute/locations/publishers/artifacttypes/offers/skus/versions/read",
    "Microsoft.Compute/capacityReservationGroups/read",
    "Microsoft.Compute/capacityReservationGroups/capacityReservations/read",
    "Microsoft.Capacity/reservationOrders/read",
    "Microsoft.Capacity/reservationOrders/reservations/read"
  ],
  "NotActions": [],
  "AssignableScopes": ["/subscriptions/<sub-id>"]
}
```

---

## Troubleshooting Permission Issues

### "Cost Management access denied"

The user needs **Cost Management Reader** on the subscription. This is separate from the standard Reader role.

```
[WARN] Cost Management access denied (need Cost Management Reader)
```

### "Workspace not found" or empty KQL results

1. Verify the workspace resource ID format: `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>`
2. Ensure the user has **Log Analytics Reader** on the workspace itself (not just the subscription)
3. If cross-subscription: the user needs Reader on the workspace's subscription for context switching

### "Reservations Reader" error

Reserved Instance data requires tenant-level access:

```
[WARN] This usually means the account lacks Reservations Reader role at the tenant level
```

Assign at tenant scope: `az role assignment create --assignee "user@domain.com" --role "Reservations Reader" --scope "/"`

### Module not found warnings

Some extended collections need specific PowerShell modules:

```powershell
# Install optional modules
Install-Module Az.Network -Scope CurrentUser
Install-Module Az.Storage -Scope CurrentUser
Install-Module Az.Reservations -Scope CurrentUser
```

---

## Impact on Assessment Quality

The Aperture Assessment generates a Data Quality score based on what data was successfully collected. Here's how permissions affect each assessment dimension:

| Assessment Area | Required Data | Impact of Missing Data |
|----------------|--------------|----------------------|
| Right-Sizing | VM inventory + Metrics | No sizing recommendations without metrics |
| Security Score | Host pool config + VM security profile | Partial score if VMs inaccessible |
| UX Score | Log Analytics (connections, profiles) | N/A score without KQL data |
| Cost Analysis | Cost Management API data | Falls back to PAYG estimates |
| Network / Shortpath | Log Analytics + Network topology | Shortpath analysis needs KQL; subnet analysis needs network data |
| Zone Resiliency | VM zones + availability data | Cannot score without zone information |
| BCDR | Scaling plans + infrastructure config | Partial assessment |
| Alerting | Alert rules + diagnostic settings | Cannot assess monitoring coverage |

> **Bottom line:** Reader + Log Analytics Reader covers ~80% of the assessment value. Adding Cost Management Reader gets you to ~95%. Everything else is incremental depth.
