<#
Scans Backend/checklists/Scripts/sql for placeholder patterns and writes
Backend/checklists/placeholder_report.txt with the list of files and a count.
#>
$root = Join-Path $PSScriptRoot '../../../checklists/Scripts/sql'
if (-not (Test-Path $root)) {
    Write-Error "Scripts directory not found: $root"
    exit 2
}
$patterns = @('Placeholder for','SELECT ''Failed'' AS Result','SELECT ''Placeholder''')
$matches = [System.Collections.Generic.List[string]]::new()
Get-ChildItem -Path $root -Filter '*.sql' -Recurse | ForEach-Object {
    $f = $_.FullName
    try {
        $text = Get-Content -LiteralPath $f -Raw -ErrorAction Stop
    } catch {
        # Could be path-too-long or access error; skip file but log to stderr
        Write-Error ("Could not read " + $f + ": " + $_.Exception.Message)
        return
    }
    foreach ($p in $patterns) {
        if ($text -match [regex]::Escape($p)) {
            $matches.Add($f)
            break
        }
    }
}
$matches = $matches | Sort-Object -Unique
$report = Join-Path $PSScriptRoot '../../../checklists/placeholder_report.txt'
$matches | Out-File -FilePath $report -Encoding utf8
"Count: $($matches.Count)" | Out-File -FilePath $report -Append
Write-Output "WROTE: $report"
