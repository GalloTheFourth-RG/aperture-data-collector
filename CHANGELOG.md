# Changelog

All notable changes to the Aperture Data Collector will be documented in this file.

## [1.6.1] — 2026-04-13

### Fixed
- **RI-covered VMs showing $0 cost** — Cost Management queries used `Usage` cost type which reports $0 compute for Reserved Instance-covered VMs. Now uses `AmortizedCost` first (spreads RI purchases across covered VMs), falling back to `Usage` only when `AmortizedCost` is not supported by the billing type (some CSP/legacy accounts). Logs which cost type was used per subscription
- **Cost query type exported in pack** — `cost-access.json` now includes `CostQueryType` field so the assessment knows whether costs are amortized or usage-based

### Changed
- **README overhaul** — Fixed 38 KQL query count (was 37), added missing parameters (`MetricsParallel`, `KqlParallel`), added missing output files (`nerdio-state.json`, `permission-failures.json`, `diagnostic.log`), clarified `IncludeAllExtended` scope (does not enable `-IncludeReservedInstances` or `-IncludeIntune`), documented PII key CSV, noted Conditional Access collection under `-IncludeIntune`
- **PERMISSIONS.md** — Updated KQL count, added Conditional Access as separate Intune step, clarified `IncludeAllExtended` exclusions, noted amortized cost behavior

## [1.6.0] — 2026-04-07

### Added
- **Peak Sessions by Host KQL Query** — New `kqlPeakSessionsByHost.kql` query collects historical peak concurrent sessions per session host from `WVDConnections`. Provides accurate peak density data even when ARM snapshot was collected outside business hours (38 total KQL queries)

## [1.5.0] — 2026-04-07

### Added
- **Real DryRun Permission Probes** — All DryRun checks now make actual API calls instead of assuming Reader role covers everything. Custom Azure roles with the correct ARM actions work correctly (PR #2 by Chad Hamilton)
- **10 New DryRun Probes** — Network Topology, Storage, Diagnostic Settings, Alert Rules, Activity Log, Policy Assignments, Image Analysis, Quota Usage, Capacity Reservations, Reserved Instances
- **Permission Registry** — Centralized `$script:PermissionRegistry` mapping every collection feature to its required ARM actions and remediation commands. Used by both DryRun and runtime error handling
- **Runtime Permission Tracking** — Extended collection sections now detect permission errors at runtime and gracefully skip with actionable messages. Skipped sections exported as `permission-failures.json` in the collection pack
- **Permission Failure Summary** — End-of-run summary lists all skipped sections and the specific ARM actions needed to fix them
- **22 Pester Tests** — `Test-IsPermissionError`, `Test-ProbeAccess`, `Add-PermissionFailure`, and `PermissionRegistry` completeness coverage (88 total tests)

### Fixed
- **PERMISSIONS.md namespace** — Custom role template used `Microsoft.Reservations` (non-existent provider) instead of `Microsoft.Capacity` for Reserved Instance actions. Added 17 missing ARM actions for all extended collection features
- **Metrics probe was hardcoded** — DryRun metrics check returned `$true` without testing actual API access. Now calls `Get-AzMetric` against a discovered VM
- **KQL drift check false positive** — Build verification flagged `kqlConnectionSuccessRate.kql` as drifted when the only difference was the expected `{timeRange}` line (collector has it, assessment doesn't). Drift check now strips `{timeRange}` lines before comparing

## [1.4.3] — 2026-03-31

### Fixed
- **Connection Success Rate inflated attempts** — KQL `kqlConnectionSuccessRate.kql` counted every WVDConnections row (Started/Connected/Completed) as a separate attempt, inflating TotalAttempts ~2-3x. Now deduplicates by CorrelationId using `take_any(State)` before counting terminal states

## [1.4.2] — 2026-03-30

### Fixed
- **FSLogix Storage duplicate rows** — Added share-level deduplication keyed on `StorageAccountName|ShareName`. Same share no longer collected multiple times when multiple host pools share a resource group
- **FSLogix Storage Quota = 0** — Added fallback from `ShareProperties.QuotaInGiB` to direct `.Quota` property when the former is null (varies by Az.Storage module version). Fixes downstream Usage % showing N/A

## [1.4.1] — 2026-03-30

### Fixed
- **Connection Quality High Latency % bug** — KQL `kqlConnectionQuality.kql` divided high-latency RTT sample count by distinct connection count (producing impossible values over 100%). Changed denominator to `count()` (total samples), matching the region query pattern

## [1.4.0] — 2026-03-24

### Added
- **AVD Workspace Collection** — New ARM REST API collection step enumerates all AVD workspaces per subscription. Captures workspace name, friendly name, location, `publicNetworkAccess`, app group count, and ARM ID. Exported as `avd-workspaces.json` in collection pack
- **Workspace Private Endpoint Detection** — New check enumerates private endpoint connections on each AVD workspace, detecting `feed` and `global` subresource types. Exported as `workspace-private-endpoints.json`
- **Host Pool `publicNetworkAccess`** — Host pool objects now include the `PublicNetworkAccess` ARM property (values: `Enabled`, `EnabledForSessionHostsOnly`, `Disabled`)
- **Host Pool PE Subresource Detection** — Enhanced host pool PE check with subresource type detection via `GroupId`. Distinguishes `connection` subresource from other PE types. Objects now include `ResourceType`, `ResourceName`, `Subresources` fields
- **5 Updated KQL Queries** — `kqlShortpathUsage`, `kqlShortpathByClient`, `kqlShortpathByGateway`, `kqlShortpathTransportRTT`, `kqlMultiLinkTransport` now join `WVDMultiLinkAdd` for granular Direct/STUN/TURN/WebSocket transport classification and Multipath detection

### Fixed
- **Workspace collection crash** — `Write-Step -Status "OK"` used invalid status value (function uses `"Done"`), causing `ForegroundColor` null binding error. Changed to `"Done"`
- **Workspace property access crash** — Direct property access (`$ws.id`, `$ws.properties`) failed under strict mode for some REST responses. Replaced with `SafeProp` guards and pre-computed all values before `[PSCustomObject]@{}`
- **ShortpathByClient KQL BadRequest** — Rewrote all 4 Shortpath KQL files to remove `WVDMultiLinkAdd` from `let` statements (`union isfuzzy=true` inside `let` fails through `Invoke-AzOperationalInsightsQuery`). Queries now use only `WVDCheckpoints` + `UdpUse`. STUN/TURN/Direct detail comes from dedicated `kqlMultiLinkTransport.kql`
- **ClientConnectionHealth column name error** — Right-side join columns `ErrorConnections`/`TopError` didn't get `1` suffix (KQL only adds suffix when name conflicts on BOTH sides). Renamed to `ErrConns`/`ErrTop` to avoid ambiguity

### Changed
- **Private Endpoint Finding Schema** — PE findings now use `ResourceType`/`ResourceName` fields (was `HostPoolName`-only). Assessment handles both schemas for backward compatibility

## [1.3.17] — 2026-03-24

### Added
- **Client Connection Health KQL query** (`kqlClientConnectionHealth.kql`) — New query joining WVDConnections with WVDErrors by CorrelationId to correlate client versions with connection error rates. Collected automatically when Log Analytics workspace is available

## [1.3.16] — 2026-03-22

### Added
- **Structured diagnostic log** — New `diagnostic-events.json` in collection ZIP captures all warnings, errors, and skipped steps with timestamps, severity, and error details. Enables offline troubleshooting without console transcripts
- **`Write-DiagEvent` helper** — Centralized diagnostic event capture function. `Write-Step` automatically logs Warn/Error/Skip events
- **Enhanced metadata** — `CollectionDurationSeconds`, `DiagnosticCounts` (TotalEvents/Errors/Warnings/Skipped), and `SkippedSubscriptions` fields added to `metadata.json`

### Improved
- **Network topology error visibility** — Subnet, VNet, private endpoint, and NSG evaluation errors now captured as structured diagnostic events in addition to console warnings

## [1.3.15] — 2026-03-20

### Fixed
- **Gallery image analysis skipped under `-ScrubPII`** — `ImageId` was nulled by PII scrubbing before the gallery image parser could extract resource group, name, and definition from the ARM path. Now uses the raw ID for parsing and applies `Protect-Value` only to the output fields
- **Resource tags collection skipped under `-ScrubPII`** — The entire resource-tags collection step was gated behind `-not $ScrubPII`, skipping it entirely when PII mode was active. Removed the gate and now wraps tag values in `Protect-VMName`/`Protect-HostPoolName`/`Protect-ResourceGroup`/`Protect-Value` instead

## [1.3.14] — 2026-03-20

### Fixed
- **KQL `SessionHostName` PII hash mismatch** — When running with `-ScrubPII`, KQL results containing FQDNs (e.g., `vm-001.contoso.com`) were hashed differently than session host short names (`vm-001`), causing the assessment's cross-region analysis to fail (100% of connection paths skipped). `Protect-KqlRow` now normalizes hostname fields to short name before hashing so both sides produce matching anonymous IDs
- **KQL `_ResourceId` field used wrong PII function** — ARM resource IDs in KQL results were being hashed with `Protect-VMName` instead of `Protect-ArmId`, producing inconsistent anonymous IDs

### Improved
- **KQL disconnect categorization** — Added `contains` checks alongside `has_any` to catch CamelCase compound error codes (e.g., `ClientNetworkLost`, `TransportClosedUnexpectedly`, `ConnectionFailedServerDisconnect`) that KQL term boundaries don't split. These codes now correctly categorize as Network Drop, Server Side, etc. instead of falling through to "Other"
- **Network topology error visibility** — Subnet analysis, VNet analysis, private endpoint, and NSG evaluation errors are now shown as yellow `[WARN]` messages instead of being silently swallowed in `-Verbose` output. Customers can now see exactly which network checks failed and why

## [1.3.13] — 2026-03-20

### Improved
- **Memory management for large environments (3,000-10,000+ VMs)** — ARM object caches (VM models, VM status, NICs, disk encryption, extensions) are now released after Step 1 flattening and checkpoint save, freeing hundreds of MB before metrics collection begins. Cost Management data is flushed to disk immediately after collection instead of accumulating in memory until final export. Together with the v1.3.12 metrics pre-aggregation, peak memory is now bounded to roughly the size of the largest single step rather than the sum of all steps
- **Memory usage reporting** — Working set (MB) is logged at 6 milestones throughout collection: start, after Step 1, after cost flush, after Step 2, after Step 3, and final. Look for `[MEM]` lines in the output to monitor memory consumption
- **Capacity reservation pagination** — Replaced array `+=` reallocation with `Generic.List.Add()` to eliminate O(n^2) copy behavior during paginated API responses

## [1.3.12] — 2026-03-20

### Fixed
- **Out-of-memory crash during metrics collection on large environments** — Environments with 2,500+ VMs could cause the PowerShell process to be killed by the OS during Step 2 (Azure Monitor metrics). The terminal would close silently with no error message. Root cause: each VM produced ~6,700 raw metric data points (7 days x 96 intervals x 10 metrics), totaling ~18 million PSCustomObject allocations at ~300-500 bytes each (5-9 GB). Now pre-aggregates per VM inside the parallel block -- each VM produces 1 summary object with AvgCPU, PeakCPU, memory, and disk metrics. Memory reduced by ~99.98%. Metadata includes `MetricsFormat: "pre-aggregated"` for evidence pack format detection

## [1.3.11] — 2026-03-20

### Fixed
- **SafeArray in foreach loops causing session host enumeration failure** — The `SafeArray` helper uses a comma-trick (`return ,@()`) which is correct for assignment contexts but wraps the entire collection as a single element in `foreach` loops. This caused the loop variable to be the entire array instead of individual items, making `SafeArmProp` see `System.Object[]` instead of individual PSCustomObjects and return null for every host pool property. Replaced all 23 `foreach + SafeArray` patterns with `foreach + @()`. SafeArray is now only used for variable assignments

## [1.3.9] — 2026-03-20

### Fixed
- **Host pool enumeration returning partial results** — `Get-AzWvdHostPool` on Az.DesktopVirtualization v5.4.1 returned only 1 host pool per subscription (3 total) while the ARM REST API found all 51. Additionally, the cmdlet's `Name` property format differed from the REST API keys, causing the Layer 0 lookup to fail. Now uses REST-parsed objects **directly** as the host pool list, completely bypassing the cmdlet for enumeration. `Get-AzWvdHostPool` is only called as a fallback when the REST API is unavailable. This means `SafeArmProp` reads properties from the REST JSON structure (`.properties.hostPoolType`, etc.) which it already supported via its nested-property traversal logic

## [1.3.8] — 2026-03-20

### Fixed
- **Host pool resource group extraction — definitive fix via ARM REST API** — Previous fallback layers (cmdlet property access, JSON extraction, Get-AzResource) all depend on `Az.DesktopVirtualization` module object mapping, which varies across autorest SDK versions and may not expose the ARM `id` property via `PSObject.Properties`. Added a new "Layer 0" that calls the ARM REST API directly via `Invoke-AzRestMethod` **before** any cmdlet-based enumeration. The raw JSON response always contains the `id` field with the full ARM resource path, making resource group extraction completely independent of the Az PowerShell module version. This is a one-call-per-subscription bulk fetch, so adds negligible overhead
- **Removed debug diagnostic logging** — Removed all `[DEBUG]` Write-Host lines added in v1.3.7 for troubleshooting. The ARM REST approach eliminates the need for property discovery diagnostics

### Changed
- **Simplified RG extraction chain** — Consolidated from 5 fallback layers (cmdlet Id, direct property, JSON regex, ResourceGroupName, individual Get-AzResource) down to 4 clean layers: REST lookup → cmdlet Id → ResourceGroupName property → Get-AzResource cache. The Get-AzResource bulk fetch only runs when the REST API is unavailable (authentication edge cases)

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
