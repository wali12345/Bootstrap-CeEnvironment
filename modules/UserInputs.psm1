<#
    Prompt helpers. Every helper first checks whether the value was passed as a
    script parameter, so anything given on the command line isn't asked for.
#>

function Test-CeSupplied {
    param([hashtable]$Bound, [string]$Name)
    return ($Bound -and $Bound.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace("$($Bound[$Name])"))
}

function Read-CeValue {
    param(
        [hashtable]$Bound,
        [string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [string]$Default = '',
        [switch]$Required,
        [string]$Pattern,
        [string]$PatternMessage = 'That value is not valid.'
    )
    $fromParameter = Test-CeSupplied $Bound $Name
    $value = if ($fromParameter) { "$($Bound[$Name])" } else { Read-CeLine $Prompt $Default }
    while ($true) {
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $Default }
        if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
            Write-Host '      A value is needed here.' -ForegroundColor Yellow
        }
        elseif ($Pattern -and -not [string]::IsNullOrWhiteSpace($value) -and $value -notmatch $Pattern) {
            Write-Host "      $PatternMessage" -ForegroundColor Yellow
        }
        else { break }
        $value = Read-CeLine $Prompt $Default
    }
    return $value.Trim()
}

function Read-CeLine {
    param([string]$Prompt, [string]$Default)
    $shown = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
    return (Read-Host "  $Prompt$shown")
}

function Read-CeChoice {
    param(
        [hashtable]$Bound,
        [string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [string]$Default
    )
    if (Test-CeSupplied $Bound $Name) {
        $supplied = "$($Bound[$Name])"
        $match = $Choices | Where-Object { $_ -eq $supplied } | Select-Object -First 1
        if ($match) { return $match }
        Write-Host "      '$supplied' isn't one of: $($Choices -join ', ')" -ForegroundColor Yellow
    }
    if (-not $Default) { $Default = $Choices[0] }
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor White
    for ($i = 0; $i -lt $Choices.Count; $i++) {
        $mark = if ($Choices[$i] -eq $Default) { '  (default)' } else { '' }
        Write-Host ("    [{0}] {1}{2}" -f ($i + 1), $Choices[$i], $mark) -ForegroundColor Gray
    }
    while ($true) {
        $raw = Read-Host "  Choose 1-$($Choices.Count) (Enter for default)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        $number = 0
        if ([int]::TryParse($raw, [ref]$number) -and $number -ge 1 -and $number -le $Choices.Count) { return $Choices[$number - 1] }
        $match = $Choices | Where-Object { $_ -eq $raw.Trim() } | Select-Object -First 1
        if ($match) { return $match }
        Write-Host "      Enter a number from 1 to $($Choices.Count)." -ForegroundColor Yellow
    }
}

function Read-CeMultiChoice {
    <# Numbered list; the user types numbers separated by commas. Can allow extra typed values. #>
    param(
        [hashtable]$Bound,
        [string]$Name,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][object[]]$Items,      # objects with Value and Label
        [string[]]$Defaults = @(),
        [switch]$AllowOther,
        [switch]$AllowNone
    )
    if (Test-CeSupplied $Bound $Name) {
        return @("$($Bound[$Name])" -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'none' })
    }
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor White
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($Defaults -contains $Items[$i].Value) { '  (default)' } else { '' }
        Write-Host ("    [{0}] {1}{2}" -f ($i + 1), $Items[$i].Label, $mark) -ForegroundColor Gray
    }
    $hint = 'Numbers separated by commas, Enter for the defaults'
    if ($AllowOther) { $hint += ', or type a name' }
    if ($AllowNone) { $hint += ", or 'none'" }
    while ($true) {
        $raw = Read-Host "  $hint"
        if ([string]::IsNullOrWhiteSpace($raw)) { return @($Defaults) }
        if ($AllowNone -and $raw.Trim() -eq 'none') { return @() }
        $picked = New-Object System.Collections.Generic.List[string]
        $bad = $false
        foreach ($part in ($raw -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $number = 0
            if ([int]::TryParse($part, [ref]$number)) {
                if ($number -ge 1 -and $number -le $Items.Count) { $picked.Add($Items[$number - 1].Value) } else { $bad = $true }
            }
            elseif ($AllowOther) { $picked.Add($part) }
            else { $bad = $true }
        }
        if (-not $bad -and ($picked.Count -gt 0 -or $AllowNone)) { return @($picked | Select-Object -Unique) }
        Write-Host "      Use the numbers 1 to $($Items.Count)." -ForegroundColor Yellow
    }
}

function Read-CeYesNo {
    param([hashtable]$Bound, [string]$Name, [Parameter(Mandatory)][string]$Prompt, [bool]$Default = $true)
    if (Test-CeSupplied $Bound $Name) { return ("$($Bound[$Name])" -match '^(y|yes|true|1)$') }
    $shown = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $raw = Read-Host "  $Prompt ($shown)"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -match '^(y|yes)$') { return $true }
        if ($raw -match '^(n|no)$') { return $false }
    }
}

function Read-CeSecret {
    param([hashtable]$Bound, [string]$Name, [Parameter(Mandatory)][string]$Prompt)
    if (Test-CeSupplied $Bound $Name) { $value = "$($Bound[$Name])" }
    else {
        $secure = Read-Host "  $Prompt" -AsSecureString
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $value = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    Register-CeSecret $value
    return $value
}

function ConvertTo-CeDomain {
    <# Suggests a domain from a display name: CONTOSO-DEV01 becomes contoso-dev01. #>
    param([string]$DisplayName)
    $domain = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9-]', '-' -replace '-{2,}', '-').Trim('-')
    if ($domain.Length -gt 63) { $domain = $domain.Substring(0, 63).Trim('-') }
    return $domain
}

Export-ModuleMember -Function Read-CeValue, Read-CeChoice, Read-CeMultiChoice, Read-CeYesNo, Read-CeSecret, ConvertTo-CeDomain, Test-CeSupplied
