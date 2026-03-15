$scriptPath = 'c:\repos\avd-data-collector\Collect-ApertureData.ps1'
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Write-Host "TOKENS_VAR_TYPE: $($tokens -ne $null ? $tokens.GetType().FullName : 'null')"
Write-Host "ERRORS_VAR_TYPE: $($errors -ne $null ? $errors.GetType().FullName : 'null')"

$parseErrors = $null
if ($errors -and $errors -is [System.Array] -and $errors.Length -gt 0) { $parseErrors = $errors }
elseif ($tokens -and $tokens -is [System.Array] -and $tokens.Length -gt 0 -and ($tokens[0] -is [System.Management.Automation.Language.ParseError])) { $parseErrors = $tokens }

if ($parseErrors) {
	foreach ($e in $parseErrors) {
		$start = if ($e.StartLine) { $e.StartLine } else { '?' }
		$msg = if ($e.Message) { $e.Message } else { $e.ToString() }
		Write-Host "PARSE_ERROR: Line $start - $msg"
	}
} else {
	Write-Host 'PARSE_OK'
}
