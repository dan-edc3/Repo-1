function Test-OnbIdentifierAvailable {
    <#
    .SYNOPSIS
        Reports whether a candidate identifier is free in every system that must agree.
    .DESCRIPTION
        An identifier's 'uniqueIn' list names the systems it must be unique across:

          "ad"          Checks sAMAccountName AND userPrincipalName in Active Directory.
          "sql:<Name>"  Runs that system's 'uniqueQuery' from config.json with the
                        candidate passed as @candidate. The query must return a count.

        Checking every system before allocating matters: a name free in AD but already
        taken in the WMS is not usable, and discovering that after the AD account exists
        means cleaning up by hand.

        Fails CLOSED. If a system cannot be reached, the candidate is treated as
        unavailable rather than assumed free, because handing out a duplicate identifier
        is far more expensive to undo than trying the next candidate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [string[]]$UniqueIn = @('ad'),
        [Parameter(Mandatory)][psobject]$Config,
        [string]$UpnSuffix
    )

    foreach ($scope in $UniqueIn) {
        if ($scope -eq 'ad') {
            try {
                if (Get-ADUser -Filter "SamAccountName -eq '$Candidate'" -ErrorAction Stop) { return $false }
                if ($UpnSuffix) {
                    $upn = "$Candidate@$UpnSuffix"
                    if (Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -ErrorAction Stop) { return $false }
                }
            }
            catch {
                Write-OnbLog -Level WARN "Could not check AD for '$Candidate': $($_.Exception.Message). Treating as unavailable."
                return $false
            }
        }
        elseif ($scope -like 'sql:*') {
            $systemName = $scope.Substring(4)
            $system = $Config.sqlSystems.$systemName
            if (-not $system) {
                Write-OnbLog -Level WARN "uniqueIn names SQL system '$systemName', which is not in config.json. Treating as unavailable."
                return $false
            }
            if (-not $system.uniqueQuery) {
                Write-OnbLog -Level WARN "SQL system '$systemName' has no 'uniqueQuery'; cannot check uniqueness. Treating as unavailable."
                return $false
            }

            $connection = $null
            try {
                $connection = New-Object System.Data.SqlClient.SqlConnection $system.connectionString
                $connection.Open()
                $cmd = $connection.CreateCommand()
                $cmd.CommandText = $system.uniqueQuery
                $cmd.CommandTimeout = 30
                [void]$cmd.Parameters.AddWithValue('@candidate', $Candidate)
                $count = [int]$cmd.ExecuteScalar()
                $cmd.Dispose()
                if ($count -gt 0) { return $false }
            }
            catch {
                Write-OnbLog -Level WARN "Could not check '$systemName' for '$Candidate': $($_.Exception.Message). Treating as unavailable."
                return $false
            }
            finally {
                if ($connection) { if ($connection.State -eq 'Open') { $connection.Close() }; $connection.Dispose() }
            }
        }
        else {
            Write-OnbLog -Level WARN "Unknown uniqueIn scope '$scope' was ignored."
        }
    }

    return $true
}
