<#
    Shared helper functions used by Export-OktaWebApps.ps1 and Import-OktaWebApps.ps1.
    You do not run this file yourself. The other scripts load it automatically.
#>

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    [OK]   $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
}

# Loads the Okta.PowerShell module. Prefers the copy in this repository (../src/Okta.PowerShell)
# and falls back to a copy installed from the PowerShell Gallery.
function Import-OktaModuleForMigration {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw ("These scripts need PowerShell 7 or newer. You are running PowerShell $($PSVersionTable.PSVersion). " +
               "Open 'PowerShell 7' (pwsh), not 'Windows PowerShell'. See migration-work.md, step 1.")
    }

    $repoModule = Join-Path $PSScriptRoot '..' 'src' 'Okta.PowerShell' 'Okta.PowerShell.psd1'
    if (Test-Path $repoModule) {
        Import-Module $repoModule -Force -ErrorAction Stop -Verbose:$false
        Write-Ok "Loaded Okta.PowerShell module from this repository."
    }
    elseif (Get-Module -ListAvailable -Name Okta.PowerShell) {
        Import-Module Okta.PowerShell -Force -ErrorAction Stop -Verbose:$false
        Write-Ok "Loaded Okta.PowerShell module from the PowerShell Gallery install."
    }
    else {
        throw ("The Okta.PowerShell module was not found. Either run these scripts from inside the " +
               "okta-powershell-cli-fork folder, or run: Install-Module Okta.PowerShell -Scope CurrentUser")
    }
}

# Turns "https://acme-admin.okta.com/" into "https://acme.okta.com".
function Get-NormalizedOrgUrl {
    param([Parameter(Mandatory)][string]$OrgUrl)

    $url = $OrgUrl.Trim().TrimEnd('/')
    if ($url -notmatch '^https://') {
        throw "The org URL must start with https:// (you entered '$OrgUrl')."
    }
    $uri = [System.Uri]$url
    $hostName = $uri.Host -replace '-admin\.', '.'
    return "https://$hostName"
}

# Asks Okta whether an org runs Identity Engine ("idx") or Classic Engine ("v1").
# This endpoint is public and needs no sign-in.
function Get-OktaOrgEngine {
    param([Parameter(Mandatory)][string]$OrgUrl)

    try {
        $info = Invoke-RestMethod -Uri "$OrgUrl/.well-known/okta-organization" -Method Get -ErrorAction Stop
        switch ($info.pipeline) {
            'idx' { return 'IdentityEngine' }
            'v1'  { return 'Classic' }
            default { return 'Unknown' }
        }
    }
    catch {
        return 'Unknown'
    }
}

# Signs in to an Okta org using either an API token or the browser (device authorization) flow.
function Connect-OktaOrg {
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [ValidateSet('ApiToken', 'Browser')][string]$AuthMethod = 'ApiToken',
        [string]$ApiTokenEnvVar,
        [string]$ClientId,
        [string[]]$Scopes
    )

    Set-OktaConfiguration -BaseUrl $OrgUrl
    $config = Get-OktaConfiguration

    # Retry automatically (up to 3 times) when Okta says "too many requests" (HTTP 429).
    $config.MaxRetries = 3
    $config.RequestTimeout = 120000
    # Clear any sign-in left over from a previous run in this PowerShell window.
    $config.ApiKey = @{}
    $config.AccessToken = $null

    if ($AuthMethod -eq 'ApiToken') {
        $token = $null
        if ($ApiTokenEnvVar) {
            $token = [Environment]::GetEnvironmentVariable($ApiTokenEnvVar)
        }
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-Host ""
            Write-Host "    Paste the API token for $OrgUrl and press Enter." -ForegroundColor White
            Write-Host "    (Nothing is shown on screen while you paste. That is normal.)" -ForegroundColor DarkGray
            $secure = Read-Host -Prompt "    API token" -AsSecureString
            $token = [System.Net.NetworkCredential]::new('', $secure).Password
        }
        else {
            Write-Ok "Using the API token stored in the environment variable `$env:$ApiTokenEnvVar."
        }
        if ([string]::IsNullOrWhiteSpace($token)) {
            throw "No API token was provided."
        }
        $config.ApiKey = @{ apiToken = $token.Trim() }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            throw "Browser sign-in needs -ClientId (the Client ID of the 'Okta PowerShell CLI' app in $OrgUrl). See migration-work.md."
        }
        $config.ClientId = $ClientId
        # Set the scope directly. The module adds "openid" itself.
        $config.Scope = ($Scopes -join ' ')
        Invoke-OktaEstablishAccessToken
        if ([string]::IsNullOrWhiteSpace((Get-OktaConfiguration).AccessToken)) {
            throw "Browser sign-in did not complete, so no access token was received."
        }
    }

    # Prove the sign-in works with a harmless read request.
    try {
        $null = Invoke-OktaListApplications -Limit 1
        Write-Ok "Signed in to $OrgUrl."
    }
    catch {
        throw "Could not sign in to $OrgUrl : $(Get-OktaErrorText $_)"
    }
}

# Turns an error from the Okta module into a short, readable message.
function Get-OktaErrorText {
    param($ErrorRecord)

    $ex = $ErrorRecord.Exception
    if ($ex.GetType().Name -eq 'OktaApiException') {
        $text = "HTTP $([int]$ex.StatusCode)"
        if ($ex.ErrorSummary) { $text += " - $($ex.ErrorSummary)" }
        if ($ex.ErrorCauses) {
            $causes = @($ex.ErrorCauses | ForEach-Object { $_.errorSummary }) -join '; '
            if ($causes) { $text += " ($causes)" }
        }
        if ([int]$ex.StatusCode -eq 401) { $text += ". The API token or sign-in is not valid for this org." }
        if ([int]$ex.StatusCode -eq 403) { $text += ". Your admin account does not have permission for this." }
        return $text
    }
    return $ex.Message
}

# Calls an Okta "list" command and follows the "next page" links until every item has been read.
# Example: Get-OktaAllPages { param($u) if ($u) { Invoke-OktaListGroups -Uri $u -WithHttpInfo } else { Invoke-OktaListGroups -Limit 200 -WithHttpInfo } }
function Get-OktaAllPages {
    param([Parameter(Mandatory)][scriptblock]$Call)

    $all = [System.Collections.Generic.List[object]]::new()
    $next = $null
    $pages = 0
    do {
        $result = & $Call $next
        foreach ($item in @($result.Response)) {
            if ($null -ne $item) { $all.Add($item) }
        }
        $newNext = $null
        if ($result.ContainsKey('NextPageUri')) { $newNext = $result.NextPageUri }
        # Stop if Okta hands back the same link again, so we can never loop forever.
        if ($newNext -and $newNext -eq $next) { break }
        $next = $newNext
        $pages++
    } while ($next -and $pages -lt 1000)

    return , $all.ToArray()
}

# Reads the org's apps, asking Okta for OpenID Connect apps only. Some orgs reject that filter
# with "HTTP 400 - Invalid search criteria"; then every app is read instead. Callers must still
# check each app's name and status, because the result can include non-OIDC apps.
function Get-OktaOidcAppList {
    foreach ($filter in @('name eq "oidc_client"', $null)) {
        try {
            if ($filter) { Write-Verbose "Listing apps with filter: $filter" } else { Write-Verbose "Listing all apps (no filter)" }
            $apps = Get-OktaAllPages {
                param($next)
                if ($next) { Invoke-OktaListApplications -Uri $next -WithHttpInfo }
                elseif ($filter) { Invoke-OktaListApplications -Filter $filter -Limit 200 -WithHttpInfo }
                else { Invoke-OktaListApplications -Limit 200 -WithHttpInfo }
            }
            return , $apps
        }
        catch {
            $isBadFilter = $_.Exception.GetType().Name -eq 'OktaApiException' -and [int]$_.Exception.StatusCode -eq 400
            if (-not ($filter -and $isBadFilter)) { throw }
            Write-Warn "Okta did not accept the filter '$filter' ($(Get-OktaErrorText $_)). Reading all apps instead; this is slower but gives the same result."
        }
    }
}

# Returns a property value, or $null when the property does not exist.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Makes a deep copy of an object by round-tripping it through JSON.
function Copy-DeepObject {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    return ($InputObject | ConvertTo-Json -Depth 50 | ConvertFrom-Json)
}
