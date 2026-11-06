<#
    Optional developer tools for working on the CE repo, installed with winget.
    Nothing here is needed to create an environment.
#>

function Install-CeDevTools {
    param([Parameter(Mandatory)][object[]]$Tools)
    $ErrorActionPreference = 'Continue'   # winget writes progress to stderr
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log -Level WARN -Message 'winget is not available, so no tools were installed. Install "App Installer" from the Microsoft Store, then re-run.'
        return @($Tools | ForEach-Object { [pscustomobject]@{ Name = $_.name; Result = 'winget missing' } })
    }
    $results = @()
    foreach ($tool in $Tools) {
        if ($tool.command -and (Get-Command $tool.command -ErrorAction SilentlyContinue)) {
            Write-Log -Level SKIP -Message "$($tool.name) is already installed"
            $results += [pscustomobject]@{ Name = $tool.name; Result = 'Already installed' }
            continue
        }
        Write-Log -Level ACTION -Message "Installing $($tool.name) ($($tool.wingetId))"
        & winget install --id $tool.wingetId --exact --silent --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Log -Level DEBUG -Message "$_" }
        $code = $LASTEXITCODE
        if ($code -eq 0) { Write-Log -Level OK -Message "$($tool.name) installed"; $results += [pscustomobject]@{ Name = $tool.name; Result = 'Installed' } }
        else { Write-Log -Level WARN -Message "winget returned $code for $($tool.name)"; $results += [pscustomobject]@{ Name = $tool.name; Result = "winget exit $code" } }
    }
    Update-CePath
    return $results
}

Export-ModuleMember -Function Install-CeDevTools
