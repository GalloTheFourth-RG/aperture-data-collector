# Changelog

All notable changes to the Aperture Data Collector will be documented in this file.

## [1.3.0] — 2026-03-15

### Added
- **Intune device enrollment** (`-IncludeIntune`) — Optional Microsoft Graph API integration to collect Intune managed device data. Authenticates via `Connect-MgGraph` with `DeviceManagementManagedDevices.Read.All` scope (separate from Azure auth). Collects device name, compliance state, encryption status, management agent, last sync time, and OS version. Filters to Windows devices. Exports as `intune-managed-devices.json` in collection ZIP. Not included in `-IncludeAllExtended` (requires separate Graph auth). DryRun validates Intune access
- **Permissions & RBAC guide** (`docs/PERMISSIONS.md`) — Complete role matrix for every collection step, setup commands (user, service principal, custom role), troubleshooting guide, and impact-on-assessment-quality table
- **DryRun pre-flight validation** — `-DryRun` now probes 6 access categories (host pools, VM inventory, Azure Monitor, Log Analytics workspaces, Cost Management, optional modules) and prints a formatted permission matrix with pass/fail/warn status, required roles, and estimated collection time. Exits without collecting data.

### Changed
- **Full rebrand** — All references updated from "AVD Data Collector" to "Aperture Data Collector", script renamed to `Collect-ApertureData.ps1`, output ZIP prefix changed to `Aperture-CollectionPack-*`

---

## [1.2.0] — 2026-03-06

### Added
- **Build system** (`build.ps1`) — Assembles KQL queries into the script at build time and runs syntax verification. Adds `$script:EmbeddedKqlQueries` placeholder for build-time injection
- **CustomRdpProperty security flags** — Host pool objects now include `ScreenCaptureProtection`, `Watermarking`, and `SsoEnabled` boolean properties extracted from `CustomRdpProperty` before PII scrubbing. This fixes a 10-point security score penalty when using `-ScrubPII` (screen capture + watermarking checks no longer fail on `[SCRUBBED]` strings)
- **Incident window KQL queries** — When `-IncludeIncidentWindow` is set, 5 key KQL queries are now dispatched for the incident time range (`IncidentWindow_WVDConnections`, `IncidentWindow_WVDPeakConcurrency`, `IncidentWindow_ProfileLoadPerformance`, `IncidentWindow_ConnectionErrors`, `IncidentWindow_ConnectionQuality`). Previously only Azure Monitor metrics were collected for incident windows
- **Subnet enrichment** — Subnet analysis objects now include `HostPools` (which host pools have VMs in the subnet), `IsPrivateSubnet` (no NAT gateway, no public IP, has NSG/route table), `HasLoadBalancer`, and `HasPublicIP` properties

### Changed
- **Unicode → ASCII** — Replaced Unicode box-drawing characters, arrows, and em dashes with ASCII equivalents for PowerShell 5.1 compatibility
- **BOM encoding** — Added UTF-8 BOM to script file for consistent encoding across systems

### Changed
- **Property naming alignment** — Collector output properties now match EP expectations directly, reducing normalization overhead:
  - `SessionHostCount` → `SessionHostVMs` (subnet analysis)
  - `IsFslogix` → `IsFSLogixLikely` (storage analysis)
  - `TotalCost` → `MonthlyEstimate` (infra cost data, values now rounded to 2 decimal places)
  - `IsCustomDns` → `DnsType` (VNet analysis, now `Custom` or `Azure Default` string)
  - `DisconnectedPeerings` → `DisconnectedPeers` (VNet analysis)
- Schema version remains 2.0 (backward compatible — EP normalizer handles both old and new property names)

## [1.1.0] — 2025-06-14

### Added
- **Extended Data Collection (Step 1b)** — 10 new optional collection categories:
  - **Cost Data** (`-IncludeCostData`): Azure Cost Management per-VM and infrastructure costs (last 30 days)
  - **Network Topology** (`-IncludeNetworkTopology`): VNet/subnet analysis, DNS config, peering, NSG rule evaluation, private endpoints, NAT Gateway
  - **Image Analysis** (`-IncludeImageAnalysis`): Azure Compute Gallery image versions, marketplace image freshness, replica counts
  - **Storage Analysis** (`-IncludeStorageAnalysis`): FSLogix storage accounts, file share capacity/quotas, private endpoints
  - **Orphaned Resources** (`-IncludeOrphanedResources`): Unattached disks, unused NICs, unassociated public IPs
  - **Diagnostic Settings** (`-IncludeDiagnosticSettings`): Host pool diagnostic log forwarding configuration
  - **Alert Rules** (`-IncludeAlertRules`): Azure Monitor metric alerts and scheduled query rules
  - **Activity Log** (`-IncludeActivityLog`): Last 7 days of activity per AVD resource group
  - **Policy Assignments** (`-IncludePolicyAssignments`): Azure Policy assignments and compliance state
  - **Resource Tags** (`-IncludeResourceTags`): Tag extraction from VMs, host pools, and storage accounts
- **`-IncludeAllExtended`** convenience switch: enables all extended collection flags at once
- **Diagnostic Readiness** post-processing: builds `diagnostic-readiness.json` from TableDiscovery KQL results
- **NSG rule findings** serialized to `nsg-rule-findings.json` — previously only available in live EP mode
- **Reserved Instance collection** (`-IncludeReservedInstances`) from previous session
- Schema version bumped to 2.0 (backward compatible — EP auto-detects extended files)
- Enhanced metadata: `ExtendedCollections` flags, 15+ new data counts, dynamic `SkipActualCosts` flag
- Az.Storage module support (optional, for FSLogix storage analysis)
- Az.Network enhanced usage (subnet/VNet/NSG/PE analysis)
- AVD resource group tracking for scoped collection

### Changed
- Metadata `SkipActualCosts` now dynamically set based on whether cost data was collected

## [1.0.0] — 2025-06-01

### Added
- Initial release
- ARM resource collection: host pools, session hosts, VMs, VMSS, app groups, scaling plans
- Azure Monitor metrics collection with parallel execution and retry logic
- 36 KQL queries covering connections, errors, disconnects, Shortpath, agent health, performance, profiles, and autoscale
- Capacity reservation group collection via ARM REST API
- Per-region vCPU quota collection
- Incident window metrics collection
- Dry run mode for collection preview
- Collection pack export (ZIP) compatible with Enhanced AVD Evidence Pack v4.12.0+
- Schema version 1.1 support
- Bulk VM pre-fetch optimization (per-RG instead of per-VM API calls)
- Cross-subscription Log Analytics workspace support
- Exponential backoff retry for API throttling (429)
