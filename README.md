# MicroSIP Answered-Call Logger for Obsidian

A small Windows PowerShell integration that appends answered incoming MicroSIP
calls to one Markdown note per day in an Obsidian vault. It records metadata
only—never audio—and uses MicroSIP's `cmdCallAnswer` event so missed, rejected,
and unanswered calls are excluded.

## Main features

- Answer-time timestamps in 24-hour `HH:mm` format
- End timestamps and durations in `HH:mm:ss`
- Daily files named `dd-MM-yyyy.md`
- Caller name from caller ID, then MicroSIP contacts, then `Unknown caller`
- Caller-ID parsing for plain numbers, SIP addresses, and display-name formats
- Greek `+30`, `0030`, and national-number contact matching
- UTF-8 Markdown, safe appends, automatic folder/note creation
- Hidden, non-interactive PowerShell execution and private error diagnostics

## Requirements

- Windows with MicroSIP and Windows PowerShell 5.1
- A locally accessible Obsidian vault
- Permission to run PowerShell scripts
- Optional: Obsidian's **Copy Inline Code** community plugin

## Installation

1. Create `%USERPROFILE%\Scripts\MicroSIP`.
2. Copy `LogAnsweredCall.ps1`, `CompleteAnsweredCall.ps1`, and
   `LaunchAnsweredCall.vbs` there.
3. Copy `config.example.json` there as `config.json`.
4. Edit `callsFolder` in `config.json` to an absolute path in your vault.
5. Close MicroSIP, then run `Install-MicroSIPHook.ps1`. It backs up the INI
   before setting the answer hook.
6. Start MicroSIP again.

Example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-MicroSIPHook.ps1
```

## MicroSIP configuration

The installer edits `%APPDATA%\MicroSIP\MicroSIP.ini` and sets
`cmdCallAnswer` and `cmdCallEnd` to launch a small Windows Script Host bridge
with the caller number MicroSIP appends. The bridge preserves caller-ID spacing
and quotes, then starts PowerShell invisibly and non-interactively. Portable
installations can pass a different INI:

```powershell
.\Install-MicroSIPHook.ps1 -MicroSipIni 'D:\Apps\MicroSIP\MicroSIP.ini'
```

The official [MicroSIP documentation](https://www.microsip.org/help) states
that `cmdCallAnswer` runs when the user answers an incoming call and receives
caller ID as a parameter.

## Obsidian configuration

Set `callsFolder` in the private `config.json`, for example:

```json
{
  "callsFolder": "C:\\Users\\YOUR_WINDOWS_USER\\Documents\\YOUR_VAULT\\Calls",
  "contactsFile": "%APPDATA%\\MicroSIP\\Contacts.xml"
}
```

For a copy button beside every number, open **Settings → Community plugins →
Browse**, find **Copy Inline Code**, install it, and enable it. The logger
writes each number as inline code, so the plugin can copy only that number.

## Contact-name lookup

The logger prefers a usable name in MicroSIP's caller-ID argument. Otherwise,
it checks the `number`, `phone`, and `mobile` fields in `Contacts.xml`.
International Greek `+30`/`0030` forms are matched to 10-digit national forms.
Short workplace extensions are compared exactly. With no match, the name is
`Unknown caller`.

## Daily-note format

```markdown
# Calls — 23-07-2026

- Answered: 09:42 — Ended: 09:57 — Duration: 00:15:08 — John Smith — `+30 210 123 4567` — Transferred: not reported by MicroSIP
- Answered: 11:17 — Ended: 11:20 — Duration: 00:03:19 — Unknown caller — `6941234567` — Transferred: not reported by MicroSIP
```

Names remain plain text, numbers remain useful for pasting/dialing, and entries
are appended in recording order without replacing unrelated note content.
While a call is active, its end time and duration display as `in progress`.
The hidden HTML marker at the end of each entry lets the end event update only
the matching call.

## Configuration options

`config.json` supports:

- `callsFolder` (required): absolute destination folder for daily notes
- `contactsFile` (optional): MicroSIP XML contacts path; environment variables
  such as `%APPDATA%` are expanded

## Testing

Run the isolated test suite; it uses temporary files and does not touch your
vault or MicroSIP configuration:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Logger.ps1
```

Then answer one controlled incoming call, hang up, and confirm today's entry
contains the answer time, end time, and duration.
Place a second test call that is not answered and confirm no entry is added.
Real caller-ID formatting depends on the PBX/provider, so test number-only,
named, international, and contact-resolved calls relevant to your environment.

## Troubleshooting

- No note: confirm `config.json` is beside the logger and `callsFolder` exists
  or its parent is available (including OneDrive).
- No event: restart MicroSIP after changing its INI and confirm the active INI.
- Wrong/missing name: inspect the non-sensitive shape of caller ID and confirm
  the number appears in `Contacts.xml`.
- Write failure: inspect `%USERPROFILE%\Scripts\MicroSIP\logs\errors.log`.
- Script policy error: retain the installer's `-ExecutionPolicy Bypass` command.

## Privacy considerations

Daily notes contain names, numbers, and answer times and may be sensitive.
Follow workplace privacy and retention rules. The project records no audio.
Never commit `config.json`, contact files, vault data, call logs, diagnostics,
SIP credentials, or a live `MicroSIP.ini`; the included `.gitignore` excludes
common local artifacts.

## Known limitations

- The initial version handles one answered call at a time.
- MicroSIP exposes only the caller number to `cmdCallAnswer` and `cmdCallEnd`.
  It does not expose a transfer-success flag, so transfer status is recorded as
  `not reported by MicroSIP` rather than an unreliable Yes/No guess.
- Provider/PBX-specific caller-ID formats may need parser adjustments.
- Greek national/international normalization is included; other national plans
  are not inferred.
- The logger relies on MicroSIP emitting `cmdCallAnswer` exactly once.
- Copy controls require the third-party Obsidian plugin.

## Uninstallation

Close MicroSIP. Restore the timestamped `MicroSIP.ini.backup-*` file created by
the installer, or set `cmdCallAnswer=""` in the active INI. Then remove
`%USERPROFILE%\Scripts\MicroSIP`. Existing Markdown notes are not deleted.

## License

[MIT](LICENSE)
