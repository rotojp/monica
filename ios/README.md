# Monica for iOS (MonicaSync)

A native iPhone companion app for [Monica](https://www.monicahq.com), the open-source
personal CRM. It connects to **monicahq.com or any self-hosted Monica instance** —
both **classic v4** and **v5 (the current beta rewrite)** — through the Monica REST
API and keeps your CRM data available where the iPhone already looks for it:

| Monica (server) | iPhone | Direction |
| --- | --- | --- |
| People (names, job & company, birthdays, addresses, emails, phone numbers, avatars) | **Contacts** app, in a dedicated *“Monica”* group | Monica → iPhone, plus optional push-back of email/phone edits |
| Tasks | **Reminders** app — a list you pick, or a dedicated *“Monica”* list | Two-way (completion always syncs back; renames too on v4) |
| Reminders (birthdays, stay-in-touch, recurring) | **Calendar** app — a calendar you pick, or a dedicated *“Monica”* calendar; recurring all-day events with a morning alert | Monica → iPhone |
| Activities (v4 only) | **Calendar** app, all-day events on the day they happened | Monica → iPhone |

The app also lets you browse your contacts and their timeline (calls, reminders,
tasks, activities), log calls, and create/complete tasks — written straight to your
Monica server.

## Choosing what syncs

- **Contacts to import** — sync everyone, or flip on *Sync only selected contacts*
  and hand-pick people in Settings. Deselecting someone removes their mirror on the
  next sync (the Monica record is never touched).
- **Reminders list** — pick any existing writable Reminders list, or let the app
  keep a dedicated “Monica” list.
- **Calendar** — pick any existing writable calendar, or let the app keep a
  dedicated “Monica” calendar.

Inside a shared list/calendar, the app only ever touches items it created itself
(they carry a `monica://…` marker in their notes).

## Server support

| | Classic Monica v4 | Monica v5 (beta) |
| --- | --- | --- |
| Detection | automatic | automatic |
| Auth | API token (Settings → API) | Sanctum token (Settings → API Tokens, needs `read` + `write`) |
| Scope | whole account | one **vault** (pick at sign-in, switch in Settings) |
| Contacts / tasks / reminders / calls | ✅ | ✅ |
| Activities | ✅ | — (v5 uses journals; no read API yet) |
| Task rename push-back | ✅ | — (completion toggle only) |

**Monica v5 note:** the vault-scoped REST endpoints the app uses
(`/api/vaults/{vault}/contacts|tasks|reminders|…`) ship in this repository —
see `routes/api.php` and `app/Domains/*/Api/Controllers`. A v5 server must
include those endpoints (any build of this repo from this branch/PR onwards).

## Native CardDAV/CalDAV as an alternative

Monica servers also expose DAV at `https://your-server/dav`. The app's
**Settings → Native CardDAV/CalDAV sync** screen walks you through adding the
server as a native iOS account, which lets iOS itself sync contacts/calendars
continuously in both directions. Both approaches can run side by side.

## Requirements & building

iOS 17.0+, Xcode 15+. The project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen); no third-party runtime
dependencies (SwiftUI + Foundation + Contacts + EventKit + BackgroundTasks):

```bash
brew install xcodegen
cd ios
xcodegen            # generates MonicaSync.xcodeproj
open MonicaSync.xcodeproj
```

Select your development team under *Signing & Capabilities*, then build & run.

## Connecting to your server

1. Create an API token on your Monica server (see the table above).
2. In the app's welcome screen, enter your server URL and paste the token.
3. On a v5 server with several vaults, pick the vault to sync.

The token lives in the iOS Keychain. Use HTTPS; plain `http://` is only allowed
toward local-network hosts (development setups).

## How syncing works

- **Manual:** the *Sync* tab has a *Sync now* button and shows per-engine results.
- **Background:** a `BGAppRefreshTask` re-syncs periodically when iOS allows it.
- Each mirrored item carries a marker back to its Monica record — synced contacts
  get a “Monica” URL pointing at their profile, reminders/events carry a
  `monica://…` line in their notes. After a reinstall the app re-adopts existing
  items instead of creating duplicates.
- Sync bookkeeping (Monica ID ↔ device ID, change fingerprints) lives in a JSON
  file in the app container.

### Conflict rules

- Monica is the source of truth. Server-side changes always win over conflicting
  local edits.
- Contacts edited **only** on the iPhone are left untouched until the same person
  changes on the server. With **Settings → Push local contact edits** enabled,
  added or removed emails/phone numbers are written back to Monica.
- Completing a synced reminder on the iPhone is always pushed back to the
  corresponding Monica task.
- Deleting a mirrored item on the iPhone is respected — the app tombstones it and
  won't re-create it (the record stays in Monica).
- Deleting something in Monica (or deselecting a contact) removes its mirror on
  the next sync (can be turned off in Settings).

### Privacy & permissions

The app asks for Contacts, Reminders and Calendar access the first time each
engine (or picker) runs. All traffic goes exclusively to the server you
configured. Contact *notes* are deliberately not written (iOS gates them behind a
special entitlement).

## Known limitations

- Avatars are fetched when a contact is first created on the device, not
  refreshed on every change.
- Custom Monica contact-field types (social profiles, …) are not mirrored — only
  emails and phone numbers.
- New reminders created directly in the target Reminders list are not turned into
  Monica tasks (Monica tasks need a contact). Create tasks from a contact's page
  in the app instead.
- Monica v5 journals, groups, loans and files have no iOS counterpart yet.

## Project layout

```
ios/
├── project.yml                  # XcodeGen manifest
└── MonicaSync/
    ├── Resources/               # Info.plist, asset catalog
    └── Sources/
        ├── App/                 # App entry point, session/app model, background refresh
        ├── API/                 # Neutral sync models, backend protocol, v4 + v5 clients
        ├── Sync/                # Contacts/Reminders/Calendar engines, mapping store
        ├── Support/             # Keychain helper
        └── UI/                  # SwiftUI screens (onboarding, people, tasks, sync, settings, pickers, DAV)
```
