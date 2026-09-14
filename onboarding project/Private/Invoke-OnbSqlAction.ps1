function Invoke-OnbSqlAction {
    <#
    .SYNOPSIS
        Runs a named, pre-defined SQL provisioning action against a line-of-business system.
    .DESCRIPTION
        No SQL text ever lives in this function. Every statement is declared in
        config.json under sqlSystems.<system>.actions.<action>, and a role file
        only ever refers to an action by name. That means:

          * A new LOB system or a changed table is a config edit, not a code edit.
          * All values are passed as SqlParameters, so nothing is ever concatenated
            into a query. A surname with an apostrophe cannot break or inject.
          * An action can declare an 'existsQuery' returning a count. If it returns
            greater than zero the action is skipped, which makes re-running a failed
            onboarding safe.
          * Each action runs inside a transaction and is rolled back on error.

        Named parameters in the statement (@Something) are filled from, in order of
        precedence: the action's own 'parameters' block in the role file, then the
        onboarding context (firstName, samAccountName, email, and any custom prompt
        answers). A parameter the statement asks for but that nothing supplies is a
        hard error rather than a silent NULL.
    .OUTPUTS
        Onb.StepResult
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][psobject]$SqlAction,   # one entry from a role's sqlActions[]
        [Parameter(Mandatory)][psobject]$Config
    )

    $systemName = $SqlAction.system
    $actionName = $SqlAction.action
    $stepName   = "SQL: $systemName / $actionName"

    $system = $Config.sqlSystems.$systemName
    if (-not $system) {
        return New-OnbStepResult -Step $stepName -Status Failed `
            -Message "System '$systemName' is not defined in config.json."
    }

    $action = $system.actions.$actionName
    if (-not $action) {
        return New-OnbStepResult -Step $stepName -Status Failed `
            -Message "Action '$actionName' is not defined for system '$systemName'."
    }

    # ---- Assemble the parameter set -------------------------------------------------
    $values = @{}
    foreach ($key in $Context.Keys) { $values[$key] = $Context[$key] }
    if ($SqlAction.PSObject.Properties.Name -contains 'parameters' -and $SqlAction.parameters) {
        foreach ($p in $SqlAction.parameters.PSObject.Properties) {
            $values[$p.Name] = Expand-OnbToken -Template ([string]$p.Value) -Context $Context
        }
    }

    $statement = [string]$action.statement
    $existsQry = [string]$action.existsQuery

    # Work out which @parameters the SQL actually asks for
    $needed = @(
        [regex]::Matches("$statement $existsQry", '@([A-Za-z0-9_]+)') |
            ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
    )
    $missing = $needed | Where-Object { -not ($values.Keys -contains $_) }
    if ($missing) {
        return New-OnbStepResult -Step $stepName -Status Failed `
            -Message ("No value supplied for SQL parameter(s): {0}" -f ($missing -join ', '))
    }

    if (-not $PSCmdlet.ShouldProcess("$systemName", "Run SQL action '$actionName'")) {
        return New-OnbStepResult -Step $stepName -Status WhatIf `
            -Message "Would run '$actionName' on '$systemName'." `
            -Data ($needed | ForEach-Object { "$_ = $($values[$_])" })
    }

    $connection  = $null
    $transaction = $null
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection $system.connectionString
        $connection.Open()

        $addParams = {
            param($cmd)
            foreach ($name in $needed) {
                $v = $values[$name]
                $null = $cmd.Parameters.AddWithValue("@$name", $(if ($null -eq $v -or $v -eq '') { [DBNull]::Value } else { $v }))
            }
        }

        # ---- Idempotency check ------------------------------------------------------
        if ($existsQry) {
            $check = $connection.CreateCommand()
            $check.CommandText = $existsQry
            $check.CommandTimeout = 30
            & $addParams $check
            $count = [int]($check.ExecuteScalar())
            $check.Dispose()
            if ($count -gt 0) {
                Write-OnbLog "SQL action '$actionName' on '$systemName' already applied; skipping."
                return New-OnbStepResult -Step $stepName -Status Skipped -Message 'Already applied.'
            }
        }

        # ---- Apply ------------------------------------------------------------------
        $transaction = $connection.BeginTransaction()
        $cmd = $connection.CreateCommand()
        $cmd.Transaction   = $transaction
        $cmd.CommandText   = $statement
        $cmd.CommandTimeout = 60
        & $addParams $cmd

        $rows = $cmd.ExecuteNonQuery()
        $transaction.Commit()
        $cmd.Dispose()

        Write-OnbLog "SQL action '$actionName' on '$systemName' affected $rows row(s)."
        New-OnbStepResult -Step $stepName -Status Success -Message "$rows row(s) affected." -Data $rows
    }
    catch {
        if ($transaction) { try { $transaction.Rollback() } catch { } }
        Write-OnbLog -Level ERROR "SQL action '$actionName' on '$systemName' failed: $($_.Exception.Message)"
        New-OnbStepResult -Step $stepName -Status Failed -Message $_.Exception.Message
    }
    finally {
        if ($connection -and $connection.State -eq 'Open') { $connection.Close() }
        if ($connection) { $connection.Dispose() }
    }
}
