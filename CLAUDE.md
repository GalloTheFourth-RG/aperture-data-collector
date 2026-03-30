# CLAUDE.md — Aperture Data Collector

## Project Overview

This is a **public**, customer-facing PowerShell script that collects Azure Virtual Desktop data for offline analysis. It gathers ARM resources, Azure Monitor metrics, Log Analytics (KQL) query results, and optional data (costs, network topology, images, storage, orphans, diagnostics, alerts, activity logs). Outputs a portable ZIP of JSON files consumed by the private **Aperture** repo (`aperture-assessment`).

> **Branding:** Part of the "Aperture" product family (tagline: "AVD Health Intelligence"). Repo name: `aperture-data-collector`. Script: `Collect-ApertureData.ps1`.

The owner (Richie) is an AVD consultant who distributes this script to customers. He is new to Git/DevOps — keep commands simple and explain what they do.

**Two-repo architecture:**
- **aperture-data-collector** (public, this repo) — Customer runs this. Read-only data collection from Azure APIs.
- **aperture-assessment** (private, at `C:\repos\aperture-assessment`) — Ingests the collection ZIP offline. Performs all analysis, scoring, and reporting. Owner's IP.

**Requires PowerShell 7+** (exits on PS 5.1).

## Build System

Source modules are assembled into a single distributable script using `@@INJECT@@` placeholder replacement:

```
src/Collect-ApertureData.ps1   → Main source (~4,090 lines)
src/helpers.ps1                → Helper functions (~260 lines) → @@INJECT:HELPERS@@
queries/*.kql                  → 36 KQL query templates → @@INJECT:KQL_QUERIES@@
```

Output: `dist/Collect-ApertureData.ps1` (~5,078 lines, self-contained)

```powershell
./build.ps1 -Verify    # Builds + 8 verification checks
```

**CRITICAL: Never edit `dist/` directly.** Always edit files in `src/` and rebuild.

### Build Verification Checks
1. PowerShell syntax valid
2. No unresolved `@@INJECT@@` placeholders
3. KQL queries embedded (37 queries)
4. Version variable present
5. No non-ASCII characters outside KQL blocks
6. All 37 KQL queries match evidence pack
7. No unguarded `.Count` calls
8. Helpers injection successful

### Build System Gotchas
- **Use `.Replace()` not `-replace`** for placeholder substitution — dollar signs in PowerShell source are interpreted as regex backreferences with `-replace`, producing 80K+ line garbage output
- **Non-ASCII in comments** — Build checks for em-dashes (`—`), arrows (`→`), box-drawing chars. Use ASCII equivalents (`--`, `->`)

## Key Files

| File | Purpose | Size |
|------|---------|------|
| `src/Collect-ApertureData.ps1` | Main source — all collection logic | ~4,090 lines |
| `src/helpers.ps1` | Write-Step, Safe*, Protect-*, Invoke-WithRetry | ~260 lines |
| `build.ps1` | Assembles src/ → dist/ with verification | ~470 lines |
| `dist/Collect-ApertureData.ps1` | Customer-facing built script | ~5,078 lines |
| `tests/Helpers.Tests.ps1` | Pester v5 test suite | 66 tests |
| `queries/*.kql` | 36 Log Analytics query templates | 36 files |

## Architecture — Execution Flow

1. **Authentication** — `Connect-AzAccount`, validates subscriptions, cross-subscription workspace access
2. **ARM Collection** — Host pools (with ARM REST Layer 0), session hosts, VMs, NICs, app groups, workspaces, scaling plans
3. **Azure Monitor Metrics** — CPU/memory/disk per VM (bulk fetch + parallel, batched in groups of 100)
4. **KQL Queries** — 36 Log Analytics queries (connections, disconnects, profiles, Shortpath, agent health)
5. **Optional Extensions** — Cost data, network topology, image analysis, storage, orphaned resources, diagnostics, alerts, activity log
6. **Intune Integration** (`-IncludeIntune`) — Microsoft Graph API for Intune managed devices (separate auth)
7. **Package** — JSON files + `metadata.json` → ZIP with checkpoints

## Critical Coding Patterns

### Read-Only
The script **never creates, modifies, or deletes** any Azure resources. This is a customer promise.

### Strict Mode
`Set-StrictMode -Version Latest` — all variables must be initialized, property access on `$null` throws.
- Use `SafeProp $obj "PropertyName"` for safe access
- Use `SafeArmProp $obj "PropertyName"` for Az module version differences
- Use `SafeCount $collection` instead of bare `.Count`
- Use `SafeArray $collection` to ensure array type through pipeline (comma-trick internally)
- **Critical**: `Where-Object` results MUST be wrapped in `@()` before calling `.Count`

### ARM REST Layer 0 (Host Pool RG Extraction)
The most battle-tested pattern in the codebase. `Get-AzWvdHostPool` objects may lack `.Id` or `.ResourceGroupName` properties depending on `Az.DesktopVirtualization` module version (autorest SDK differences). The script uses a 4-layer cascade:

1. **Layer 0 (REST API)**: `Invoke-AzRestMethod` GET to `/subscriptions/{subId}/providers/Microsoft.DesktopVirtualization/hostPools?api-version=2024-04-03` — raw JSON always contains `id` field. Builds `$hpRestLookup` hashtable
2. **Layer 1 (Cmdlet Id)**: `SafeArmProp $hp 'Id'` → parse RG from ARM path segments
3. **Layer 2 (Property)**: `SafeProp $hp 'ResourceGroupName'`
4. **Layer 3 (Get-AzResource)**: Bulk `Get-AzResource -ResourceType` cache — only populated when REST API is unavailable

**Why Layer 0 exists**: Az.DesktopVirtualization v5.4.1 doesn't expose ARM `id` via `PSObject.Properties`. Previous 4-layer fallback (cmdlet Id, JSON extraction, direct property bypass, individual Get-AzResource) all failed. The ARM REST API bypasses all Az module object-mapping entirely.

### Error Resilience
Each collection step wrapped in try/catch. `$ErrorActionPreference = "Continue"`. Missing permissions or unavailable APIs produce warnings — never crashes. `Invoke-WithRetry` handles 429/503 with exponential backoff.

### Metrics Collection
- Bulk fetch via `Get-AzMetric` (up to 50 VMs per call)
- Parallel processing: `ForEach-Object -Parallel` batched in groups of 100 VMs
- GC between batches to prevent OOM on 1000+ VM environments
- `-MetricsParallel` (default 5), `-MetricsLookbackDays` (default 7), `-MetricsTimeGrainMinutes` (default 15)

### Cost Management API
- Column order varies by billing type (EA/MCA/CSP) — MUST read `properties.columns` to build dynamic name-to-index lookup
- Column names vary: `Cost` vs `PreTaxCost`, `UsageDate` vs `BillingMonth`
- Cost cells can be `System.Object[]` instead of scalar — guard with array check

### PII Scrubbing (`-ScrubPII`)
All identifiable data anonymized in output using `Protect-*` functions in `src/helpers.ps1`:
- `Protect-VMName`, `Protect-HostPoolName`, `Protect-Username`, `Protect-ResourceGroup`
- `Protect-IP`, `Protect-ArmId`, `Protect-SubscriptionId`, `Protect-SubnetId`
- `Protect-KqlRow` handles KQL result anonymization via field-name pattern matching

### Schema Versioning
- `metadata.json` includes SchemaVersion (currently 2.0), CollectorVersion, TenantId, SubscriptionIds, collection parameters, per-source status/counts
- Evidence pack validates schema version on import

## Testing

```powershell
./build.ps1 -Verify                               # Build + 8 verification checks
Invoke-Pester tests/Helpers.Tests.ps1 -Output Minimal  # 66 Pester v5 tests
```

Tests cover: SafeCount, SafeArray, SafeProp, SafeArmProp, Get-ArmIdSafe, Get-NameFromArmId, Get-SubFromArmId, ARM ID RG extraction patterns, REST API response parsing, 4-layer cascade logic, all Protect-* functions (PII on/off), Protect-KqlRow, Write-Step, Invoke-WithRetry.

Note: `.vscode/settings.json` (gitignored) disables Pester auto-discovery to prevent VS Code crashes in multi-root workspace.

## Version Management

Version must be updated in TWO places:
1. `src/Collect-ApertureData.ps1` line ~14: `Version: X.Y.Z` (comment-based help)
2. `src/Collect-ApertureData.ps1` line ~175: `$script:ScriptVersion = "X.Y.Z"`

Also update `CHANGELOG.md` with every version bump.

Current version: **1.4.1**

## Common Tasks

### Adding a new collection step
1. Add parameter (e.g., `-IncludeNewData`)
2. Add collection section following existing pattern (Write-Step, try/catch, store result)
3. Add to metadata DataSources with status/count
4. Update `docs/SCHEMA.md` with field documentation
5. Update README.md

### Adding a new KQL query
1. Create `queries/kqlNewQueryName.kql` with `{timeRange}` placeholder
2. Add to the KQL execution loop in the script
3. Document in `docs/QUERIES.md`
4. Add matching query to the evidence pack's `src/queries/` folder

## Bug Patterns to Watch For

- **`SafeArray` pipeline unrolling** — `return @()` gets pipeline-unrolled to `$null`. Uses comma-trick `return ,@()` internally
- **Az module property variability** — Never assume `Get-AzWvd*` objects have specific properties. Always use SafeProp/SafeArmProp
- **ForEach-Object -Parallel OOM** — Batch VMs, flush between batches, GC.Collect(). Never process 1000+ VMs in single parallel block
- **Cost column order** — Dynamic column detection, never hardcoded indices
- **Non-ASCII in source** — Build rejects em-dashes and Unicode in comments. Use ASCII only
- **`$null.Count` in strict mode** — PS 5.1 crashes; PS 7 returns 0 but strict mode may still throw depending on context
- **`Write-Step -Status` values** — Only accepts: `Start`, `Progress`, `Done`, `Skip`, `Warn`, `Error`. Do NOT use `"OK"` — it produces a null color that crashes `Write-Host -ForegroundColor`
- **`union isfuzzy=true` inside `let` statements** — DOES NOT WORK through `Invoke-AzOperationalInsightsQuery` (returns `BadRequest`). Only top-level `union isfuzzy=true` is safe. Proven across 5+ patterns in v1.4.0
- **KQL join column suffix rule** — KQL only adds `1` suffix when column name exists on BOTH sides of a join. Right-side-only columns keep original names
- **REST API property access in strict mode** — `ConvertFrom-Json` objects from ARM REST may not have all expected properties. Always use `SafeProp` instead of `$obj.property`

## Key Constraints

- **Customer-facing**: Output must be clear, professional, and helpful
- **Read-only**: Absolutely no write operations against Azure
- **Graceful failures**: Missing permissions or unavailable APIs warn, don't crash
- **DryRun mode**: Validates connectivity and permissions without collecting data
- **Large environments**: Must handle 1000+ VMs without timeouts or OOM
