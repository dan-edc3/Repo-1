<#
    Double-click launcher (or: right-click > Run with PowerShell).
    Imports the module from this folder and opens the window.
#>
#requires -Version 5.1

$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'CompanyOnboarding.psd1') -Force
    Show-OnboardingConsole
}
catch {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "Onboarding console failed to start:`r`n`r`n$($_.Exception.Message)",
        'Onboarding', 'OK', 'Error') | Out-Null
}
