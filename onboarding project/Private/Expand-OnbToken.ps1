function Expand-OnbToken {
    <#
    .SYNOPSIS
        Replaces {tokens} in a string with values from the onboarding context.
    .DESCRIPTION
        Role files are data, so they need placeholders. Anywhere a role file contains
        e.g. "{firstInitial}{lastName}" or "OU=Users,{domainDn}", this swaps in the real
        value. Token names are matched case-insensitively.

        A token may carry a length limit as {token:N}, which takes the first N characters.
        This is how you satisfy a system with a short field without inventing a separate
        token for every length: {lastName:7} gives at most seven characters of surname.

        An unknown token is left in place and a warning raised, so a typo in a role file
        is loud rather than silently producing "OU={typo},DC=...".
    .EXAMPLE
        Expand-OnbToken -Template '{firstInitial}{lastName:7}' -Context $ctx
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)][hashtable]$Context
    )

    if ([string]::IsNullOrEmpty($Template)) { return $Template }

    $result = [regex]::Replace($Template, '\{([A-Za-z0-9_]+)(?::(\d+))?\}', {
        param($match)
        $key   = $match.Groups[1].Value
        $limit = $match.Groups[2].Value

        $hit = $Context.Keys | Where-Object { $_ -eq $key } | Select-Object -First 1
        if ($null -eq $hit) {
            Write-Warning "Unknown token '{$key}' in template '$Template'."
            return $match.Value
        }

        $value = [string]$Context[$hit]
        if ($limit -and $value.Length -gt [int]$limit) { $value = $value.Substring(0, [int]$limit) }
        return $value
    })

    return $result
}
