<#
.SYNOPSIS
    Build script for Aperture Data Collector -- embeds KQL queries into a single distributable script.

.DESCRIPTION
    Reads all .kql files from queries/ and embeds them as a PowerShell hashtable
    in the output script, replacing the @@INJECT:KQL_QUERIES@@ placeholder.
    The resulting dist/Collect-ApertureData.ps1 is fully self-contained.

.PARAMETER Verify
    Run syntax and structure checks after building.

.EXAMPLE
    ./build.ps1 -Verify
#>
param(
    [switch]$Verify
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Write-Host ""
Write-Host "Aperture Data Collector -- Build System" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

$srcScript = Join-Path $PSScriptRoot "Collect-ApertureData.ps1"
$queriesDir = Join-Path $PSScriptRoot "queries"
$distDir = Join-Path $PSScriptRoot "dist"
$distScript = Join-Path $distDir "Collect-ApertureData.ps1"

# Validate source exists
if (-not (Test-Path $srcScript)) {
    Write-Host "  ERROR: Collect-ApertureData.ps1 not found" -ForegroundColor Red
    exit 1
}

# Read source
$content = [System.IO.File]::ReadAllText($srcScript, [System.Text.Encoding]::UTF8)
Write-Host "  Source: Collect-ApertureData.ps1 ($(($content -split "`n").Count) lines)" -ForegroundColor Green

# Build embedded KQL hashtable
$kqlFiles = Get-ChildItem -Path $queriesDir -Filter "*.kql" -ErrorAction SilentlyContinue | Sort-Object Name
if ($kqlFiles.Count -eq 0) {
    Write-Host "  ERROR: No .kql files found in queries/" -ForegroundColor Red
    exit 1
}

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('$script:EmbeddedKqlQueries = @{')
foreach ($kqlFile in $kqlFiles) {
    $queryName = $kqlFile.BaseName
    $queryContent = [System.IO.File]::ReadAllText($kqlFile.FullName, [System.Text.Encoding]::UTF8).TrimEnd()
    # Single-quoted here-strings (@'...'@) are fully literal -- no escaping needed
    $null = $sb.AppendLine("    '$queryName' = @'")
    $null = $sb.AppendLine($queryContent)
    $null = $sb.AppendLine("'@")
}
$null = $sb.AppendLine('}')

$kqlBlock = $sb.ToString().TrimEnd()
$kqlLineCount = ($kqlBlock -split "`n").Count
Write-Host "  Embedded $($kqlFiles.Count) KQL queries ($kqlLineCount lines)" -ForegroundColor Green

# Replace placeholder
if ($content -notmatch '@@INJECT:KQL_QUERIES@@') {
    Write-Host "  ERROR: @@INJECT:KQL_QUERIES@@ placeholder not found in source" -ForegroundColor Red
    exit 1
}
$content = $content -replace '# @@INJECT:KQL_QUERIES@@', $kqlBlock

# Ensure dist/ exists
if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

# Write with UTF-8 BOM for PS 5.1 compatibility
$bomEncoding = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($distScript, $content, $bomEncoding)

$outputLines = ($content -split "`n").Count
$outputSize = [math]::Round((Get-Item $distScript).Length / 1KB, 1)
Write-Host ""
Write-Host "Build complete:" -ForegroundColor Green
Write-Host "  Output: $distScript"
Write-Host "  Lines: $outputLines"
Write-Host "  Size: $($outputSize) KB"
Write-Host ""

# Verification
if ($Verify) {
    Write-Host "Running verification checks..." -ForegroundColor Cyan

    $allPassed = $true

    # 1. Syntax check
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($distScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) {
        Write-Host "  [OK] PowerShell syntax valid" -ForegroundColor Green
    } else {
        Write-Host "  [X] Syntax errors:" -ForegroundColor Red
        $errors | Select-Object -First 5 | ForEach-Object {
            Write-Host "    Line $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor Red
        }
        $allPassed = $false
    }

    # 2. No unresolved placeholders
    if ($content -match '@@INJECT:') {
        Write-Host "  [X] Unresolved @@INJECT@@ placeholders found" -ForegroundColor Red
        $allPassed = $false
    } else {
        Write-Host "  [OK] No unresolved placeholders" -ForegroundColor Green
    }

    # 3. Embedded queries present
    if ($content -match 'EmbeddedKqlQueries = @\{' -and $content -match "kqlTableDiscovery") {
        Write-Host "  [OK] KQL queries embedded ($($kqlFiles.Count) queries)" -ForegroundColor Green
    } else {
        Write-Host "  [X] KQL queries not properly embedded" -ForegroundColor Red
        $allPassed = $false
    }

    # 4. Version variable present
    if ($content -match '\$script:ScriptVersion\s*=') {
        Write-Host "  [OK] Version variable present" -ForegroundColor Green
    } else {
        Write-Host "  [X] Version variable missing" -ForegroundColor Red
        $allPassed = $false
    }

    # 5. No non-ASCII in double-quoted strings
    $distLines = $content -split "`n"
    $unicodeIssues = @()
    for ($i = 0; $i -lt $distLines.Count; $i++) {
        foreach ($c in $distLines[$i].ToCharArray()) {
            if ([int]$c -gt 127) {
                # Skip if inside a here-string (KQL content is safe)
                $unicodeIssues += "Line $($i+1): U+$([string]::Format('{0:X4}', [int]$c))"
                break
            }
        }
    }
    # KQL here-strings are safe (they're in single-quoted here-strings)
    # Only flag if issues are outside KQL blocks
    $inKqlBlock = $false
    $realIssues = @()
    for ($i = 0; $i -lt $distLines.Count; $i++) {
        $line = $distLines[$i]
        if ($line -match "^    '.+' = @'") { $inKqlBlock = $true; continue }
        if ($line -match "^'@") { $inKqlBlock = $false; continue }
        if (-not $inKqlBlock) {
            foreach ($c in $line.ToCharArray()) {
                if ([int]$c -gt 127) {
                    $realIssues += "Line $($i+1): U+$([string]::Format('{0:X4}', [int]$c)) in: $($line.Trim().Substring(0, [math]::Min(60, $line.Trim().Length)))"
                    break
                }
            }
        }
    }
    if ($realIssues.Count -eq 0) {
        Write-Host "  [OK] No non-ASCII characters outside KQL blocks" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Non-ASCII characters found outside KQL blocks:" -ForegroundColor Yellow
        $realIssues | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        # Warning only, not a failure -- KQL content in here-strings is safe
    }

    # 6. KQL drift check against evidence pack
    $epQueriesDir = Join-Path $PSScriptRoot ".." "aperture-assessment" "src" "queries"
    if (Test-Path $epQueriesDir) {
        $driftIssues = @()
        foreach ($kqlFile in $kqlFiles) {
            $epFile = Join-Path $epQueriesDir $kqlFile.Name
            if (Test-Path $epFile) {
                $collectorContent = (Get-Content $kqlFile.FullName -Raw).Trim()
                $epContent = (Get-Content $epFile -Raw).Trim()
                if ($collectorContent -ne $epContent) {
                    $driftIssues += $kqlFile.Name
                }
            }
        }
        if ($driftIssues.Count -eq 0) {
            Write-Host "  [OK] All $($kqlFiles.Count) KQL queries match evidence pack" -ForegroundColor Green
        } else {
            Write-Host "  [X] KQL drift detected ($($driftIssues.Count) files differ):" -ForegroundColor Red
            $driftIssues | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $allPassed = $false
        }
    } else {
        Write-Host "  [--] Evidence pack not found -- skipping KQL drift check" -ForegroundColor Gray
    }

    # 7. Bare .Count safety check
    # In PS 7+ .Count works on scalars/$null via intrinsic members, but still
    # fails on null intermediate property chains ($null.Prop.Count) and some
    # .NET types. SafeCount or @() wrapping prevents edge-case crashes.
    Write-Host ""
    Write-Host "Strict Mode Safety (.Count):" -ForegroundColor Cyan
    $srcLines = $content -split "`n"
    $bareCountIssues = @()
    $inHereString = $false

    # Pre-pass: identify variables guaranteed to be arrays/collections from init
    $safeVarNames = @{}
    for ($i = 0; $i -lt $srcLines.Count; $i++) {
        $l = $srcLines[$i]
        if ($l -match '\$(\w+)\s*=\s*@\(') { $safeVarNames[$matches[1]] = $true }              # $var = @(...)
        if ($l -match '\$(\w+)\s*=\s*\[System\.Collections') { $safeVarNames[$matches[1]] = $true } # List[object]::new()
        if ($l -match '\$(\w+)\s*=\s*@\{') { $safeVarNames[$matches[1]] = $true }               # $var = @{}
        if ($l -match '\$(\w+)\s*\+=') { $safeVarNames[$matches[1]] = $true }                    # $var += (array append)
        if ($l -match '\$(\w+)\s*=.*-split') { $safeVarNames[$matches[1]] = $true }              # $var = x -split y
        if ($l -match '^\s*\[.*\]\s*\$(\w+)') { $safeVarNames[$matches[1]] = $true }            # [Type]$param
    }

    for ($i = 0; $i -lt $srcLines.Count; $i++) {
        $line = $srcLines[$i]
        $trimmed = $line.Trim()

        # Track here-string boundaries (KQL content is safe)
        if ($inHereString) {
            if ($trimmed -eq "'@" -or $trimmed -eq '"@') { $inHereString = $false }
            continue
        }
        if ($trimmed -match "=\s*@['""]$") {
            $inHereString = $true
            continue
        }

        # Skip comment-only lines and lines without .Count
        if ($trimmed -match '^\s*#') { continue }
        if ($line -notmatch '\.Count\b') { continue }

        # SAFE patterns — these never crash in strict mode
        if ($line -match 'SafeCount') { continue }                          # Using the safe helper
        if ($line -match '@\([^)]*\)\.Count') { continue }                  # @(...).Count — always array
        if ($line -match '\.PSObject\.Properties') { continue }              # .Match() returns MatchCollection
        if ($line -match 'Measure-Object.*\.Count') { continue }            # Measure-Object always returns object
        if ($line -match 'function\s+Safe') { continue }                    # SafeCount function definition
        if ($line -match '\-split\b.*\.Count') { continue }                  # -split always returns array
        if ($line -match '\.Keys\b.*\.Count') { continue }                   # Hashtable .Keys always exists
        if ($line -match '#.*\.Count') { continue }                          # .Count inside a trailing comment
        if ($line -match '\.Count\s*[+\-]{2}') { continue }                  # .Count++ is custom property increment
        if ($line -match '\$Obj\b.*\.Count') { continue }                    # Inside SafeCount function body
        if ($line -match 'count-safe') { continue }                          # Explicit developer suppression
        # Skip if the variable was initialized as array/collection/hashtable
        if ($line -match '\$(\w+)\.Count' -and $safeVarNames.ContainsKey($matches[1])) { continue }

        $snippet = $trimmed.Substring(0, [math]::Min(100, $trimmed.Length))
        $bareCountIssues += "Line $($i+1): $snippet"
    }

    if ($bareCountIssues.Count -eq 0) {
        Write-Host "  [OK] No unguarded .Count calls detected" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] $($bareCountIssues.Count) unguarded .Count call(s) -- use SafeCount or @() wrapping:" -ForegroundColor Yellow
        $bareCountIssues | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
        if ($bareCountIssues.Count -gt 20) {
            Write-Host "    ... and $($bareCountIssues.Count - 20) more" -ForegroundColor Yellow
        }
        # Warning only for now — will become a build failure once existing code is cleaned up
    }

    Write-Host ""
    if ($allPassed) {
        Write-Host "All checks passed [OK]" -ForegroundColor Green
    } else {
        Write-Host "Some checks failed [X]" -ForegroundColor Red
        exit 1
    }
}
