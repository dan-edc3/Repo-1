# CompanyOnboarding

A modular, config-driven onboarding tool for a hybrid AD environment. Creates the
on-prem AD account, applies group membership, and runs pre-defined SQL provisioning
actions against line-of-business systems — from a WinForms window or from the command line.

## The one idea to hold onto

**Logic lives in code. Everything that changes lives in data.**

- Adding a new account type = drop a JSON file in `Roles\`. No code change.
- Changing which groups a role gets = edit that role's JSON. No code change.
- A new LOB database, or a changed table = edit `config.json`. No code change.
- Redesigning the window = edit one file that contains zero provisioning logic.

That's the fix for "poorly organized, broke easily, hard to update." The old scripts
broke because each account type was its own copy of the logic. Here there is one code
path and many data files.

## Layout

```
CompanyOnboarding\
├── CompanyOnboarding.psd1        Module manifest (version lives here)
├── CompanyOnboarding.psm1        Loader
├── Start-OnboardingConsole.ps1   Double-click launcher
├── config.json                   Domain settings + every SQL statement
├── Roles\                        One JSON file per account type
│   ├── nurse.json
│   └── frontdesk.json
├── Public\                       Commands you call
│   ├── Invoke-Onboarding.ps1         <- the engine
│   ├── Show-OnboardingConsole.ps1    <- the window (no logic)
│   ├── Get-OnboardingRole.ps1
│   └── Get-OnboardingConfig.ps1
└── Private\                      Internal building blocks
    ├── New-OnbAdAccount.ps1
    ├── Add-OnbGroupMembership.ps1
    ├── Invoke-OnbSqlAction.ps1
    ├── Expand-OnbToken.ps1
    ├── New-OnbPassword.ps1
    ├── New-OnbStepResult.ps1
    └── Write-OnbLog.ps1
```

## Requirements

- Windows PowerShell 5.1 (the WinForms + ActiveDirectory combination is most reliable here)
- RSAT ActiveDirectory module
- Network access to the SQL instances named in `config.json`
- The account running it needs AD create/modify rights on the target OUs and
  INSERT/UPDATE rights on the LOB tables

## First-run setup

1. Edit `config.json`: `domain`, `domainDn`, `defaultUpnSuffix`, `logPath`.
2. Replace the sample entries under `sqlSystems` with your real connection strings
   and statements.
3. Edit or replace the two sample role files with your real account types.
4. Test without touching anything:

```powershell
Import-Module .\CompanyOnboarding.psd1 -Force
Invoke-Onboarding -FirstName Test -LastName User -RoleId nurse `
                  -ExtraField @{ Unit = 'ICU' } -WhatIf -Verbose
```

`-WhatIf` walks the whole run and reports what each step *would* do, including the
exact SQL parameter values, without writing anything. Use it before every real run
until you trust the role file.

## First run: replace the placeholders

The module ships with a fictional domain. Run this before anything else — it names the
exact file and setting for every value still left as shipped:

```powershell
Import-Module .\CompanyOnboarding.psd1 -Force
Test-OnboardingConfig
```

Everything it reports as `PLACEHOLDER` needs replacing:

| Setting | In | Change to |
|---|---|---|
| `domain` | `config.json` | your AD domain, e.g. `corp.example` |
| `domainDn` | `config.json` | its DN, e.g. `DC=corp,DC=example` |
| `defaultUpnSuffix` | `config.json` | your UPN/email suffix |
| `logPath` | `config.json` | a share both admins can write to |
| `sqlSystems.*.connectionString` | `config.json` | your real servers and databases |
| `groups` | `Roles\*.json` | your real group names |

**The UPN suffix is defined in exactly one place** — `defaultUpnSuffix` in `config.json`.
Add `upnSuffix` to a role's `ad` block only if that role genuinely needs a different one.

## Changing the username pattern

To switch from `dreyes` to `dana.reyes`, three keys in `config.json` must change together,
under `naming.samAccountName`:

```json
"format": "{firstName}.{lastName}",
"collisionFormats": ["{firstInitial}.{lastName}", "{firstName}.{lastName}{n}"],
"transform": ["ascii", "keep:A-Za-z0-9.", "lower"],
"validate": "^[a-z][a-z0-9.]{2,19}$"
```

The `transform` line is the one that catches people out. `alphanumeric` keeps only letters
and digits, so it strips the dot straight back out and `{firstName}.{lastName}` quietly
produces `danareyes`. **`keep:<characters>` keeps only what you list**, so
`keep:A-Za-z0-9.` permits the dot. Use `keep:A-Za-z0-9-` for a hyphen instead.

`validate` must also allow the separator, or every candidate is rejected.

Verified: this produces `dana.reyes`, falls back to `d.reyes` when taken, then
`dana.reyes2`, and still handles `Siobhan O'Brien-Smith` as `siobhan.obriensmith` — the
apostrophe and hyphen are removed while the dot survives.

Run `Test-OnboardingRole` after changing it. It checks the three keys agree and reports a
format whose separator the transforms would strip.

## Everyday use

```powershell
# The window
.\Start-OnboardingConsole.ps1

# Or straight from the console
Invoke-Onboarding -FirstName Dana -LastName Reyes -RoleId nurse -ExtraField @{ Unit='3West' }

# Or a whole batch from HR's spreadsheet
Import-Csv .\newhires.csv | ForEach-Object {
    Invoke-Onboarding -FirstName $_.First -LastName $_.Last -RoleId $_.Role
}
```

## Adding a new account type

Copy `Roles\nurse.json`, change `roleId` and `displayName`, adjust the OU, group list,
and SQL actions. Save it in `Roles\`. It appears in the dropdown next time the console
opens. If it needs an operator-supplied value (a unit, a location, a cost centre), add
an entry to `prompts` — the window builds that field automatically, and the answer is
usable as `{Name}` anywhere in the role file and as `@Name` in any SQL action.

## Why the SQL is structured the way it is

Every statement lives in `config.json` as a **named action**, and every value is passed
as a `SqlParameter`. Nothing is ever concatenated into a query, so an operator typing
`O'Brien` can't break — or exploit — anything.

Each action can declare an `existsQuery` returning a count. If it comes back greater
than zero the action is skipped. Combined with the same check on the AD steps, this
makes the whole run **safe to re-run**: if it fails at step 6 of 8, fix the cause and
run it again. Steps 1–5 report `Skipped` and it picks up where it stopped.

## Failure behaviour

- If the **AD account** step fails, everything downstream is skipped — there's no
  point granting groups to a user that doesn't exist.
- If a **group or SQL** step fails, the remaining steps still run. You get a checklist
  with one red line rather than an all-or-nothing failure and no report.
- Every run writes a timestamped log to `logPath`, recording who ran it, what was
  attempted, and what each step returned.

## Suggested change management

Even for two admins, put this folder in a Git repo. Then:

- Role and config changes are reviewable diffs, and you can see *when* a group was
  added to a role and by whom — which is exactly the history that was missing before.
- Bump `ModuleVersion` in the `.psd1` when behaviour changes.
- Keep the working copy on a share or a jump box so you're both running the same
  version, rather than each holding a private copy that drifts.

## Role inheritance (`extends`)

With 30+ job functions, one self-contained file per function would recreate the original
problem — the same group list copy-pasted 22 times, drifting apart over the years.

Instead there are two **abstract** base roles and one small file per job function:

```
base-employee                 all-staff group, employee-number and shift
   |                          prompts, the AD attribute mappings
   |
   +-- base-salaried          salaried OU, E3 licence, VPN, office shares/printers
   |     +-- hr-manager               title + department, nothing else
   |     +-- operations-supervisor    title + department, nothing else
   |     +-- ... 20 more
   |
   +-- base-hourly            hourly OU, F3 licence, floor printers
         +-- agv-operator             title + WMS role code
         +-- tasker                   title + WMS role code
         |     +-- backup-tasker      inherits Tasker's access, overrides the title
         +-- ... 11 more
```

**Licence groups sit on the tier bases, not on `base-employee`.** Because arrays are
additive, an E3 group on the universal base would give hourly staff both E3 *and* F3.
The rule of thumb: something belongs on `base-employee` only if it is true of literally
every account.

**Each backup function extends its primary** (`backup-tasker` extends `tasker`), so it
gets that function's groups and WMS role automatically and its file records only the
title. If a backup should get less than the primary, add the differences there or set
`"sqlActionsReset": true` and list its own.

An individual job function file is the whole of this:

```json
{
  "roleId": "operations-supervisor",
  "displayName": "Operations Supervisor",
  "extends": "base-salaried",
  "ad": { "title": "Operations Supervisor", "department": "Operations" },
  "groups": [],
  "sqlActions": []
}
```

**Merge rules:**

| In the child | Result |
|---|---|
| A scalar (`title`, `ou`, `company`) | Overrides the parent |
| A nested object (`ad`, `otherAttributes`) | Merged property by property, child wins |
| An array (`groups`, `sqlActions`, `prompts`) | **Added** to the parent's, duplicates removed |

The additive rule for arrays is the important one: a job function lists only the groups
that are *extra* for it. To discard an inherited array instead of adding to it, set
`"groupsReset": true` alongside your own `groups`.

Roles marked `"abstract": true` are building blocks — used as parents, hidden from the
dropdown. Add a group to `base-employee` and all 22 job functions get it at once.

Always check what a change actually resolved to:

```powershell
(Get-OnboardingRole -RoleId operations-supervisor).groups
Get-OnboardingRole -IncludeAbstract | Select-Object roleId, displayName, extends
```

## AD attributes

Two categories, and the difference matters:

**First-class attributes** have a dedicated `New-ADUser` parameter and are listed in
`$firstClassFields` in `New-OnbAdAccount.ps1`. Currently: title, department, company,
division, organization, office, description, **employeeNumber**, employeeID,
streetAddress, city, state, postalCode, officePhone, mobilePhone, homePage. Adding a
name to that list is a one-time change that every role then benefits from. AD **rejects**
an attribute supplied both as a parameter and via `otherAttributes`, so a first-class
attribute must not be put in `otherAttributes`.

**Everything else** goes in the role's `otherAttributes` block with no code change at all
— `extensionAttribute1` through `15`, `employeeType`, custom schema extensions.

> **Naming trap:** what Exchange Online calls `CustomAttribute1` is `extensionAttribute1`
> in Active Directory. Same attribute, different name depending on the tool. On-prem you
> must write `extensionAttribute1`.

Current mappings, all set in `base-employee.json` so they apply everywhere:

| Field | Goes to | Value |
|---|---|---|
| Employee number | `employeeNumber` | as entered |
| Employee number | `description` | `Emp# 123456` |
| Shift | `company` | as selected |
| Shift | `extensionAttribute1` | as selected |

## Prompts and validation

The two prompts on `base-employee` appear on every account type because prompt arrays are
inherited additively. A prompt's answer is usable three ways with no further wiring:

- as `{EmployeeNumber}` anywhere in any role file
- as `@EmployeeNumber` in any SQL action
- as an AD attribute value, via either mechanism above

A prompt can carry a `validation` regex and a `validationMessage`. The employee number
uses `^[0-9]+$` — digits only, any length — so a mistyped or pasted value is caught in the
window rather than after it has been written to AD and two databases. If you learn the
real bounds, tighten it to something like `^[0-9]{5,7}$` in `base-employee.json`.

> **Leading zeros:** if any employee number can start with `0`, the receiving SQL column
> must be `VARCHAR`/`NVARCHAR`, not `INT`. An `INT` column silently turns `004821` into
> `4821`, and the `existsQuery` that makes re-runs safe would stop matching.

## Governing how usernames are made

All identifier generation is declared in the `naming` block of `config.json` and applied
by one code path. A role file may override any part of it with its own `naming` block,
which merges attribute by attribute like everything else.

Each identifier declares:

| Key | Purpose |
|---|---|
| `format` | The preferred pattern. `{token:N}` takes the first N characters. |
| `collisionFormats` | Tried in order when the preferred name is taken. |
| `transform` | Applied in order. Put `ascii` first. |
| `maxLength` / `minLength` | Hard bounds. 20 for sAMAccountName is an AD limit. |
| `validate` | Regex the final value must match, or the candidate is rejected. |
| `uniqueIn` | Systems it must be free in: `ad`, or `sql:<SystemName>`. |

Two identifiers ship configured: `samAccountName` (lowercase, max 20, unique in AD) and
`wmsUserId` (uppercase, max 8, unique in the WMS) as a worked example of a system with a
tighter convention. Add another block and it is resolved automatically and made available
everywhere as `{tokenName}` and `@tokenName`.

The console preview reads these same rules — it merges `config.naming` with any role
override exactly as `Invoke-Onboarding` does, and shows every identifier the naming block
defines, not just the username. Change a `format` in `config.json` and the preview changes
with it. It shows *preferred* names only: collisions are resolved against AD and the LOB
systems at run time, so the real account can land on a different name.

**Keep format, transform and validate consistent.** A format containing a separator that
the transforms then strip is silently not what it looks like: `{firstName}.{lastName}`
with an `alphanumeric` transform produces `danareyes`, not `dana.reyes`.
`Test-OnboardingRole` checks every format against its own transforms and validate pattern
and reports the contradiction.

### Collisions

Formats are tried in order, then any format containing `{n}` is retried with n = 2, 3, 4.
Truncation applies to the name part only, never to `{n}` - a chopped counter would collide
with a real account, which is the whole thing this avoids. Twenty people named Dana Reyes
resolve to twenty distinct names, and a sixteen-character surname still fits under the
twenty-character cap with its counter intact.

### Re-runs vs. genuine collisions

This distinction matters more than the formats do.

A matching **name** does not mean "already onboarded" - usually it means a different person
with a similar name. Re-run detection therefore keys on the **employee number**, the only
identifier here that identifies a human:

- **Employee number already in AD** - the same person. Creation is skipped, the remaining
  steps continue against the existing account, and a failed run resumes cleanly.
- **No match** - a new person. Naming allocates them their own identifier, even if the
  preferred name collides.
- **Name taken but employee number does not match it** - the run stops with a clear failure
  and changes nothing.

Before this, a second Dana Reyes would have been reported as "Skipped" and then had her
groups and WMS roles applied *to the first Dana Reyes's account*.

### Awkward names

`ascii` folds accented letters to their base rather than deleting them, and handles the
letters with no decomposed form. `alphanumeric` then removes apostrophes, hyphens and
spaces. Verified end to end: `O'Brien-Smith` gives `sobriensmith`, `Hernandez Rodriguez`
gives `jhernandezrodriguez`, and accented surnames fold correctly.

> Both `Convert-OnbName.ps1` and every other file in this module are deliberately pure
> ASCII. Windows PowerShell 5.1 assumes the system ANSI codepage for a `.ps1` saved as
> UTF-8 without a BOM, which corrupts literal accented characters. Special letters are
> written as `[char]` codepoints instead. If you edit that file, keep it ASCII.

## Checking your work

Inheritance has one failure mode worth respecting: a change to a base role can break all
of its children, while every individual file still looks perfectly fine on its own. So
after editing any role file — and especially a base role — run:

```powershell
Test-OnboardingRole                                  # every role, every check
Test-OnboardingRole | Where-Object Status -ne OK     # just the problems
```

It verifies that each selectable role still has an OU, title, employee-number attribute,
the `Emp# ...` description and shift mapping, both inherited prompts, exactly one licence
group, no leaked `abstract` flag, that every SQL action names a system and action that
actually exist in `config.json`, and that every naming format agrees with its own
transforms and validate pattern.

The licence check earns its place: because arrays are additive, putting a licence group
on `base-employee` gives the hourly tier both E3 and F3. That is invisible in the role
files and expensive in Microsoft billing. Adding one to the universal base flags 14 roles
immediately.

To see what a specific role resolved to, or why one vanished from the dropdown:

```powershell
(Get-OnboardingRole -RoleId backup-tasker).groups
Get-OnboardingRole -IncludeAbstract -Verbose | Select-Object roleId, displayName, abstract
```

## Not yet wired up

- Exchange hybrid mailbox enablement (`Enable-RemoteMailbox`) — omitted because
  licensing appears to be group-based here. If mailboxes need explicit provisioning,
  it becomes one more private function and one more step in the orchestrator.
- Home folder / share permissions.
- A `Remove-`/offboarding counterpart, which would reuse the same role files in reverse.
- Real group names. Every `groups` array holds placeholder `GRP-*` names.
- Real WMS role codes. Each hourly function carries a placeholder `RoleCode` derived from
  its title (`AGV_OPERATOR`, `BACKUP_GROUP_COORDINATOR`); replace with the real codes.
- Real SQL schema. The `WMS` and `LaborManagement` statements in `config.json` are
  plausible shapes, not your actual tables.
