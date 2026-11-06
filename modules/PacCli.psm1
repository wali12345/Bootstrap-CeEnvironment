<#
    Installs or updates the Power Platform CLI (pac), signs in, and wraps pac calls.
    Also holds the helpers that read pac's JSON output. pac doesn't document the
    shape of that output, so the helpers look for values rather than fixed fields.
#>

function Update-CePath {
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $dotnetTools = Join-Path $env:USERPROFILE '.dotnet\tools'
    if ((Test-Path $dotnetTools) -and ($env:PATH -notlike "*$dotnetTools*")) { $env:PATH = "$dotnetTools;$env:PATH" }
}

function Invoke-Pac {
    <# Runs pac and returns ExitCode, Lines and Text. Never throws on a non-zero exit. #>
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Quiet)
    $display = Hide-CeSecret ('pac ' + ($Arguments -join ' '))
    Write-Log -Level DEBUG -Message $display
    if (-not $Quiet) { Write-Host "      > $display" -ForegroundColor DarkGray }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& pac @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    $text = Hide-CeSecret ($lines -join "`n")
    Write-Log -Level DEBUG -Message $text
    if (-not $Quiet) { foreach ($line in $lines) { if ($line.Trim()) { Write-Host "        $(Hide-CeSecret $line)" -ForegroundColor DarkGray } } }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Text = $text }
}

function Test-CePacReady {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) { return $false }
    $result = Invoke-Pac -Arguments @('help') -Quiet
    return ($result.ExitCode -eq 0 -and $result.Text -match 'Version')
}

function Get-CePacVersion {
    $result = Invoke-Pac -Arguments @('help') -Quiet
    if ($result.Text -match 'Version:\s*([0-9][0-9.]+\S*)') { return $Matches[1] }
    return 'unknown'
}

function Install-CePac {
    <# Uses the .NET tool when the .NET SDK is present, otherwise winget, otherwise the MSI. #>
    param([Parameter(Mandatory)][psobject]$Config)
    # Native tools write progress to stderr; on Windows PowerShell 5.1 that must not stop the script.
    $ErrorActionPreference = 'Continue'
    Update-CePath
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    $isDotnetTool = $false
    if ($dotnet) {
        $list = & dotnet tool list --global 2>$null
        $isDotnetTool = [bool]($list | Select-String -SimpleMatch $Config.pacCli.dotnetToolId)
    }

    if (Test-CePacReady) {
        Write-Log -Level ACTION -Message 'pac is installed; updating it to the latest version'
        if ($isDotnetTool) { & dotnet tool update --global $Config.pacCli.dotnetToolId 2>&1 | Out-Null }
        else { Invoke-Pac -Arguments @('install', 'latest') -Quiet | Out-Null }
        Update-CePath
        Write-Log -Level OK -Message "pac $(Get-CePacVersion)"
        return
    }

    if ($dotnet) {
        Write-Log -Level ACTION -Message 'Installing pac as a .NET tool'
        & dotnet tool install --global $Config.pacCli.dotnetToolId 2>&1 | Out-Null
        Update-CePath
        if (Test-CePacReady) { Write-Log -Level OK -Message "pac $(Get-CePacVersion) installed"; return }
        Write-Log -Level WARN -Message 'The .NET tool install did not work; trying winget'
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Log -Level ACTION -Message "Installing pac with winget ($($Config.pacCli.wingetId))"
        & winget install --id $Config.pacCli.wingetId --exact --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null
        Update-CePath
        # The winget and MSI packages install a launcher; this fetches the CLI itself.
        if ((Get-Command pac -ErrorAction SilentlyContinue) -and -not (Test-CePacReady)) { Invoke-Pac -Arguments @('install', 'latest') -Quiet | Out-Null }
        if (Test-CePacReady) { Write-Log -Level OK -Message "pac $(Get-CePacVersion) installed"; return }
        Write-Log -Level WARN -Message 'winget did not install pac; trying the MSI'
    }

    $staging = [System.Environment]::ExpandEnvironmentVariables($Config.paths.stagingDir)
    if (-not (Test-Path $staging)) { New-Item -ItemType Directory -Path $staging -Force | Out-Null }
    $msi = Join-Path $staging 'PowerAppsCLI.msi'
    Write-Log -Level ACTION -Message "Downloading the pac MSI from $($Config.pacCli.msiUrl)"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Config.pacCli.msiUrl -OutFile $msi -UseBasicParsing -ErrorAction Stop
    $process = Start-Process msiexec -ArgumentList @('/i', "`"$msi`"", '/quiet', '/norestart') -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw "The pac MSI failed with exit code $($process.ExitCode)." }
    Update-CePath
    if ((Get-Command pac -ErrorAction SilentlyContinue) -and -not (Test-CePacReady)) { Invoke-Pac -Arguments @('install', 'latest') -Quiet | Out-Null }
    if (-not (Test-CePacReady)) { throw 'pac still is not available. Install it from https://aka.ms/PowerAppsCLI and re-run.' }
    Write-Log -Level OK -Message "pac $(Get-CePacVersion) installed"
}

function Connect-CePac {
    <# Creates (or refreshes) the bootstrap's pac auth profile and checks admin access. #>
    param(
        [Parameter(Mandatory)][psobject]$Config,
        [Parameter(Mandatory)][ValidateSet('Interactive', 'DeviceCode', 'ServicePrincipal')][string]$Method,
        [string]$TenantId,
        [string]$AppId,
        [string]$ClientSecret
    )
    $name = $Config.pacCli.authProfileName
    Invoke-Pac -Arguments @('telemetry', 'disable') -Quiet | Out-Null
    Invoke-Pac -Arguments @('auth', 'delete', '--name', $name) -Quiet | Out-Null

    $arguments = @('auth', 'create', '--name', $name)
    switch ($Method) {
        'DeviceCode' { $arguments += '--deviceCode' }
        'ServicePrincipal' { $arguments += @('--applicationId', $AppId, '--clientSecret', $ClientSecret, '--tenant', $TenantId) }
    }
    if ($Method -eq 'Interactive') { Write-Log -Level INFO -Message 'A browser window opens: sign in with your Power Platform admin account.' }
    if ($Method -eq 'DeviceCode') { Write-Log -Level INFO -Message 'Open the link shown below on any device and enter the code.' }
    $result = Invoke-Pac -Arguments $arguments
    if ($result.ExitCode -ne 0) { throw 'Sign-in failed. See the pac output above.' }
    Invoke-Pac -Arguments @('auth', 'select', '--name', $name) -Quiet | Out-Null

    $environments = @(Get-CeEnvironmentList)
    Write-Log -Level OK -Message "Signed in. This account can see $($environments.Count) Dataverse environments."
}

# ---------- JSON helpers ----------

function ConvertFrom-CeJsonText {
    <# Finds and parses the JSON part of pac's output (pac sometimes prints text around it). #>
    param([string[]]$Lines)
    $starts = @(for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i].TrimStart() -match '^[\[{]') { $i } }) | Select-Object -First 5
    $ends = @(for ($i = $Lines.Count - 1; $i -ge 0; $i--) { if ($Lines[$i].TrimEnd() -match '[\]}]$') { $i } }) | Select-Object -First 5
    foreach ($start in $starts) {
        foreach ($end in $ends) {
            if ($end -lt $start) { continue }
            try { return Get-CeJsonItems (($Lines[$start..$end] -join "`n") | ConvertFrom-Json) } catch { }
        }
    }
    throw 'pac returned no JSON that could be read.'
}

function Get-CeJsonItems {
    param($Node)
    if ($null -eq $Node) { return }
    if ($Node -is [System.Array]) { foreach ($item in $Node) { Get-CeJsonItems $item }; return }
    foreach ($wrapper in 'value', 'items', 'Items', 'Value', 'results') {
        $property = $Node.PSObject.Properties[$wrapper]
        if ($property -and ($property.Value -is [System.Array])) { Get-CeJsonItems $property.Value; return }
    }
    $Node
}

function Get-CeStringValues {
    param($Object)
    foreach ($property in $Object.PSObject.Properties) { if ($property.Value -is [string]) { $property.Value } }
}

function Get-CePropertyValue {
    <# First non-empty value among the given property names (ignores case, spaces and underscores). #>
    param($Object, [string[]]$Names)
    $wanted = $Names | ForEach-Object { ($_ -replace '[\s_]', '').ToLowerInvariant() }
    foreach ($property in $Object.PSObject.Properties) {
        $key = ($property.Name -replace '[\s_]', '').ToLowerInvariant()
        if ($wanted -contains $key -and -not [string]::IsNullOrWhiteSpace("$($property.Value)")) { return $property.Value }
    }
    return $null
}

# ---------- Environments ----------

function Get-CeEnvironmentList {
    <# Dataverse environments this account can see: DisplayName, EnvironmentUrl, HostName, EnvironmentId. #>
    $result = Invoke-Pac -Arguments @('admin', 'list', '--json') -Quiet
    if ($result.ExitCode -ne 0) { throw "Couldn't list environments. Does this account have Power Platform admin rights? $($result.Text)" }
    $items = @(ConvertFrom-CeJsonText -Lines $result.Lines)
    foreach ($item in $items) {
        $urls = @(Get-CeStringValues $item | Where-Object { $_ -match '^https://[^/\s]+\.dynamics\.com/?$' })
        if ($urls.Count -eq 0) { continue }
        $url = $urls | Where-Object { $_ -notmatch '\.api\.' } | Select-Object -First 1
        if (-not $url) { $url = $urls[0] }
        [pscustomobject]@{
            DisplayName    = "$(Get-CePropertyValue $item @('DisplayName', 'FriendlyName', 'Name'))"
            EnvironmentUrl = $url.TrimEnd('/') + '/'
            HostName       = ([uri]$url).Host.ToLowerInvariant()
            EnvironmentId  = "$(Get-CePropertyValue $item @('EnvironmentId', 'Id'))"
        }
    }
}

function Find-CeEnvironment {
    param([Parameter(Mandatory)][string]$Domain, [object[]]$Environments)
    if (-not $Environments) { $Environments = @(Get-CeEnvironmentList) }
    $prefix = $Domain.Trim().ToLowerInvariant() + '.'
    return $Environments | Where-Object { $_.HostName.StartsWith($prefix) } | Select-Object -First 1
}

Export-ModuleMember -Function Update-CePath, Invoke-Pac, Test-CePacReady, Get-CePacVersion, Install-CePac, Connect-CePac, ConvertFrom-CeJsonText, Get-CeJsonItems, Get-CeStringValues, Get-CePropertyValue, Get-CeEnvironmentList, Find-CeEnvironment
