# Checklist: WSFC quorum / witness configured correctly for the node count (avoids split-brain); quorum model documented
# Scoring: 0=No cluster/quorum detected or NoQuorum; 1=Misconfigured (e.g., NodeMajority on even nodes risking split-brain); 2=Configured but suboptimal (e.g., witness on odd nodes); 3=Correctly configured for node count following best practices.
# NOTE: This script provides automated evidence. Full compliance requires human review.
$Score = 0
$Result = "Fail"

try {
    Import-Module FailoverClusters -ErrorAction SilentlyContinue
    $nodes = Get-ClusterNode -ErrorAction Stop
    $nodeCount = $nodes.Count
    $quorum = Get-ClusterQuorum -ErrorAction Stop
    $nodeType = $quorum.NodeType.ToString()

    if ($nodeCount -eq 0) {
        $Score = 0
    }
    elseif ($nodeType -eq 'NoQuorum') {
        $Score = 0
    }
    elseif ($nodeCount % 2 -eq 0) {
        # Even number of nodes requires a witness to avoid split-brain
        if ($nodeType -eq 'NodeAndFileShareMajority' -or $nodeType -eq 'NodeAndDiskMajority') {
            $Score = 3
        }
        else {
            $Score = 1
        }
    }
    else {
        # Odd number of nodes
        if ($nodeType -eq 'NodeMajority') {
            $Score = 3
        }
        elseif ($nodeType -eq 'NodeAndFileShareMajority' -or $nodeType -eq 'NodeAndDiskMajority') {
            $Score = 2
        }
        else {
            $Score = 1
        }
    }
}
catch {
    $Score = 0
}

$Result = if ($Score -ge 2) { "Pass" } else { "Fail" }

[PSCustomObject]@{ Result = $Result; Score = $Score }