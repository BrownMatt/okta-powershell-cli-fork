# Copying Okta Web Apps from Production to Preview

This folder has scripts that copy OpenID Connect (OIDC) **web applications** from the Okta
**production** org (`yourcompany.okta.com`) into the **preview** org (`yourcompany.oktapreview.com`).

You don't need to know PowerShell to use them. Every step below says what to type and what you
should see. Replace `yourcompany` with your org's name wherever it appears.

## Contents

1. [What's in this folder](#1-whats-in-this-folder)
2. [Do you need an API key, or do you sign in to Okta?](#2-do-you-need-an-api-key-or-do-you-sign-in-to-okta)
3. [How the migration works](#3-how-the-migration-works)
4. [Which apps are exported](#4-which-apps-are-exported)
5. [Identity Engine or Classic?](#5-identity-engine-or-classic)
6. [One-time setup](#6-one-time-setup)
7. [Step by step: run the migration](#7-step-by-step-run-the-migration)
8. [All options](#8-all-options)
9. [What is not copied](#9-what-is-not-copied)
10. [Troubleshooting](#10-troubleshooting)
11. [PowerShell basics](#11-powershell-basics)

---

## 1. What's in this folder

| File | What it is | Do you run it? |
|------|------------|----------------|
| `Export-OktaWebApps.ps1` | Reads the web apps from an org and saves them to a file. **Read-only.** It never changes anything. | Yes (step 7.1) |
| `Import-OktaWebApps.ps1` | Creates the apps in another org from the saved file, or updates them if they already exist there. | Yes (steps 7.3 and 7.4) |
| `Export-OktaWebConfig.ps1` | Reads apps from an org and writes a `web.<app label>.config` file with each app's Okta settings, for developers. **Read-only.** | Optional (step 7.6) |
| `OktaMigration.Common.ps1` | Helper code the scripts share. | No, it loads automatically |
| `url-map.sample.csv` | Example file for swapping production URLs for test URLs. | You copy and edit it (step 7.2) |
| `migration-work.md` | This guide. | |
| `exports/` | Created automatically. Holds the export files and results. It is excluded from git. | |

The scripts use the **Okta PowerShell module** (`Okta.PowerShell`) that lives in this repository
under `src/Okta.PowerShell`.

---

## 2. Do you need an API key, or do you sign in to Okta?

**Either one works.** The Okta PowerShell module supports two ways to sign in.

### Option A: API token (recommended for this migration)

An API token is a long secret string that you create in the Okta Admin Console. It works like a
password for scripts.

- The token has the **same permissions as the admin who created it**. A token made by a Read-Only
  Administrator can only read.
- You create **one token per org**: one in production, one in preview. A token from one org doesn't
  work in the other.
- Okta shows the token **only once**, when you create it. Paste it straight into the script prompt, or
  store it in a password manager.
- Okta disables a token after 30 days without use. Revoke it when the migration is finished.

This is the simplest option. Setup needs no Okta configuration beyond creating the token.

### Option B: Sign in through your browser (the "device authorization" flow)

The script prints a web address. You open it, sign in to Okta as yourself (including MFA), and click
**Allow**. The script then receives a short-lived access token (usually valid for 1 hour).

- No long-lived secret is created, which is more secure.
- Setup takes more work: an Okta admin must first create an app named something like
  "Okta PowerShell CLI" **in each org** (steps are in [6.6](#66-optional-set-up-browser-sign-in)).
- You still need admin rights in Okta. The browser sign-in only proves who you are.

**Recommendation:**
- For production, use an API token created by an admin with **Read-Only Administrator** rights. The
  export only needs to read.
- For preview, use a token created by a **Super Administrator**. The import needs to create apps,
  assign groups and assign authentication policies.

---

## 3. How the migration works

```
 PRODUCTION org                                                     PREVIEW org
 yourcompany.okta.com                                      yourcompany.oktapreview.com

 ┌──────────────────┐  Export-OktaWebApps.ps1  ┌──────────────┐  Import-OktaWebApps.ps1  ┌──────────────┐
 │ OIDC web apps    │ ───── (read only) ─────> │ export .json │ ─ (creates or updates) > │ web apps     │
 └──────────────────┘                          │ summary .csv │                          └──────────────┘
                                               └──────────────┘
                                                      │
                                   optional: url-map.csv swaps production
                                   URLs for test URLs during import
```

1. **Export** from production. You get a `.json` file (for the import script) and a `.csv` summary
   (to open in Excel).
2. **Review** the summary. Optionally create a **URL map** so that
   `https://payroll.yourcompany.com` becomes `https://payroll-test.yourcompany.com` in preview.
3. **Dry run** the import against preview. It checks everything and shows what it would do, but
   creates and changes nothing.
4. **Import** for real. New apps get a new Client ID and client secret in preview. Apps that are
   already in preview are updated to match production.
5. **Hand the new Client IDs and secrets** to the app owners, so their test environments can point
   at preview.

### Running the import more than once

You can run the import **as many times as you like**. For each app it checks whether an app with the
**same label** already exists in preview:

| In preview... | What the import does |
|---------------|----------------------|
| No app with that label | **Creates** the app. |
| One app with that label, and its settings already match the export | **Nothing**. It reports `Unchanged`. |
| One app with that label, with different settings | **Updates** the app so it matches the export, and lists exactly which settings changed. |
| More than one app with that label | **Stops for that app** (`Failed`) and lists their IDs. It can't tell which one to update. |
| An app with that label that isn't an OIDC app (e.g. a SAML app) | **Stops for that app** (`Failed`). It won't turn one kind of app into another. |

So to bring preview up to date after production changes, just **export again and import again**.

When an existing app is **updated**:
- **Kept as they are:** its **label**, **Client ID** and **client secret**. The app keeps working
  for anyone already using it in preview.
- **Kept as they are:** its **active/inactive status** and its signing keys.
- **Copied from the export:**
  - sign-in and sign-out redirect URIs, grant types and response types
  - client authentication, PKCE and consent settings
  - issuer mode, initiate-login URI and the other URIs
  - visibility, accessibility and notes

  A redirect URI that was removed in production is removed in preview too.
- **Authentication policy (Identity Engine):** changed only if the policy chosen for the app
  ([section 5](#5-identity-engine-or-classic)) is different from the one it has now. If no policy is
  chosen, the current one is kept.
- **Groups (with `-AssignGroups`):** groups the app is missing are **added**. Groups are **never
  removed**, so any extra groups you added by hand in preview stay.

If you'd rather leave existing apps alone, add `-ExistingApps Skip`. Existing apps are then reported
as `Skipped` and not touched.

> **Matching is by label.** If you rename an app in production (or in preview), the import no longer
> recognises it and creates a second app. To avoid this, give the two apps the same label again
> before running the import.

---

## 4. Which apps are exported

An app is exported when it is:

- an **OpenID Connect** app (`signOnMode = OPENID_CONNECT`), **and**
- of application type **Web** (in the Admin Console it shows as "Web Application"), **and**
- **Active**. Add `-IncludeInactive` to also export deactivated apps.

Web apps usually have two kinds of redirect URL. The export saves both, along with everything else
needed to rebuild the app:

| In the Okta Admin Console | In the export file |
|---------------------------|--------------------|
| **Sign-in redirect URIs** | `redirect_uris` |
| **Sign-out redirect URIs** | `post_logout_redirect_uris` |

To export **only** apps that have both kinds, add `-RequireBothRedirectTypes`. The summary CSV has
a column `HasBothRedirectTypes` so you can check this before deciding.

Everything else the export saves per app:
- label and status
- grant types and response types
- client authentication method, PKCE, consent, issuer mode
- initiate-login URI, logo/policy/terms-of-service URIs, public keys (JWKS)
- visibility settings (such as "Do not display application icon to users")
- admin and end-user notes
- the **authentication policy** name
- the **groups** assigned to the app

A full untouched copy of each app is also saved under `raw`, for reference.

---

## 5. Identity Engine or Classic?

Okta has two generations of its sign-in engine:

| | **Okta Identity Engine (OIE)** | **Classic Engine** |
|---|---|---|
| Who has it | All new orgs; most orgs upgraded since 2023 | Older orgs not yet upgraded |
| How app sign-in rules work | Each app uses a shared **authentication policy** (Security > Authentication Policies) | Each app has its own **sign-on policy** rules on the app's *Sign On* tab |
| Extra grant type | **Interaction Code** (for apps with embedded sign-in) | Not available |

**How to tell which engine an org uses:** open this address in your browser (no sign-in needed):
`https://yourcompany.oktapreview.com/.well-known/okta-organization`.
If the page shows `"pipeline":"idx"`, the org uses **Identity Engine**. If it shows `"pipeline":"v1"`,
it uses **Classic**. The scripts also check this and print it as "Org engine".

When you import, you **must** choose one of the two with `-SignInFlow`:

### `-SignInFlow IdentityEngine`

- The preview org must be an Identity Engine org. The script stops with an explanation if it isn't.
- Each new app is given an **authentication policy**:
  1. The policy you name with `-AuthenticationPolicyName "Policy name"`, used for every app.
  2. If you don't name one, the script uses the **policy with the same name** the app used in
     production, when a policy of that name exists in preview.
  3. Otherwise Okta's **default** policy applies. The results file says which one each app got.
- Grant types are copied from production. Add `-EnableInteractionCode` to also turn on the
  **Interaction Code** grant. Only do this if the app uses Okta's embedded sign-in SDKs **and**
  Interaction Code is enabled in the preview org (Settings > Account > Embedded widget sign-in support).

### `-SignInFlow Classic`

- No authentication policy is assigned, and the Identity-Engine-only **Interaction Code** grant type
  is removed from the app.
- In a **Classic** preview org, the app gets the normal Classic default sign-on behaviour. You can then
  add per-app sign-on rules on the app's *Sign On* tab.
- In an **Identity Engine** preview org, the script warns you and continues. Okta then applies its
  default authentication policy to the app. The app is set up without any Identity Engine specific
  settings, which is what "Classic" means here.

> **Check this matches what you mean by "Classic flow".** If your team uses the phrase for a
> specific setting in the Admin Console, compare it against the description above before relying on
> `-SignInFlow Classic`, and adjust the script if needed.

---

## 6. One-time setup

### 6.1 Install PowerShell 7

The Okta module needs **PowerShell 7 or newer**. Windows includes an older "Windows PowerShell 5.1"
that **won't work**.

- **Windows:** open the Start menu, type `cmd`, open **Command Prompt**, and run:
  ```
  winget install --id Microsoft.PowerShell --source winget
  ```
  If `winget` isn't available, download the `.msi` installer from
  <https://aka.ms/powershell-release?tag=stable> and install it.
- **Mac:** install [Homebrew](https://brew.sh), then run `brew install --cask powershell` in Terminal.

**To open PowerShell 7:**
- **Windows:** Start menu → type **pwsh** → open **PowerShell 7**. The window title must say
  "PowerShell 7". If it says just "Windows PowerShell", you opened the wrong one.
- **Mac:** open Terminal and type `pwsh`.

**Check the version:**
```powershell
$PSVersionTable.PSVersion
```
The `Major` number must be **7** or higher.

### 6.2 Get this folder onto your computer

Choose one of these:
- **With git:** `git clone https://github.com/BrownMatt/okta-powershell-cli-fork.git`
- **Without git:** on the GitHub page for this repository click **Code > Download ZIP**, then unzip it.

Keep the **whole repository**. The scripts load the Okta module from the `src` folder next to
`MigrationWork`.

### 6.3 Go to the MigrationWork folder

In PowerShell 7, use `cd` ("change directory"). For example, if you unzipped to your Downloads folder:
```powershell
cd ~/Downloads/okta-powershell-cli-fork/MigrationWork
```
To confirm you're in the right place, type `ls`. You should see `Export-OktaWebApps.ps1` in the list.

### 6.4 Allow the scripts to run (Windows)

Windows blocks scripts downloaded from the internet. Run these two lines **once in each new
PowerShell window**. They only affect that window:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Get-ChildItem -Recurse .. -Include *.ps1,*.psm1,*.psd1 | Unblock-File
```
If you skip this, you'll see an error like *"running scripts is disabled on this system"*.

### 6.5 Create the API tokens (Option A)

Do this **in each org**: production and preview.

1. Sign in to the Okta Admin Console. For production that is
   `https://yourcompany-admin.okta.com`, for preview `https://yourcompany-admin.oktapreview.com`.
2. Go to **Security > API**, then the **Tokens** tab.
3. Click **Create token**, give it a name like `app-migration-2026`, and click **Create token**.
4. **Copy the token value now.** Okta won't show it again. Keep it somewhere safe until you run
   the script.

Remember which admin creates each token:
- In **production**, a **Read-Only Administrator** is enough.
- In **preview**, use a **Super Administrator**.

When the migration is done, go back to the same page and **revoke** both tokens.

### 6.6 (optional) Set up browser sign-in

Skip this if you use API tokens. **In each org**, an admin must:

1. Go to **Applications > Applications > Create App Integration**.
2. Choose **OIDC - OpenID Connect**, then **Native Application**, then click **Next**.
3. Name it `Okta PowerShell CLI`.
   - Under **Grant type**, tick **Device Authorization** (and leave Refresh Token unticked).
   - Under **Assignments**, assign it to the admins who will run the scripts.
   - Click **Save**.
4. On the app's **General** tab, click **Edit** and set **Client authentication** to **None**, if it
   isn't already. Copy the **Client ID**.
5. On the app's **Okta API Scopes** tab, click **Grant** next to each of these:
   - **Production:** `okta.apps.read`, `okta.groups.read`, `okta.policies.read`
   - **Preview:** `okta.apps.read`, `okta.apps.manage`, `okta.groups.read`, `okta.policies.read`

Then add these to the commands in step 7: `-AuthMethod Browser -ClientId <the Client ID from step 4>`.
The script prints a web address. Open it, sign in, and approve. The script waits until you do.

---

## 7. Step by step: run the migration

Open **PowerShell 7**, go to the `MigrationWork` folder ([6.3](#63-go-to-the-migrationwork-folder)),
and on Windows run the lines in [6.4](#64-allow-the-scripts-to-run-windows).

> **Tip:** type the first few letters of a file or option and press **Tab**. PowerShell completes it
> for you.

### 7.1 Export from production

```powershell
./Export-OktaWebApps.ps1 -OrgUrl https://yourcompany.okta.com
```

When asked, paste the **production** API token and press **Enter**. Nothing appears on screen
while you paste. That's normal.

You should see output like this:
```
==> Reading OpenID Connect apps
    [OK]   Found 42 OpenID Connect app(s) in total.
    [OK]   17 of them are Web apps matching label '*'.
==> Collecting details for each app
    [OK]   Payroll  (sign-in URIs: 2, sign-out URIs: 1, groups: 3)
    ...
==> Writing the export files
    [OK]   Export file : .../MigrationWork/exports/okta-web-apps-yourcompany-2026-09-27_101500.json
    [OK]   Summary CSV : .../MigrationWork/exports/okta-web-apps-yourcompany-2026-09-27_101500.csv
```

**Open the summary CSV in Excel** and check that the list of apps and redirect URIs looks right.

Useful variations:
```powershell
# Only apps that have both sign-in and sign-out redirect URIs
./Export-OktaWebApps.ps1 -OrgUrl https://yourcompany.okta.com -RequireBothRedirectTypes

# Only apps whose label starts with "Payroll"
./Export-OktaWebApps.ps1 -OrgUrl https://yourcompany.okta.com -LabelFilter "Payroll*"
```

### 7.2 (optional) Create a URL map

Production apps usually redirect to production websites, and in preview you probably want the test
websites instead.

1. Copy the sample file:
   ```powershell
   Copy-Item ./url-map.sample.csv ./url-map.csv
   ```
2. Open `url-map.csv` in Excel or Notepad. Keep the heading row `Find,Replace` exactly as it is, and
   add one row per website:
   ```
   Find,Replace
   https://payroll.yourcompany.com,https://payroll-test.yourcompany.com
   https://hr.yourcompany.com,https://hr-test.yourcompany.com
   ```
3. Save it as CSV.

During import, every URL in the app is changed wherever it contains a `Find` value. That covers
sign-in and sign-out redirect URIs, the initiate-login URI and the other URL fields. Matching ignores
upper/lower case. Values that aren't URLs are never changed.

`url-map.csv` is excluded from git.

### 7.3 Dry run the import (always do this first)

Replace the file name with the `.json` file from step 7.1.

```powershell
./Import-OktaWebApps.ps1 `
    -OrgUrl https://yourcompany.oktapreview.com `
    -ExportFile ./exports/okta-web-apps-yourcompany-2026-09-27_101500.json `
    -SignInFlow IdentityEngine `
    -UrlMapFile ./url-map.csv `
    -AssignGroups `
    -DryRun
```

The backtick `` ` `` at the end of a line means "the command continues on the next line". You can
also type the whole command on one line without the backticks.

- Paste the **preview** API token when asked.
- Leave out `-UrlMapFile ./url-map.csv` if you skipped step 7.2.
- Use `-SignInFlow Classic` instead if that's what you want. See [section 5](#5-identity-engine-or-classic).

Read the output. For each app you see the redirect URIs it would get (after the URL map), the
authentication policy, and any groups that don't exist in preview:
```
DRY RUN: nothing will be created or changed.
==> Creating and updating apps
    [OK]   Payroll : would be CREATED. Policy: Payroll MFA. Grant types: authorization_code, refresh_token
           Sign-in redirect URIs : https://payroll-test.yourcompany.com/callback
           Sign-out redirect URIs: https://payroll-test.yourcompany.com/logout
    [WARN] Payroll : these groups do not exist in the target org: Payroll Admins
    [OK]   HR Portal : would be UPDATED (0oa1ab2cd3EF). Changes: sign-in redirect URIs; notes
    [OK]   Expenses : already up to date, nothing would change.
```
**Read the "would be UPDATED" lines carefully.** They list exactly which settings of an existing
preview app would be overwritten with the production values.
A results file `exports/dryrun-results-....csv` is also written.

### 7.4 Run the import for real

Run the **same command without `-DryRun`**. To also save the new client secrets to a file, add
`-SaveClientSecrets`:

```powershell
./Import-OktaWebApps.ps1 `
    -OrgUrl https://yourcompany.oktapreview.com `
    -ExportFile ./exports/okta-web-apps-yourcompany-2026-09-27_101500.json `
    -SignInFlow IdentityEngine `
    -UrlMapFile ./url-map.csv `
    -AssignGroups `
    -SaveClientSecrets
```

At the end you get a count of each outcome:
```
Created                  12
CreatedWithWarnings      2
Updated                  3
Unchanged                5
```

| Result | Meaning |
|--------|---------|
| `Created` | The app was created and everything was applied. |
| `CreatedWithWarnings` | The app was created, but something extra didn't work, such as a group missing in preview or a policy that couldn't be assigned. The `Message` column says what. Fix that by hand in the Admin Console. |
| `Updated` | The app already existed in preview and was changed to match the export. The `Changes` column lists what changed. |
| `UpdatedWithWarnings` | As `Updated`, but something extra didn't work (see the `Message` column). |
| `Unchanged` | The app already existed in preview and already matched the export. Nothing was changed. |
| `UnchangedWithWarnings` | As `Unchanged`, but there's something to look at, usually a group missing in preview (see the `Message` column). |
| `Skipped` | The app exists in preview and you used `-ExistingApps Skip`. Nothing was changed. |
| `Failed` | Okta refused to create or update the app, or the app couldn't be matched safely. The `Message` column says why. See [Troubleshooting](#10-troubleshooting). |
| `WouldCreate`, `WouldUpdate`, `WouldNotChange` | Dry run only: what would happen. Nothing was changed. |

### 7.5 After the import

1. Open `exports/import-results-....csv`. It lists each app's **app ID** and **Client ID** in
   preview, and for updated apps, what changed.
2. If you used `-SaveClientSecrets`, `exports/client-secrets-....csv` holds the secrets of the
   **newly created** apps. Updated apps keep their existing secret.
   - Pass each secret to its app owner through a secure channel, such as your password manager.
     **Never** send them by email or chat.
   - Then **delete the file**.
   - If you didn't save them, secrets can be copied from each app's **General** tab in the Admin Console.
3. Sign in to the preview Admin Console, open a couple of the new apps, and compare them with production.
4. Ask the app owners to point their test environment at the preview org and test sign-in.
5. If developers need `web.config` settings for the apps, do [7.6](#76-optional-write-webconfig-files-for-developers) now.
6. **Revoke the API tokens** ([6.5](#65-create-the-api-tokens-option-a)).

### 7.6 (optional) Write web.config files for developers

`Export-OktaWebConfig.ps1` reads apps from an org and writes one file per app with the settings an
ASP.NET app needs to sign in with Okta. Like the export, it only reads from Okta.

```powershell
./Export-OktaWebConfig.ps1 -OrgUrl https://yourcompany.oktapreview.com -Label "LHA_DQMP LocalHost"
```

This writes `exports/web.LHA_DQMP_LocalHost.config`. Spaces and characters that aren't allowed in a
file name become `_`. `-Label` accepts wildcards and lists, e.g. `-Label "LHA_*"` writes a file for
every Web app whose label starts with `LHA_`. It signs in the same way as the import, and by
default uses the preview token in `$env:OKTA_TARGET_API_TOKEN`.

The file looks like this:

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="okta:ClientId" value="0oa1abc..." />
    <add key="okta:ClientSecret" value="..." />
    <add key="okta:OrgUri" value="https://yourcompany.oktapreview.com" />
    <add key="okta:RedirectUri" value="https://localhost:44300/authorization-code/callback" />
    <!-- Other sign-in redirect URIs for this app: -->
    <!-- <add key="okta:RedirectUri" value="https://dqmp.yourcompany.com/authorization-code/callback" /> -->
    <add key="okta:PostLogoutRedirectUri" value="https://localhost:44300/" />
    <!-- api key is same API key powershell script uses -->
    <add key="okta:APIkey" value="..." />
    <add key="oktaAPIuri" value="https://yourcompany.oktapreview.com" />
  </appSettings>
</configuration>
```

| Setting | Where the value comes from |
|---------|----------------------------|
| `okta:ClientId` | The app's Client ID. |
| `okta:ClientSecret` | The app's newest **active** client secret. Empty, with a warning, if the app has none (for example it uses public/private keys). |
| `okta:OrgUri`, `oktaAPIuri` | The org URL you passed to `-OrgUrl`, without `-admin`. |
| `okta:RedirectUri` | The app's first sign-in redirect URI. Any others are listed as comments underneath; to use one, swap it with the active line. |
| `okta:PostLogoutRedirectUri` | The app's first sign-out redirect URI, with the others as comments, in the same way. |
| `okta:APIkey` | The API token the script signed in with. If you signed in with `-AuthMethod Browser` there is no token, so it's `REPLACE_WITH_OKTA_API_TOKEN`. |

Running the script again overwrites the files with fresh values, for example after a secret is rotated.

> **Warning:** each file holds a client secret and your **API token** in plain text. The token
> carries all of your admin rights, so anyone who can read the file can change the org.
> - Hand files over through a secure channel, such as your password manager. Never by email or chat.
> - Don't commit them. `exports/` is excluded from git; if you use `-OutputFolder`, keep it outside the repository.
> - If you revoke the token (step 7.5), the `okta:APIkey` in these files stops working too.
>   For an app that keeps calling the Okta API, create a separate token for it and replace the value.

---

## 8. All options

To see the built-in help for a script at any time:
```powershell
Get-Help ./Import-OktaWebApps.ps1 -Detailed
```

### Export-OktaWebApps.ps1

| Option | Required? | What it does |
|--------|-----------|--------------|
| `-OrgUrl` | **Yes** | The org to export from, e.g. `https://yourcompany.okta.com`. The `-admin` address also works. |
| `-AuthMethod` | No | `ApiToken` (default) or `Browser`. |
| `-ClientId` | With `Browser` | Client ID of the "Okta PowerShell CLI" app ([6.6](#66-optional-set-up-browser-sign-in)). |
| `-ApiTokenEnvVar` | No | Environment variable to read the token from, instead of asking. Default `OKTA_SOURCE_API_TOKEN`. |
| `-OutputFolder` | No | Where to save files. Default: the `exports` folder here. |
| `-IncludeInactive` | No | Also export deactivated apps. |
| `-RequireBothRedirectTypes` | No | Only export apps with both sign-in and sign-out redirect URIs. |
| `-LabelFilter` | No | Only apps whose label matches, e.g. `"Payroll*"`. `*` means "anything". |

### Import-OktaWebApps.ps1

| Option | Required? | What it does |
|--------|-----------|--------------|
| `-OrgUrl` | **Yes** | The org to create apps in, e.g. `https://yourcompany.oktapreview.com`. |
| `-ExportFile` | **Yes** | The `.json` file from the export. |
| `-SignInFlow` | **Yes** | `IdentityEngine` or `Classic`. See [section 5](#5-identity-engine-or-classic). |
| `-DryRun` | No | Check everything and show what would happen; create and change nothing. |
| `-ExistingApps` | No | `Update` (default): update apps that already exist in preview. `Skip`: leave them alone. See [Running the import more than once](#running-the-import-more-than-once). |
| `-AuthenticationPolicyName` | No | Identity Engine only: the policy to give every app, e.g. `"Any two factors"`. |
| `-EnableInteractionCode` | No | Identity Engine only: add the Interaction Code grant type. |
| `-UrlMapFile` | No | CSV with `Find,Replace` columns for swapping URLs ([7.2](#72-optional-create-a-url-map)). |
| `-AssignGroups` | No | Assign the same groups as in production, matched by exact group name. |
| `-Label` | No | Only import apps whose label matches, e.g. `-Label "Payroll*","HR*"`. |
| `-KeepClientId` | No | When creating an app, reuse the production Client ID instead of letting Okta generate a new one. Existing apps always keep their Client ID. |
| `-IssuerMode` | No | Force the issuer mode (`ORG_URL`, `CUSTOM_URL` or `DYNAMIC`) for all apps. See [Troubleshooting](#10-troubleshooting). |
| `-CreateInactive` | No | Create new apps deactivated, so you can activate them by hand later. The status of existing apps is never changed. |
| `-SaveClientSecrets` | No | Save the Client IDs and secrets of newly created apps to a separate CSV. Handle it like a password. |
| `-AuthMethod`, `-ClientId` | No | As for the export. |
| `-ApiTokenEnvVar` | No | Default `OKTA_TARGET_API_TOKEN`. |
| `-AllowSameOrg` | No | Safety override: allow importing into the same org the export came from. |

### Export-OktaWebConfig.ps1

| Option | Required? | What it does |
|--------|-----------|--------------|
| `-OrgUrl` | **Yes** | The org to read from, e.g. `https://yourcompany.oktapreview.com`. |
| `-Label` | **Yes** | Which apps, e.g. `"LHA_DQMP LocalHost"`, `"LHA_*"` or `"Payroll","HR Portal"`. |
| `-AuthMethod`, `-ClientId` | No | As for the export. With `Browser`, `okta:APIkey` gets a placeholder. |
| `-ApiTokenEnvVar` | No | Default `OKTA_TARGET_API_TOKEN`. Use `OKTA_SOURCE_API_TOKEN` to read from production. |
| `-OutputFolder` | No | Where to write the files. Default: the `exports` folder here. |
| `-IncludeInactive` | No | Also write files for deactivated apps. |

#### Using an environment variable instead of pasting the token

The token is kept only in the current PowerShell window and is gone once you close it:
```powershell
$env:OKTA_SOURCE_API_TOKEN = "paste-production-token-here"
$env:OKTA_TARGET_API_TOKEN = "paste-preview-token-here"
```
Don't put tokens in files or scripts.

---

## 9. What is not copied

These things are **not** created in preview. Set them up by hand if you need them:

- **Client secrets.** Every app gets a **new** secret in preview (see [7.5](#75-after-the-import)).
- **Individual user assignments.** Only **group** assignments are copied, and only with
  `-AssignGroups`. Users and groups don't exist in preview unless you create them there.
- **The authentication policies themselves.** The script only *assigns* existing policies. Create
  matching policies in preview first if you want the same rules.
- **Classic per-app sign-on rules.** These are the rules on the app's *Sign On* tab in Classic orgs.
- **App logos.**
- **Custom authorization servers and their claims, scopes and access policies**
  (Security > API > Authorization Servers).
- **Provisioning settings and profile mappings.**
- **Anything outside OIDC web apps**: SAML apps, SPA/native/service apps, and bookmark apps.

---

## 10. Troubleshooting

| What you see | What it means / what to do |
|--------------|----------------------------|
| `running scripts is disabled on this system` | Run the two lines in [6.4](#64-allow-the-scripts-to-run-windows) in the same window. |
| `These scripts need PowerShell 7 or newer` | You opened "Windows PowerShell". Open **PowerShell 7** (pwsh) instead ([6.1](#61-install-powershell-7)). |
| `The term './Export-OktaWebApps.ps1' is not recognized` | You're not in the `MigrationWork` folder. Use `cd` ([6.3](#63-go-to-the-migrationwork-folder)). |
| `The Okta.PowerShell module was not found` | The `MigrationWork` folder was copied out of the repository. Keep it inside the full repository. |
| `HTTP 401 ... The API token or sign-in is not valid for this org` | Wrong token, or a token from the other org. Production tokens only work in production, and preview tokens only in preview. |
| `HTTP 403 ... does not have permission` | The admin who created the token lacks rights. Use a Super Administrator token for the import. |
| `HTTP 400 - Invalid search criteria` while *Reading OpenID Connect apps* | Your org doesn't accept the filter used to list only OIDC apps. The current version of the export handles this: it prints a `[WARN]` line and reads all apps instead. If you still see this as a `[FAIL]`, get the latest version of this folder (see [6.2](#62-get-this-folder-onto-your-computer)). |
| `The org URL must start with https://` | Include `https://`, e.g. `https://yourcompany.okta.com`. |
| `The target org ... is the same org the export came from` | You pointed the import at production. Check `-OrgUrl`. |
| `You chose -SignInFlow IdentityEngine, but ... is a Classic Engine org` | The preview org is Classic. Use `-SignInFlow Classic`. |
| `No authentication policy named '...' exists` | Check the exact name under Security > Authentication Policies in preview, including capitals and spaces. |
| `Failed` with a message about **issuer** or `issuer_mode` | The production app uses a custom domain that preview doesn't have. Re-run with `-IssuerMode ORG_URL`. |
| `Failed` with a message about **redirect_uris** | A redirect URI isn't allowed, e.g. `http://` for a non-localhost address. Fix it in the URL map, or in the export `.json` under `definition`. |
| `Failed` with a message about **interaction_code** | Interaction Code isn't enabled in the preview org. Leave out `-EnableInteractionCode`, or use `-SignInFlow Classic`. |
| `Failed` with a message about **client_id** | You used `-KeepClientId` and that Client ID already exists in preview. Leave the option out. |
| `Failed`: *2 apps labelled '...' exist in the target org* | Preview has duplicate apps with that label. Rename or delete the extra ones in the preview Admin Console, then run again. |
| `Failed`: *exists but it is not an OpenID Connect app* | A non-OIDC app in preview (e.g. SAML) has the same label. Rename one of them, then run again. |
| An app was created twice after being renamed | Apps are matched by label. Delete the duplicate, make the labels the same again, and re-run. |
| `Groups not found in target org` | That group doesn't exist in preview. Create it, then assign it to the app in the Admin Console. |
| `No active OpenID Connect Web app ... has a label matching ...` (web.config script) | Check the label's spelling in the Admin Console; capitals don't matter. Only OIDC **Web** apps are used. Add `-IncludeInactive` for a deactivated app. |
| `has no client secret` (web.config script) | The app signs in with public/private keys or has no secret. `okta:ClientSecret` is left empty. |
| `Another app gets the same file name` (web.config script) | Two labels differ only in characters that become `_`. The second file name ends with the app ID. |
| `Hit Rate limit: Retrying request` (with `-Verbose`) | Okta is asking the script to slow down. It waits and retries automatically. |

**Changing an app before import:** the export `.json` is a plain text file. Under each app,
`definition` is exactly what gets sent to Okta, and you can edit it in a text editor. For example, you
can change a `label` so the app gets a different name in preview. Keep a backup copy first. The
label is also how the app is matched on the next run, so use the same edited file every time.

**More detail:** add `-Verbose` to any command to see each request the scripts make.

---

## 11. PowerShell basics

| You want to... | Type |
|----------------|------|
| See which folder you're in | `pwd` |
| List files in the folder | `ls` |
| Go into a folder | `cd FolderName` |
| Go up one folder | `cd ..` |
| Run a script in this folder | `./ScriptName.ps1` (the `./` means "this folder") |
| Repeat or edit your last command | Press the **Up arrow** |
| Finish typing a name for you | Press **Tab** |
| Stop a running script | Press **Ctrl + C** |
| Open a CSV in Excel (Windows) | `Invoke-Item ./exports/filename.csv` |
| Open the exports folder (Windows) | `explorer ./exports` |
| Open the exports folder (Mac) | `open ./exports` |
| See a script's help | `Get-Help ./Import-OktaWebApps.ps1 -Detailed` |

- **Quotes:** put values that contain spaces in quotes, e.g. `-AuthenticationPolicyName "Any two factors"`.
- **Options:** start with `-`, and their order doesn't matter.
- **Switches:** an option with no value after it, like `-DryRun`, is a switch. Including it turns it on.
