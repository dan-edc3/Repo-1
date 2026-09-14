@{
    RootModule        = 'CompanyOnboarding.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b0c1f2d3-4e5a-4b6c-8d9e-0f1a2b3c4d5e'
    Author            = 'IT Operations'
    Description       = 'Modular, config-driven user onboarding for a hybrid AD environment.'
    PowerShellVersion = '5.1'

    # Deliberately NOT listed as hard requirements so the module still imports on a
    # machine without RSAT (e.g. for editing role files). Each function checks at runtime.
    # RequiredModules = @('ActiveDirectory')

    FunctionsToExport = @(
        'Get-OnboardingRole',
        'Get-OnboardingConfig',
        'Invoke-Onboarding',
        'Test-OnboardingRole',
        'Test-OnboardingConfig',
        'Show-OnboardingConsole'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
