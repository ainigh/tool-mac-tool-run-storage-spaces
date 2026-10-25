# Storage Spaces

Storage Spaces keeps what the apps on your Mac keep, a space each, and serves it to them over
HTTP on `127.0.0.1:8771` ([API.md](API.md)). It's a small app in the menu bar (three stacked
squares), and everything it keeps is in plain files in `~/Desktop/STORAGE-SPACES`, so you can
open, read and change any of it yourself.

| Space | Whose | What's in it |
|---|---|---|
| **USER** | yours | **LIBRARY** (your notes), **MEMORY** (a file for each kind of thing remembered: PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS…, each a node of the mind), **MIND** (how it all links, in the text mind-map notation) |
| **SUPER** | [Super Face](https://github.com/ainigh/JUST-super-mac-tts-ONLY-service)'s | **PROMPT** (the standing instructions it reads before every request), **MEMORY** (its playbook: what it has learned about getting things done for you) |
| **PETER** | [Peter](https://github.com/ainigh/tool-mac-tool-run-agent)'s | **SCHEDULE**, **STATUS**, **FOLLOWING** (the runs he's following), **SETTINGS** |
| **PENDING** | waiting | **REQUESTS** (apps asking for access), **WRITES** (changes held until they're approved) |
| **OTHER** | any other app's | a folder of notes each, made the first time it writes |

The library, MEMORY and the mind are the ones [Tool Mac Tool Run](https://github.com/ainigh/tool-mac-tool-run)
had, moved here as they were (the same files, the same operations, the same routes:
`/api/library`, `/api/memory`, `/api/mind`). How the apps fit together, and what changes in
the others: [ARCHITECTURE.md](ARCHITECTURE.md).

- **Who may do what.** Peter may read and write every space: he's the one who gets things done,
  and the one who lets other apps in. Every other app has its own space, and asks for the rest
  (`POST /api/access/requests`): Peter says yes or no, or you do, in the window (for an hour, or
  for good). A change an app may not make can wait in PENDING until it's approved. Apps can claim
  their names with a key, so no other can pass itself off as Peter.
- **Records with versions.** Peter's things are JSON records; every write raises a record's
  version, and a write that would overwrite someone else's unseen is turned down.
- **What changed, as it happens.** `GET /api/changes?after=N&wait=25`: an app waits for the next
  change instead of asking again and again.
- **Its window.** Click the icon › **Open Storage Spaces…**: every space and store (a click shows
  it in the Finder), what's **Waiting** for your yes or no (the icon fills in when something is,
  and a notification says so), who's **Allowed** what (take any of it back), and the settings.
- **Tool Mac Tool Run's things come in.** The first time it opens, it copies in Tool Mac Tool
  Run's library, MEMORY and mind (and Peter's schedule), leaving the originals as they were.
  **Bring In Tool Mac Tool Run's Things** in its menu does it again (only what's new).
- **Resets.** Reset one space (its things to the Trash, then as it came), or **Factory Reset…**
  in the menu: every space to the Trash, the settings forgotten, and the app opens again as it
  was installed.

## Install

Paste this in Terminal (it installs Homebrew's `gh` if needed and signs you in to GitHub, since
the repository may be private):

```bash
/bin/bash -c 'for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && eval "$("$b" shellenv)"; done; command -v gh >/dev/null || brew install gh; gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https -h github.com; gh api -H "Accept: application/vnd.github.raw" repos/ainigh/tool-mac-tool-run-storage-spaces/contents/install.sh | bash'
```

It takes the latest release GitHub built (or builds it on your Mac if there's none yet: that
needs Apple's command line tools), installs `~/Applications/StorageSpaces.app`, and opens it. It
adds itself to your login items the first time (**Open at Login** in its menu turns that off).
Needs macOS 14 or newer. macOS asks once whether it may use your Desktop folder (that's where
STORAGE-SPACES is): say yes.

**Updates**: it checks at launch and every six hours; when there's a new version, its menu (and a
notification) says so, and **Update** installs it and restarts it (if the new one won't open, the
one you had comes back). Running the install line again works too. What an update did is in
`~/Library/Logs/StorageSpaces/update.log`. An update never touches STORAGE-SPACES.

## Try it

```bash
curl -s localhost:8771/api/health
curl -s localhost:8771/api/spaces -H 'X-Client: Peter'
curl -s -X PUT localhost:8771/api/library/files/groceries -H 'X-Client: Peter' -d '{"text": "- eggs"}'
curl -s -X POST localhost:8771/api/access/requests -H 'X-Client: Me' -d '{"space": "user", "store": "library", "access": "read", "why": "trying it"}'
open http://127.0.0.1:8771/
```

## Working on it

```bash
swift test                 # StorageCore, on any machine (Linux too)
swift run StorageSpaces    # the app, on a Mac (STORAGE_HOME=/tmp/spaces to keep it away from your Desktop)
scripts/build-app.sh       # build/StorageSpaces.app and build/StorageSpaces.zip
```

| | |
|---|---|
| `Sources/StorageCore/Spaces.swift` | the spaces, their stores, where each is on disk, making them ready, resetting one |
| `Sources/StorageCore/Notes/`, `Mind/` | notes (the library), MEMORY and the mind: moved from Tool Mac Tool Run as they were |
| `Sources/StorageCore/Records.swift` | records: JSON by key, with versions |
| `Sources/StorageCore/Access.swift` | who may do what: the rules, grants, clients' keys |
| `Sources/StorageCore/API/` | the HTTP API: the router, notes, MEMORY, the mind, records, access, PENDING |
| `Sources/StorageCore/Import.swift`, `FactoryReset.swift` | bringing Tool Mac Tool Run's things in; the factory reset |
| `Sources/StorageSpaces/` | the menu bar app: its menu, its window, the server, the updater |
| `docs/` | the docs it serves (`/api/docs/{name}`): the mind's notation and guide, MEMORY's guide |

Every push is tested on Linux and built on macOS by GitHub Actions; a push to `main` is
published as a release, which is what the install line and the updater take.
