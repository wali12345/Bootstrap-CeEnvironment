<#
    Installing Dynamics 365 apps one at a time and waiting for each to finish, plus
    the Marketing step, which has to be started by a person in the admin center.
#>

function Get-CeApplicationList {
    <# Apps in the environment as objects, or $null if pac couldn't answer. #>
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [ValidateSet('All', 'Installed', 'NotInstalled')][string]$InstallState = 'All')
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("ce-apps-{0}.json" -f [guid]::NewGuid())
    try {
        $result = Invoke-Pac -Arguments @('application', 'list', '--environment', $EnvironmentUrl, '--installState', $InstallState, '--output', $file) -Quiet
        if ($result.ExitCode -ne 0 -or -not (Test-Path $file)) { return $null }
        $raw = Get-Content -LiteralPath $file -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return , @() }
        try { return , @(ConvertFrom-CeJsonText -Lines ($raw -split "`r?`n")) } catch { return $null }
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}

function Test-CeApplicationMatch {
    param($Application, [string]$Name)
    foreach ($value in (Get-CeStringValues $Application)) { if ($value -eq $Name) { return $true } }
    return $false
}

function Get-CeApplicationStateText {
    param($Application)
    $state = Get-CePropertyValue $Application @('State', 'InstallState', 'ApplicationState', 'Status')
    if ($state -is [string]) { return $state }
    $last = Get-CePropertyValue $Application @('LastOperation')
    if ($last) { return "$(Get-CePropertyValue $last @('State', 'Status'))" }
    return ''
}

function ConvertTo-CeStatus {
    param([string]$StateText)
    if ($StateText -match 'fail') { return 'Failed' }
    if ($StateText -match '^(Installed|TemplateInstalled|UpdateAvailable)$') { return 'Installed' }
    if ($StateText -match 'Installing|Requested|Retrying|Scheduled|Upgrading|Updating|Pending|Queued|Running|InProgress') { return 'InProgress' }
    return 'NotInstalled'
}

function Get-CeApplicationState {
    <#
        Installed, InProgress, Failed, NotInstalled, NotListed or Unknown. Anything still
        running wins, so the next app never starts while this one is busy.
    #>
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [Parameter(Mandatory)][string]$Name)
    $installed = Get-CeApplicationList -EnvironmentUrl $EnvironmentUrl -InstallState Installed
    $all = Get-CeApplicationList -EnvironmentUrl $EnvironmentUrl -InstallState All
    if ($null -eq $installed -or $null -eq $all) { return [pscustomobject]@{ Status = 'Unknown'; State = '' } }
    $installedEntries = @($installed | Where-Object { Test-CeApplicationMatch $_ $Name })
    $listedEntries = @($all | Where-Object { Test-CeApplicationMatch $_ $Name })
    if ($installedEntries.Count -eq 0 -and $listedEntries.Count -eq 0) { return [pscustomobject]@{ Status = 'NotListed'; State = '' } }

    $statuses = @(
        foreach ($entry in $installedEntries) {
            $entryStatus = ConvertTo-CeStatus (Get-CeApplicationStateText $entry)
            if ($entryStatus -eq 'NotInstalled') { 'Installed' } else { $entryStatus }
        }
        foreach ($entry in $listedEntries) { ConvertTo-CeStatus (Get-CeApplicationStateText $entry) }
    )
    $texts = @(($installedEntries + $listedEntries) | ForEach-Object { Get-CeApplicationStateText $_ } | Where-Object { $_ } | Select-Object -Unique)
    $status = 'NotInstalled'
    foreach ($candidate in 'InProgress', 'Installed', 'Failed', 'NotInstalled') {
        if ($statuses -contains $candidate) { $status = $candidate; break }
    }
    return [pscustomobject]@{ Status = $status; State = ($texts -join ', ') }
}

function Start-CeApplicationInstall {
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [Parameter(Mandatory)][string]$Name)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result = Invoke-Pac -Arguments @('application', 'install', '--environment', $EnvironmentUrl, '--application-name', $Name)
        if ($result.ExitCode -eq 0) { return }
        $state = Get-CeApplicationState -EnvironmentUrl $EnvironmentUrl -Name $Name
        if ($state.Status -eq 'InProgress' -or $state.Status -eq 'Installed') { return }
        if ($attempt -lt 3) { Write-Log -Level WARN -Message "Install request for $Name failed (attempt $attempt of 3); trying again in 3 minutes"; Start-Sleep -Seconds 180 }
    }
    throw "Couldn't start the install of $Name. See the pac output above."
}

function Wait-CeApplication {
    <#
        Checks every PollSeconds until the app is installed. When the time is up it asks
        whether to keep waiting. A failure has to show twice in a row, because an old
        state can linger for a few minutes after a new request.
    #>
    param(
        [Parameter(Mandatory)][string]$EnvironmentUrl,
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = 300,
        [int]$PollSeconds = 300,
        [switch]$Resubmit,
        [int]$NotStartedLimitMinutes = 0
    )
    $started = Get-Date
    $deadline = $started.AddMinutes($TimeoutMinutes)
    $notStartedSince = $null
    $resubmitted = $false
    $failedChecks = 0
    while ($true) {
        $state = Get-CeApplicationState -EnvironmentUrl $EnvironmentUrl -Name $Name
        $detail = if ($state.State) { " ($($state.State))" } else { '' }
        Write-Log -Level INFO -Message ('[{0}] {1}: {2}{3}' -f (Format-CeElapsed ((Get-Date) - $started)), $Name, $state.Status, $detail)
        if ($state.Status -eq 'Installed') { return $state }

        if ($state.Status -eq 'Failed') {
            $failedChecks++
            if ($failedChecks -ge 2) { throw "$Name failed to install$detail. Open the environment's Dynamics 365 apps page in the admin center to see why." }
        }
        else { $failedChecks = 0 }

        if ($state.Status -eq 'NotInstalled') {
            if ($null -eq $notStartedSince) { $notStartedSince = Get-Date }
            $waited = ((Get-Date) - $notStartedSince).TotalMinutes
            if ($Resubmit -and -not $resubmitted -and $waited -ge 30) {
                Write-Log -Level WARN -Message "$Name still hasn't started after 30 minutes; sending the install request again"
                Start-CeApplicationInstall -EnvironmentUrl $EnvironmentUrl -Name $Name
                $resubmitted = $true
            }
            elseif ($NotStartedLimitMinutes -gt 0 -and $waited -ge $NotStartedLimitMinutes) {
                throw "$Name has shown as not installed for $NotStartedLimitMinutes minutes. Either its install wasn't started, or pac lists it under another name (check with: pac application list --environment $EnvironmentUrl --installState Installed)."
            }
        }
        else { $notStartedSince = $null }

        if ((Get-Date) -ge $deadline) {
            $raw = Read-Host "  $Name is still $($state.Status) after $(Format-CeElapsed ((Get-Date) - $started)). Minutes to keep waiting (Enter to stop)"
            $extra = 0
            if ([int]::TryParse($raw, [ref]$extra) -and $extra -gt 0) { $deadline = (Get-Date).AddMinutes($extra) }
            else { throw "Stopped waiting for $Name. It may still be installing; re-run later and it picks up where it left off." }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Install-CeApplication {
    <# Installs one app and waits for it. Skips it if it's already installed. #>
    param([Parameter(Mandatory)][string]$EnvironmentUrl, [Parameter(Mandatory)][string]$Name, [int]$TimeoutMinutes = 300, [int]$PollSeconds = 300)
    $state = Get-CeApplicationState -EnvironmentUrl $EnvironmentUrl -Name $Name
    for ($check = 1; $state.Status -eq 'Unknown' -and $check -le 5; $check++) {
        Write-Log -Level INFO -Message "Couldn't read the environment's apps yet; checking again in 2 minutes"
        Start-Sleep -Seconds 120
        $state = Get-CeApplicationState -EnvironmentUrl $EnvironmentUrl -Name $Name
    }
    if ($state.Status -eq 'Installed') { Write-Log -Level SKIP -Message "$Name is already installed"; return 'Already installed' }
    if ($state.Status -eq 'NotListed') {
        $names = Get-CeApplicationList -EnvironmentUrl $EnvironmentUrl -InstallState NotInstalled
        if ($names) {
            Write-Log -Level INFO -Message 'Apps you can install in this environment:'
            $names | ForEach-Object { Get-CePropertyValue $_ @('UniqueName', 'ApplicationUniqueName') } | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        }
        throw "$Name isn't available to install in this environment. Check its unique name against the list above."
    }
    if ($state.Status -eq 'InProgress') { Write-Log -Level INFO -Message "An install of $Name is already running; waiting for it" }
    else {
        Write-Log -Level ACTION -Message "Installing $Name (often 30 minutes to 2 hours)"
        Start-CeApplicationInstall -EnvironmentUrl $EnvironmentUrl -Name $Name
    }
    Wait-CeApplication -EnvironmentUrl $EnvironmentUrl -Name $Name -TimeoutMinutes $TimeoutMinutes -PollSeconds $PollSeconds -Resubmit | Out-Null
    Write-Log -Level OK -Message "$Name is installed"
    return 'Installed'
}

function Invoke-CeMarketingStep {
    <# Opens the admin center, waits for the person to start the install, then waits for it to finish. #>
    param([Parameter(Mandatory)][psobject]$Config, [Parameter(Mandatory)][psobject]$Environment)
    $appName = $Config.marketing.appName
    $state = Get-CeApplicationState -EnvironmentUrl $Environment.EnvironmentUrl -Name $appName
    if ($state.Status -eq 'Installed') { Write-Log -Level SKIP -Message 'Marketing is already installed'; return 'Already installed' }

    Write-Host ''
    Write-Host '  Marketing has to be installed from the Power Platform admin center:' -ForegroundColor White
    Write-Host '    1. Use an account with a Dynamics 365 licence, the System Administrator role and' -ForegroundColor Gray
    Write-Host '       permission to register applications in Microsoft Entra ID.' -ForegroundColor Gray
    Write-Host "    2. Environments > ... next to $($Environment.DisplayName) > Settings > Product > Features:" -ForegroundColor Gray
    Write-Host '       check that Block unmanaged customizations is Off, or the install fails.' -ForegroundColor Gray
    Write-Host '    3. Manage > Dynamics 365 apps, pick the geo at the top right, find Dynamics 365' -ForegroundColor Gray
    Write-Host '       Customer Insights or Dynamics 365 Marketing, then ... > Manage.' -ForegroundColor Gray
    Write-Host "    4. Select Install next to $($Environment.DisplayName) and agree to the terms." -ForegroundColor Gray
    Write-Host ''
    try { Start-Process $Config.marketing.adminCenterUrl } catch { Write-Log -Level INFO -Message "Open $($Config.marketing.adminCenterUrl)" }

    $answer = Read-Host "  Press Enter once you've started the install, or type 'skip'"
    if ($answer -match '^skip$') { Write-Log -Level SKIP -Message 'Marketing skipped'; return 'Skipped' }

    $state = Get-CeApplicationState -EnvironmentUrl $Environment.EnvironmentUrl -Name $appName
    if ($state.Status -eq 'NotListed') {
        Write-Log -Level WARN -Message "pac doesn't list '$appName' here, so the bootstrap can't track it. Check the environment's Dynamics 365 apps page."
        return 'Not tracked'
    }
    Wait-CeApplication -EnvironmentUrl $Environment.EnvironmentUrl -Name $appName -TimeoutMinutes $Config.marketing.timeoutMinutes `
        -PollSeconds $Config.applications.pollSeconds -NotStartedLimitMinutes $Config.marketing.notStartedLimitMinutes | Out-Null
    Write-Log -Level OK -Message 'Marketing is installed'
    return 'Installed'
}

Export-ModuleMember -Function Get-CeApplicationList, Get-CeApplicationState, Install-CeApplication, Wait-CeApplication, Invoke-CeMarketingStep
