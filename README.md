# CE environment bootstrap

**Create a Dynamics 365 CE environment and install its apps one after another, from one command that asks you for everything.**

It needs none of the Finance and Operations developer tooling (Visual Studio, LocalDB, SQL, X++ folders): only the Power Platform CLI, which it installs, and a sign-in.

## Quick start

```powershell
# Open PowerShell (no need for Administrator), then:
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Bootstrap-CeEnvironment.ps1
```

You need:

- A **Power Platform admin** account (or a service principal registered with `pac admin application register`)
- At least **1 GB of free Dataverse database capacity** in the tenant
- **A few hours**. Creating the environment takes 30-90 minutes, and each app often 30 minutes to 2 hours. Keep the window open and the PC awake.

## What it asks

| Prompt | Default | Notes |
|---|---|---|
| Sign-in method | Interactive | Interactive (browser), DeviceCode (remote sessions), ServicePrincipal |
| Display name | | e.g. `CONTOSO-DEV01` |
| Domain | suggested from the name | First part of the URL. If it already exists, you can reuse that environment or pick another |
| Type | Sandbox | Sandbox, Production, Developer, Trial |
| Region | unitedkingdom | |
| Currency / language | GBP / 1033 | |
| Templates | D365_FieldService | Read live from `pac admin list-app-templates` for the region |
| Security group | none | Entra group ID to restrict who can use the environment |
| Apps | Power Pages, Omnichannel | Installed in the order chosen; you can type other unique names |
| App users | | Application (client) IDs to add as System Administrator, or `none` |
| Marketing | Yes | You start it in the admin center; the script then waits for it |
| Developer tools | No | Git, Node.js LTS, .NET SDK, VS Code, Visual Studio (via winget) |

It shows a summary and asks **Start?** before it changes anything.

## Phases

| # | Phase | What happens |
|---|---|---|
| 0 | Sign-in method | Chooses how pac signs in |
| 1 | pac CLI and sign-in | Installs or updates pac (.NET tool, winget or MSI), signs in, checks admin access |
| 2 | Environment details | The prompts above, with live checks (domain free, templates offered) |
| 3 | Confirm | Summary, then Start? |
| 4 | Create environment | `pac admin create`, or reuses the environment that has the domain; waits until it answers |
| 5 | Application users | `pac admin assign-user --application-user`, retried while the environment starts up |
| 6 | Dynamics 365 apps | `pac application install` for each app, waiting until it's installed before the next one starts. If an app fails it asks whether to carry on |
| 7 | Marketing | Opens the admin center with the steps, waits for you to start the install, then waits for it to finish |
| 8 | Developer tools | Optional winget installs |
| 9 | Check and next steps | Shows each app's state and saves the run to `%LOCALAPPDATA%\CeBootstrap\last-run.json` |

## Running it without prompts

Pass any value as a parameter and it isn't asked for:

```powershell
.\Bootstrap-CeEnvironment.ps1 `
    -AuthMethod Interactive `
    -DisplayName CONTOSO-DEV01 -Domain contoso-dev01 `
    -EnvironmentType Sandbox -Region unitedkingdom -Currency GBP -Language 1033 `
    -Templates D365_FieldService `
    -Applications 'PowerPages_CustomerPortal_V2,msdyn_OmnichannelPrimeProactiveAIAnchor' `
    -ApplicationUsers 11111111-2222-3333-4444-555555555555 `
    -IncludeMarketing Yes -InstallDevTools No -Yes
```

Check an environment's apps without changing anything:

```powershell
.\Bootstrap-CeEnvironment.ps1 -Verify -EnvironmentUrl https://contoso-dev01.crm11.dynamics.com
```

## Re-running

Safe. If the domain already exists, the script offers to reuse that environment, skips apps that are installed, and picks up installs that are still running. If waiting runs past the time limit it asks how much longer to wait, so a slow install doesn't end the run.

## Marketing

Microsoft only documents installing Marketing (Customer Insights - Journeys) from the admin center: **Manage > Dynamics 365 apps > Dynamics 365 Marketing or Customer Insights > ... > Manage > Install**. It needs a user with a Dynamics 365 licence, the System Administrator role and permission to register applications in Microsoft Entra ID. It fails if the environment's **Block unmanaged customizations** setting is on. The script shows these steps and opens the page for you.

## Configuration

`config\defaults.json` holds the defaults and lists: regions, fallback templates, the app catalog (add apps here so they appear in the menu), timeouts, the Marketing app name and the developer tools.

## Logs

Each run writes `C:\Temp\CeBootstrap-<timestamp>.log` (structured, with pac commands and output) and a `.transcript.txt`. Client secrets are masked.

## Files

```text
Bootstrap-CeEnvironment/
├── Bootstrap-CeEnvironment.ps1   # run this
├── config/defaults.json          # defaults, app catalog, tool list
└── modules/
    ├── Logger.psm1               # log file, phases, summary, secret masking
    ├── UserInputs.psm1           # prompts, menus, validation
    ├── PacCli.psm1               # install pac, sign in, environment list, JSON helpers
    ├── CeEnvironment.psm1        # create or reuse the environment, app users
    ├── CeApplications.psm1       # install apps one by one, wait, Marketing step
    └── DevTools.psm1             # optional winget tools
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "Couldn't list environments" | The account isn't a Power Platform admin, or the service principal isn't registered |
| Create fails mentioning capacity | The tenant has less than 1 GB free database capacity |
| "... isn't available to install in this environment" | Wrong unique name; the script lists the names that are available |
| Marketing "has shown as not installed for 60 minutes" | The install wasn't started, or pac lists it under another name: set `marketing.appName` in the config |
| An app's state stays empty | pac's JSON output changed. Send the log file |
| Script won't start (execution policy) | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` first |

Runs on Windows PowerShell 5.1 or PowerShell 7.

## Disclaimer

This is a community script, not a Microsoft product, and it comes with no warranty. It creates environments and installs apps in your tenant, which uses storage capacity and can take hours. Read it before you run it, try it first in a tenant or sandbox where a spare environment doesn't matter, and check your organisation's policies on creating environments. pac doesn't document the shape of its JSON output, so a future pac release could change what the script reads; the log file shows exactly what pac returned.
