function Test-OnboardingRole {
    <#
    .SYNOPSIS
        Health-checks every role definition and reports what inheritance actually produced.
    .DESCRIPTION
        Run this after editing any role file, and especially after editing a base role.
        It catches the failure mode that inheritance makes easy: a change to a parent
        that quietly breaks all of its children, where each individual file still looks
        perfectly fine on its own.

        Checks each selectable role for:
          * an OU, title, sAMAccountName format, and the employee-number attribute
          * the 'Emp# ...' description and the shift-to-company mapping surviving inheritance
          * the inherited prompts still being present
          * exactly one licence group (two means a base role is handing out both tiers)
          * no leaked 'abstract' flag, which would hide the role from the console
          * every SQL action naming a system and action that exist in config.json
    .EXAMPLE
        Test-OnboardingRole
    .EXAMPLE
        Test-OnboardingRole | Where-Object Status -ne OK | Format-Table -AutoSize
    #>
    [CmdletBinding()]
    param()

    $config = Get-OnboardingConfig
    $roles  = @(Get-OnboardingRole)

    if (-not $roles) {
        [pscustomobject]@{ Role='(none)'; Status='FAIL'
            Issue='No selectable roles. Every file was rejected, or all inherited abstract=true.' }
        return
    }

    foreach ($role in $roles) {
        $issues = [System.Collections.Generic.List[string]]::new()

        if ($role.abstract) { $issues.Add("Leaked abstract flag - this role is hidden from the console.") }

        # Catch settings that look authoritative but are silently ignored. A stale
        # ad.samAccountNameFormat is worse than no setting at all: someone edits it,
        # sees nothing change, and loses trust in the whole config.
        if ($role.ad.samAccountNameFormat) {
            $issues.Add("ad.samAccountNameFormat is set but IGNORED - username rules live in the 'naming' block of config.json. Remove it.")
        }

        foreach ($pair in @(
            @{ Name='ad.ou';                   Value=$role.ad.ou },
            @{ Name='ad.title';                Value=$role.ad.title },
            @{ Name='ad.employeeNumber';       Value=$role.ad.employeeNumber },
            @{ Name='ad.description';          Value=$role.ad.description },
            @{ Name='ad.company';              Value=$role.ad.company }
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$pair.Value)) {
                $issues.Add("$($pair.Name) is empty after inheritance.")
            }
        }

        foreach ($needed in 'EmployeeNumber','Shift') {
            if ($needed -notin @($role.prompts).name) { $issues.Add("Prompt '$needed' was not inherited.") }
        }

        $licences = @($role.groups | Where-Object { $_ -match 'Licence|License' })
        if ($licences.Count -eq 0)  { $issues.Add("No licence group.") }
        if ($licences.Count -gt 1)  { $issues.Add("More than one licence group: $($licences -join ', '). A base role is probably handing out two tiers.") }

        # ---- Prompts -------------------------------------------------------------------
        foreach ($prompt in @($role.prompts)) {
            if (-not $prompt) { continue }
            $pn = if ($prompt.name) { $prompt.name } else { '(unnamed)' }
            if (-not $prompt.name)  { $issues.Add("A prompt has no 'name'.") }
            if (-not $prompt.label) { $issues.Add("Prompt '$pn' has no 'label'.") }

            if ($prompt.type -eq 'choice') {
                if (-not $prompt.options) { $issues.Add("Choice prompt '$pn' has no options."); continue }

                $labels = @(); $values = @()
                foreach ($o in $prompt.options) {
                    if ($o -is [string]) { $labels += $o; $values += $o; continue }
                    if ([string]::IsNullOrWhiteSpace([string]$o.label)) {
                        $issues.Add("Prompt '$pn' has an option with no 'label'."); continue
                    }
                    $labels += [string]$o.label
                    $values += $(if ($null -ne $o.value) { [string]$o.value } else { [string]$o.label })
                }
                # Labels are matched case-insensitively in the console's lookup table, so
                # two labels differing only by case would silently collapse to one.
                $dupL = @($labels | Group-Object -NoElement | Where-Object Count -gt 1).Name
                if ($dupL) { $issues.Add("Prompt '$pn' has duplicate option label(s): $($dupL -join ', ').") }
                $dupV = @($values | Group-Object -CaseSensitive -NoElement | Where-Object Count -gt 1).Name
                if ($dupV) { $issues.Add("Prompt '$pn' has duplicate option value(s): $($dupV -join ', '). Two labels would produce the same value.") }
            }
        }

        # ---- Naming ------------------------------------------------------------------
        # Resolve each identifier against a synthetic awkward name, with availability
        # checks skipped. This catches a format whose transforms or validate pattern
        # contradict it - e.g. a format containing a dot that 'alphanumeric' then strips.
        $naming = $config.naming
        if (($role.PSObject.Properties.Name -contains 'naming') -and $role.naming) {
            $naming = Merge-OnbRole -Base $config.naming -Override $role.naming -Nested
        }
        if ($naming) {
            $probe = @{
                firstName='Testcase'; lastName="O'Probe-Name"; firstInitial='T'; lastInitial='O'
                upnSuffix='example.com'; EmployeeNumber='999999'; Shift='1st'
            }
            foreach ($idName in @($naming.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })) {
                $spec = $naming.$idName
                foreach ($fmt in (@($spec.format) + @($spec.collisionFormats) | Where-Object { $_ })) {
                    $raw  = Expand-OnbToken -Template ($fmt -replace '\{n(?::\d+)?\}','2') -Context $probe -WarningAction SilentlyContinue
                    $done = Convert-OnbName -Value $raw -Transforms @($spec.transform)
                    if ($spec.maxLength -and $done.Length -gt [int]$spec.maxLength) { $done = $done.Substring(0,[int]$spec.maxLength) }
                    if ($spec.validate -and $done -notmatch $spec.validate) {
                        $issues.Add("Naming '$idName': format '$fmt' yields '$done', which fails its own validate pattern.")
                    }
                    $stripped = ($fmt -replace '\{[^}]+\}','')
                    if ($stripped -and $done -notmatch [regex]::Escape($stripped.Substring(0,1))) {
                        $issues.Add("Naming '$idName': format '$fmt' contains literal '$stripped' that the transforms remove - the separator is silently dropped.")
                    }
                }
                $r = New-OnbIdentifier -Name $idName -Spec $spec -Context $probe -Config $config -SkipAvailability -WarningAction SilentlyContinue
                if (-not $r.Success) { $issues.Add("Naming '$idName': no format could produce a valid value.") }
            }
        }

        foreach ($action in @($role.sqlActions)) {
            if (-not $action) { continue }
            $sys = $config.sqlSystems.($action.system)
            if (-not $sys) { $issues.Add("SQL system '$($action.system)' is not in config.json."); continue }
            if (-not $sys.actions.($action.action)) {
                $issues.Add("SQL action '$($action.action)' is not defined for system '$($action.system)'.")
            }
        }

        if ($issues.Count -eq 0) {
            [pscustomobject]@{ Role=$role.roleId; Status='OK'; Issue='' }
        }
        else {
            foreach ($i in $issues) { [pscustomobject]@{ Role=$role.roleId; Status='FAIL'; Issue=$i } }
        }
    }
}
