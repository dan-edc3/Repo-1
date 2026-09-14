function New-OnbStepResult {
    <#
    .SYNOPSIS
        Builds the standard result object that every provisioning step returns.
    .DESCRIPTION
        Every step in an onboarding run reports back with the same shape, so the
        console (or a log, or a CSV) can render a uniform checklist without
        knowing anything about what the step actually did.
        Status is one of: Success, Skipped, Failed, WhatIf.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('Success','Skipped','Failed','WhatIf')][string]$Status,
        [string]$Message = '',
        [object]$Data    = $null
    )

    [pscustomobject]@{
        PSTypeName = 'Onb.StepResult'
        TimeStamp  = (Get-Date)
        Step       = $Step
        Status     = $Status
        Message    = $Message
        Data       = $Data
    }
}
