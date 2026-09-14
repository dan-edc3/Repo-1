function Get-OnboardingConfig {
    <#
    .SYNOPSIS
        Loads config.json (environment settings and SQL action definitions).
    .DESCRIPTION
        Cached after first load. Use -Force after editing config.json in a session
        that already imported the module.
    .EXAMPLE
        (Get-OnboardingConfig).sqlSystems.PSObject.Properties.Name
        Lists the LOB systems the module knows how to talk to.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:OnbConfig -and -not $Force) { return $script:OnbConfig }

    if (-not (Test-Path $script:OnbConfigPath)) {
        throw "Configuration file not found at '$script:OnbConfigPath'."
    }

    try {
        $script:OnbConfig = Get-Content -Path $script:OnbConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "config.json is not valid JSON: $($_.Exception.Message)"
    }

    return $script:OnbConfig
}
