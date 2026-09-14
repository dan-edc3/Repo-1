function Convert-OnbName {
    <#
    .SYNOPSIS
        Applies a named list of transforms to a candidate identifier.
    .DESCRIPTION
        Different systems demand different shapes: AD wants lowercase and at most 20
        characters, a WMS might want 8 uppercase letters, a badge system might refuse
        digits. Rather than encode any of that in code, each identifier in config.json
        lists the transforms it needs, applied in the order given.

        Available transforms:
          ascii         Fold accented characters to their base letter. Do this FIRST -
                        the later filters would otherwise simply delete the accented
                        character and lose it entirely.
          alphanumeric  Keep only A-Z, a-z and 0-9. Removes apostrophes, hyphens, spaces
                        and periods, so O'Brien-Smith becomes OBrienSmith.
          alpha         Keep only letters.
          numeric       Keep only digits.
          nospace       Remove whitespace only, leaving punctuation intact.
          lower / upper Force case.
          keep:<chars>  Keep ONLY the characters listed, which are a regex character-class
                        body. This is how you permit a separator: keep:A-Za-z0-9. allows a
                        dot, keep:A-Za-z0-9- allows a hyphen. Use this instead of
                        'alphanumeric' when the format contains a literal separator,
                        otherwise the separator is silently stripped back out.
    .NOTES
        This file is deliberately pure ASCII. Windows PowerShell 5.1 assumes the system
        ANSI codepage for a .ps1 saved as UTF-8 without a BOM, which corrupts literal
        accented characters. Special letters are therefore written as [char] codepoints.

        The substitutions below use String.Replace (ordinal, case-sensitive) rather than
        a hashtable, because PowerShell hashtable literals are CASE-INSENSITIVE - an
        upper and lower case pair of the same letter is a duplicate-key parse error that
        kills the entire file at load time.
    .EXAMPLE
        Convert-OnbName -Value "O'Brien-Smith" -Transforms ascii,alphanumeric,lower
        obriensmith
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [string[]]$Transforms = @()
    )

    $result = $Value

    foreach ($t in $Transforms) {
        # A transform may carry an argument after a colon, e.g. "keep:A-Za-z0-9."
        $name = $t
        $arg  = $null
        $ix   = $t.IndexOf(':')
        if ($ix -ge 0) {
            $name = $t.Substring(0, $ix)
            $arg  = $t.Substring($ix + 1)
        }

        switch ($name.ToLower()) {
            'ascii' {
                # Decompose, then drop the combining marks. This turns an accented
                # character into its base letter instead of deleting it.
                $decomposed = $result.Normalize([System.Text.NormalizationForm]::FormD)
                $sb = [System.Text.StringBuilder]::new()
                foreach ($ch in $decomposed.ToCharArray()) {
                    if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne
                        [System.Globalization.UnicodeCategory]::NonSpacingMark) {
                        [void]$sb.Append($ch)
                    }
                }
                $result = $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)

                # Letters with no decomposed form, handled explicitly.
                $specials = @(
                    @([char]0x00DF, 'ss'),   # sharp s
                    @([char]0x00E6, 'ae'),   # ae ligature
                    @([char]0x00C6, 'AE'),
                    @([char]0x0153, 'oe'),   # oe ligature
                    @([char]0x0152, 'OE'),
                    @([char]0x00F8, 'o'),    # o with stroke
                    @([char]0x00D8, 'O'),
                    @([char]0x0111, 'd'),    # d with stroke
                    @([char]0x0110, 'D'),
                    @([char]0x0142, 'l'),    # l with stroke
                    @([char]0x0141, 'L'),
                    @([char]0x00FE, 'th'),   # thorn
                    @([char]0x00DE, 'TH'),
                    @([char]0x00F0, 'd'),    # eth
                    @([char]0x00D0, 'D')
                )
                foreach ($pair in $specials) {
                    $result = $result.Replace([string]$pair[0], [string]$pair[1])
                }
            }
            'keep' {
                if ([string]::IsNullOrEmpty($arg)) {
                    Write-Warning "Transform 'keep' needs a character list, e.g. keep:A-Za-z0-9. - ignored."
                }
                else {
                    # $arg is a regex character-class body. A ']' or '\' in it would break
                    # the class, so those are rejected rather than silently misbehaving.
                    if ($arg -match '[\]\\]') {
                        Write-Warning "Transform 'keep:$arg' contains ] or \, which is not supported - ignored."
                    }
                    else {
                        $result = $result -replace "[^$arg]", ''
                    }
                }
            }
            'alphanumeric' { $result = $result -replace '[^A-Za-z0-9]', '' }
            'alpha'        { $result = $result -replace '[^A-Za-z]', '' }
            'numeric'      { $result = $result -replace '[^0-9]', '' }
            'nospace'      { $result = $result -replace '\s', '' }
            'lower'        { $result = $result.ToLowerInvariant() }
            'upper'        { $result = $result.ToUpperInvariant() }
            default        { Write-Warning "Unknown name transform '$t' was ignored." }
        }
    }

    $result
}
