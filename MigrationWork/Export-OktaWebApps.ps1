<#
.SYNOPSIS
    Exports the OIDC "Web" applications from an Okta org (for example production) to a JSON file.

.DESCRIPTION
    This script only READS from Okta. It never changes anything in the org you export from.

    It finds every OpenID Connect app whose application type is "Web", and saves everything
    needed to rebuild the app in another org:
      - name, label, status
      - sign-in redirect URIs and sign-out redirect URIs
      - grant types, response types, client authentication method, PKCE, consent, issuer mode,
        initiate login URI, logo/policy/terms URIs, public keys (JWKS)
      - app visibility and accessibility settings, admin/end-user notes
      - the authentication policy the app uses (Identity Engine orgs)
      - the groups assigned to the app
    It also keeps a full copy of the original app ("raw") for reference.

    Two files are written to the output folder:
      okta-web-apps-<org>-<date>.json   <- give this file to Import-OktaWebApps.ps1
      okta-web-apps-<org>-<date>.csv    <- a summary you can open in Excel

.PARAMETER OrgUrl
    The Okta org to export from, e.g. https://yourcompany.okta.com

.PARAMETER AuthMethod
    ApiToken (default) - you paste an Okta API token.
    Browser            - you sign in through your web browser (needs -ClientId, see migration-work.md).

.PARAMETER ClientId
    Only for -AuthMethod Browser: the Client ID of the "Okta PowerShell CLI" app in this org.

.PARAMETER ApiTokenEnvVar
    Name of an environment variable that holds the API token. Default: OKTA_SOURCE_API_TOKEN.
    If the variable is empty you are asked to paste the token instead.

.PARAMETER OutputFolder
    Folder to write the export to. Default: an "exports" folder next to this script.

.PARAMETER IncludeInactive
    Also export apps that are deactivated. By default only ACTIVE apps are exported.

.PARAMETER RequireBothRedirectTypes
    Only export apps that have at least one sign-in redirect URI AND at least one sign-out redirect URI.

.PARAMETER LabelFilter
    Only export apps whose label matches this pattern. * is a wildcard. Example: "HR*"

.EXAMPLE
    ./Export-OktaWebApps.ps1 -OrgUrl https://yourcompany.okta.com

.EXAMPLE
    ./Export-OktaWebApps.ps1 -OrgUrl https://yourcompany.okta.com -RequireBothRedirectTypes -LabelFilter "Payroll*"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OrgUrl,

    [ValidateSet('ApiToken', 'Browser')]
    [string]$AuthMethod = 'ApiToken',

    [string]$ClientId,

    [string]$ApiTokenEnvVar = 'OKTA_SOURCE_API_TOKEN',

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'exports'),

    [switch]$IncludeInactive,

    [switch]$RequireBothRedirectTypes,

    [string]$LabelFilter = '*'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OktaMigration.Common.ps1')

# Builds the part of the app that Okta needs to create a copy of it.
# Anything Okta generates itself (ids, dates, links, secrets, signing keys) is left out.
function ConvertTo-AppDefinition {
    param($App)

    $settings = Get-Prop $App 'settings'
    $oauthSettings = Copy-DeepObject (Get-Prop $settings 'oauthClient')

    $creds = Get-Prop (Get-Prop $App 'credentials') 'oauthClient'
    $credOut = [ordered]@{}
    foreach ($name in 'token_endpoint_auth_method', 'pkce_required', 'autoKeyRotation', 'client_id') {
        $value = Get-Prop $creds $name
        if ($null -ne $value) { $credOut[$name] = $value }
    }

    $settingsOut = [ordered]@{ oauthClient = $oauthSettings }
    foreach ($name in 'app', 'notes') {
        $value = Get-Prop $settings $name
        if ($null -ne $value) { $settingsOut[$name] = Copy-DeepObject $value }
    }

    $def = [ordered]@{
        name        = $App.name
        label       = $App.label
        signOnMode  = $App.signOnMode
        credentials = [ordered]@{ oauthClient = $credOut }
        settings    = $settingsOut
    }
    foreach ($name in 'visibility', 'accessibility', 'profile') {
        $value = Get-Prop $App $name
        if ($null -ne $value) { $def[$name] = Copy-DeepObject $value }
    }
    return $def
}

try {
    $OrgUrl = Get-NormalizedOrgUrl $OrgUrl

    Write-Step "Loading the Okta PowerShell module"
    Import-OktaModuleForMigration

    Write-Step "Checking $OrgUrl"
    $engine = Get-OktaOrgEngine $OrgUrl
    Write-Ok "Org engine: $engine"

    Write-Step "Signing in to $OrgUrl"
    Connect-OktaOrg -OrgUrl $OrgUrl -AuthMethod $AuthMethod -ApiTokenEnvVar $ApiTokenEnvVar -ClientId $ClientId `
        -Scopes @('okta.apps.read', 'okta.groups.read', 'okta.policies.read')

    Write-Step "Reading OpenID Connect apps"
    $allApps = Get-OktaOidcAppList
    $oidcApps = @($allApps | Where-Object {
        $_.name -eq 'oidc_client' -and ($IncludeInactive -or $_.status -eq 'ACTIVE')
    })
    $statusText = if ($IncludeInactive) { 'active or inactive' } else { 'active' }
    Write-Ok "Read $($allApps.Count) app(s); $($oidcApps.Count) of them are $statusText OpenID Connect apps."

    $webApps = @($oidcApps | Where-Object {
        (Get-Prop (Get-Prop $_.settings 'oauthClient') 'application_type') -eq 'web' -and $_.label -like $LabelFilter
    })
    Write-Ok "$($webApps.Count) of them are Web apps matching label '$LabelFilter'."

    $policyNames = @{}
    $exported = [System.Collections.Generic.List[object]]::new()
    $summary = [System.Collections.Generic.List[object]]::new()
    $skippedForRedirects = 0

    Write-Step "Collecting details for each app"
    foreach ($app in $webApps) {
        $oauth = $app.settings.oauthClient
        $signIn = @(Get-Prop $oauth 'redirect_uris' | Where-Object { $_ })
        $signOut = @(Get-Prop $oauth 'post_logout_redirect_uris' | Where-Object { $_ })
        $hasBoth = ($signIn.Count -gt 0 -and $signOut.Count -gt 0)

        if ($RequireBothRedirectTypes -and -not $hasBoth) {
            Write-Warn "Skipping '$($app.label)': it does not have both sign-in and sign-out redirect URIs."
            $skippedForRedirects++
            continue
        }

        # Authentication policy (only Identity Engine orgs have these).
        $policyId = $null
        $policyName = $null
        $links = Get-Prop $app '_links'
        $policyLink = Get-Prop $links 'accessPolicy'
        if ($policyLink -and $policyLink.href) {
            $policyId = ($policyLink.href -split '/')[-1]
            if (-not $policyNames.ContainsKey($policyId)) {
                try { $policyNames[$policyId] = (Get-OktaPolicy -PolicyId $policyId).name }
                catch {
                    Write-Warn "Could not read authentication policy $policyId for '$($app.label)': $(Get-OktaErrorText $_)"
                    $policyNames[$policyId] = $null
                }
            }
            $policyName = $policyNames[$policyId]
        }

        # Group assignments.
        $groups = @()
        try {
            $appId = $app.id
            $assignments = Get-OktaAllPages {
                param($next)
                if ($next) { Invoke-OktaListApplicationGroupAssignments -AppId $appId -Uri $next -WithHttpInfo }
                else { Invoke-OktaListApplicationGroupAssignments -AppId $appId -Limit 200 -Expand 'group' -WithHttpInfo }
            }
            $groups = @($assignments | ForEach-Object {
                $embedded = Get-Prop $_ '_embedded'
                $group = Get-Prop $embedded 'group'
                $name = if ($group) { $group.profile.name } else { $null }
                if (-not $name) {
                    try { $name = (Get-OktaGroup -GroupId $_.id).profile.name } catch { $name = $null }
                }
                [ordered]@{ id = $_.id; name = $name; priority = (Get-Prop $_ 'priority') }
            })
        }
        catch {
            Write-Warn "Could not read group assignments for '$($app.label)': $(Get-OktaErrorText $_)"
        }

        $exported.Add([ordered]@{
            source = [ordered]@{
                id                       = $app.id
                status                   = $app.status
                clientId                 = $app.credentials.oauthClient.client_id
                created                  = $app.created
                lastUpdated              = $app.lastUpdated
                authenticationPolicyId   = $policyId
                authenticationPolicyName = $policyName
                groups                   = $groups
            }
            definition = ConvertTo-AppDefinition $app
            raw        = $app
        })

        $summary.Add([pscustomobject]@{
            Label                    = $app.label
            Status                   = $app.status
            ClientId                 = $app.credentials.oauthClient.client_id
            SignInRedirectUris       = $signIn -join ' | '
            SignOutRedirectUris      = $signOut -join ' | '
            HasBothRedirectTypes     = $hasBoth
            GrantTypes               = @(Get-Prop $oauth 'grant_types') -join ', '
            ClientAuthMethod         = $app.credentials.oauthClient.token_endpoint_auth_method
            AuthenticationPolicy     = $policyName
            Groups                   = @($groups | ForEach-Object { $_.name }) -join ', '
        })
        Write-Ok "$($app.label)  (sign-in URIs: $($signIn.Count), sign-out URIs: $($signOut.Count), groups: $($groups.Count))"
    }

    Write-Step "Writing the export files"
    if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
    $orgName = ([System.Uri]$OrgUrl).Host.Split('.')[0]
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $jsonPath = Join-Path $OutputFolder "okta-web-apps-$orgName-$stamp.json"
    $csvPath = Join-Path $OutputFolder "okta-web-apps-$orgName-$stamp.csv"

    $export = [ordered]@{
        exportFormatVersion = 1
        exportedAt          = (Get-Date).ToUniversalTime().ToString('o')
        sourceOrg           = $OrgUrl
        sourceOrgEngine     = $engine
        appCount            = $exported.Count
        apps                = $exported
    }
    $export | ConvertTo-Json -Depth 50 | Set-Content -Path $jsonPath -Encoding utf8
    $summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8

    Write-Ok "Export file : $jsonPath"
    Write-Ok "Summary CSV : $csvPath"
    Write-Host ""
    Write-Host "Done. Exported $($exported.Count) web app(s)." -ForegroundColor Green
    if ($skippedForRedirects -gt 0) {
        Write-Host "$skippedForRedirects app(s) were skipped because they did not have both redirect URI types." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Fail "Export stopped: $(Get-OktaErrorText $_)"
    exit 1
}
