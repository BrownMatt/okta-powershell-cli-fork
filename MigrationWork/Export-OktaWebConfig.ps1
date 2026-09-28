<#
.SYNOPSIS
    Reads OIDC "Web" apps from an Okta org and writes a web.<label>.config file for each one.

.DESCRIPTION
    This script only READS from Okta. It never changes anything in the org.

    For every Web app whose label matches -Label, it writes a file named
    web.<label>.config to the output folder. Spaces and characters that can't be used in a
    file name become _, so "LHA_DQMP LocalHost" becomes web.LHA_DQMP_LocalHost.config.

    Each file contains an <appSettings> section with:
      okta:ClientId               the app's Client ID
      okta:ClientSecret           the app's newest active client secret
      okta:OrgUri                 the org URL, e.g. https://yourcompany.okta.com
      okta:RedirectUri            the app's first sign-in redirect URI
      okta:PostLogoutRedirectUri  the app's first sign-out redirect URI
      okta:APIkey                 the API token this script signed in with
      oktaAPIuri                  the org URL
    If an app has more than one redirect URI, the others are listed as comments under the
    setting, so they can be swapped in.

    WARNING: the files contain a client secret and the API token in plain text. Anyone who can
    read a file can use that token with all of your admin rights. Keep the files out of source
    control and delete them when you're done. The default "exports" folder is ignored by git.

    Existing files with the same name are overwritten, so running the script again picks up
    changes made in Okta, such as a rotated secret.

.PARAMETER OrgUrl
    The Okta org to read from, e.g. https://yourcompany.oktapreview.com

.PARAMETER Label
    The app label(s) to write files for. * is a wildcard. Examples:
      -Label "LHA_DQMP LocalHost"
      -Label "LHA_*"
      -Label "Payroll", "HR Portal"

.PARAMETER AuthMethod
    ApiToken (default) - you paste an Okta API token. That token is also written to okta:APIkey.
    Browser            - you sign in through your web browser (needs -ClientId). There's no API
                         token in that case, so okta:APIkey gets a placeholder you fill in.

.PARAMETER ClientId
    Only for -AuthMethod Browser: the Client ID of the "Okta PowerShell CLI" app in this org.

.PARAMETER ApiTokenEnvVar
    Name of an environment variable that holds the API token. Default: OKTA_TARGET_API_TOKEN
    (the oktapreview token). Use OKTA_SOURCE_API_TOKEN to read from production.
    If the variable is empty you are asked to paste the token instead.

.PARAMETER OutputFolder
    Folder to write the files to. Default: an "exports" folder next to this script.

.PARAMETER IncludeInactive
    Also write files for apps that are deactivated. By default only ACTIVE apps are used.

.EXAMPLE
    ./Export-OktaWebConfig.ps1 -OrgUrl https://yourcompany.oktapreview.com -Label "LHA_DQMP LocalHost"

.EXAMPLE
    ./Export-OktaWebConfig.ps1 -OrgUrl https://yourcompany.oktapreview.com -Label "LHA_*"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OrgUrl,

    [Parameter(Mandatory)]
    [string[]]$Label,

    [ValidateSet('ApiToken', 'Browser')]
    [string]$AuthMethod = 'ApiToken',

    [string]$ClientId,

    [string]$ApiTokenEnvVar = 'OKTA_TARGET_API_TOKEN',

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'exports'),

    [switch]$IncludeInactive
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OktaMigration.Common.ps1')

$ApiKeyPlaceholder = 'REPLACE_WITH_OKTA_API_TOKEN'

# "LHA_DQMP LocalHost" -> "web.LHA_DQMP_LocalHost.config". Uses the same rules on every OS, so a
# file made on a Mac has the same name as one made on Windows.
function Get-WebConfigFileName {
    param([string]$AppLabel)
    $safe = $AppLabel.Trim() -replace '[\s\\/:*?"<>|\x00-\x1F]', '_'
    return "web.$safe.config"
}

# The Authorization header for calls this script makes itself (the module has no command for
# reading client secrets).
function Get-OktaAuthHeader {
    $config = Get-OktaConfiguration
    if ($config.ApiKey -and $config.ApiKey['apiToken']) { return @{ Authorization = "SSWS $($config.ApiKey['apiToken'])" } }
    return @{ Authorization = "Bearer $($config.AccessToken)" }
}

# Returns the app's newest ACTIVE client secret, or $null when it has none.
function Get-AppClientSecret {
    param($App)

    try {
        $secrets = @(Invoke-RestMethod -Method Get -Uri "$OrgUrl/api/v1/apps/$($App.id)/credentials/secrets" `
            -Headers (Get-OktaAuthHeader) -ErrorAction Stop)
        $newest = $secrets | Where-Object { $_.status -eq 'ACTIVE' -and $_.client_secret } |
            Sort-Object { [datetime]$_.created } -Descending | Select-Object -First 1
        if ($newest) { return $newest.client_secret }
    }
    catch {
        Write-Verbose "Could not list client secrets for '$($App.label)': $($_.Exception.Message)"
    }

    # Older orgs return the secret with the app itself.
    $secret = Get-Prop (Get-Prop $App.credentials 'oauthClient') 'client_secret'
    if (-not $secret) {
        try { $secret = Get-Prop (Get-OktaApplication -AppId $App.id).credentials.oauthClient 'client_secret' }
        catch { Write-Verbose "Could not read '$($App.label)' again: $(Get-OktaErrorText $_)" }
    }
    return $secret
}

# Writes the <add key=... /> line, followed by the other values as commented-out lines.
function Write-AppSetting {
    param([System.Xml.XmlWriter]$Writer, [string]$Key, [string[]]$Values, [string]$OthersLabel)

    $Writer.WriteStartElement('add')
    $Writer.WriteAttributeString('key', $Key)
    $Writer.WriteAttributeString('value', [string]($Values | Select-Object -First 1))
    $Writer.WriteEndElement()

    $others = @($Values | Select-Object -Skip 1)
    if ($others.Count -gt 0) {
        $Writer.WriteComment(" $OthersLabel ")
        foreach ($value in $others) {
            # "--" is not allowed inside an XML comment.
            $escaped = [System.Security.SecurityElement]::Escape($value) -replace '--', '-&#45;'
            $Writer.WriteComment(" <add key=`"$Key`" value=`"$escaped`" /> ")
        }
    }
}

function Write-WebConfigFile {
    param([string]$Path, $App, [string]$Secret, [string]$ApiKey, [string[]]$SignIn, [string[]]$SignOut)

    $settings = [System.Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.Encoding = [System.Text.UTF8Encoding]::new($false)

    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('configuration')
        $writer.WriteComment(" Written by Export-OktaWebConfig.ps1 from $OrgUrl on $(Get-Date -Format 'yyyy-MM-dd HH:mm') for the app '$($App.label -replace '--', '- -')' ($($App.id)). ")
        $writer.WriteComment(' This file contains a client secret and an Okta API token. Do not commit it to source control. ')
        $writer.WriteStartElement('appSettings')

        Write-AppSetting $writer 'okta:ClientId' @($App.credentials.oauthClient.client_id)
        Write-AppSetting $writer 'okta:ClientSecret' @($Secret)
        Write-AppSetting $writer 'okta:OrgUri' @($OrgUrl)
        Write-AppSetting $writer 'okta:RedirectUri' $SignIn 'Other sign-in redirect URIs for this app:'
        Write-AppSetting $writer 'okta:PostLogoutRedirectUri' $SignOut 'Other sign-out redirect URIs for this app:'
        $writer.WriteComment(' api key is same API key powershell script uses ')
        Write-AppSetting $writer 'okta:APIkey' @($ApiKey)
        Write-AppSetting $writer 'oktaAPIuri' @($OrgUrl)

        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Dispose()
    }
}

$failed = 0
try {
    $OrgUrl = Get-NormalizedOrgUrl $OrgUrl

    Write-Step "Loading the Okta PowerShell module"
    Import-OktaModuleForMigration

    Write-Step "Signing in to $OrgUrl"
    Connect-OktaOrg -OrgUrl $OrgUrl -AuthMethod $AuthMethod -ApiTokenEnvVar $ApiTokenEnvVar -ClientId $ClientId `
        -Scopes @('okta.apps.read')

    $config = Get-OktaConfiguration
    $apiKey = if ($config.ApiKey -and $config.ApiKey['apiToken']) { $config.ApiKey['apiToken'] } else { $null }
    if (-not $apiKey) {
        Write-Warn "You signed in through the browser, so there is no API token to write. okta:APIkey will be '$ApiKeyPlaceholder'."
        $apiKey = $ApiKeyPlaceholder
    }

    Write-Step "Finding Web apps matching $(($Label | ForEach-Object { "'$_'" }) -join ', ')"
    $allApps = Get-OktaOidcAppList
    $apps = @($allApps | Where-Object {
        $app = $_
        $app.name -eq 'oidc_client' -and
        ($IncludeInactive -or $app.status -eq 'ACTIVE') -and
        (Get-Prop (Get-Prop $app.settings 'oauthClient') 'application_type') -eq 'web' -and
        @($Label | Where-Object { $app.label -like $_ }).Count -gt 0
    } | Sort-Object label)

    if ($apps.Count -eq 0) {
        $statusText = if ($IncludeInactive) { '' } else { 'active ' }
        throw "No ${statusText}OpenID Connect Web app in $OrgUrl has a label matching $($Label -join ', '). Check the spelling, or add -IncludeInactive if the app is deactivated."
    }
    Write-Ok "Found $($apps.Count) app(s)."

    Write-Step "Writing web.config files"
    if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
    $usedNames = @{}

    foreach ($app in $apps) {
        try {
            $fileName = Get-WebConfigFileName $app.label
            if ($usedNames.ContainsKey($fileName.ToLowerInvariant())) {
                $fileName = ($fileName -replace '\.config$', '') + "_$($app.id).config"
                Write-Warn "Another app gets the same file name as '$($app.label)', so its file name includes the app ID: $fileName"
            }
            $usedNames[$fileName.ToLowerInvariant()] = $true

            $oauth = $app.settings.oauthClient
            $signIn = @(Get-Prop $oauth 'redirect_uris' | Where-Object { $_ })
            $signOut = @(Get-Prop $oauth 'post_logout_redirect_uris' | Where-Object { $_ })

            $secret = Get-AppClientSecret $app
            if (-not $secret) {
                $clientAuth = $app.credentials.oauthClient.token_endpoint_auth_method
                Write-Warn "'$($app.label)' has no client secret (client authentication: $clientAuth). okta:ClientSecret will be empty."
            }
            if ($signIn.Count -eq 0) { Write-Warn "'$($app.label)' has no sign-in redirect URI. okta:RedirectUri will be empty." }
            if ($signOut.Count -eq 0) { Write-Warn "'$($app.label)' has no sign-out redirect URI. okta:PostLogoutRedirectUri will be empty." }

            $path = Join-Path $OutputFolder $fileName
            Write-WebConfigFile -Path $path -App $app -Secret $secret -ApiKey $apiKey -SignIn $signIn -SignOut $signOut
            Write-Ok "$($app.label)  ->  $path"
        }
        catch {
            $failed++
            Write-Fail "$($app.label): $(Get-OktaErrorText $_)"
        }
    }

    Write-Host ""
    Write-Host "Done. Wrote $($apps.Count - $failed) web.config file(s) to $OutputFolder" -ForegroundColor Green
    Write-Host "These files contain a client secret and the API token. Don't commit them, and delete them when you're done." -ForegroundColor Yellow
}
catch {
    Write-Host ""
    Write-Fail "Stopped: $(Get-OktaErrorText $_)"
    exit 1
}
if ($failed -gt 0) { exit 1 }
