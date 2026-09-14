function Add-OnbGroupMembership {
    <#
    .SYNOPSIS
        Adds the new user to each group listed in the role definition.
    .DESCRIPTION
        Each group is handled independently and returns its own step result, so one
        missing group doesn't abort the rest of the run - you get a checklist with
        one red line instead of an all-or-nothing failure.

        If you use group-based licensing in Entra, the licence groups belong in this
        same list; there is no separate licensing step to maintain.
    .OUTPUTS
        Onb.StepResult (one per group)
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$Role
    )

    $sam = $Context['samAccountName']

    foreach ($groupTemplate in @($Role.groups)) {
        if ([string]::IsNullOrWhiteSpace($groupTemplate)) { continue }
        $group    = Expand-OnbToken -Template $groupTemplate -Context $Context
        $stepName = "Group: $group"

        try {
            $adGroup = Get-ADGroup -Identity $group -ErrorAction Stop
        }
        catch {
            Write-OnbLog -Level ERROR "Group '$group' not found in AD."
            New-OnbStepResult -Step $stepName -Status Failed -Message "Group not found in AD."
            continue
        }

        try {
            $isMember = Get-ADGroupMember -Identity $adGroup -ErrorAction Stop |
                        Where-Object { $_.SamAccountName -eq $sam }
            if ($isMember) {
                New-OnbStepResult -Step $stepName -Status Skipped -Message 'Already a member.'
                continue
            }
        }
        catch {
            # A very large or cross-domain group can fail enumeration; fall through and
            # let Add-ADGroupMember decide - it is safe to attempt on an existing member.
            Write-OnbLog -Level WARN "Could not enumerate members of '$group': $($_.Exception.Message)"
        }

        if (-not $PSCmdlet.ShouldProcess($group, "Add '$sam' to group")) {
            New-OnbStepResult -Step $stepName -Status WhatIf -Message "Would add '$sam'."
            continue
        }

        try {
            Add-ADGroupMember -Identity $adGroup -Members $sam -ErrorAction Stop
            Write-OnbLog "Added '$sam' to group '$group'."
            New-OnbStepResult -Step $stepName -Status Success -Message 'Added.'
        }
        catch {
            Write-OnbLog -Level ERROR "Failed adding '$sam' to '$group': $($_.Exception.Message)"
            New-OnbStepResult -Step $stepName -Status Failed -Message $_.Exception.Message
        }
    }
}
