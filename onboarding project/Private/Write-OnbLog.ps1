function Write-OnbLog {
    <#
    .SYNOPSIS
        Appends a line to the per-run onboarding log and echoes it to the verbose stream.
    .DESCRIPTION
        The log path is set once at the start of a run by Invoke-Onboarding, which
        stashes it in $script:OnbCurrentLogFile. If no run is active the message
        still goes to the verbose stream, it just isn't persisted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    if ($script:OnbCurrentLogFile) {
        try   { Add-Content -Path $script:OnbCurrentLogFile -Value $line -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Warning "Could not write to log '$script:OnbCurrentLogFile': $_" }
    }

    switch ($Level) {
        'ERROR' { Write-Verbose $line }
        'WARN'  { Write-Verbose $line; Write-Warning $Message }
        default { Write-Verbose $line }
    }
}
