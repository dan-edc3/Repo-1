function Invoke-Onboarding {
    <#
    .SYNOPSIS
        Runs a full onboarding for one user against one role definition.
    .DESCRIPTION
        This is the engine. The WinForms console is only a front end for this
        function, which means anything the window can do can also be scripted,
        scheduled, or bulk-run from a CSV without touching the GUI.

        Steps run in order: AD account, group membership, then each SQL action.
        Every step returns its own result object and a failure in one step does not
        abort the others, because a half-finished user you can see is easier to fix
        than a run that stopped with no report. Every step is idempotent, so the
        normal fix for a partial failure is to correct the problem and re-run.

        Supports -WhatIf. Run it that way first, every time.
    .PARAMETER ExtraField
        Answers to the role's custom prompts, e.g. @{ Unit = '3West' }. These become
        available as {tokens} in the role file and as @parameters in SQL actions.
    .EXAMPLE
        Invoke-Onboarding -FirstName Dana -LastName Reyes -RoleId nurse -WhatIf
    .EXAMPLE
        $r = Invoke-Onboarding -FirstName Dana -LastName Reyes -RoleId nurse -ExtraField @{ Unit = 'ICU' }
        $r | Format-Table Step, Status, Message
    .EXAMPLE
        Import-Csv .\newhires.csv | ForEach-Object {
            Invoke-Onboarding -FirstName $_.First -LastName $_.Last -RoleId $_.Role
        }
    .OUTPUTS
        Onb.StepResult[]
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$RoleId,
        [hashtable]$ExtraField = @{},
        [securestring]$Password,
        [string]$SamAccountName
    )

    $config = Get-OnboardingConfig
    $role   = Get-OnboardingRole -RoleId $RoleId

    # ---- Start the run log ----------------------------------------------------------
    $runId = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $RoleId
    try {
        if ($config.logPath -and -not (Test-Path $config.logPath)) {
            New-Item -Path $config.logPath -ItemType Directory -Force | Out-Null
        }
        $script:OnbCurrentLogFile = Join-Path $config.logPath "$runId.log"
    }
    catch {
        Write-Warning "Could not prepare log folder '$($config.logPath)'; continuing without a file log."
        $script:OnbCurrentLogFile = $null
    }

    Write-OnbLog "=== Onboarding run $runId started by $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME ==="
    Write-OnbLog "User: $FirstName $LastName   Role: $($role.displayName) ($RoleId)   WhatIf: $($WhatIfPreference)"

    try {
        # ---- Build the context that every token and SQL parameter draws from --------
        # Keep the human's name as they gave it. Stripping characters belongs to the
        # naming transforms, which each identifier configures for itself - a surname is
        # not the same thing as a username, and O'Brien should stay O'Brien in DisplayName.
        $first = $FirstName.Trim()
        $last  = $LastName.Trim()

        $context = @{
            firstName     = $first
            lastName      = $last
            firstInitial  = $first.Substring(0,1)
            lastInitial   = $last.Substring(0,1)
            displayName   = "$first $last"
            roleId        = $role.roleId
            roleName      = $role.displayName
            domainDn      = $config.domainDn
            domain        = $config.domain
            createdBy     = "$env:USERDOMAIN\$env:USERNAME"
            runId         = $runId
        }
        foreach ($k in $ExtraField.Keys) { $context[$k] = $ExtraField[$k] }

        # ---- Choice prompts with separate labels and values ------------------------------
        # A choice option may be a plain string, or an object with 'label' and 'value'.
        # The value is what flows into AD and SQL; the label is also made available as
        # {Name_label} for the places that want the human-readable word instead of the code.
        foreach ($prompt in @($role.prompts)) {
            if (-not $prompt -or $prompt.type -ne 'choice' -or -not $prompt.options) { continue }
            $pname = $prompt.name
            if (-not $context.ContainsKey($pname)) { continue }
            $supplied = [string]$context[$pname]
            if ([string]::IsNullOrWhiteSpace($supplied)) { continue }

            $pairs = foreach ($o in $prompt.options) {
                if ($o -is [string]) { [pscustomobject]@{ Label = $o; Value = $o } }
                else {
                    $lbl = [string]$o.label
                    [pscustomobject]@{
                        Label = $lbl
                        Value = if ($null -ne $o.value) { [string]$o.value } else { $lbl }
                    }
                }
            }

            $byValue = @($pairs | Where-Object { $_.Value -ceq $supplied })[0]
            if ($byValue) { $context["${pname}_label"] = $byValue.Label; continue }

            # Tolerate a label being supplied where a value was expected - most likely a
            # CSV import written by someone reading the dropdown rather than the config.
            $byLabel = @($pairs | Where-Object { $_.Label -eq $supplied })[0]
            if ($byLabel) {
                Write-OnbLog -Level WARN "Prompt '$pname': received the label '$supplied'; using its value '$($byLabel.Value)'."
                $context[$pname]           = $byLabel.Value
                $context["${pname}_label"] = $byLabel.Label
                continue
            }

            Write-OnbLog -Level WARN "Prompt '$pname': '$supplied' is not one of the configured options. Passing it through unchanged."
        }

        $context['upnSuffix'] = if ($role.ad.upnSuffix) { $role.ad.upnSuffix } else { $config.defaultUpnSuffix }

        # ---- Naming --------------------------------------------------------------------
        # Site standard from config.json, with any per-role override merged over it.
        $naming = $config.naming
        if ($role.PSObject.Properties.Name -contains 'naming' -and $role.naming) {
            $naming = Merge-OnbRole -Base $config.naming -Override $role.naming -Nested
        }

        # Is this person already in AD? Keyed on employee number, never on name -
        # see Find-OnbExistingAccount for why that distinction matters.
        $existing = Find-OnbExistingAccount -EmployeeNumber ([string]$context['EmployeeNumber'])

        if ($existing) {
            $context['samAccountName'] = $existing.SamAccountName
            $context['isRerun']        = $true
            Write-OnbLog "Re-run against existing account '$($existing.SamAccountName)'; naming resolution skipped."
        }
        elseif ($SamAccountName) {
            # An explicit override still has to satisfy the rules
            $context['samAccountName'] = (Convert-OnbName -Value $SamAccountName -Transforms @($naming.samAccountName.transform))
            if ($naming.samAccountName.validate -and $context['samAccountName'] -notmatch $naming.samAccountName.validate) {
                throw "Supplied SamAccountName '$($context['samAccountName'])' does not match the required pattern '$($naming.samAccountName.validate)'."
            }
            Write-OnbLog -Level WARN "sAMAccountName was supplied explicitly as '$($context['samAccountName'])', bypassing the naming rules."
        }
        else {
            $resolved = New-OnbIdentifier -Name 'samAccountName' -Spec $naming.samAccountName -Context $context -Config $config
            if (-not $resolved.Success) {
                throw "Could not allocate a unique sAMAccountName. Tried: $($resolved.Tried -join ', '). Check the collisionFormats and maxAttempts in config.json."
            }
            $context['samAccountName'] = $resolved.Value
            if ($resolved.Attempts -gt 1) {
                Write-OnbLog -Level WARN "sAMAccountName '$($resolved.Value)' was allocated after $($resolved.Attempts) candidates - the preferred pattern was already taken."
            }
        }

        $context['userPrincipalName'] = "$($context['samAccountName'])@$($context['upnSuffix'])"
        $context['email']             = $context['userPrincipalName']

        # Any further identifiers the site defines (WMS user id, badge id, ...).
        # These become {tokens} and @parameters like anything else in the context.
        foreach ($idName in @($naming.PSObject.Properties.Name | Where-Object { $_ -ne 'samAccountName' -and $_ -notlike '_*' })) {
            if ($context.ContainsKey($idName)) { continue }
            $spec = $naming.$idName
            $r = New-OnbIdentifier -Name $idName -Spec $spec -Context $context -Config $config
            if ($r.Success) { $context[$idName] = $r.Value }
            else {
                Write-OnbLog -Level WARN "Could not allocate identifier '$idName'; any step needing it will fail."
            }
        }

        # ---- Password ---------------------------------------------------------------
        # Resolved after naming, because a template may reference {samAccountName}.
        if (-not $Password) {
            $pw = Resolve-OnbPassword -Context $context -Config $config
            if (-not $pw.Ok) {
                throw "Could not generate an initial password: $($pw.Warnings -join ' ')"
            }
            foreach ($w in $pw.Warnings) { Write-OnbLog -Level WARN $w }
            $Password = ConvertTo-SecureString $pw.Value -AsPlainText -Force
            $context['initialPassword']     = $pw.Value
            $context['initialPasswordMode'] = $pw.Mode
        }

        # ---- Run the steps ----------------------------------------------------------
        $results = [System.Collections.Generic.List[object]]::new()

        $results.Add((New-OnbAdAccount -Context $context -Role $role -Password $Password))

        $adOk = $results[0].Status -in 'Success','Skipped','WhatIf'
        if (-not $adOk) {
            Write-OnbLog -Level ERROR 'AD account step failed; skipping all downstream steps.'
            $results.Add((New-OnbStepResult -Step 'Downstream steps' -Status Skipped `
                -Message 'Not attempted because the AD account was not created.'))
        }
        else {
            foreach ($r in (Add-OnbGroupMembership -Context $context -Role $role)) { $results.Add($r) }

            foreach ($sqlAction in @($role.sqlActions)) {
                if (-not $sqlAction) { continue }
                $results.Add((Invoke-OnbSqlAction -Context $context -SqlAction $sqlAction -Config $config))
            }
        }

        # ---- Summarise ---------------------------------------------------------------
        $failed = @($results | Where-Object Status -eq 'Failed').Count
        Write-OnbLog "=== Run $runId finished: $($results.Count) step(s), $failed failed ==="

        # Attach run-level facts to the first result so the caller/GUI can show them
        $results[0] | Add-Member -NotePropertyName RunId           -NotePropertyValue $runId -Force
        $results[0] | Add-Member -NotePropertyName SamAccountName  -NotePropertyValue $context['samAccountName'] -Force
        $results[0] | Add-Member -NotePropertyName UserPrincipalName -NotePropertyValue $context['userPrincipalName'] -Force
        if ($context.ContainsKey('initialPassword')) {
            $results[0] | Add-Member -NotePropertyName InitialPassword     -NotePropertyValue $context['initialPassword'] -Force
            $results[0] | Add-Member -NotePropertyName InitialPasswordMode -NotePropertyValue $context['initialPasswordMode'] -Force
        }

        return $results.ToArray()
    }
    finally {
        $script:OnbCurrentLogFile = $null
    }
}
