function Merge-OnbRole {
    <#
    .SYNOPSIS
        Merges a child role definition over its parent (the 'extends' mechanism).
    .DESCRIPTION
        Merge rules, chosen to match what you'd intuitively expect from a role file:

          * Scalars (title, department, ou, company...) - the child OVERRIDES the parent.
          * Nested objects (ad, otherAttributes)        - merged property by property,
                                                          child wins on conflicts.
          * Arrays (groups, sqlActions, prompts)        - ADDITIVE. The child's entries
                                                          are appended to the parent's.
                                                          Duplicate group names are removed.

        The additive rule for arrays is the important one: a job-function file lists
        only the groups that are EXTRA for that function, and inherits the common set.

        If a child genuinely needs to discard an inherited array rather than add to it,
        set e.g. "groupsReset": true alongside its own "groups".

        Identity properties (roleId, displayName, description, extends, abstract) always
        come from the child - a child is never accidentally named after its parent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Base,
        [Parameter(Mandatory)][psobject]$Override,
        # Set when recursing into a nested object such as 'ad'. The identity exclusions
        # below are a TOP-LEVEL concept only: at the top, 'description' is the human
        # description of the role and must not inherit; inside 'ad', 'description' is the
        # AD attribute (the "Emp# ######" string) and absolutely must inherit. Applying
        # the same list at every depth silently blanks it on every child role.
        [switch]$Nested
    )

    $nonInheritable = if ($Nested) { @() } else {
        @('roleId','displayName','description','extends','abstract','SourceFile')
    }
    $result = [ordered]@{}

    foreach ($p in $Base.PSObject.Properties) {
        if ($p.Name -in $nonInheritable) { continue }
        # A parent's explanatory _comment keys shouldn't follow its children around either
        if ($p.Name -like '_*') { continue }
        $result[$p.Name] = $p.Value
    }

    foreach ($p in $Override.PSObject.Properties) {
        $name  = $p.Name
        $value = $p.Value

        if ($name -in $nonInheritable -or $name -like '_*' -or $name -like '*Reset') {
            $result[$name] = $value
            continue
        }

        $inherited = if ($result.Contains($name)) { $result[$name] } else { $null }
        $resetName = "${name}Reset"
        $reset     = $Override.PSObject.Properties.Name -contains $resetName -and $Override.$resetName

        if ($null -ne $inherited -and
            $inherited -is [psobject] -and $value -is [psobject] -and
            $inherited -isnot [System.Collections.IList] -and $value -isnot [System.Collections.IList] -and
            $inherited -isnot [string] -and $value -isnot [string]) {
            # Nested object: recurse so 'ad' merges attribute by attribute
            $result[$name] = Merge-OnbRole -Base $inherited -Override $value -Nested
        }
        elseif (($value -is [System.Collections.IList]) -and $value -isnot [string]) {
            if ($reset -or $null -eq $inherited) {
                $result[$name] = @($value)
            }
            else {
                $combined = @(@($inherited) + @($value)) | Where-Object { $null -ne $_ }
                # De-duplicate only when the array is plain strings (group names)
                if (@($combined | Where-Object { $_ -isnot [string] }).Count -eq 0) {
                    $combined = $combined | Select-Object -Unique
                }
                $result[$name] = @($combined)
            }
        }
        else {
            $result[$name] = $value
        }
    }

    [pscustomobject]$result
}
