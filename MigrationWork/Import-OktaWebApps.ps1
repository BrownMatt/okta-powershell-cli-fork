<#
.SYNOPSIS
    Creates or updates Okta OIDC web applications in a target org (for example oktapreview) from an
    export made by Export-OktaWebApps.ps1.

.DESCRIPTION
    You can run this script as many times as you like. For every app in the export file it:
      1. Replaces production URLs with test URLs, if you give it a URL map file (optional).
      2. Adds the sign-in flow to the end of the label: "LHA_Dev" becomes "LHA_Dev OIE" with
         -SignInFlow IdentityEngine, or "LHA_Dev Classic" with -SignInFlow Classic.
         Then it looks for an app with that label in the target org.
           - Not found: CREATES the app (Okta generates a new Client ID and client secret).
           - Found:     UPDATES the existing app so its settings match the export. The app keeps its
                        Client ID and client secret. If nothing is different, nothing is changed.
      3. Identity Engine only: makes sure the app uses the right authentication policy.
      4. Optional: adds any groups (matched by group name) that the app had in the source org.

    Always run it with -DryRun first. A dry run signs in and checks everything, and lists exactly
    what it would create or change, but changes nothing.

    A results CSV is written to the output folder, listing each app and what happened to it.

.PARAMETER OrgUrl
    The Okta org to create the apps in, e.g. https://yourcompany.oktapreview.com

.PARAMETER ExportFile
    The .json file created by Export-OktaWebApps.ps1.

.PARAMETER SignInFlow
    IdentityEngine - Set the apps up for Okta Identity Engine: each app is given an authentication
                     policy (see -AuthenticationPolicyName). The target org must be an Identity Engine org.
    Classic        - Set the apps up the Classic way: no authentication policy is assigned, and the
                     Identity-Engine-only "interaction_code" grant type is removed. On an Identity Engine
                     org, Okta then applies its default authentication policy to the app.
    The flow is also added to the end of each app's label in the target org: " OIE" or " Classic".

.PARAMETER ExistingApps
    What to do when an app with the same label already exists in the target org.
    Update (default) - change the existing app so it matches the export.
    Skip             - leave the existing app alone.

.PARAMETER AuthenticationPolicyName
    Identity Engine only. The name of the authentication policy to assign to every app,
    e.g. "Any two factors". If you leave this out, the script uses the policy with the same name
    the app had in the source org, and if that does not exist, leaves the policy as it is
    (new apps get Okta's default policy).

.PARAMETER EnableInteractionCode
    Identity Engine only. Adds the "Interaction Code" grant type to each app. Only use this if the
    app uses Okta's embedded sign-in (Identity Engine SDKs) and your org has Interaction Code enabled.

.PARAMETER UrlMapFile
    A CSV file with two columns, Find and Replace. Every URL in the app that contains a Find value has
    that part replaced. See url-map.sample.csv.

.PARAMETER AssignGroups
    Also assign each app to the groups it had in the source org. Groups are matched by exact name;
    groups that do not exist in the target org are reported and skipped. Groups are only ever added,
    never removed.

.PARAMETER KeepClientId
    When CREATING an app, use the same Client ID it has in the source org instead of a new random one.
    (An existing app always keeps its Client ID.)

.PARAMETER IssuerMode
    Overrides the issuer mode for every app. Use ORG_URL if the target org has no custom domain
    and apps fail with an issuer_mode error.

.PARAMETER CreateInactive
    Create new apps deactivated. By default a new app is created active if it was active in the source.
    The active/inactive status of existing apps is never changed.

.PARAMETER Label
    Only import apps whose label matches one of these patterns. * is a wildcard.
    Use the label as it is in the export, without " OIE" or " Classic".

.PARAMETER DryRun
    Show what would happen without creating or changing anything.

.PARAMETER SaveClientSecrets
    Write the Client IDs and client secrets of newly CREATED apps to a separate CSV file. Treat that
    file like a password: store it securely and delete it when you are done.

.PARAMETER AuthMethod
    ApiToken (default) or Browser. See migration-work.md.

.PARAMETER ClientId
    Only for -AuthMethod Browser: the Client ID of the "Okta PowerShell CLI" app in the target org.

.PARAMETER ApiTokenEnvVar
    Name of an environment variable holding the target org API token. Default: OKTA_TARGET_API_TOKEN.

.PARAMETER AllowSameOrg
    Allow importing into the same org the export came from. Off by default as a safety check.

.EXAMPLE
    ./Import-OktaWebApps.ps1 -OrgUrl https://yourcompany.oktapreview.com -ExportFile ./exports/okta-web-apps-yourcompany-2026-09-27_101500.json -SignInFlow IdentityEngine -DryRun

.EXAMPLE
    ./Import-OktaWebApps.ps1 -OrgUrl https://yourcompany.oktapreview.com -ExportFile ./exports/okta-web-apps-yourcompany-2026-09-27_101500.json -SignInFlow Classic -UrlMapFile ./url-map.csv -AssignGroups
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$OrgUrl,

    [Parameter(Mandatory)]
    [string]$ExportFile,

    [Parameter(Mandatory)]
    [ValidateSet('IdentityEngine', 'Classic')]
    [string]$SignInFlow,

    [ValidateSet('Update', 'Skip')]
    [string]$ExistingApps = 'Update',

    [string]$AuthenticationPolicyName,

    [switch]$EnableInteractionCode,

    [string]$UrlMapFile,

    [switch]$AssignGroups,

    [switch]$KeepClientId,

    [ValidateSet('ORG_URL', 'CUSTOM_URL', 'DYNAMIC')]
    [string]$IssuerMode,

    [switch]$CreateInactive,

    [string[]]$Label = @('*'),

    [switch]$DryRun,

    [switch]$SaveClientSecrets,

    [ValidateSet('ApiToken', 'Browser')]
    [string]$AuthMethod = 'ApiToken',

    [string]$ClientId,

    [string]$ApiTokenEnvVar = 'OKTA_TARGET_API_TOKEN',

    [string]$OutputFolder = (Join-Path $PSScriptRoot 'exports'),

    [switch]$AllowSameOrg
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'OktaMigration.Common.ps1')

# Replaces URL fragments (from the URL map) in every URL-looking string inside an object.
function Update-UrlsInObject {
    param($Object, $Map)

    if ($null -eq $Object -or $Map.Count -eq 0) { return }

    $apply = {
        param([string]$Text)
        if ($Text -notmatch '://') { return $Text }
        foreach ($row in $Map) {
            $Text = $Text.Replace($row.Find, $row.Replace, [System.StringComparison]::OrdinalIgnoreCase)
        }
        return $Text
    }

    if ($Object -is [System.Array]) {
        for ($i = 0; $i -lt $Object.Count; $i++) {
            if ($Object[$i] -is [string]) { $Object[$i] = & $apply $Object[$i] }
            else { Update-UrlsInObject $Object[$i] $Map }
        }
    }
    elseif ($Object -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Object.PSObject.Properties) {
            if ($prop.Value -is [string]) { $prop.Value = & $apply $prop.Value }
            else { Update-UrlsInObject $prop.Value $Map }
        }
    }
}

# Sets or adds a property on an object.
function Set-Prop {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Like Get-Prop, but a one-item list stays a list (needed when comparing values).
function Get-RawProp {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return , $p.Value }
    return $null
}

# Returns a value with all object keys sorted, so two objects can be compared regardless of key order.
function ConvertTo-Canonical {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $out = [ordered]@{}
        foreach ($k in ($Value.Keys | Sort-Object)) { $out[$k] = ConvertTo-Canonical $Value[$k] }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $out = [ordered]@{}
        foreach ($p in ($Value.PSObject.Properties | Sort-Object Name)) { $out[$p.Name] = ConvertTo-Canonical $p.Value }
        return $out
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return , @(foreach ($item in $Value) { ConvertTo-Canonical $item })
    }
    return $Value
}

function Test-SameValue {
    param($A, $B)
    $ja = ConvertTo-Json -InputObject (ConvertTo-Canonical $A) -Depth 50 -Compress
    $jb = ConvertTo-Json -InputObject (ConvertTo-Canonical $B) -Depth 50 -Compress
    return $ja -eq $jb
}

# Friendly names for the settings people usually care about.
$FriendlyNames = @{
    redirect_uris              = 'sign-in redirect URIs'
    post_logout_redirect_uris  = 'sign-out redirect URIs'
    grant_types                = 'grant types'
    response_types             = 'response types'
    initiate_login_uri         = 'initiate login URI'
    token_endpoint_auth_method = 'client authentication'
    pkce_required              = 'PKCE'
    consent_method             = 'consent'
    issuer_mode                = 'issuer mode'
}
function Get-FriendlyName([string]$Name) {
    if ($FriendlyNames.ContainsKey($Name)) { return $FriendlyNames[$Name] }
    return $Name
}

# Copies the settings from an export definition onto an existing app (in memory).
# Returns the list of settings that were different. The label, Client ID, client secret,
# signing keys and active/inactive status of the existing app are never touched.
function Merge-AppDefinition {
    param($Target, $Definition)

    $changes = [System.Collections.Generic.List[string]]::new()

    # settings.oauthClient: compare and copy key by key.
    $targetSettings = Get-Prop $Target 'settings'
    if (-not $targetSettings) {
        $targetSettings = [pscustomobject]@{}
        Set-Prop $Target 'settings' $targetSettings
    }
    $targetOauth = Get-Prop $targetSettings 'oauthClient'
    if (-not $targetOauth) {
        $targetOauth = [pscustomobject]@{}
        Set-Prop $targetSettings 'oauthClient' $targetOauth
    }
    $defOauth = $Definition.settings.oauthClient
    foreach ($p in $defOauth.PSObject.Properties) {
        if (-not (Test-SameValue (Get-RawProp $targetOauth $p.Name) $p.Value)) {
            Set-Prop $targetOauth $p.Name $p.Value
            $changes.Add((Get-FriendlyName $p.Name))
        }
    }
    # Okta leaves the redirect URI lists out when they are empty, so an URI list that exists in the
    # target but not in the export has been removed in the source and must be emptied here too.
    foreach ($name in 'redirect_uris', 'post_logout_redirect_uris') {
        $current = @(Get-Prop $targetOauth $name | Where-Object { $_ })
        if (-not $defOauth.PSObject.Properties[$name] -and $current.Count -gt 0) {
            $targetOauth.PSObject.Properties.Remove($name)
            $changes.Add((Get-FriendlyName $name))
        }
    }

    # Other settings sections are compared as a whole.
    foreach ($name in 'notes', 'app') {
        $value = Get-RawProp $Definition.settings $name
        if ($null -ne $value -and -not (Test-SameValue (Get-RawProp $targetSettings $name) $value)) {
            Set-Prop $targetSettings $name $value
            $changes.Add($name)
        }
    }
    foreach ($name in 'visibility', 'accessibility', 'profile') {
        $value = Get-RawProp $Definition $name
        if ($null -ne $value -and -not (Test-SameValue (Get-RawProp $Target $name) $value)) {
            Set-Prop $Target $name $value
            $changes.Add($name)
        }
    }

    # Client credentials settings (never the Client ID or secret).
    $targetCreds = Get-Prop (Get-Prop $Target 'credentials') 'oauthClient'
    $defCreds = Get-Prop (Get-Prop $Definition 'credentials') 'oauthClient'
    if ($targetCreds -and $defCreds) {
        foreach ($name in 'token_endpoint_auth_method', 'pkce_required', 'autoKeyRotation') {
            $value = Get-RawProp $defCreds $name
            if ($null -ne $value -and -not (Test-SameValue (Get-RawProp $targetCreds $name) $value)) {
                Set-Prop $targetCreds $name $value
                $changes.Add((Get-FriendlyName $name))
            }
        }
    }

    return $changes.ToArray()
}

$results = [System.Collections.Generic.List[object]]::new()
$secrets = [System.Collections.Generic.List[object]]::new()

try {
    $OrgUrl = Get-NormalizedOrgUrl $OrgUrl

    Write-Step "Reading the export file"
    if (-not (Test-Path $ExportFile)) { throw "Export file not found: $ExportFile" }
    $export = Get-Content -Path $ExportFile -Raw | ConvertFrom-Json
    if (-not $export.PSObject.Properties['apps'] -or $export.exportFormatVersion -ne 1) {
        throw "'$ExportFile' is not an export file created by Export-OktaWebApps.ps1."
    }
    $apps = @($export.apps | Where-Object {
        $appLabel = $_.definition.label
        @($Label | Where-Object { $appLabel -like $_ }).Count -gt 0
    })
    Write-Ok "Export from $($export.sourceOrg) taken $($export.exportedAt): $(@($export.apps).Count) app(s), $($apps.Count) selected."
    if ($apps.Count -eq 0) { throw "No apps in the export match -Label $($Label -join ', ')." }

    if (-not $AllowSameOrg -and $export.sourceOrg -eq $OrgUrl) {
        throw "The target org ($OrgUrl) is the same org the export came from. Use -AllowSameOrg if you really mean this."
    }

    $urlMap = @()
    if ($UrlMapFile) {
        Write-Step "Reading the URL map"
        if (-not (Test-Path $UrlMapFile)) { throw "URL map file not found: $UrlMapFile" }
        $urlMap = @(Import-Csv -Path $UrlMapFile | Where-Object { $_.Find })
        if ($urlMap.Count -gt 0 -and -not ($urlMap[0].PSObject.Properties['Find'] -and $urlMap[0].PSObject.Properties['Replace'])) {
            throw "The URL map file must have the column headings Find and Replace."
        }
        foreach ($row in $urlMap) { Write-Ok "'$($row.Find)'  ->  '$($row.Replace)'" }
    }

    Write-Step "Loading the Okta PowerShell module"
    Import-OktaModuleForMigration

    Write-Step "Checking $OrgUrl"
    $engine = Get-OktaOrgEngine $OrgUrl
    Write-Ok "Org engine: $engine"
    if ($SignInFlow -eq 'IdentityEngine' -and $engine -eq 'Classic') {
        throw "You chose -SignInFlow IdentityEngine, but $OrgUrl is a Classic Engine org. Use -SignInFlow Classic."
    }
    if ($SignInFlow -eq 'Classic' -and $engine -eq 'IdentityEngine') {
        Write-Warn "$OrgUrl is an Identity Engine org. With -SignInFlow Classic no policy is assigned, so Okta applies its default authentication policy to new apps."
    }
    if ($SignInFlow -eq 'Classic' -and ($AuthenticationPolicyName -or $EnableInteractionCode)) {
        throw "-AuthenticationPolicyName and -EnableInteractionCode only work with -SignInFlow IdentityEngine."
    }

    Write-Step "Signing in to $OrgUrl"
    Connect-OktaOrg -OrgUrl $OrgUrl -AuthMethod $AuthMethod -ApiTokenEnvVar $ApiTokenEnvVar -ClientId $ClientId `
        -Scopes @('okta.apps.manage', 'okta.apps.read', 'okta.groups.read', 'okta.policies.read')

    # Authentication policies in the target org, by name.
    $policiesByName = @{}
    $forcedPolicy = $null
    if ($SignInFlow -eq 'IdentityEngine') {
        Write-Step "Reading authentication policies"
        $policies = Get-OktaAllPages {
            param($next)
            if ($next) { Invoke-OktaListPolicies -Type 'ACCESS_POLICY' -Uri $next -WithHttpInfo }
            else { Invoke-OktaListPolicies -Type 'ACCESS_POLICY' -WithHttpInfo }
        }
        foreach ($p in $policies) { $policiesByName[$p.name] = $p }
        Write-Ok "Found $($policies.Count) authentication policies: $(@($policies | ForEach-Object { $_.name }) -join ', ')"
        if ($AuthenticationPolicyName) {
            if (-not $policiesByName.ContainsKey($AuthenticationPolicyName)) {
                throw "No authentication policy named '$AuthenticationPolicyName' exists in $OrgUrl."
            }
            $forcedPolicy = $policiesByName[$AuthenticationPolicyName]
        }
    }

    Write-Step "Reading apps that already exist in $OrgUrl"
    $existing = Get-OktaAllPages {
        param($next)
        if ($next) { Invoke-OktaListApplications -Uri $next -WithHttpInfo }
        else { Invoke-OktaListApplications -Limit 200 -WithHttpInfo }
    }
    # label (lower case) -> list of apps with that label
    $existingByLabel = @{}
    foreach ($e in $existing) {
        $key = $e.label.ToLowerInvariant()
        if (-not $existingByLabel.ContainsKey($key)) { $existingByLabel[$key] = [System.Collections.Generic.List[object]]::new() }
        $existingByLabel[$key].Add($e)
    }
    Write-Ok "$($existing.Count) app(s) already exist. Existing apps with a matching label will be: $(if ($ExistingApps -eq 'Update') { 'updated' } else { 'skipped' })."

    $groupCache = @{}
    function Find-TargetGroup([string]$Name) {
        if ($groupCache.ContainsKey($Name)) { return $groupCache[$Name] }
        $found = @(Invoke-OktaListGroups -Q $Name -Limit 200) | Where-Object { $_.profile.name -eq $Name } | Select-Object -First 1
        $groupCache[$Name] = $found
        return $found
    }

    # Makes sure the app is assigned to the source groups. Returns what it did (or would do).
    function Sync-AppGroups {
        param([string]$AppId, $SourceGroups, [bool]$IsNewApp)

        $out = [ordered]@{ Added = @(); Missing = @(); Warnings = @() }
        $alreadyAssigned = @()
        if (-not $IsNewApp) {
            $current = Get-OktaAllPages {
                param($next)
                if ($next) { Invoke-OktaListApplicationGroupAssignments -AppId $AppId -Uri $next -WithHttpInfo }
                else { Invoke-OktaListApplicationGroupAssignments -AppId $AppId -Limit 200 -WithHttpInfo }
            }
            $alreadyAssigned = @($current | ForEach-Object { $_.id })
        }
        foreach ($g in $SourceGroups) {
            $target = Find-TargetGroup $g.name
            if (-not $target) { $out.Missing += $g.name; continue }
            if ($alreadyAssigned -contains $target.id) { continue }
            if ($DryRun) { $out.Added += $g.name; continue }
            try {
                $body = if ($null -ne $g.priority) { [pscustomobject]@{ priority = $g.priority } } else { [pscustomobject]@{} }
                New-OktaApplicationGroupAssignment -AppId $AppId -GroupId $target.id -ApplicationGroupAssignment $body | Out-Null
                $out.Added += $g.name
            }
            catch {
                $out.Warnings += "Could not assign group '$($g.name)': $(Get-OktaErrorText $_)"
            }
        }
        if ($out.Missing) { $out.Warnings += "Groups not found in target org: $($out.Missing -join ', ')" }
        return $out
    }

    if ($DryRun) {
        Write-Host ""
        Write-Host "DRY RUN: nothing will be created or changed." -ForegroundColor Magenta
    }

    $labelSuffix = if ($SignInFlow -eq 'Classic') { 'Classic' } else { 'OIE' }

    Write-Step "Creating and updating apps"
    foreach ($entry in $apps) {
        $def = Copy-DeepObject $entry.definition
        $source = $entry.source
        # The sign-in flow goes at the end of the label: "LHA_Dev" becomes "LHA_Dev Classic" or "LHA_Dev OIE".
        # Apps are matched on this label, so each flow gets its own app in the target org.
        $appLabel = $def.label.Trim()
        if (-not $appLabel.EndsWith(" $labelSuffix", [StringComparison]::OrdinalIgnoreCase)) { $appLabel = "$appLabel $labelSuffix" }
        $def.label = $appLabel
        $row = [ordered]@{
            Label = $appLabel; Result = ''; AppId = ''; ClientId = ''; Changes = ''
            AuthenticationPolicy = ''; GroupsAdded = ''; GroupsMissing = ''
            SignInRedirectUris = ''; SignOutRedirectUris = ''; Message = ''
        }

        try {
            # --- Prepare the app definition --------------------------------------------------------
            Update-UrlsInObject $def $urlMap

            $oauthCreds = $def.credentials.oauthClient
            if (-not $KeepClientId -and $oauthCreds.PSObject.Properties['client_id']) {
                $oauthCreds.PSObject.Properties.Remove('client_id')
            }

            $oauth = $def.settings.oauthClient
            $grants = [System.Collections.Generic.List[string]]::new()
            foreach ($g in @(Get-Prop $oauth 'grant_types')) { if ($g) { $grants.Add($g) } }
            if ($SignInFlow -eq 'Classic') { [void]$grants.Remove('interaction_code') }
            if ($EnableInteractionCode -and -not $grants.Contains('interaction_code')) { $grants.Add('interaction_code') }
            Set-Prop $oauth 'grant_types' ([string[]]$grants)
            if ($IssuerMode) { Set-Prop $oauth 'issuer_mode' $IssuerMode }

            $row.SignInRedirectUris = @(Get-Prop $oauth 'redirect_uris') -join ' | '
            $row.SignOutRedirectUris = @(Get-Prop $oauth 'post_logout_redirect_uris') -join ' | '

            # Which authentication policy to use ($null = leave it to Okta / leave as is).
            $policy = $null
            if ($SignInFlow -eq 'IdentityEngine') {
                if ($forcedPolicy) { $policy = $forcedPolicy }
                elseif ($source.authenticationPolicyName -and $policiesByName.ContainsKey($source.authenticationPolicyName)) {
                    $policy = $policiesByName[$source.authenticationPolicyName]
                }
            }
            $sourceGroups = @($source.groups | Where-Object { $_ -and $_.name })

            # --- Does the app already exist? ---------------------------------------------------------
            $sameLabel = @()
            if ($existingByLabel.ContainsKey($appLabel.ToLowerInvariant())) { $sameLabel = @($existingByLabel[$appLabel.ToLowerInvariant()]) }

            if ($sameLabel.Count -gt 1) {
                throw "$($sameLabel.Count) apps labelled '$appLabel' exist in the target org ($(@($sameLabel | ForEach-Object { $_.id }) -join ', ')). Rename or delete the extra ones, then run again."
            }

            $warnings = @()

            if ($sameLabel.Count -eq 1) {
                # ======================= UPDATE AN EXISTING APP =======================
                $match = $sameLabel[0]
                $row.AppId = $match.id
                $row.ClientId = Get-Prop (Get-Prop $match.credentials 'oauthClient') 'client_id'

                if ($match.name -ne 'oidc_client') {
                    throw "An app labelled '$appLabel' exists (id $($match.id)) but it is not an OpenID Connect app, so it cannot be updated."
                }
                if ($ExistingApps -eq 'Skip') {
                    $row.Result = 'Skipped'
                    $row.Message = "Already exists (id $($match.id)) and -ExistingApps Skip was used."
                    Write-Warn "$appLabel : already exists, skipped."
                    continue
                }

                $target = Get-OktaApplication -AppId $match.id
                $changes = @(Merge-AppDefinition $target $def)

                # Policy: only change it if it is different.
                $policyChange = $false
                $currentPolicyLink = Get-Prop (Get-Prop $target '_links') 'accessPolicy'
                $currentPolicyId = if ($currentPolicyLink -and $currentPolicyLink.href) { ($currentPolicyLink.href -split '/')[-1] } else { $null }
                if ($policy -and $policy.id -ne $currentPolicyId) { $policyChange = $true }
                $row.AuthenticationPolicy = if ($policy) { $policy.name } else { '(unchanged)' }

                if ($DryRun) {
                    $groupsPlan = if ($AssignGroups) { Sync-AppGroups -AppId $match.id -SourceGroups $sourceGroups -IsNewApp $false } else { $null }
                    $allChanges = @($changes)
                    if ($policyChange) { $allChanges += "authentication policy -> $($policy.name)" }
                    if ($groupsPlan -and $groupsPlan.Added) { $allChanges += "add groups: $($groupsPlan.Added -join ', ')" }
                    if ($groupsPlan) { $row.GroupsAdded = $groupsPlan.Added -join ', '; $row.GroupsMissing = $groupsPlan.Missing -join ', ' }
                    $row.Changes = $allChanges -join '; '
                    if ($allChanges.Count -gt 0) {
                        $row.Result = 'WouldUpdate'
                        Write-Ok "$appLabel : would be UPDATED ($($match.id)). Changes: $($row.Changes)"
                    }
                    else {
                        $row.Result = 'WouldNotChange'
                        Write-Ok "$appLabel : already up to date, nothing would change."
                    }
                    if ($groupsPlan -and $groupsPlan.Missing) { Write-Warn "$appLabel : these groups do not exist in the target org: $($groupsPlan.Missing -join ', ')" }
                    continue
                }

                $done = @()
                if ($changes.Count -gt 0) {
                    Update-OktaApplication -AppId $match.id -Application $target | Out-Null
                    $done += $changes
                    Write-Ok "$appLabel : updated ($($changes -join ', '))."
                }
                if ($policyChange) {
                    try {
                        Set-OktaApplicationPolicy -AppId $match.id -PolicyId $policy.id | Out-Null
                        $done += "authentication policy -> $($policy.name)"
                        Write-Ok "$appLabel : authentication policy '$($policy.name)' assigned."
                    }
                    catch { $warnings += "Could not assign policy '$($policy.name)': $(Get-OktaErrorText $_)" }
                }
                if ($AssignGroups -and $sourceGroups.Count -gt 0) {
                    $g = Sync-AppGroups -AppId $match.id -SourceGroups $sourceGroups -IsNewApp $false
                    $row.GroupsAdded = $g.Added -join ', '
                    $row.GroupsMissing = $g.Missing -join ', '
                    if ($g.Added) { $done += "add groups: $($g.Added -join ', ')"; Write-Ok "$appLabel : added groups: $($g.Added -join ', ')" }
                    $warnings += $g.Warnings
                }
                $row.Changes = $done -join '; '
                if ($done.Count -gt 0) { $row.Result = 'Updated' }
                else {
                    $row.Result = 'Unchanged'
                    Write-Ok "$appLabel : already up to date."
                }
            }
            else {
                # ======================= CREATE A NEW APP =======================
                $row.AuthenticationPolicy = if ($policy) { $policy.name } elseif ($SignInFlow -eq 'IdentityEngine') { '(Okta default)' } else { '(Classic - none assigned)' }

                if ($DryRun) {
                    $row.Result = 'WouldCreate'
                    if ($AssignGroups) {
                        $row.GroupsMissing = @($sourceGroups | Where-Object { -not (Find-TargetGroup $_.name) } | ForEach-Object { $_.name }) -join ', '
                        $row.GroupsAdded = @($sourceGroups | Where-Object { Find-TargetGroup $_.name } | ForEach-Object { $_.name }) -join ', '
                    }
                    Write-Ok "$appLabel : would be CREATED. Policy: $($row.AuthenticationPolicy). Grant types: $($grants -join ', ')"
                    Write-Host "           Sign-in redirect URIs : $($row.SignInRedirectUris)" -ForegroundColor DarkGray
                    Write-Host "           Sign-out redirect URIs: $($row.SignOutRedirectUris)" -ForegroundColor DarkGray
                    if ($row.GroupsMissing) { Write-Warn "$appLabel : these groups do not exist in the target org: $($row.GroupsMissing)" }
                    continue
                }

                $activate = (-not $CreateInactive) -and ($source.status -eq 'ACTIVE')
                $created = New-OktaApplication -Application $def -Activate $activate
                $row.AppId = $created.id
                $row.ClientId = $created.credentials.oauthClient.client_id
                $row.Result = 'Created'
                $existingByLabel[$appLabel.ToLowerInvariant()] = [System.Collections.Generic.List[object]]::new()
                $existingByLabel[$appLabel.ToLowerInvariant()].Add($created)
                Write-Ok "$appLabel : created (app id $($created.id), client id $($row.ClientId))."

                if ($SaveClientSecrets) {
                    $secret = Get-Prop $created.credentials.oauthClient 'client_secret'
                    $secrets.Add([pscustomobject]@{ Label = $appLabel; ClientId = $row.ClientId; ClientSecret = $secret })
                }

                if ($policy) {
                    try {
                        Set-OktaApplicationPolicy -AppId $created.id -PolicyId $policy.id | Out-Null
                        Write-Ok "$appLabel : authentication policy '$($policy.name)' assigned."
                    }
                    catch { $warnings += "Could not assign policy '$($policy.name)': $(Get-OktaErrorText $_)" }
                }
                if ($AssignGroups -and $sourceGroups.Count -gt 0) {
                    $g = Sync-AppGroups -AppId $created.id -SourceGroups $sourceGroups -IsNewApp $true
                    $row.GroupsAdded = $g.Added -join ', '
                    $row.GroupsMissing = $g.Missing -join ', '
                    if ($g.Added) { Write-Ok "$appLabel : assigned groups: $($g.Added -join ', ')" }
                    $warnings += $g.Warnings
                }
            }

            if ($warnings) {
                $row.Result = "$($row.Result)WithWarnings"
                $row.Message = $warnings -join ' | '
                foreach ($w in $warnings) { Write-Warn "$appLabel : $w" }
            }
        }
        catch {
            $row.Result = 'Failed'
            $row.Message = Get-OktaErrorText $_
            Write-Fail "$appLabel : $($row.Message)"
        }
        finally {
            $results.Add([pscustomobject]$row)
        }
    }
}
catch {
    Write-Host ""
    Write-Fail "Import stopped: $(Get-OktaErrorText $_)"
    $stopped = $true
}

if ($results.Count -gt 0) {
    Write-Step "Writing results"
    if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
    $orgName = ([System.Uri]$OrgUrl).Host.Split('.')[0]
    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $kind = if ($DryRun) { 'dryrun' } else { 'import' }
    $resultPath = Join-Path $OutputFolder "$kind-results-$orgName-$stamp.csv"
    $results | Export-Csv -Path $resultPath -NoTypeInformation -Encoding utf8
    Write-Ok "Results: $resultPath"

    if ($secrets.Count -gt 0) {
        $secretPath = Join-Path $OutputFolder "client-secrets-$orgName-$stamp.csv"
        $secrets | Export-Csv -Path $secretPath -NoTypeInformation -Encoding utf8
        Write-Warn "Client secrets written to $secretPath. Store them somewhere safe, then delete this file."
    }

    Write-Host ""
    $results | Group-Object Result | ForEach-Object { Write-Host ("{0,-24} {1}" -f $_.Name, $_.Count) }
}

if ($stopped -or @($results | Where-Object { $_.Result -eq 'Failed' }).Count -gt 0) { exit 1 }
