function Show-OnboardingConsole {
    <#
    .SYNOPSIS
        Opens the WinForms onboarding window.
    .DESCRIPTION
        This function contains NO provisioning logic. It collects input, calls
        Invoke-Onboarding, and renders the returned step results. That separation is
        deliberate: the window can be redesigned or thrown away without touching
        anything that creates accounts, and the engine can be tested without clicking.

        The role dropdown and the custom fields below it are both built at runtime
        from the JSON files in Roles\, so a new account type appears here with no
        change to this file.
    .EXAMPLE
        Show-OnboardingConsole
    #>
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $roles = @(Get-OnboardingRole)
    if (-not $roles) {
        # Distinguish "no files" from "files present but none selectable" - the second
        # case usually means a base role's abstract flag leaked into its children, and
        # reporting it as "not found" sends you looking in entirely the wrong place.
        $fileCount = @(Get-ChildItem -Path $script:OnbRolesPath -Filter '*.json' -File -ErrorAction SilentlyContinue).Count
        $msg = if ($fileCount -eq 0) {
            "No .json role files found in:`r`n$script:OnbRolesPath"
        } else {
            "$fileCount role file(s) were found, but none are selectable.`r`n`r`n" +
            "They were all either rejected as invalid or marked abstract. Run this to see why:`r`n`r`n" +
            "    Test-OnboardingRole`r`n" +
            "    Get-OnboardingRole -IncludeAbstract -Verbose"
        }
        [System.Windows.Forms.MessageBox]::Show($msg,'Onboarding','OK','Error') | Out-Null
        return
    }

    # ---------------------------------------------------------------- form scaffold --
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = 'User Onboarding'
    $form.Size            = New-Object System.Drawing.Size(760, 700)
    $form.StartPosition   = 'CenterScreen'
    $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize     = New-Object System.Drawing.Size(700, 600)

    function New-Label ($text, $x, $y, $w = 130) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
        $l.Size = New-Object System.Drawing.Size($w, 20)
        $l
    }
    function New-Box ($x, $y, $w = 260) {
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point($x, $y)
        $t.Size = New-Object System.Drawing.Size($w, 24)
        $t
    }

    # ------------------------------------------------------------------ identity ----
    $grpUser          = New-Object System.Windows.Forms.GroupBox
    $grpUser.Text     = 'New user'
    $grpUser.Location = New-Object System.Drawing.Point(12, 12)
    $grpUser.Size     = New-Object System.Drawing.Size(720, 150)
    $grpUser.Anchor   = 'Top,Left,Right'

    $grpUser.Controls.Add((New-Label 'First name' 15 30))
    $txtFirst = New-Box 150 27; $grpUser.Controls.Add($txtFirst)

    $grpUser.Controls.Add((New-Label 'Last name' 15 62))
    $txtLast = New-Box 150 59; $grpUser.Controls.Add($txtLast)

    $grpUser.Controls.Add((New-Label 'Account type' 15 94))
    $cmbRole          = New-Object System.Windows.Forms.ComboBox
    $cmbRole.Location = New-Object System.Drawing.Point(150, 91)
    $cmbRole.Size     = New-Object System.Drawing.Size(260, 24)
    $cmbRole.DropDownStyle = 'DropDownList'
    foreach ($r in $roles) { [void]$cmbRole.Items.Add($r.displayName) }
    $cmbRole.SelectedIndex = 0
    $grpUser.Controls.Add($cmbRole)

    $lblPreview          = New-Label '' 430 30 275
    $lblPreview.Size     = New-Object System.Drawing.Size(275, 110)
    $lblPreview.ForeColor = [System.Drawing.Color]::DimGray
    $grpUser.Controls.Add($lblPreview)
    $form.Controls.Add($grpUser)

    # ------------------------------------------------- role-specific custom fields --
    $grpCustom          = New-Object System.Windows.Forms.GroupBox
    $grpCustom.Text     = 'Role options'
    $grpCustom.Location = New-Object System.Drawing.Point(12, 170)
    $grpCustom.Size     = New-Object System.Drawing.Size(720, 140)
    $grpCustom.Anchor   = 'Top,Left,Right'
    $pnlCustom          = New-Object System.Windows.Forms.FlowLayoutPanel
    $pnlCustom.Location = New-Object System.Drawing.Point(10, 22)
    $pnlCustom.Size     = New-Object System.Drawing.Size(700, 110)
    $pnlCustom.AutoScroll = $true
    $pnlCustom.FlowDirection = 'TopDown'
    $pnlCustom.WrapContents  = $false
    $grpCustom.Controls.Add($pnlCustom)
    $form.Controls.Add($grpCustom)

    $script:CustomControls = @{}

    $rebuildCustom = {
        $pnlCustom.Controls.Clear()
        $script:CustomControls = @{}
        $role = $roles[$cmbRole.SelectedIndex]

        if (-not ($role.PSObject.Properties.Name -contains 'prompts') -or -not $role.prompts) {
            $none = New-Object System.Windows.Forms.Label
            $none.Text = 'This account type has no extra options.'
            $none.ForeColor = [System.Drawing.Color]::DimGray
            $none.AutoSize = $true
            $pnlCustom.Controls.Add($none)
            return
        }

        foreach ($prompt in $role.prompts) {
            $row = New-Object System.Windows.Forms.Panel
            $row.Size = New-Object System.Drawing.Size(660, 30)

            # Built inline rather than via a helper: this runs from an event handler,
            # by which time function-scoped helpers are out of scope.
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text     = $prompt.label + $(if ($prompt.required) { ' *' } else { '' })
            $lbl.Location = New-Object System.Drawing.Point(0, 5)
            $lbl.Size     = New-Object System.Drawing.Size(200, 20)
            $row.Controls.Add($lbl)

            $valueMap = $null
            if ($prompt.type -eq 'choice') {
                $ctl = New-Object System.Windows.Forms.ComboBox
                $ctl.DropDownStyle = 'DropDownList'

                # An option is either a plain string (label and value are the same) or an
                # object with separate 'label' and 'value'. The operator picks the label;
                # everything downstream - AD, SQL, tokens - receives the value.
                $valueMap = @{}
                foreach ($o in $prompt.options) {
                    if ($o -is [string]) { $lbl = $o; $val = $o }
                    else {
                        $lbl = [string]$o.label
                        $val = if ($null -ne $o.value) { [string]$o.value } else { $lbl }
                    }
                    if ([string]::IsNullOrWhiteSpace($lbl)) { continue }
                    # Hashtable keys are case-insensitive, so labels differing only by case
                    # would silently collapse into one entry.
                    if ($valueMap.ContainsKey($lbl)) {
                        Write-Warning "Prompt '$($prompt.name)': duplicate option label '$lbl' ignored."
                        continue
                    }
                    $valueMap[$lbl] = $val
                    [void]$ctl.Items.Add($lbl)
                }
                if ($ctl.Items.Count) { $ctl.SelectedIndex = 0 }
            }
            elseif ($prompt.type -eq 'bool') {
                $ctl = New-Object System.Windows.Forms.CheckBox
            }
            else {
                $ctl = New-Object System.Windows.Forms.TextBox
            }
            $ctl.Location = New-Object System.Drawing.Point(210, 2)
            $ctl.Size     = New-Object System.Drawing.Size(260, 24)
            $row.Controls.Add($ctl)

            $script:CustomControls[$prompt.name] = @{ Control = $ctl; Prompt = $prompt; ValueMap = $valueMap }
            $pnlCustom.Controls.Add($row)
        }
    }

    $updatePreview = {
        $role = $roles[$cmbRole.SelectedIndex]
        $f = $txtFirst.Text.Trim()
        $l = $txtLast.Text.Trim()

        if (-not ($f -and $l)) {
            $lblPreview.Text = 'Enter a first and last name to preview the username.'
            return
        }

        # Resolve exactly the way Invoke-Onboarding will: site naming standard from
        # config.json, with any per-role override merged over it. Reading the rules from
        # anywhere else would let this preview drift away from what actually happens.
        $cfg    = Get-OnboardingConfig
        $naming = $cfg.naming
        if (($role.PSObject.Properties.Name -contains 'naming') -and $role.naming) {
            $naming = Merge-OnbRole -Base $cfg.naming -Override $role.naming -Nested
        }

        $sfx = if ($role.ad.upnSuffix) { $role.ad.upnSuffix } else { $cfg.defaultUpnSuffix }
        $ctx = @{
            firstName = $f; lastName = $l
            firstInitial = $f.Substring(0,1); lastInitial = $l.Substring(0,1)
            upnSuffix = $sfx
        }

        $lines = [System.Collections.Generic.List[string]]::new()

        foreach ($idName in @($naming.PSObject.Properties.Name | Where-Object { $_ -notlike '_*' })) {
            $spec  = $naming.$idName
            $value = Convert-OnbName -Transforms @($spec.transform) `
                        -Value (Expand-OnbToken -Template $spec.format -Context $ctx -WarningAction SilentlyContinue)
            if ($spec.maxLength -and $value.Length -gt [int]$spec.maxLength) {
                $value = $value.Substring(0, [int]$spec.maxLength)
            }

            $flag = ''
            if ($spec.validate -and $value -notmatch $spec.validate) { $flag = '   << fails validation' }
            $lines.Add("$idName :  $value$flag")
            if ($idName -eq 'samAccountName') { $lines.Add("UPN / email  :  $value@$sfx") }
        }

        $lines.Add('')
        $lines.Add("$(@($role.groups).Count) group(s), $(@($role.sqlActions).Count) SQL action(s).")
        # The real run checks AD and the LOB systems and may land on a different name.
        # Saying so here avoids an operator insisting the window "promised" a username.
        $lines.Add('Preferred names only - collisions are resolved at run time.')

        $lblPreview.Text = ($lines -join "`r`n")
    }

    $cmbRole.Add_SelectedIndexChanged({ & $rebuildCustom; & $updatePreview })
    $txtFirst.Add_TextChanged($updatePreview)
    $txtLast.Add_TextChanged($updatePreview)

    # ---------------------------------------------------------------------- results --
    $grid                     = New-Object System.Windows.Forms.ListView
    $grid.Location            = New-Object System.Drawing.Point(12, 320)
    $grid.Size                = New-Object System.Drawing.Size(720, 260)
    $grid.View                = 'Details'
    $grid.FullRowSelect       = $true
    $grid.GridLines           = $true
    $grid.Anchor              = 'Top,Bottom,Left,Right'
    [void]$grid.Columns.Add('Step', 260)
    [void]$grid.Columns.Add('Status', 80)
    [void]$grid.Columns.Add('Detail', 360)
    $form.Controls.Add($grid)

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Location  = New-Object System.Drawing.Point(12, 590)
    $lblStatus.Size      = New-Object System.Drawing.Size(720, 22)
    $lblStatus.Anchor    = 'Bottom,Left,Right'
    $form.Controls.Add($lblStatus)

    # ---------------------------------------------------------------------- buttons --
    $btnPreview          = New-Object System.Windows.Forms.Button
    $btnPreview.Text     = 'Preview (no changes)'
    $btnPreview.Location = New-Object System.Drawing.Point(12, 618)
    $btnPreview.Size     = New-Object System.Drawing.Size(160, 32)
    $btnPreview.Anchor   = 'Bottom,Left'

    $btnRun              = New-Object System.Windows.Forms.Button
    $btnRun.Text         = 'Create account'
    $btnRun.Location     = New-Object System.Drawing.Point(182, 618)
    $btnRun.Size         = New-Object System.Drawing.Size(160, 32)
    $btnRun.Anchor       = 'Bottom,Left'

    $btnClose            = New-Object System.Windows.Forms.Button
    $btnClose.Text       = 'Close'
    $btnClose.Location   = New-Object System.Drawing.Point(632, 618)
    $btnClose.Size       = New-Object System.Drawing.Size(100, 32)
    $btnClose.Anchor     = 'Bottom,Right'
    $btnClose.Add_Click({ $form.Close() })

    $form.Controls.AddRange(@($btnPreview, $btnRun, $btnClose))

    # ------------------------------------------------------------------ the handler --
    $execute = {
        param([bool]$Preview)

        $grid.Items.Clear()
        $lblStatus.Text = ''

        if (-not $txtFirst.Text.Trim() -or -not $txtLast.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show('First and last name are required.','Onboarding','OK','Warning') | Out-Null
            return
        }

        $extra = @{}
        foreach ($name in $script:CustomControls.Keys) {
            $entry = $script:CustomControls[$name]
            $value = if ($entry.Control -is [System.Windows.Forms.CheckBox]) {
                         $entry.Control.Checked
                     }
                     elseif ($entry.ValueMap -and $entry.Control.Text -and $entry.ValueMap.ContainsKey($entry.Control.Text)) {
                         # Hand on the option's VALUE, not the label the operator saw
                         $entry.ValueMap[$entry.Control.Text]
                     }
                     else {
                         $entry.Control.Text
                     }
            if ($entry.Prompt.required -and [string]::IsNullOrWhiteSpace([string]$value)) {
                [System.Windows.Forms.MessageBox]::Show("'$($entry.Prompt.label)' is required.",'Onboarding','OK','Warning') | Out-Null
                $entry.Control.Focus()
                return
            }

            # A prompt may declare a 'validation' regex. Catching a mistyped employee
            # number here is far cheaper than catching it after it has been written to
            # AD and to two databases.
            if ($entry.Prompt.validation -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                if ([string]$value -notmatch $entry.Prompt.validation) {
                    $msg = if ($entry.Prompt.validationMessage) { $entry.Prompt.validationMessage }
                           else { "'$($entry.Prompt.label)' is not in the expected format." }
                    [System.Windows.Forms.MessageBox]::Show($msg,'Onboarding','OK','Warning') | Out-Null
                    $entry.Control.Focus()
                    return
                }
            }

            $extra[$name] = $value
        }

        $role = $roles[$cmbRole.SelectedIndex]

        if (-not $Preview) {
            $confirm = [System.Windows.Forms.MessageBox]::Show(
                "Create a '$($role.displayName)' account for $($txtFirst.Text) $($txtLast.Text)?`r`n`r`nThis will write to Active Directory and to the configured line-of-business databases.",
                'Confirm', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { return }
        }

        $form.Cursor = 'WaitCursor'
        $btnRun.Enabled = $false; $btnPreview.Enabled = $false
        try {
            $results = Invoke-Onboarding -FirstName $txtFirst.Text -LastName $txtLast.Text `
                        -RoleId $role.roleId -ExtraField $extra -WhatIf:$Preview -Confirm:$false

            foreach ($r in $results) {
                $item = New-Object System.Windows.Forms.ListViewItem($r.Step)
                [void]$item.SubItems.Add($r.Status)
                [void]$item.SubItems.Add($r.Message)
                $item.ForeColor = switch ($r.Status) {
                    'Success' { [System.Drawing.Color]::DarkGreen }
                    'Skipped' { [System.Drawing.Color]::DarkGoldenrod }
                    'Failed'  { [System.Drawing.Color]::Firebrick }
                    default   { [System.Drawing.Color]::DimGray }
                }
                [void]$grid.Items.Add($item)
            }

            $failed = @($results | Where-Object Status -eq 'Failed').Count
            $first  = $results[0]
            $lblStatus.Text = if ($Preview) {
                "Preview only - nothing was changed. $($results.Count) step(s) would run."
            } else {
                "$($results.Count) step(s), $failed failed. Username: $($first.SamAccountName)"
            }

            if (-not $Preview -and $first.PSObject.Properties.Name -contains 'InitialPassword') {
                $modeNote = if ($first.InitialPasswordMode -eq 'template') {
                    "`r`n`r`nNOTE: this password was built from a fixed template, so it is predictable from the employee number and initials. The user must change it at first logon."
                } else { '' }
                $msg = "Account: $($first.SamAccountName)`r`nUPN: $($first.UserPrincipalName)`r`nTemporary password: $($first.InitialPassword)$modeNote`r`n`r`nVerify if an account is needed for Avigilon.`r`n`r`nCopy this to the clipboard?"
                if ([System.Windows.Forms.MessageBox]::Show($msg,'Account created','YesNo','Information') -eq 'Yes') {
                    [System.Windows.Forms.Clipboard]::SetText("$($first.UserPrincipalName)  $($first.InitialPassword)")
                }
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("The run could not start:`r`n`r`n$($_.Exception.Message)",'Onboarding','OK','Error') | Out-Null
        }
        finally {
            $form.Cursor = 'Default'
            $btnRun.Enabled = $true; $btnPreview.Enabled = $true
        }
    }

    $btnPreview.Add_Click({ & $execute $true  })
    $btnRun.Add_Click(    { & $execute $false })

    & $rebuildCustom
    & $updatePreview
    [void]$form.ShowDialog()
    $form.Dispose()
}
