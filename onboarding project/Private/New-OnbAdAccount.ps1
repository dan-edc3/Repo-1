function New-OnbAdAccount {
    <#
    .SYNOPSIS
        Creates the on-premises AD account for a new user, per the role definition.
    .DESCRIPTION
        In a hybrid environment the on-prem account is the source of truth; Entra
        Connect carries it to the cloud. This function only touches AD.

        It is idempotent: if the sAMAccountName already exists it reports Skipped
        rather than failing, so a run that died partway through can be re-run.
    .OUTPUTS
        Onb.StepResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$Role,
        [Parameter(Mandatory)][securestring]$Password
    )

    $sam = $Context['samAccountName']

    # A re-run is identified upstream by EMPLOYEE NUMBER, not by name. Reaching this
    # function with isRerun set means the account genuinely belongs to this person, so
    # skipping creation and continuing with the remaining steps is correct and resumable.
    if ($Context['isRerun']) {
        try   { $acct = Get-ADUser -Identity $sam -ErrorAction Stop }
        catch { return New-OnbStepResult -Step 'Create AD account' -Status Failed -Message $_.Exception.Message }
        return New-OnbStepResult -Step 'Create AD account' -Status Skipped `
            -Message "Account '$sam' already exists for this employee number." -Data $acct.DistinguishedName
    }

    # Otherwise the name was just allocated as unique, so anything already sitting on it
    # is a surprise - most likely another admin creating an account at the same moment.
    # Failing here is deliberate: silently continuing would apply this person's groups and
    # WMS roles to somebody else's account.
    try {
        $clash = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction Stop
        if ($clash) {
            Write-OnbLog -Level ERROR "'$sam' was allocated as free but already exists ($($clash.DistinguishedName))."
            return New-OnbStepResult -Step 'Create AD account' -Status Failed `
                -Message "'$sam' already exists and does not belong to employee number $($Context['EmployeeNumber']). Nothing was changed. Re-run to allocate a different name."
        }
    }
    catch {
        return New-OnbStepResult -Step 'Create AD account' -Status Failed `
            -Message "Could not query AD for '$sam': $($_.Exception.Message)"
    }

    # Every string in the role's AD block may contain {tokens}
    $ou = Expand-OnbToken -Template $Role.ad.ou -Context $Context

    $params = @{
        Name                  = $Context['displayName']
        GivenName             = $Context['firstName']
        Surname               = $Context['lastName']
        DisplayName           = $Context['displayName']
        SamAccountName        = $sam
        UserPrincipalName     = $Context['userPrincipalName']
        EmailAddress          = $Context['email']
        Path                  = $ou
        AccountPassword       = $Password
        Enabled               = $true
        ChangePasswordAtLogon = [bool]$Role.ad.changePasswordAtLogon
    }

    # ---- First-class New-ADUser parameters ------------------------------------------
    # These attributes have a dedicated New-ADUser parameter, so they MUST be set here
    # and NOT via OtherAttributes - AD rejects an attribute supplied both ways.
    # Adding a name to this list is a one-time change that benefits every role. Deciding
    # what a role puts IN the attribute stays in the role's JSON.
    $firstClassFields = @(
        'title','department','company','division','organization','office','description',
        'employeeNumber','employeeID','streetAddress','city','state','postalCode',
        'officePhone','mobilePhone','homePage'
    )
    foreach ($field in $firstClassFields) {
        $value = $Role.ad.$field
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $params[$field] = Expand-OnbToken -Template ([string]$value) -Context $Context
        }
    }

    # ---- Everything else -------------------------------------------------------------
    # otherAttributes sets any LDAP attribute that has no dedicated parameter -
    # extensionAttribute1..15, employeeType, custom schema extensions - with no code change.
    # NOTE: what Exchange Online calls CustomAttribute1 is extensionAttribute1 in AD.
    #       Use the AD name here.
    if (($Role.ad.PSObject.Properties.Name -contains 'otherAttributes') -and $Role.ad.otherAttributes) {
        $other = @{}
        foreach ($p in $Role.ad.otherAttributes.PSObject.Properties) {
            $expanded = Expand-OnbToken -Template ([string]$p.Value) -Context $Context
            # AD rejects empty values in OtherAttributes, so drop anything that
            # resolved to nothing (e.g. an optional prompt the operator left blank).
            if (-not [string]::IsNullOrWhiteSpace($expanded)) { $other[$p.Name] = $expanded }
            else { Write-OnbLog -Level WARN "Attribute '$($p.Name)' resolved to an empty value; not set." }
        }
        if ($other.Count) { $params['OtherAttributes'] = $other }
    }

    if (-not $PSCmdlet.ShouldProcess("$sam in $ou", 'Create AD user')) {
        return New-OnbStepResult -Step 'Create AD account' -Status WhatIf `
            -Message "Would create '$sam' in '$ou'." -Data $params
    }

    try {
        New-ADUser @params -ErrorAction Stop
        $created = Get-ADUser -Identity $sam -ErrorAction Stop
        Write-OnbLog "Created AD account '$sam' at $($created.DistinguishedName)."
        New-OnbStepResult -Step 'Create AD account' -Status Success `
            -Message "Created '$sam' in '$ou'." -Data $created.DistinguishedName
    }
    catch {
        Write-OnbLog -Level ERROR "Failed to create AD account '$sam': $($_.Exception.Message)"
        New-OnbStepResult -Step 'Create AD account' -Status Failed `
            -Message $_.Exception.Message
    }
}
