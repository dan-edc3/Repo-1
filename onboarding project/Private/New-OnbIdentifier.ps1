function New-OnbIdentifier {
    <#
    .SYNOPSIS
        Resolves one identifier (sAMAccountName, WMS user id, ...) to a unique, valid value.
    .DESCRIPTION
        Works through the identifier's formats in order, transforms each candidate, checks
        it against the validation pattern, and tests it for availability in every system
        listed in 'uniqueIn'. The first candidate that passes everything wins.

        Collision strategy, in order:
          1. The primary 'format'.
          2. Each entry in 'collisionFormats', in the order written - this is where a site
             convention like "add the middle initial" or "use the full first name" goes.
          3. Any format containing {n} is retried with n = 2, 3, 4 ... up to maxAttempts.

        Truncation is applied to the NAME PART only, never to {n}: with maxLength 20, the
        21st Dana Reyes gets a name ending in "21", not a silently chopped one. A number
        that gets cut off produces a collision with a real account, which is the failure
        this whole function exists to prevent.

        Returns an object with Value, Format (which pattern won), Attempts, and Success.
    .NOTES
        This does NOT reserve the name. Two admins onboarding simultaneously could in
        principle resolve the same candidate; AD itself rejects the second create, and the
        step reports a clean failure rather than a duplicate. With two admins that race is
        not worth engineering around.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][psobject]$Spec,
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$Config,
        # Skips the availability lookups so a naming config can be validated offline.
        # Used by Test-OnboardingRole; never set this on a real onboarding run.
        [switch]$SkipAvailability
    )

    $transforms  = @($Spec.transform)
    $maxLength   = if ($Spec.maxLength)   { [int]$Spec.maxLength }   else { 0 }
    $minLength   = if ($Spec.minLength)   { [int]$Spec.minLength }   else { 0 }
    $maxAttempts = if ($Spec.maxAttempts) { [int]$Spec.maxAttempts } else { 50 }
    $uniqueIn    = if ($Spec.uniqueIn)    { @($Spec.uniqueIn) }      else { @() }
    $upnSuffix   = $Context['upnSuffix']

    $formats = @($Spec.format) + @($Spec.collisionFormats) | Where-Object { $_ }
    $tried   = [System.Collections.Generic.List[string]]::new()

    foreach ($format in $formats) {
        $hasCounter = $format -match '\{n(?::\d+)?\}'
        $limit      = if ($hasCounter) { $maxAttempts } else { 1 }

        for ($n = if ($hasCounter) { 2 } else { 1 }; $tried.Count -lt $maxAttempts; $n++) {

            # Expand the name part with {n} held back, so truncation can never eat the number
            $marker   = [char]0x241F
            $template = $format -replace '\{n(?::\d+)?\}', $marker
            $namePart = Expand-OnbToken -Template $template -Context $Context
            $namePart = Convert-OnbName -Value ($namePart -replace [regex]::Escape($marker), '') -Transforms $transforms

            $suffix = if ($hasCounter) { [string]$n } else { '' }

            if ($maxLength -gt 0) {
                $room = $maxLength - $suffix.Length
                if ($room -lt 1) {
                    Write-OnbLog -Level WARN "Identifier '$Name': maxLength $maxLength cannot fit the counter; skipping format '$format'."
                    break
                }
                if ($namePart.Length -gt $room) { $namePart = $namePart.Substring(0, $room) }
            }

            $candidate = $namePart + $suffix
            if ($tried -contains $candidate) { if (-not $hasCounter) { break } else { continue } }
            $tried.Add($candidate)

            if ($minLength -gt 0 -and $candidate.Length -lt $minLength) {
                Write-OnbLog -Level WARN "Identifier '$Name': candidate '$candidate' is shorter than minLength $minLength."
                if (-not $hasCounter) { break } else { continue }
            }

            if ($Spec.validate -and $candidate -notmatch $Spec.validate) {
                Write-OnbLog -Level WARN "Identifier '$Name': candidate '$candidate' fails pattern '$($Spec.validate)'."
                if (-not $hasCounter) { break } else { continue }
            }

            $available = if ($SkipAvailability) { $true }
                         else { Test-OnbIdentifierAvailable -Candidate $candidate -UniqueIn $uniqueIn -Config $Config -UpnSuffix $upnSuffix }
            if ($available) {
                Write-OnbLog "Identifier '$Name' resolved to '$candidate' using format '$format' after $($tried.Count) candidate(s)."
                return [pscustomobject]@{
                    Name = $Name; Value = $candidate; Format = $format
                    Attempts = $tried.Count; Success = $true; Tried = $tried.ToArray()
                }
            }

            if (-not $hasCounter) { break }
            if ($n -ge $limit)    { break }
        }
    }

    Write-OnbLog -Level ERROR "Identifier '$Name' could not be resolved. Tried: $($tried -join ', ')"
    [pscustomobject]@{
        Name = $Name; Value = $null; Format = $null
        Attempts = $tried.Count; Success = $false; Tried = $tried.ToArray()
    }
}
