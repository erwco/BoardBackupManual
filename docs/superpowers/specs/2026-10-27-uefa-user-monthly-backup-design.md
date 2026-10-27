# Design: add UEFA_User database with month-end-only selection

Date: 2026-10-27
Requested by: Thomas Biselx (FS Support Team)
Script: `Run-Backup.bat` -> `scripts/Backup-BoardApp.ps1` (+ `scripts/azCopyInterface.psm1`, `scripts/backup-config.json`)

## Request

Add one database to the backup transfer:

- Source path: `https://uefastrg01.file.core.windows.net/bss/backup/uefa-c1`
- Backup folder: `UEFA_User.hbmp`
- Destination: `\\uefafiler01\FFP-Board-Backup\uefa-c1`
- Selection rule: only the backup corresponding to the last day of the previous
  month. Example: a run on 03.08.2026 selects the folder dated 31.07.2026. The
  mid-month (day 16) snapshot must NOT be transferred for this database.
- All existing databases (LD, CLFFP, QA) keep their current behaviour: both the
  month-end and the mid-month snapshot.

## Current behaviour (relevant parts)

- `BackupDays` (global, `[1, 16]`) is turned into target dates by
  `Get-LastMonthDay`: the most recent occurrence of each day-of-month.
- For every `BackupPaths` entry, the script lists the Azure directory once, then
  for each `type` and each target date selects the newest folder whose embedded
  timestamp is strictly before that date. Day 1 therefore yields the last
  backup of the previous month; day 16 yields the mid-month backup.
- Folder names are matched with `DirectoryRegex`; the `type` capture group is
  the alternation `(LD|CLFFP|QA)`. `UEFA_User.hbmp` does not match today and is
  ignored.
- Destination is `<Destination>\<entry name>\<folder name>`, so an entry named
  `uefa-c1` already lands in `\\uefafiler01\FFP-Board-Backup\uefa-c1`.

## Design

### Config: optional per-entry `days`

Each `BackupPaths` entry may carry an optional `days` array. When present it
replaces the global `BackupDays` for that entry only. When absent the global
value applies (no change for existing entries).

`scripts/backup-config.json` after the change:

```json
{
    "StorageUrl": "https://uefastrg01.file.core.windows.net",
    "Destination": "\\\\uefafiler01\\FFP-Board-Backup",
    "BackupDays": [1, 16],
    "DirectoryRegex": "^(?<datetime>\\d+-\\d+-\\d+\\s\\d+-\\d+-\\d+-\\d+)\\W+\\w+(?<type>(LD|CLFFP|QA|User))\\.hbmp$",
    "SyncTimeoutSeconds": 18000,
    "BackupPaths": [
        { "name": "uefa-c1", "path": "bss/backup/uefa-c1", "types": ["LD", "CLFFP", "QA"] },
        { "name": "uefa-c1", "path": "bss/backup/uefa-c1", "types": ["User"], "days": [1] },
        { "name": "uefa-s1", "path": "bss/backup/uefa-s1", "types": ["LD", "CLFFP"] }
    ]
}
```

Two changes: `User` is added to the regex alternation, and a second `uefa-c1`
entry restricted to type `User` with `days: [1]` is added.

### Script changes (`scripts/Backup-BoardApp.ps1`)

1. **Config conversion.** When building the `$BackupPaths` hashtables, copy an
   optional `days` property. Validate it: if present it must be a non-empty
   array of integers in 1..31, otherwise throw a configuration error naming the
   entry (same style as the existing `types` validation).
2. **Target dates per entry.** Replace the single global `$targetDates`
   computation with a helper that computes target dates from a given day list.
   Compute the global list once (for the log line that exists today), and for
   each entry compute `$entryTargetDates` from `$bkPath.days` when set, else
   reuse the global list. Log the entry's target dates in the existing
   "Searching target directories..." message so a user can see that `User`
   only has one date.
3. **Selection loop.** Iterate `$entryTargetDates` instead of `$targetDates`.
   No other change to the selection, sync, or summary logic.

`Get-LastMonthDay` in the module is unchanged. No change to `Run-Backup.bat`
or `Run-Backup-Debug.bat`.

### Documentation (`UserGuide.html`)

- Section 5d "Directory discovery": mention type `User` and that an entry can
  restrict itself to specific days.
- Section 7 "Configuration Reference", `BackupPaths` row: add
  `days` (optional) - overrides `BackupDays` for this entry; used for
  `UEFA_User` so only the month-end snapshot is transferred.

## Behaviour after the change

Run on 03.08.2026, global `BackupDays` `[1, 16]`:

| Entry            | Target dates        | Folders selected (per type)              |
|------------------|---------------------|------------------------------------------|
| uefa-c1 LD/CLFFP/QA | 01.08, 16.07     | newest before 01.08 (31.07), newest before 16.07 (15.07) |
| uefa-c1 User     | 01.08               | newest before 01.08 (31.07) only          |
| uefa-s1 LD/CLFFP | 01.08, 16.07        | unchanged                                 |

Run on 20.08.2026: `User` target date is still 01.08 (day 1 has already
occurred this month), so the 31.07 folder is selected. The rule "last day of the
previous month" holds whenever the script runs during the month.

Cost: `bss/backup/uefa-c1` is listed from Azure twice per run (one extra small
HTTP request). Accepted for simplicity; a listing cache can be added later if
more split entries appear.

## Error handling

- Invalid `days` (not an array, empty, non-integer, outside 1..31) stops the
  script at config load with a message naming the entry, before any SAS prompt.
- A `User` folder missing in Azure results in zero matches for that entry, same
  as today for any other type. The run continues with the other entries.

## Alternatives considered

- **Per-type override map** (`"typeDays": { "User": [1] }` on the existing
  entry): avoids the duplicate listing but adds a nested config shape and more
  PowerShell 5.1 parsing code.
- **Top-level `MonthlyOnlyTypes`**: smallest config but hard-codes a type name
  into a global special case.

## Testing

No live Azure or filer access is available in the development environment, so
verification is by unit-style checks:

1. Regex check: `UEFA_LD`, `UEFA_CLFFP`, `UEFA_QA`, `UEFA_User` folder names
   match with the expected `type`; an unrelated name does not match.
2. Selection check: a PowerShell test that fakes the directory listing for
   uefa-c1 (folders for 15.07, 31.07, 15.08 for all four types), fixes the
   reference date to 03.08.2026, and asserts that `User` selects only the
   31.07 folder while `LD` selects 31.07 and 15.07. This requires making the
   reference date injectable, so `Get-LastMonthDay` gains an optional
   `-ReferenceDate` parameter defaulting to today (behaviour unchanged).
3. Config validation check: `days` with an out-of-range value throws the
   expected configuration error.
4. Manual run by the operator with `Run-Backup-Debug.bat` after deployment, and
   confirm the summary table lists exactly one `UEFA_User.hbmp` row.

## Out of scope

- Creating the approval ticket Thomas mentioned (that is his process step).
- Caching directory listings, or changing how other types are selected.
