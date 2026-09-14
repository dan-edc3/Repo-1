function Resolve-OnbPassword {
    <#
    .SYNOPSIS
        Produces the initial password, either randomly or from a configured template.
    .DESCRIPTION
        Mode is set by the 'password' block in config.json.

          random    (default) A cryptographically random string. Nobody can predict it.
          template  Built from a token template such as {firstInitial}{lastInitial}#{EmployeeNumber}.

        The template mode exists because a helpdesk often needs to hand a password over
        the phone or reconstruct it without looking it up. That convenience is exactly
        what makes it weak: anyone who can work out the inputs can work out the password.
        This function therefore validates the result hard and reports what it gave up.

        Checks applied to a templated password, all of which AD would otherwise enforce
        by rejecting the account creation with an unhelpful error:

          * Every token resolved - a leftover {Token} means the password contains a brace.
          * Meets the configured minimum length.
          * Satisfies AD complexity: at least three of uppercase, lowercase, digit,
            non-alphanumeric.
          * Does not contain the sAMAccountName, and does not contain a run of more than
            two characters from the user's name. AD refuses both, so a template using
            {firstName} rather than {firstInitial} will fail every time.
    .OUTPUTS
        PSCustomObject with Value, Mode, Warnings and Ok.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$Config
    )

    $spec     = $Config.password
    $warnings = [System.Collections.Generic.List[string]]::new()

    # ---- Random (the safe default) ----------------------------------------------------
    if (-not $spec -or $spec.mode -ne 'template') {
        $length = if ($spec -and $spec.length) { [int]$spec.length } else { 16 }
        return [pscustomobject]@{
            Value = (New-OnbPassword -Length $length); Mode = 'random'; Ok = $true; Warnings = @()
        }
    }

    # ---- Template ---------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($spec.template)) {
        return [pscustomobject]@{
            Value = $null; Mode = 'template'; Ok = $false
            Warnings = @("password.mode is 'template' but no 'template' is set in config.json.")
        }
    }

    $plain = Expand-OnbToken -Template $spec.template -Context $Context

    if ($plain -match '\{[A-Za-z0-9_]+\}') {
        return [pscustomobject]@{
            Value = $null; Mode = 'template'; Ok = $false
            Warnings = @("Password template left an unresolved token: '$plain'. Check the token names against the prompts on this role.")
        }
    }

    $minLength = if ($spec.minLength) { [int]$spec.minLength } else { 8 }
    if ($plain.Length -lt $minLength) {
        return [pscustomobject]@{
            Value = $null; Mode = 'template'; Ok = $false
            Warnings = @("Password from template is $($plain.Length) characters, below the minimum of $minLength. Employee numbers vary in length, so a short one produces a short password - add a fixed suffix to the template.")
        }
    }

    # AD complexity: at least three of the four character categories
    $categories = 0
    if ($plain -cmatch '[A-Z]')            { $categories++ }
    if ($plain -cmatch '[a-z]')            { $categories++ }
    if ($plain -match  '[0-9]')            { $categories++ }
    if ($plain -match  '[^A-Za-z0-9]')     { $categories++ }
    if ($categories -lt 3) {
        return [pscustomobject]@{
            Value = $null; Mode = 'template'; Ok = $false
            Warnings = @("Password from template uses only $categories of the 4 character categories; AD complexity requires 3. Add a symbol, a digit, or mixed case to the template.")
        }
    }

    # AD refuses a password containing the account name, or a run of more than two
    # characters taken from the user's display name.
    $sam = [string]$Context['samAccountName']
    if ($sam -and $plain -match [regex]::Escape($sam)) {
        return [pscustomobject]@{
            Value = $null; Mode = 'template'; Ok = $false
            Warnings = @("Password contains the account name '$sam'; AD will reject it.")
        }
    }
    foreach ($part in @($Context['firstName'], $Context['lastName'])) {
        if ([string]::IsNullOrWhiteSpace($part) -or $part.Length -le 2) { continue }
        if ($plain -match [regex]::Escape($part)) {
            return [pscustomobject]@{
                Value = $null; Mode = 'template'; Ok = $false
                Warnings = @("Password contains '$part' from the user's name; AD rejects runs of more than two characters from the display name. Use {firstInitial} rather than {firstName}.")
            }
        }
    }

    $warnings.Add("Initial password was generated from a fixed template, so it is predictable to anyone who knows the inputs. It must be changed at first logon.")

    [pscustomobject]@{ Value = $plain; Mode = 'template'; Ok = $true; Warnings = $warnings.ToArray() }
}
