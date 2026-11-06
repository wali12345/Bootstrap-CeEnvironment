<#
    Creating the Dataverse environment and adding application users.
#>

function Get-CeTemplates {
    <# Dynamics 365 templates offered in a region (live from pac), or $null if pac can't say. #>
    param([Parameter(Mandatory)][string]$Region)
    $result = Invoke-Pac -Arguments @('admin', 'list-app-templates', '--region', $Region) -Quiet
    if ($result.ExitCode -ne 0) { return $null }
    $names = @([regex]::Matches($result.Text, '\bD365_[A-Za-z0-9_]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    if ($names.Count -eq 0) { return $null }
    return , $names
}

function New-CeEnvironment {
    <#
        Creates the environment unless one already uses the domain, then waits until it
        answers. pac adds a number to a domain that's taken (contoso-dev01 becomes contoso-dev010),
        so this always checks first.
    #>
    param([Parameter(Mandatory)][hashtable]$Settings, [int]$TimeoutMinutes = 180)
    $before = @(Get-CeEnvironmentList)
    $environment = Find-CeEnvironment -Domain $Settings.Domain -Environments $before
    $created = $false

    if ($environment) {
        Write-Log -Level SKIP -Message "$($environment.EnvironmentUrl) already exists; using it"
    }
    else {
        $arguments = @(
            'admin', 'create',
            '--name', $Settings.DisplayName,
            '--type', $Settings.Type,
            '--region', $Settings.Region,
            '--currency', $Settings.Currency,
            '--language', $Settings.Language,
            '--domain', $Settings.Domain,
            '--max-async-wait-time', "$TimeoutMinutes"
        )
        if (@($Settings.Templates).Count -gt 0) { $arguments += @('--templates', (@($Settings.Templates) -join ',')) }
        if ($Settings.SecurityGroupId) { $arguments += @('--security-group-id', $Settings.SecurityGroupId) }

        Write-Log -Level ACTION -Message "Creating $($Settings.DisplayName). With Dynamics 365 templates this usually takes 30-90 minutes."
        $started = Get-Date
        $result = Invoke-Pac -Arguments $arguments
        if ($result.ExitCode -ne 0) {
            if ($result.Text -match 'capacity|storage') {
                throw 'Microsoft refused to create the environment because of storage capacity. You need at least 1 GB of free database capacity; free some up or add capacity, then re-run.'
            }
            throw 'pac admin create failed. If it timed out, the environment may still be being created: check the admin center, then re-run (the bootstrap reuses it once it exists).'
        }
        $created = $true
        Write-Log -Level OK -Message "pac admin create finished after $(Format-CeElapsed ((Get-Date) - $started))"

        $knownHosts = @($before | ForEach-Object { $_.HostName })
        $domainLower = $Settings.Domain.ToLowerInvariant()
        for ($check = 1; $check -le 15 -and -not $environment; $check++) {
            $after = @(Get-CeEnvironmentList)
            $environment = Find-CeEnvironment -Domain $Settings.Domain -Environments $after
            if (-not $environment) {
                $environment = $after | Where-Object { $knownHosts -notcontains $_.HostName -and $_.HostName.StartsWith($domainLower) } | Select-Object -First 1
            }
            if (-not $environment) { Write-Log -Level INFO -Message 'The new environment is not listed yet; checking again in 2 minutes'; Start-Sleep -Seconds 120 }
        }
        if (-not $environment) { throw "pac admin create finished, but no environment for '$($Settings.Domain)' appeared. Check Environments in the admin center." }
        if (-not $environment.HostName.StartsWith("$domainLower.")) {
            Write-Log -Level WARN -Message "The domain was taken, so the environment was created as $($environment.HostName)"
        }
    }

    Write-Log -Level ACTION -Message 'Waiting until the environment answers'
    for ($check = 1; $check -le 20; $check++) {
        if ($null -ne (Get-CeApplicationList -EnvironmentUrl $environment.EnvironmentUrl -InstallState Installed)) { break }
        if ($check -eq 20) { Write-Log -Level WARN -Message 'The environment is still not answering app queries; carrying on anyway'; break }
        Start-Sleep -Seconds 90
    }
    Write-Log -Level OK -Message "Environment ready: $($environment.EnvironmentUrl)"
    $environment | Add-Member -NotePropertyName Created -NotePropertyValue $created -Force
    return $environment
}

function Add-CeApplicationUsers {
    <# pac admin assign-user --application-user for each ID, retried while a new environment starts up. #>
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [string[]]$ApplicationIds, [string]$Role = 'System Administrator')
    $results = @()
    foreach ($id in @($ApplicationIds)) {
        $done = $false
        for ($attempt = 1; $attempt -le 6 -and -not $done; $attempt++) {
            $result = Invoke-Pac -Arguments @('admin', 'assign-user', '--environment', $EnvironmentUrl, '--user', $id, '--role', $Role, '--application-user')
            if ($result.ExitCode -eq 0 -or $result.Text -match 'already') { $done = $true }
            elseif ($attempt -lt 6) {
                Write-Log -Level WARN -Message "Attempt $attempt of 6 for $id failed; a new environment can take a few minutes to accept users. Trying again in 3 minutes."
                Start-Sleep -Seconds 180
            }
        }
        if ($done) { Write-Log -Level OK -Message "Application user $id has '$Role'" }
        else { Write-Log -Level ERROR -Message "Couldn't add application user $id. See the pac output above." }
        $results += [pscustomobject]@{ Id = $id; Added = $done }
    }
    return $results
}

Export-ModuleMember -Function Get-CeTemplates, New-CeEnvironment, Add-CeApplicationUsers
