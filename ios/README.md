# Monica for iOS (MonicaSync)

A native iPhone companion app for [Monica](https://www.monicahq.com), the open-source
personal CRM. It connects to **monicahq.com or any self-hosted Monica instance** through
the Monica REST API and keeps your CRM data available where the iPhone already looks
for it:

| Monica (server) | iPhone | Direction |
| --- | --- | --- |
| People (names, nicknames, job & company, birthdays, addresses, emails, phone numbers, avatars) | **Contacts** app, in a dedicated *“Monica”* group | Monica → iPhone, plus optional push-back of email/phone edits |
| Tasks | **Reminders** app, in a dedicated *“Monica”* list | Two-way (completion & renames sync back to the server) |
| Reminders (birthdays, stay-in-touch, one-off & recurring) | **Calendar** app, dedicated *“Monica”* calendar, as recurring all-day events with a morning alert | Monica → iPhone |
| Activities (things you did together) | **Calendar** app, all-day events on the day they happened | Monica → iPhone |

The app also lets you browse your contacts, see their timeline (calls, activities,
reminders, tasks), log a call, add tasks, and complete tasks — all written straight to
your Monica server.

## Requirements

- **Server:** a Monica instance exposing the stable REST API (Monica **v4.x**, which is
  what monicahq.com and current self-hosted releases run). The v5 rewrite on `main`
  only exposes a minimal API so far; this app will adopt it once contacts/tasks
  endpoints land there.
- **Client:** iOS 17.0+, Xcode 15+ to build.

## Building

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
so no `.xcodeproj` churn lands in the repo:

```bash
brew install xcodegen
cd ios
xcodegen            # generates MonicaSync.xcodeproj
open MonicaSync.xcodeproj
```

Select your development team under *Signing & Capabilities*, then build & run on a
device or simulator. There are no third-party dependencies — the app is plain SwiftUI
+ Foundation + Contacts + EventKit + BackgroundTasks.

## Connecting to your server

1. On your Monica instance, go to **Settings → API** and create a personal access
   token.
2. In the app's welcome screen, enter your server URL (`https://app.monicahq.com` or
   your self-hosted URL) and paste the token.
3. The token is stored in the iOS Keychain; the server URL in app preferences.

Self-hosted notes:

- Use HTTPS. App Transport Security blocks plain `http://` for public hosts;
  `http://` to local-network hosts is permitted for development setups.
- If your instance lives in a subdirectory, include the path (the app normalizes
  trailing slashes and a pasted `/api` suffix automatically).

## How syncing works

- **Manual:** the *Sync* tab has a *Sync now* button and shows per-engine results.
- **Background:** a `BGAppRefreshTask` re-syncs periodically when iOS allows it.
- Each mirrored item carries a marker back to its Monica record — synced contacts get
  a “Monica” URL pointing at their profile on your server, reminders/events carry a
  `monica://…` line in their notes. After a reinstall the app re-adopts existing items
  instead of creating duplicates.
- Sync bookkeeping (Monica ID ↔ device ID, change fingerprints) lives in a JSON file
  in the app container; the address book, Reminders and Calendar stores are never
  scanned beyond the app's own group/list/calendar plus a one-pass URL index used for
  re-adoption.

### Conflict rules

- Monica is the source of truth. Server-side changes always win over conflicting
  local edits.
- Contacts edited **only** on the iPhone are left untouched until the same person
  changes on the server. With **Settings → Push local contact edits** enabled, added
  or removed emails/phone numbers are written back to Monica as contact fields.
- Completing or renaming a synced reminder on the iPhone is always pushed back to the
  corresponding Monica task.
- Deleting a mirrored item on the iPhone is respected — the app tombstones it and
  won't re-create it (the record stays in Monica).
- Deleting something in Monica removes its mirror on the next sync (can be turned off
  in Settings).

### Privacy & permissions

The app asks for Contacts, Reminders and Calendar access the first time each engine
runs; each permission is only needed for the sync directions you enable. All traffic
goes exclusively to the server you configured. Contact *notes* are deliberately not
written (iOS gates them behind a special entitlement).

## Known limitations

- Avatars are fetched when a contact is first created on the device, not refreshed on
  every change.
- Custom Monica contact-field types (social profiles, etc.) are not mirrored — only
  emails and phone numbers.
- New reminders created directly in the “Monica” Reminders list are not turned into
  Monica tasks (Monica tasks need a contact). Create tasks from a contact's page in
  the app instead.
- Monica “gifts” and “debts” have no iOS counterpart and stay in the app/on the web.

## Project layout

```
ios/
├── project.yml                  # XcodeGen manifest
└── MonicaSync/
    ├── Resources/               # Info.plist, asset catalog
    └── Sources/
        ├── App/                 # App entry point, session/app model, background refresh
        ├── API/                 # Monica REST API client + Codable models
        ├── Sync/                # Contacts/Reminders/Calendar engines, mapping store
        ├── Support/             # Keychain helper
        └── UI/                  # SwiftUI screens (onboarding, people, tasks, sync, settings)
```
