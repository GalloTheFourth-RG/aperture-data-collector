<#
.SYNOPSIS
    Build script for AVD Data Collector -- embeds KQL queries into a single distributable script.

.DESCRIPTION
    Reads all .kql files from queries/ and embeds them as a PowerShell hashtable
    in the output script, replacing the @@INJECT:KQL_QUERIES@@ placeholder.
    The resulting dist/Collect-AVDData.ps1 is fully self-contained.

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
Write-Host "AVD Data Collector -- Build System" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

$srcScript = Join-Path $PSScriptRoot "Collect-AVDData.ps1"
$queriesDir = Join-Path $PSScriptRoot "queries"
$distDir = Join-Path $PSScriptRoot "dist"
$distScript = Join-Path $distDir "Collect-AVDData.ps1"

# Validate source exists
if (-not (Test-Path $srcScript)) {
    Write-Host "  ERROR: Collect-AVDData.ps1 not found" -ForegroundColor Red
    exit 1
}

# Read source
$content = [System.IO.File]::ReadAllText($srcScript, [System.Text.Encoding]::UTF8)
Write-Host "  Source: Collect-AVDData.ps1 ($(($content -split "`n").Count) lines)" -ForegroundColor Green

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

    Write-Host ""
    if ($allPassed) {
        Write-Host "All checks passed [OK]" -ForegroundColor Green
    } else {
        Write-Host "Some checks failed [X]" -ForegroundColor Red
        exit 1
    }
}
