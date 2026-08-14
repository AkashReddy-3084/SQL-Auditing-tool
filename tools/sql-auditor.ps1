Param(
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$Args
)

# Resolve paths
$scriptDir = [string](Split-Path -Parent $MyInvocation.MyCommand.Definition)
$repoRoot = [string]((Get-Item $scriptDir).Parent.FullName)

function Write-Usage {
    Write-Host "Usage: .\tools\sql-auditor.ps1 [<args for SQLAuditor.exe or dotnet run>]"
    Write-Host "Examples:"
    Write-Host "  .\tools\sql-auditor.ps1 evaluate --items 1.1.2,3.1.2 --server myserver\\instance"
    Write-Host "  .\tools\sql-auditor.ps1 --dump-checklist"
}

if ($Args -eq $null -or $Args.Length -eq 0) {
    Write-Usage
    exit 0
}

# Candidate exe location (project targets net10.0)
$exeCandidates = @()
$exeCandidates += [System.IO.Path]::Combine($repoRoot, 'Backend','core','bin','Debug','net10.0','SQLAuditor.exe')

$exePath = $null
foreach ($p in $exeCandidates) {
    if (Test-Path $p) { $exePath = $p; break }
}

# If exe not found, try building the project
if (-not $exePath) {
    $proj = Join-Path $repoRoot "Backend\core\SQLAuditor.csproj"
    if (Test-Path $proj) {
        Write-Host "SQLAuditor.exe not found. Running 'dotnet build' for Backend/core..."
        & dotnet build $proj -c Debug
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "dotnet build failed (exit $LASTEXITCODE). Will attempt 'dotnet run' instead."
            $exePath = $null
        } else {
            foreach ($p in $exeCandidates) { if (Test-Path $p) { $exePath = $p; break } }
        }
    }
}

# Execute
if ($exePath) {
    Write-Host "Executing SQLAuditor.exe: $exePath`n" -ForegroundColor Cyan
    & $exePath @Args
    exit $LASTEXITCODE
} else {
    # Fallback to dotnet run (requires .NET SDK)
    $proj = Join-Path $repoRoot "Backend\core\SQLAuditor.csproj"
    if (Test-Path $proj) {
        Write-Host "Launching via 'dotnet run --project $proj -- [args]'" -ForegroundColor Cyan
        & dotnet run --project $proj -- @Args
        exit $LASTEXITCODE
    } else {
        Write-Error "Could not find SQLAuditor.exe or project file at Backend/core. Ensure you are in the repository root."
        exit 2
    }
}
