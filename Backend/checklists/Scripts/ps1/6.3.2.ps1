$Result = 'Fail'
$Score = 0
$DatabaseQueried = 'master'
$Finding = 'No network isolation evidence found'

try {
    $fwProfile = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    $fwEnabled = $false
    if ($fwProfile) {
        $fwEnabled = ($fwProfile.Enabled | Where-Object { $_ -eq 'True' }).Count -gt 0
    }

    $rules = Get-NetFirewallRule -Enabled True -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SQL*' -or $_.DisplayName -like '*mssql*' }
    
    if ($fwEnabled) {
        if ($rules) {
            $Score = 3
            $Finding = "Firewall is enabled and SQL-specific rules are configured. Rules count: $($rules.Count)"
        } else {
            $Score = 2
            $Finding = "Firewall is enabled, but no specific SQL rules were identified (may be using default allow or broad rules)"
        }
    } else {
        # Check if listening on specific IP rather than 0.0.0.0
        $listeners = Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue
        if ($listeners -and $listeners.LocalAddress -ne '0.0.0.0') {
            $Score = 1
            $Finding = "Firewall disabled, but SQL is bound to a specific IP: $($listeners.LocalAddress)"
        } else {
            $Score = 0
            $Finding = "Firewall disabled and SQL is listening on all interfaces (0.0.0.0)"
        }
    }
} catch {
    $Score = 0
    $Finding = "Error evaluating network isolation: $($_.Exception.Message)"
}

$Result = if ($Score -ge 2) { 'Pass' } else { 'Fail' }
[PSCustomObject]@{ Result = $Result; Score = $Score; DatabaseQueried = $DatabaseQueried; Finding = $Finding }