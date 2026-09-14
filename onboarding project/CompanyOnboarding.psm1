#requires -Version 5.1
<#
    CompanyOnboarding module loader.
    Dot-sources every function in Public\ and Private\, then exports only Public.
#>

$script:OnbModuleRoot = $PSScriptRoot
$script:OnbConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:OnbRolesPath  = Join-Path $PSScriptRoot 'Roles'
$script:OnbConfig     = $null   # lazily loaded cache

$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public\*.ps1')  -ErrorAction SilentlyContinue)
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private\*.ps1') -ErrorAction SilentlyContinue)

foreach ($file in @($private + $public)) {
    try   { . $file.FullName }
    catch { Write-Error "Failed to import '$($file.FullName)': $_" }
}

Export-ModuleMember -Function $public.BaseName
