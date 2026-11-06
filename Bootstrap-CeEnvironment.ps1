#Requires -Version 5.1
<#
.SYNOPSIS
    Dynamics 365 CE environment bootstrap.
.DESCRIPTION
    Walks you through creating a Dynamics 365 CE (Dataverse) environment and installs
    its prerequisites one after another, waiting for each to finish:

      0. Sign-in method          5. Application users
      1. pac CLI and sign-in     6. Dynamics 365 apps, one at a time
      2. Environment details     7. Marketing (you start it in the admin center)
      3. Confirm                 8. Developer tools (optional)
      4. Create environment      9. Check and next steps

    Anything you pass as a parameter isn't asked for. Re-running is safe: an
    environment that already has the domain is reused, and installed apps are skipped.
.EXAMPLE
    .\Bootstrap-CeEnvironment.ps1
    Asks for everything.
.EXAMPLE
    .\Bootstrap-CeEnvironment.ps1 -DisplayName CONTOSO-DEV01 -Domain contoso-dev01 -ApplicationUsers 11111111-2222-3333-4444-555555555555
    Asks only for what's missing.
.EXAMPLE
    .\Bootstrap-CeEnvironment.ps1 -Verify -EnvironmentUrl https://contoso-dev01.crm11.dynamics.com
    Only shows which apps are installed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Interactive', 'DeviceCode', 'ServicePrincipal')]
    [string]$AuthMethod,
    [string]$TenantId,
    [string]$AppId,
    [string]$ClientSecret,

    [string]$DisplayName,
    [string]$Domain,
    [string]$EnvironmentType,
    [string]$Region,
    [string]$Currency,
    [string]$Language,
    [string]$Templates,          # comma-separated, or 'none'
    [string]$SecurityGroupId,    # or 'none'

    [string]$Applications,       # comma-separated unique names, or 'none'
    [string]$ApplicationUsers,   # comma-separated application (client) IDs, or 'none'
    [string]$SecurityRole,
    [ValidateSet('Yes', 'No')]
    [string]$IncludeMarketing,
    [ValidateSet('Yes', 'No')]
    [string]$InstallDevTools,
    [string]$DevTools,           # comma-separated tool names from config\defaults.json

    [switch]$Yes,                # don't ask for confirmation before starting
    [switch]$Verify,
    [string]$EnvironmentUrl      # for -Verify
)

$ErrorActionPreference = 'Stop'
$bound = @{}
foreach ($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }

foreach ($module in 'Logger', 'UserInputs', 'PacCli', 'CeEnvironment', 'CeApplications', 'DevTools') {
    Import-Module (Join-Path $PSScriptRoot "modules\$module.psm1") -Force -DisableNameChecking
}
$config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config\defaults.json') -Raw | ConvertFrom-Json
$breadcrumbPath = [System.Environment]::ExpandEnvironmentVariables($config.paths.breadcrumb)

Write-Host ''
Write-Host '  Dynamics 365 CE environment bootstrap' -ForegroundColor White
Write-Host "  v$($config.scriptVersion). Creates an environment and installs its apps one at a time." -ForegroundColor Gray
Initialize-CeLog -Directory $config.paths.logDir

$run = [ordered]@{ Environment = $null; Apps = [ordered]@{}; Marketing = 'Not requested'; AppUsers = @(); DevTools = @() }
$exitCode = 0

function Select-CeSignIn {
    Write-PhaseStart '0' 'Sign-in method'
    $method = Read-CeChoice -Bound $bound -Name 'AuthMethod' -Prompt 'How should pac sign in?' `
        -Choices @('Interactive', 'DeviceCode', 'ServicePrincipal') -Default 'Interactive'
    $auth = @{ Method = $method }
    if ($method -eq 'ServicePrincipal') {
        $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
        $auth.TenantId = Read-CeValue -Bound $bound -Name 'TenantId' -Prompt 'Tenant ID' -Required -Pattern $guid -PatternMessage 'Enter a GUID.'
        $auth.AppId = Read-CeValue -Bound $bound -Name 'AppId' -Prompt 'Application (client) ID' -Required -Pattern $guid -PatternMessage 'Enter a GUID.'
        $auth.ClientSecret = Read-CeSecret -Bound $bound -Name 'ClientSecret' -Prompt 'Client secret (hidden)'
    }
    Write-Log -Level OK -Message "Sign-in method: $method"
    Write-PhaseEnd 'OK' $method
    return $auth
}

function Connect-CeTools([hashtable]$Auth) {
    Write-PhaseStart '1' 'pac CLI and sign-in'
    Install-CePac -Config $config
    Connect-CePac -Config $config -Method $Auth.Method -TenantId $Auth.TenantId -AppId $Auth.AppId -ClientSecret $Auth.ClientSecret
    Write-PhaseEnd 'OK'
}

try {
    # ---------------------------------------------------------------- Verify only
    if ($Verify) {
        $auth = Select-CeSignIn
        Connect-CeTools $auth
        Write-PhaseStart 'V' 'Check an environment'
        $lastUrl = ''
        if (Test-Path $breadcrumbPath) { try { $lastUrl = (Get-Content $breadcrumbPath -Raw | ConvertFrom-Json).environmentUrl } catch { } }
        $url = Read-CeValue -Bound $bound -Name 'EnvironmentUrl' -Prompt 'Environment URL' -Default $lastUrl -Required -Pattern '^https://.+\.dynamics\.com/?$' -PatternMessage 'Use the https://<name>.crmNN.dynamics.com form.'
        $names = @($config.applications.catalog | ForEach-Object { $_.uniqueName }) + $config.marketing.appName
        foreach ($name in $names) {
            $state = Get-CeApplicationState -EnvironmentUrl $url -Name $name
            $level = if ($state.Status -eq 'Installed') { 'OK' } else { 'WARN' }
            Write-Log -Level $level -Message ('{0,-45} {1} {2}' -f $name, $state.Status, $state.State)
        }
        Write-PhaseEnd 'OK'
        return
    }

    # ---------------------------------------------------------------- 0-1
    $auth = Select-CeSignIn
    Connect-CeTools $auth

    # ---------------------------------------------------------------- 2. Inputs
    Write-PhaseStart '2' 'Environment details'
    $settings = @{}
    $settings.DisplayName = Read-CeValue -Bound $bound -Name 'DisplayName' -Prompt 'Environment display name (e.g. CONTOSO-DEV01)' -Required `
        -Pattern "^.{1,$($config.environment.displayNameMaxLength)}$" -PatternMessage "Use 1 to $($config.environment.displayNameMaxLength) characters."
    $domainPattern = '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
    $environments = @(Get-CeEnvironmentList)
    $useExisting = $false
    while ($true) {
        $settings.Domain = (Read-CeValue -Bound $bound -Name 'Domain' -Prompt 'Domain, the first part of the URL' -Default (ConvertTo-CeDomain $settings.DisplayName) `
            -Required -Pattern $domainPattern -PatternMessage 'Lower-case letters, numbers and single hyphens; no hyphen at the start or end.').ToLowerInvariant()
        if ($settings.Domain -match '--') { Write-Host '      Two hyphens in a row are not allowed.' -ForegroundColor Yellow; $bound.Remove('Domain'); continue }
        $existing = Find-CeEnvironment -Domain $settings.Domain -Environments $environments
        if (-not $existing) { Write-Log -Level OK -Message "The domain $($settings.Domain) is free"; break }
        $choice = Read-CeChoice -Prompt "$($existing.EnvironmentUrl) ('$($existing.DisplayName)') already exists. What now?" `
            -Choices @('Use it: install whatever is missing', 'Enter a different domain') -Default 'Use it: install whatever is missing'
        if ($choice -like 'Use it*') { $useExisting = $true; break }
        $bound.Remove('Domain')
    }

    if (-not $useExisting) {
        $settings.Type = Read-CeChoice -Bound $bound -Name 'EnvironmentType' -Prompt 'Environment type' -Choices @($config.environment.types) -Default $config.environment.defaultType
        $settings.Region = Read-CeChoice -Bound $bound -Name 'Region' -Prompt 'Region' -Choices @($config.environment.regions) -Default $config.environment.defaultRegion
        $settings.Currency = Read-CeValue -Bound $bound -Name 'Currency' -Prompt 'Currency' -Default $config.environment.defaultCurrency -Pattern '^[A-Za-z]{3}$' -PatternMessage 'Use a 3-letter code such as GBP.'
        $settings.Language = Read-CeValue -Bound $bound -Name 'Language' -Prompt 'Language code (1033 = English)' -Default $config.environment.defaultLanguage -Pattern '^\d{4,5}$' -PatternMessage 'Use a number such as 1033.'

        $offered = Get-CeTemplates -Region $settings.Region
        if (-not $offered) { $offered = @($config.environment.fallbackTemplates); Write-Log -Level WARN -Message "Couldn't read the templates offered in $($settings.Region); showing the usual ones" }
        $items = @($offered | ForEach-Object { [pscustomobject]@{ Value = $_; Label = $_ } })
        $settings.Templates = @(Read-CeMultiChoice -Bound $bound -Name 'Templates' -Prompt 'Dynamics 365 templates (installed while the environment is created)' `
            -Items $items -Defaults @($config.environment.defaultTemplates | Where-Object { $offered -contains $_ }) -AllowNone)
        if ($settings.Templates.Count -eq 0) {
            Write-Log -Level WARN -Message "With no template, Dynamics 365 apps may not be enabled, and that can't be turned on later. Marketing and other Dynamics 365 apps then can't be installed."
        }
        $group = Read-CeValue -Bound $bound -Name 'SecurityGroupId' -Prompt "Entra security group ID to restrict access ('none' for no group)" -Default 'none' `
            -Pattern '^(none|[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})$' -PatternMessage "Enter a GUID or 'none'."
        $settings.SecurityGroupId = if ($group -eq 'none') { '' } else { $group }
    }

    $appItems = @($config.applications.catalog | ForEach-Object { [pscustomobject]@{ Value = $_.uniqueName; Label = "$($_.uniqueName)  - $($_.description)" } })
    $appDefaults = @($config.applications.catalog | Where-Object { $_.default } | ForEach-Object { $_.uniqueName })
    $settings.Apps = @(Read-CeMultiChoice -Bound $bound -Name 'Applications' -Prompt 'Apps to install, in this order' -Items $appItems -Defaults $appDefaults -AllowOther -AllowNone)

    $users = Read-CeValue -Bound $bound -Name 'ApplicationUsers' -Prompt "Application (client) IDs to add as app users, comma-separated ('none' to skip)" -Required `
        -Pattern '^(none|[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}(\s*,\s*[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})*)$' -PatternMessage "Enter one or more GUIDs separated by commas, or 'none'."
    $settings.AppUsers = @(if ($users -ne 'none') { $users -split ',' | ForEach-Object { $_.Trim() } })
    if ($settings.AppUsers.Count -gt 0) {
        $settings.Role = Read-CeValue -Bound $bound -Name 'SecurityRole' -Prompt 'Security role for the app users' -Default $config.applications.defaultSecurityRole
    }
    $settings.Marketing = Read-CeYesNo -Bound $bound -Name 'IncludeMarketing' -Prompt 'Install Marketing afterwards (you start it in the admin center)?' -Default $true

    $settings.DevTools = @()
    if (Read-CeYesNo -Bound $bound -Name 'InstallDevTools' -Prompt 'Also install developer tools on this machine (Git, Node.js, .NET SDK...)?' -Default $false) {
        $toolItems = @($config.devTools | ForEach-Object { [pscustomobject]@{ Value = $_.name; Label = "$($_.name)  - $($_.reason)" } })
        $picked = @(Read-CeMultiChoice -Bound $bound -Name 'DevTools' -Prompt 'Which tools?' -Items $toolItems -Defaults @($config.devTools | Where-Object { $_.default } | ForEach-Object { $_.name }) -AllowNone)
        $settings.DevTools = @($config.devTools | Where-Object { $picked -contains $_.name })
    }
    Write-PhaseEnd 'OK'

    # ---------------------------------------------------------------- 3. Confirm
    Write-PhaseStart '3' 'Confirm'
    $rows = [ordered]@{}
    if ($useExisting) { $rows['Environment'] = "$($existing.EnvironmentUrl) (existing)" }
    else {
        $rows['Display name'] = $settings.DisplayName
        $rows['Domain'] = $settings.Domain
        $rows['Type / region'] = "$($settings.Type) / $($settings.Region)"
        $rows['Currency / language'] = "$($settings.Currency) / $($settings.Language)"
        $rows['Templates'] = $(if ($settings.Templates.Count) { $settings.Templates -join ', ' } else { 'none' })
        $rows['Security group'] = $(if ($settings.SecurityGroupId) { $settings.SecurityGroupId } else { 'none' })
    }
    $rows['App users'] = $(if ($settings.AppUsers.Count) { "$($settings.AppUsers -join ', ') as $($settings.Role)" } else { 'none' })
    $rows['Apps, in order'] = $(if ($settings.Apps.Count) { $settings.Apps -join ' > ' } else { 'none' })
    $rows['Marketing'] = $(if ($settings.Marketing) { 'Yes (you start it in the admin center)' } else { 'No' })
    $rows['Developer tools'] = $(if ($settings.DevTools.Count) { ($settings.DevTools | ForEach-Object { $_.name }) -join ', ' } else { 'none' })
    Write-Host ''
    foreach ($key in $rows.Keys) { Write-Host ('    {0,-20} {1}' -f $key, $rows[$key]) -ForegroundColor Gray; Write-Log -Level DEBUG -Message "INPUT $key = $($rows[$key])" }
    Write-Host ''
    Write-Log -Level INFO -Message 'Creating the environment and installing apps can take several hours. Keep this window open and the PC awake.'
    if (-not $Yes -and -not (Read-CeYesNo -Prompt 'Start?' -Default $true)) { Write-PhaseEnd 'SKIP' 'Cancelled'; Write-Log -Level INFO -Message 'Nothing was changed.'; return }
    Write-PhaseEnd 'OK'

    # ---------------------------------------------------------------- 4. Create
    Write-PhaseStart '4' 'Create environment'
    if ($useExisting) {
        $environment = $existing
        $environment | Add-Member -NotePropertyName Created -NotePropertyValue $false -Force
        Write-Log -Level SKIP -Message "Using $($environment.EnvironmentUrl)"
        Write-PhaseEnd 'SKIP' 'Existing'
    }
    else {
        $environment = New-CeEnvironment -Settings $settings -TimeoutMinutes $config.environment.createTimeoutMinutes
        Write-PhaseEnd 'OK' $environment.HostName
    }
    $run.Environment = $environment

    # ---------------------------------------------------------------- 5. App users
    Write-PhaseStart '5' 'Application users'
    if ($settings.AppUsers.Count -eq 0) { Write-PhaseEnd 'SKIP' 'None requested' }
    else {
        $run.AppUsers = @(Add-CeApplicationUsers -EnvironmentUrl $environment.EnvironmentUrl -ApplicationIds $settings.AppUsers -Role $settings.Role)
        $failedUsers = @($run.AppUsers | Where-Object { -not $_.Added })
        if ($failedUsers.Count) { Write-PhaseEnd 'WARN' "$($failedUsers.Count) not added" } else { Write-PhaseEnd 'OK' }
    }

    # ---------------------------------------------------------------- 6. Apps
    Write-PhaseStart '6' 'Dynamics 365 apps'
    if ($settings.Apps.Count -eq 0) { Write-PhaseEnd 'SKIP' 'None requested' }
    else {
        $stopApps = $false
        foreach ($app in $settings.Apps) {
            if ($stopApps) { $run.Apps[$app] = 'Not attempted'; continue }
            try { $run.Apps[$app] = Install-CeApplication -EnvironmentUrl $environment.EnvironmentUrl -Name $app -TimeoutMinutes $config.applications.timeoutMinutes -PollSeconds $config.applications.pollSeconds }
            catch {
                $run.Apps[$app] = 'Failed'
                Write-Log -Level ERROR -Message $_.Exception.Message
                if (-not (Read-CeYesNo -Prompt 'Carry on with the next app?' -Default $true)) { $stopApps = $true }
            }
        }
        $notInstalled = @($run.Apps.Keys | Where-Object { $run.Apps[$_] -notmatch 'Installed' })
        if ($notInstalled.Count) { Write-PhaseEnd 'WARN' "Not installed: $($notInstalled -join ', ')" } else { Write-PhaseEnd 'OK' }
    }

    # ---------------------------------------------------------------- 7. Marketing
    Write-PhaseStart '7' 'Marketing'
    if (-not $settings.Marketing) { Write-PhaseEnd 'SKIP' 'Not requested' }
    else {
        try { $run.Marketing = Invoke-CeMarketingStep -Config $config -Environment $environment }
        catch { $run.Marketing = 'Failed'; Write-Log -Level ERROR -Message $_.Exception.Message }
        $status = if ($run.Marketing -match 'Installed') { 'OK' } elseif ($run.Marketing -eq 'Skipped') { 'SKIP' } else { 'WARN' }
        Write-PhaseEnd $status $run.Marketing
    }

    # ---------------------------------------------------------------- 8. Dev tools
    Write-PhaseStart '8' 'Developer tools'
    if ($settings.DevTools.Count -eq 0) { Write-PhaseEnd 'SKIP' 'Not requested' }
    else {
        $run.DevTools = @(Install-CeDevTools -Tools $settings.DevTools)
        $toolProblems = @($run.DevTools | Where-Object { $_.Result -notmatch 'Installed' })
        if ($toolProblems.Count) { Write-PhaseEnd 'WARN' "$($toolProblems.Count) not installed" } else { Write-PhaseEnd 'OK' }
    }

    # ---------------------------------------------------------------- 9. Check
    Write-PhaseStart '9' 'Check and next steps'
    foreach ($app in $settings.Apps) {
        $state = Get-CeApplicationState -EnvironmentUrl $environment.EnvironmentUrl -Name $app
        $level = if ($state.Status -eq 'Installed') { 'OK' } else { 'WARN' }
        Write-Log -Level $level -Message ('{0,-45} {1}' -f $app, $state.Status)
    }
    $breadcrumbDir = Split-Path $breadcrumbPath -Parent
    if (-not (Test-Path $breadcrumbDir)) { New-Item -ItemType Directory -Path $breadcrumbDir -Force | Out-Null }
    [ordered]@{
        displayName    = $environment.DisplayName
        environmentUrl = $environment.EnvironmentUrl
        environmentId  = $environment.EnvironmentId
        created        = $environment.Created
        apps           = $run.Apps
        marketing      = $run.Marketing
        finishedAt     = (Get-Date).ToString('s')
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $breadcrumbPath -Encoding UTF8

    Write-Host ''
    Write-Host "  Environment: $($environment.EnvironmentUrl)" -ForegroundColor Green
    Write-Host '  Next:' -ForegroundColor White
    Write-Host "    - Deploy your solutions to it (pac solution import, or your release pipeline)." -ForegroundColor Gray
    Write-Host "    - Check apps any time: .\Bootstrap-CeEnvironment.ps1 -Verify -EnvironmentUrl $($environment.EnvironmentUrl)" -ForegroundColor Gray
    if ($run.Marketing -in @('Skipped', 'Not tracked', 'Failed')) { Write-Host '    - Marketing still needs installing or checking in the admin center.' -ForegroundColor Gray }
    Write-PhaseEnd 'OK'
}
catch {
    $exitCode = 1
    Write-Log -Level ERROR -Message $_.Exception.Message
    Write-PhaseEnd 'ERROR' 'Stopped'
    Write-Log -Level INFO -Message 'Fix the problem and run the script again; it reuses the environment and skips installed apps.'
}
finally {
    Write-CeSummary
    Write-Host ''
    Write-Host "  Log: $(Get-CeLogPath)" -ForegroundColor DarkGray
    Stop-CeLog
}
exit $exitCode
