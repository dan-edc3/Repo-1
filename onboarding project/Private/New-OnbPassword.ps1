function New-OnbPassword {
    <#
    .SYNOPSIS
        Generates a random initial password that satisfies typical AD complexity rules.
    .DESCRIPTION
        Guarantees at least one character from each of four character classes, then
        fills the remainder and shuffles. Ambiguous characters (0/O, 1/l/I) are
        excluded because these passwords get read aloud or typed off a printout.
        Uses the cryptographic RNG rather than Get-Random.
    #>
    [CmdletBinding()]
    param([ValidateRange(12,64)][int]$Length = 16)

    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnpqrstuvwxyz',
        '23456789',
        '!#$%^&*-_=+?'
    )
    $all = -join $sets

    $rng   = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(4)

    try {
        $next = {
            param([string]$source)
            $rng.GetBytes($bytes)
            $value = [BitConverter]::ToUInt32($bytes, 0)
            $source[[int]($value % $source.Length)]
        }

        $chars = [System.Collections.Generic.List[char]]::new()
        foreach ($s in $sets) { $chars.Add((& $next $s)) }
        for ($i = $chars.Count; $i -lt $Length; $i++) { $chars.Add((& $next $all)) }

        # Fisher-Yates shuffle so the guaranteed characters aren't always up front
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % ($i + 1))
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }

        -join $chars
    }
    finally { $rng.Dispose() }
}
