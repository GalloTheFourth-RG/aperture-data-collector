# Copilot Instructions — Aperture Data Collector

## Quick Context for Copilot

This is a **public**, customer-facing PowerShell script that collects Azure Virtual Desktop data for offline analysis. It gathers ARM resources, Azure Monitor metrics, Log Analytics (KQL) query results, and optional data (costs, network topology, images, storage, orphans, diagnostics, alerts, activity logs). Outputs a portable ZIP of JSON files consumed by the private **Aperture** repo (`aperture-assessment`).

**Two-repo architecture:**
- **avd-data-collector** (public, this repo) — Customer runs this. Read-only data collection from Azure APIs.
- **Aperture** (`aperture-assessment`, private) — Ingests the collection ZIP offline. Performs all analysis, scoring, and reporting.

**Single script**: `src/Collect-ApertureData.ps1` (~4,090 lines). Build system (`build.ps1`) embeds helpers and KQL queries into `dist/Collect-ApertureData.ps1` for self-contained distribution. Source runs directly when `queries/` folder is present.

**Build system:** Source modules in `src/` are assembled into `dist/Collect-ApertureData.ps1` via `build.ps1` using `@@INJECT@@` placeholder replacement (`.Replace()` method, NOT `-replace` regex). **Never edit `dist/` directly.**

```
src/Collect-ApertureData.ps1  → Main source (~4,090 lines)
src/helpers.ps1               → Write-Step, Safe*, Protect-*, Invoke-WithRetry (~260 lines) → @@INJECT:HELPERS@@
queries/*.kql                 → 37 KQL query templates → @@INJECT:KQL_QUERIES@@
```

Build: `./build.ps1 -Verify` (assembles src/ → dist/, runs 8 checks: syntax, placeholders, KQL, version, non-ASCII, KQL drift, .Count lint, helpers injection).

Tests: `Invoke-Pester tests/Helpers.Tests.ps1` (66 Pester v5 tests covering all helper functions + REST fallback cascade).

**Requires PowerShell 7+** (exits on PS 5.1).

---

## Architecture

1. **Authentication** — `Connect-AzAccount`, validates subscriptions, cross-subscription workspace access
2. **ARM Collection** — Host pools, session hosts, application groups, workspaces, scaling plans, VMs, NICs
3. **Azure Monitor Metrics** — CPU, memory, disk per session host VM (bulk fetch, configurable lookback and grain)
4. **KQL Queries** — 37 Log Analytics queries from `queries/` folder (connections, disconnects, profiles, Shortpath, agent health, client connection health)
5. **Optional Extensions** — Cost data, network topology, image analysis, storage, orphaned resources, diagnostics, alerts, activity log
6. **Intune Integration** (`-IncludeIntune`) — Microsoft Graph API collection of Intune managed devices (separate auth via `Connect-MgGraph`)
7. **Package** — JSON files + `metadata.json` → ZIP

### KQL Queries (37 templates)

Stored in `queries/*.kql`. Each is parameterised with `{timeRange}` placeholder replaced at runtime. Categories: agent health, connections, disconnections, errors, FSLogix profiles, network transport, Shortpath, session concurrency.

---

## Critical Coding Patterns

### Read-Only
The script **never creates, modifies, or deletes** any Azure resources. This is a customer promise.

### Strict Mode
`Set-StrictMode -Version Latest` — all variables must be initialized, property access on `$null` throws.
- **Critical**: `Where-Object` results MUST be wrapped in `@()` before calling `.Count`. Without wrapping, a single match returns a scalar (no `.Count`), zero matches returns `$null` (`.Count` throws in strict mode). Always use: `$filtered = @($collection | Where-Object { ... })` then `$filtered.Count`.
- Use `SafeProp $obj "PropertyName"` for safe property access
- Use `SafeArmProp $obj "PropertyName"` for Az module version differences (handles `.Property` vs `.Properties` nesting, case-insensitive)
- Use `SafeCount $collection` instead of bare `.Count`
- Use `SafeArray $collection` to ensure array type through pipeline

### ARM REST Layer 0 (Host Pool RG Extraction)
`Get-AzWvdHostPool` objects may lack `.Id` or `.ResourceGroupName` depending on `Az.DesktopVirtualization` module version (autorest SDK differences). The script uses a 4-layer cascade:
1. **Layer 0 (REST API)**: `Invoke-AzRestMethod` GET to ARM REST API — raw JSON always contains `id` field. Builds `$hpRestLookup` hashtable before any cmdlet calls
2. **Layer 1 (Cmdlet Id)**: `SafeArmProp $hp 'Id'` → parse RG from ARM path
3. **Layer 2 (Property)**: `SafeProp $hp 'ResourceGroupName'`
4. **Layer 3 (Get-AzResource)**: Bulk cache — only populated when REST API is unavailable

### Error Resilience
Each collection step is wrapped in try/catch. Missing permissions, unavailable APIs, or empty results produce warnings — never crashes. `$ErrorActionPreference = "Continue"` in collection loops.

### Schema Versioning
- `metadata.json` includes SchemaVersion (currently 2.0), CollectorVersion, TenantId, SubscriptionIds, collection parameters, per-source status/counts
- Evidence pack validates schema version on import

### PowerState Normalisation
Collector saves bare codes (`running`, `deallocated`). Evidence pack expects `VM running` — prefix normalisation happens on the consumer side.

### Metric Collection
- Uses `Get-AzMetric` with bulk fetch (up to 50 VMs per call)
- Parallel processing via `ForEach-Object -Parallel` (PS 7 required)
- **Batched in groups of 100 VMs** with GC between batches to prevent OOM on large environments
- Configurable: `-MetricsLookbackDays` (1-30, default 7), `-MetricsTimeGrainMinutes` (5/15/30/60, default 15)
- `-MetricsParallel` (default 5) — lowered from 15 to prevent memory pressure

### Cost Management API
- Column order varies by billing type (EA/MCA/CSP) — MUST read `properties.columns` to build dynamic name-to-index lookup
- Column names vary: `Cost` vs `PreTaxCost`, `UsageDate` vs `BillingMonth`
- Cost cells can be `System.Object[]` — guard with array check

### PS 7 Requirement
The script requires PowerShell 7+ and exits with an error on PS 5.1. Avoid `??`, `?.` and Unicode chars in double-quoted strings for consistency with evidence pack coding standards.
- `[System.Collections.Generic.List[object]]` for growable collections

---

## Common Tasks

### Adding a new collection step
1. Add parameter (e.g., `-IncludeNewData`)
2. Add collection section following existing pattern (Write-Host, try/catch, store result)
3. Add to metadata DataSources with status/count
4. Update `docs/SCHEMA.md` with field documentation
5. Update README.md

### Adding a new KQL query
1. Create `queries/kqlNewQueryName.kql` with `{timeRange}` placeholder
2. Add to the KQL execution loop in the script
3. Document in `docs/QUERIES.md`
4. Add matching query to the evidence pack's `src/queries/` folder

### Version bumping
Update `$script:ScriptVersion` and `$script:SchemaVersion` at top of script, and README.md.

---

## Key Constraints

- **Customer-facing**: Output must be clear, professional, and helpful
- **Read-only**: Absolutely no write operations
- **Graceful failures**: Missing permissions or unavailable APIs warn, don't crash
- **DryRun mode**: Validates connectivity and permissions without collecting data
- **Large environments**: Must handle 1000+ VMs without timeouts (bulk fetch, parallel processing)
