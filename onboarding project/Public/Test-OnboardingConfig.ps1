function Test-OnboardingConfig {
    <#
    .SYNOPSIS
        Reports which shipped placeholder values are still in config.json, and where.
    .DESCRIPTION
        The module ships with a fictional domain (contoso), fictional servers (SQL01,
        FILESERVER) and fictional groups (GRP-*). Until those are replaced the tool will
        happily preview and even attempt runs against a domain that does not exist.

        Run this first, before anything else. It tells you the exact file and setting to
        edit rather than leaving you to guess why the window still says contoso.com.
    .EXAMPLE
        Test-OnboardingConfig
    .EXAMPLE
        Test-OnboardingConfig | Where-Object Status -eq 'PLACEHOLDER'
    #>
    [CmdletBinding()]
    param()

    $config   = Get-OnboardingConfig -Force
    $patterns = 'contoso', 'SQL01', 'SQL02', 'FILESERVER', 'example\.com'

    $report = [System.Collections.Generic.List[object]]::new()

    $check = {
        param($where, $setting, $value)
        if ([string]::IsNullOrWhiteSpace([string]$value)) { return }
        foreach ($p in $patterns) {
            if ([string]$value -match $p) {
                $report.Add([pscustomobject]@{
                    Status = 'PLACEHOLDER'; Where = $where; Setting = $setting; Value = $value })
                return
            }
        }
        $report.Add([pscustomobject]@{ Status = 'OK'; Where = $where; Setting = $setting; Value = $value })
    }

    foreach ($k in 'domain','domainDn','defaultUpnSuffix','logPath') {
        & $check 'config.json' $k $config.$k
    }

    foreach ($sysName in @($config.sqlSystems.PSObject.Properties.Name)) {
        & $check 'config.json' "sqlSystems.$sysName.connectionString" $config.sqlSystems.$sysName.connectionString
    }

    # Group names live in the role files, so report the count rather than every line
    $placeholderGroups = @(
        Get-OnboardingRole -IncludeAbstract |
            ForEach-Object { $_.groups } |
            Where-Object { $_ -like 'GRP-*' } |
            Select-Object -Unique
    )
    if ($placeholderGroups) {
        $report.Add([pscustomobject]@{
            Status  = 'PLACEHOLDER'
            Where   = 'Roles\*.json'
            Setting = 'groups'
            Value   = "$($placeholderGroups.Count) placeholder GRP-* name(s): $($placeholderGroups -join ', ')"
        })
    }

    $report
}
