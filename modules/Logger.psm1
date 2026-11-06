<#
    Logging for the CE bootstrap: a structured log file, a transcript, phase banners
    with elapsed times, and masking of secrets in everything written.
#>

$script:LogFile = $null
$script:TranscriptFile = $null
$script:Secrets = New-Object System.Collections.Generic.List[string]
$script:Phases = New-Object System.Collections.Generic.List[object]
$script:CurrentPhase = $null

function Initialize-CeLog {
    param([Parameter(Mandatory)][string]$Directory)
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $Directory "CeBootstrap-$stamp.log"
    $script:TranscriptFile = Join-Path $Directory "CeBootstrap-$stamp.transcript.txt"
    try { Start-Transcript -Path $script:TranscriptFile -Force | Out-Null } catch { $script:TranscriptFile = $null }
    Write-Log -Level INFO -Message "Log: $($script:LogFile)"
    Write-Log -Level DEBUG -Message ("Machine {0}, user {1}, PowerShell {2}, {3}" -f $env:COMPUTERNAME, $env:USERNAME, $PSVersionTable.PSVersion, [System.Environment]::OSVersion.VersionString)
}

function Register-CeSecret {
    param([string]$Value)
    if (-not [string]::IsNullOrEmpty($Value) -and $Value.Length -ge 4) { $script:Secrets.Add($Value) }
}

function Hide-CeSecret {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    foreach ($secret in $script:Secrets) { $Text = $Text.Replace($secret, '********') }
    return $Text
}

function Write-Log {
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'ACTION', 'SKIP', 'DEBUG')]
        [string]$Level = 'INFO',
        [string]$Message
    )
    $Message = Hide-CeSecret $Message
    if ($script:LogFile) {
        $line = '{0} [{1,-6}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    }
    if ($Level -eq 'DEBUG') { return }
    $colour = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; ACTION = 'Cyan'; SKIP = 'DarkGray' }[$Level]
    $tag = @{ INFO = '   '; OK = ' OK'; WARN = ' !!'; ERROR = ' XX'; ACTION = ' >>'; SKIP = ' --' }[$Level]
    Write-Host "  $tag $Message" -ForegroundColor $colour
}

function Write-PhaseStart {
    param([Parameter(Mandatory)][string]$Number, [Parameter(Mandatory)][string]$Title)
    $script:CurrentPhase = [pscustomobject]@{ Number = $Number; Title = $Title; Started = Get-Date; Status = 'Running'; Elapsed = ''; Note = '' }
    Write-Host ''
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkCyan
    Write-Host "   Phase $Number  $Title" -ForegroundColor White
    Write-Host ('  ' + ('=' * 66)) -ForegroundColor DarkCyan
    Write-Log -Level DEBUG -Message "PHASE $Number START: $Title"
}

function Write-PhaseEnd {
    param([ValidateSet('OK', 'WARN', 'SKIP', 'ERROR')][string]$Status = 'OK', [string]$Note = '')
    if (-not $script:CurrentPhase) { return }
    $elapsed = (Get-Date) - $script:CurrentPhase.Started
    $script:CurrentPhase.Status = $Status
    $script:CurrentPhase.Elapsed = Format-CeElapsed $elapsed
    $script:CurrentPhase.Note = $Note
    $script:Phases.Add($script:CurrentPhase)
    Write-Log -Level DEBUG -Message "PHASE $($script:CurrentPhase.Number) END: $Status after $($script:CurrentPhase.Elapsed) $Note"
    $script:CurrentPhase = $null
}

function Format-CeElapsed {
    param([TimeSpan]$Span)
    if ($Span.TotalHours -ge 1) { return '{0}h {1:00}m' -f [math]::Floor($Span.TotalHours), $Span.Minutes }
    if ($Span.TotalMinutes -ge 1) { return '{0}m {1:00}s' -f [math]::Floor($Span.TotalMinutes), $Span.Seconds }
    return '{0}s' -f [math]::Round($Span.TotalSeconds)
}

function Write-CeSummary {
    Write-Host ''
    Write-Host '  Summary' -ForegroundColor White
    Write-Host '  -------' -ForegroundColor White
    foreach ($phase in $script:Phases) {
        $colour = @{ OK = 'Green'; WARN = 'Yellow'; SKIP = 'DarkGray'; ERROR = 'Red' }[$phase.Status]
        $text = '  {0,-4} {1,-34} {2,-6} {3,8}  {4}' -f $phase.Number, $phase.Title, $phase.Status, $phase.Elapsed, $phase.Note
        Write-Host $text -ForegroundColor $colour
        Write-Log -Level DEBUG -Message "SUMMARY $text"
    }
}

function Get-CeLogPath { return $script:LogFile }

function Stop-CeLog {
    if ($script:TranscriptFile) { try { Stop-Transcript | Out-Null } catch { } }
}

Export-ModuleMember -Function Initialize-CeLog, Register-CeSecret, Hide-CeSecret, Write-Log, Write-PhaseStart, Write-PhaseEnd, Format-CeElapsed, Write-CeSummary, Get-CeLogPath, Stop-CeLog
