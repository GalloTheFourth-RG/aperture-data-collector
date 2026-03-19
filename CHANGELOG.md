# Changelog

All notable changes to the Aperture Data Collector will be documented in this file.

## [1.3.7] — 2026-03-19

### Fixed
- **Host pool RG extraction still failing on Az.DesktopVirtualization v5.4.1** — The 3-layer fallback added in v1.3.4 was insufficient for some autorest-generated SDK versions where `PSObject.Properties` enumeration may not expose `Id`. Added 2 new fallback layers: direct property access bypass (`$hp.Id`, `$hp.ResourceId`) and JSON serialization extraction (`ConvertTo-Json` + regex parse). Also added per-host-pool individual `Get-AzResource -Name` lookup as Layer 4 (slower but more reliable than bulk query for narrow RBAC roles). Includes `[DEBUG]` diagnostic output for property discovery to aid further troubleshooting

### Changed
- **Build system: `-replace` to `.Replace()`** — Build.ps1 used `-replace` (regex) for `@@INJECT@@` replacements, which corrupted dist output because `$` in PowerShell source code was interpreted as regex backreferences. Produced 80,000+ line dist file with garbled content. Switched to literal `.Replace()` method. This was a latent bug introduced when helpers injection was added — KQL injection was also affected
- **Helpers extraction** — Extracted Write-Step, Safe*, Get-*FromArmId, Invoke-WithRetry, and all Protect-* functions from inline definitions into `src/helpers.ps1`. Injected at build time via `@@INJECT:HELPERS@@` with dot-source fallback for running from source. Reduces main script size and enables future shared framework sync
- **Unicode cleanup** — Replaced em-dashes and box-drawing characters in comments with ASCII equivalents to pass non-ASCII build verification

## [1.3.6] — 2026-03-19

### Fixed
- **Cost Management column order assumption** — Cost parsing used hardcoded column indices (`$row[0]` = Cost, `$row[1]` = Date, etc.) which fails when the API returns columns in a different order across billing account types (EA, MCA, CSP). Now reads the `columns` property from the response to build a dynamic name-to-index lookup. Also adds defensive handling for unexpected array-valued cells (`System.Object[]` cast error)

## [1.3.5] — 2026-03-19

### Fixed
- **OutOfMemoryException on large VM counts** — Main metrics collection processed all VMs in a single parallel block, accumulating millions of data points in a ConcurrentBag. With 1000+ VMs this could exceed process memory. Now batches VMs into groups of 100 with GC between batches. Also fixed hardcoded `-ThrottleLimit 15` to use the `$MetricsParallel` parameter (default lowered from 15 to 5)
- **WorkspaceResourceId strict mode error** — Explicit `$item.WorkspaceResourceId = Protect-ArmId $item.WorkspaceResourceId` lines caused 'property cannot be found' in strict mode for some KQL result objects. Removed redundant explicit assignments since `Protect-KqlRow` already handles this property safely via `PSObject.Properties` iteration

## [1.3.4] — 2026-03-19

### Fixed
- **SafeArray pipeline unrolling** — `SafeArray` used `return @()` which PowerShell pipeline-unrolls to `$null` (zero items) or a scalar (one item), causing `.Count` strict mode crashes. Fixed with comma-trick (`return ,@()`) to preserve array type through the pipeline
- **Host pool ResourceGroup extraction** — When `Get-AzWvdHostPool` returns objects without an ARM-style `.Id` or `.ResourceGroupName` property (varies by Az.DesktopVirtualization module version), `$hpRg` was empty string, causing `Get-AzWvdSessionHost` to fail with "Cannot bind argument to parameter 'ResourceGroupName'". Added `Get-AzResource` ARM lookup as bulletproof fallback, plus graceful skip when RG cannot be determined
- **VMSS direct property access** — `$vmssObj.Name` and `.ResourceGroupName` used unsafe direct access in strict mode. Changed to `SafeProp` with null guard
- **Capacity Reservation property casing** — REST API response properties (`$crg.id`, `$crg.name`) vary between lowercase and PascalCase across PowerShell versions. Changed to `SafeProp` with case fallback and skip guard for null IDs

## [1.3.3] — 2026-03-18

### Fixed
- **Subscription loop resilience** — Widened try/catch to wrap entire per-subscription ARM collection (host pools, VMs, session hosts, app groups, scaling plans, VMSS, capacity reservations). Previously only the subscription context switch was protected; a terminating error during host pool processing would kill the entire script. Now any per-subscription crash logs the error with line number and continues to the next subscription.

### Added
- **Build-time .Count lint** — `build.ps1 -Verify` now scans for bare `.Count` calls that aren't provably safe (missing `SafeCount` or `@()` wrapping). Pre-pass identifies safe variable initializations; supports `# count-safe` suppression comment for reviewed false positives.

## [1.3.2] — 2026-03-17

### Changed
- **Cross-run Graph auth reuse hardening** — `-IncludeIntune` now requests `Connect-MgGraph -ContextScope CurrentUser` when supported, allowing cached Graph context reuse across new shell sessions and reducing repeated interactive sign-in prompts
- **Compatibility fallback** — If the installed Graph module does not support `ContextScope`, collector falls back to process-scoped auth behavior without breaking collection

## [1.3.1] — 2026-03-17

### Changed
- **Graph auth reuse for `-IncludeIntune`** — Collector now checks for an existing Microsoft Graph context and reuses it when tenant + required scopes already match, reducing repeated sign-in prompts across runs in the same shell
- **Optional Graph sign-out control** — Added `-DisconnectGraphOnExit` switch to explicitly disconnect Microsoft Graph at the end of a run when desired
- **Documentation refresh** — Updated README, user manual, and permissions guide to document Graph scope requirements (`DeviceManagementManagedDevices.Read.All`, `Policy.Read.All`) and session reuse behavior

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
