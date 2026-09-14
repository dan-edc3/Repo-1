function Get-OnboardingRole {
    <#
    .SYNOPSIS
        Loads account-type (role) definitions from the Roles folder, resolving inheritance.
    .DESCRIPTION
        A role is a plain JSON file. Adding a new account type means dropping a new file
        in Roles\ - no code changes, and the console picks it up on next launch.

        A role may declare "extends": "<roleId>" to inherit from another role. The parent
        holds everything shared; the child holds only what differs. See Merge-OnbRole for
        the exact merge rules (scalars override, arrays add).

        A role with "abstract": true is a building block, not a selectable account type.
        It is used as a parent but hidden from the console dropdown. Use -IncludeAbstract
        to see them when debugging.
    .EXAMPLE
        Get-OnboardingRole | Select-Object roleId, displayName
    .EXAMPLE
        # Verify what a job function actually resolves to after inheritance
        (Get-OnboardingRole -RoleId operations-supervisor).groups
    #>
    [CmdletBinding()]
    param(
        [string]$RoleId,
        [switch]$IncludeAbstract
    )

    if (-not (Test-Path $script:OnbRolesPath)) {
        throw "Roles folder not found at '$script:OnbRolesPath'."
    }

    # ---- Pass 1: load every file raw --------------------------------------------------
    $raw = @{}
    foreach ($file in (Get-ChildItem -Path $script:OnbRolesPath -Filter '*.json' -File)) {
        try {
            $role = Get-Content -Path $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-Warning "Skipping '$($file.Name)': not valid JSON. $($_.Exception.Message)"
            continue
        }

        $missing = @('roleId','displayName') | Where-Object { $_ -notin $role.PSObject.Properties.Name }
        if ($missing) {
            Write-Warning "Skipping '$($file.Name)': missing required property/properties: $($missing -join ', ')."
            continue
        }

        if ($raw.ContainsKey($role.roleId)) {
            Write-Warning "Duplicate roleId '$($role.roleId)' in '$($file.Name)'; keeping the first one found."
            continue
        }

        $role | Add-Member -NotePropertyName SourceFile -NotePropertyValue $file.FullName -Force
        $raw[$role.roleId] = $role
    }

    # ---- Pass 2: resolve 'extends' chains ---------------------------------------------
    $resolve = {
        param($role, $chain)

        if ($role.roleId -in $chain) {
            throw "Circular 'extends' chain detected: $(($chain + $role.roleId) -join ' -> ')."
        }
        if (-not ($role.PSObject.Properties.Name -contains 'extends') -or -not $role.extends) {
            return $role
        }
        if (-not $raw.ContainsKey($role.extends)) {
            throw "Role '$($role.roleId)' extends '$($role.extends)', which does not exist."
        }

        $parent = & $resolve $raw[$role.extends] ($chain + $role.roleId)
        Merge-OnbRole -Base $parent -Override $role
    }

    $roles = foreach ($id in $raw.Keys) {
        try { & $resolve $raw[$id] @() }
        catch { Write-Warning "Skipping role '$id': $($_.Exception.Message)" }
    }

    # ---- Pass 3: validate the resolved result -----------------------------------------
    $roles = foreach ($role in $roles) {
        $isAbstract = ($role.PSObject.Properties.Name -contains 'abstract') -and $role.abstract
        if (-not $isAbstract -and -not $role.ad) {
            Write-Warning "Skipping role '$($role.roleId)': no 'ad' block, even after inheritance."
            continue
        }
        $role
    }

    if (-not $IncludeAbstract) {
        $roles = $roles | Where-Object { -not (($_.PSObject.Properties.Name -contains 'abstract') -and $_.abstract) }
    }

    if ($RoleId) {
        $match = $roles | Where-Object { $_.roleId -eq $RoleId }
        if (-not $match) { throw "No selectable role definition found with roleId '$RoleId'." }
        return $match
    }

    $roles | Sort-Object displayName
}
