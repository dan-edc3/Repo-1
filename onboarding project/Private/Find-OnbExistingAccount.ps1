function Find-OnbExistingAccount {
    <#
    .SYNOPSIS
        Finds an existing AD account for THIS person, by employee number.
    .DESCRIPTION
        This is the distinction that makes re-running safe without being dangerous.

        A matching sAMAccountName does NOT mean "we already onboarded this person" - it
        very often means a different person with a similar name. Treating that as a
        no-op is how a second Dana Reyes ends up with the first Dana Reyes's groups and
        WMS roles, on the first Dana Reyes's account.

        The employee number is the only identifier here that actually identifies a human,
        so it is what re-run detection keys on:

          * Match on employeeNumber -> genuinely the same person. Skip creation, carry on
            with the remaining steps against the existing account. This makes a failed
            run resumable.
          * No match -> a new person, even if the generated name collides. Naming
            resolution allocates them their own identifier.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EmployeeNumber)

    if ([string]::IsNullOrWhiteSpace($EmployeeNumber)) { return $null }

    try {
        $found = @(Get-ADUser -Filter "employeeNumber -eq '$EmployeeNumber'" `
                    -Properties employeeNumber, DisplayName, UserPrincipalName -ErrorAction Stop)
    }
    catch {
        Write-OnbLog -Level WARN "Could not search AD by employee number: $($_.Exception.Message)"
        return $null
    }

    if ($found.Count -gt 1) {
        Write-OnbLog -Level WARN ("Employee number '$EmployeeNumber' matches {0} accounts: {1}. Using none of them; resolve this by hand." -f
            $found.Count, (($found.SamAccountName) -join ', '))
        return $null
    }

    if ($found.Count -eq 1) {
        Write-OnbLog "Employee number '$EmployeeNumber' already belongs to '$($found[0].SamAccountName)'. Treating this as a re-run."
        return $found[0]
    }

    return $null
}
