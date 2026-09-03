$Result = 'Fail'
$Score = 0
$DatabaseQueried = 'master'
$Finding = 'No evidence of encryption found'

try {
    # To determine if TLS is enforced and active connections are encrypted, 
    # we must query the SQL Server instance for connection properties.
    # Since this is a ps1 script, we use a SQL query to check sys.dm_exec_connections.
    
    $query = "SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID"
    
    # We assume the environment provides a way to execute SQL; using Invoke-Sqlcmd as the standard for ps1 audit scripts.
    $connectionInfo = Invoke-Sqlcmd -Query $query -Database 'master' -ErrorAction Stop
    
    $isEncrypted = $connectionInfo.encrypt_option
    
    # Check Registry for TLS version enforcement (Server side)
    $tls12Reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server' -ErrorAction SilentlyContinue
    $tls11Reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server' -ErrorAction SilentlyContinue
    $tls10Reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server' -ErrorAction SilentlyContinue

    $tls12Enabled = ($tls12Reg.Enabled -eq 1)
    $legacyEnabled = ($tls11Reg.Enabled -eq 1) -or ($tls10Reg.Enabled -eq 1)

    if ($isEncrypted -eq 1 -and $tls12Enabled -and -not $legacyEnabled) {
        $Score = 3
        $Finding = "Connection is encrypted and TLS 1.2 is explicitly enforced with legacy versions disabled."
    } elseif ($isEncrypted -eq 1) {
        $Score = 2
        $Finding = "Connection is encrypted, but legacy TLS versions may still be active or not explicitly disabled."
    } elseif ($isEncrypted -eq 0 -and $legacyEnabled) {
        $Score = 1
        $Finding = "Connection is unencrypted and legacy TLS versions are active."
    } else {
        $Score = 0
        $Finding = "Encryption is not detected for the current connection and no strict TLS 1.2 enforcement found."
    }
} catch {
    $Score = 0
    $Finding = "Error evaluating encryption: $($_.Exception.Message)"
}

$Result = if ($Score -ge 2) { 'Pass' } else { 'Fail' }
[PSCustomObject]@{ Result = $Result; Score = $Score; DatabaseQueried = $DatabaseQueried; Finding = $Finding }