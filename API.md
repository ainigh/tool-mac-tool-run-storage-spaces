# Storage Spaces API ({{VERSION}})

Storage Spaces keeps what the apps on this Mac keep, a space each, and serves it over HTTP at
**`http://127.0.0.1:8771`** (this Mac only). Every answer is JSON (a note read with
`?format=text`, the mind's log and the docs are text). Nothing waits for a click on the Mac:
it's storage, not programs.

## In one minute

```bash
# Who you are goes with every request: "client" (in the query or body), or an X-Client header.
curl -s localhost:8771/api/spaces -H 'X-Client: Peter'

# The person's library, MEMORY and mind, as Tool Mac Tool Run served them:
curl -s -X PUT localhost:8771/api/library/files/groceries -H 'X-Client: Peter' -d '{"text": "- eggs"}'
curl -s localhost:8771/api/memory/recall?name=ada -H 'X-Client: Peter'
curl -s -X POST localhost:8771/api/mind/add -H 'X-Client: Peter' -d '{"from": "sam", "label": "writes", "to": "paper"}'

# Peter's records (JSON by key, versioned):
curl -s -X PUT localhost:8771/api/spaces/peter/schedule/records/item-1 -H 'X-Client: Peter' -d '{"text": "stand up", "due": "2026-11-03T09:00:00Z"}'

# An app that may not read MEMORY asks; Peter (or the person) says yes:
curl -s -X POST localhost:8771/api/access/requests -H 'X-Client: Super Voice' -d '{"space": "user", "store": "memory", "access": "read", "why": "to greet people by name"}'
curl -s -X POST localhost:8771/api/access/requests/1/approve -H 'X-Client: Peter' -d '{"hours": 2}'

# What changed (waits up to 25 seconds for something to):
curl -s 'localhost:8771/api/changes?after=0&wait=25' -H 'X-Client: Peter'
```

## The spaces

| Space | Whose | Its stores (kind) |
|---|---|---|
| `user` | the person's | `library` (notes): their notes · `memory` (memory): MEMORY, a file for each kind of thing (PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS, LOCATIONS, IDEAS, LEVERAGE, STRATEGIES, OTHERS), each a node of the mind · `mind` (mind): the append-only log in the text mind-map notation |
| `super` | Super Face's | `prompt` (notes): its standing instructions (`instructions`), and any other part of its prompt kept here · `memory` (notes): what it has learned (`playbook`) |
| `peter` | Peter's | `schedule`, `status`, `following` (the runs he's following), `settings` (records) |
| `pending` | the system's | `requests` (access asked for), `writes` (changes held for approval), as records: read them through `/api/access/requests` and `/api/pending` |
| `other` | any other app's | a notes store per app, named by its name in lower case with dashes (`Super Voice` → `other/super-voice`), made the first time it writes |

On disk: `~/Desktop/STORAGE-SPACES/USER/LIBRARY/groceries.md`, `PETER/SCHEDULE/item-1.json`… (or
where `STORAGE_HOME` says). Every file can be read and changed by hand.

Every store's routes are under `/api/spaces/{space}/{store}`; `GET` it for what it has and every
operation it takes. The person's three keep Tool Mac Tool Run's routes too:
`/api/library…` = `/api/spaces/user/library…`, `/api/memory…` = `/api/spaces/user/memory…`,
`/api/mind…` = `/api/spaces/user/mind…`.

## Who may do what

- **Who you are**: `client` (in the query or the JSON body), else the `X-Client` header, else your
  User-Agent's first word. No name: `401 who_are_you`. `you` and `Storage Spaces` are reserved.
- **The rules**: **Peter** may read and write every space (he's the one who lets other apps in).
  **Super Face** may read and write `super`. **Any other app** may read and write its own store in
  `other`. The person may do anything, in the Storage Spaces window.
- **The rest is asked for** (below), and a yes is a **grant**: an app may `read` (or `write`) a
  space, or one store of it, for good or until a time.
- Storage Spaces comes with one grant: **Tool Mac Tool Run** may write `user` (the library,
  MEMORY and the mind were its own). The person can take it back.
- Turned down: `403 no_access`, with `need`, `has`, the `fix`, and `ask`: the request to send.

### Claiming a name: `POST /api/clients/register`

Sent once, in your name: the answer has a `key`. From then on every request in that name must
carry it (`X-Storage-Key: <key>`, or `Authorization: Bearer <key>`), or it's `401 bad_key`; so no
other app can pass itself off as you. Registering again needs the old key (`409 name_taken`
without it). Lost it: the person forgets it in the window (Access › Forget Its Key), and you
register again. Only the key's hash is kept. `GET /api/clients`: the apps known.

### Asking: `/api/access…`

| Route | Who | What |
|---|---|---|
| `GET /api/access` | anyone | what you may do with every store, your grants, the rules (Peter: `?for=<app>`; and every grant, every open request) |
| `GET /api/access/check?space=&store=&access=` | anyone | `access`, `allowed` (Peter: `&for=<app>`) |
| `POST /api/access/requests` | any app | `{space, store?, access: read·write, why, until?·minutes?·hours?·days?}` → `202`, the request (`id`, `state: open`). The same one still open is that one. Already allowed: `state: already` |
| `GET /api/access/requests` (`?state=open`) | anyone | yours (Peter, the person: every one) |
| `GET /api/access/requests/{id}` | its app, Peter | how it went: `open`, `approved` (with its `grant`), `denied` (with an `answer`), `withdrawn` |
| `POST /api/access/requests/{id}/approve` | Peter, the person, the space's owner | `{access?, until?·hours?…, why?}`: a grant (no more than was asked) |
| `POST /api/access/requests/{id}/deny` | the same | `{why?}` |
| `DELETE /api/access/requests/{id}` | its app | takes it back |
| `GET /api/access/grants` | anyone | the grants you have, or may give |
| `POST /api/access/grants` | Peter, the person, the space's owner | `{to, space, store?, access, until?·hours?…, why?}`: a yes without being asked |
| `DELETE /api/access/grants/{id}` | the same, or the app itself | takes it back |

Once decided, a request stays a week (so its app can see how it went), then goes.

### Holding a change: `"hold": true`

A change you may not make, sent with `"hold": true` (in the body or query, or an `X-Hold: true`
header), isn't turned down: it's kept in PENDING (`202`, `held: true`, `pending.id`) and done
exactly as it was sent, in your name, once Peter or the person approves it.

| Route | Who | What |
|---|---|---|
| `GET /api/pending` (`?state=waiting`) | anyone | your held changes (Peter, the person: every one, and the open requests) |
| `GET /api/pending/{id}` | its app, Peter | `state`: `waiting`, `applied` (with `result`: the answer it got), `failed`, `denied`, `withdrawn`; `what`: it in words |
| `POST /api/pending/{id}/approve` · `/deny` | Peter, the person, the space's owner | done (or not) |
| `DELETE /api/pending/{id}` | its app | takes it back |

## Notes: `user/library`, `user/memory`, `super/prompt`, `super/memory`, `other/*`

A note is a Markdown file known by its name (`groceries` is `LIBRARY/groceries.md`). Every
operation is one `op` of `POST /api/spaces/{space}/{store}` (`{"op": "read", "name": "groceries"}`),
and the usual ones have a route of their own:

| `op` | Route | Takes | Gives |
|---|---|---|---|
| `list` | `GET …/files` | `sort` (name·modified·created·size), `order`, `q`, `limit`, `offset`, `content` | `notes`, `count`, `total` |
| `names` | `GET …/names` | | `names` |
| `read` | `GET …/files/{name}` (`?format=text`: the text alone) | `name` | `text`, `title`, `size`, `words`, `lines`, `modified`, `created` |
| `read_many` | | `names` | `notes`, `missing` |
| `exists` | `GET …/files/{name}/exists` | `name` | `exists` |
| `write` | `PUT …/files/{name}` | `name`, `text` | `new`, `action` (created·replaced) |
| `create` | `POST …/files` | `name`, `text?` | `409 already_exists` if it's there |
| `append` | `POST …/files/{name}/append` | `name`, `text` | on a line of its own at the end (made if needed) |
| `rename` | `POST …/files/{name}/rename` | `name`, `to`, `overwrite?` | |
| `copy` | `POST …/files/{name}/copy` | `name`, `to` | |
| `delete` | `DELETE …/files/{name}` | `name` | to the store's own Trash, as `name (1)` |
| `search` | `GET …/search?q=` | `q`, `match` (all·any), `case_sensitive`, `whole_words`, `names_only`, `lines`, `limit` | `results` with the lines, the best first |
| `find` | `GET …/find?q=` | the same | `names`, the best first |
| `recent` | `GET …/recent` | `limit` | `notes`, the latest changed first |
| `outline` | `GET …/files/{name}/outline` | `name` | `headings` |
| `backlinks` | `GET …/files/{name}/backlinks` | `name` | the notes linking to it |
| `stats` | `GET …/stats` | | `notes`, `bytes`, `words`, `trashed`, `newest` |
| `trash` | `GET …/trash` | | what's in its Trash |
| `restore` | `POST …/trash/restore` | `name`, `number?`, `as?` | |
| `empty_trash` | `POST …/trash/empty` | `older_than_days?` | `deleted` |

### MEMORY's own (`user/memory`, `/api/memory`)

| `op` | Route | Takes | Gives |
|---|---|---|---|
| `remember` | `POST /api/memory/remember` | `category` (PEOPLE…), `about`, `text?`, `links?` (`[{label?, to, category?}]`), `notes?` | a line in the file, and in the mind `\| PEOPLE \| ada lovelace` with its links and notes |
| `recall` | `GET /api/memory/recall?name=` | `name` | `found`, `nodes`, `about`, `categories`, `mentions`, `lines` |
| `categories` | `GET /api/memory/categories` | | each file, `default`, `members` |
| `members` | `GET /api/memory/categories/{name}/members` | | what the mind files under it |
| `upcoming` | `GET /api/memory/upcoming` | `days` (30) | the days coming up, in the mind and the files |
| `sync` | `POST /api/memory/sync` | | makes each file a node |
| `defaults` | `POST /api/memory/defaults` | | puts back any of the nine files that isn't there |

A memory file written, renamed or restored is a node of the mind straight away.

## The mind: `user/mind`, `/api/mind`

The text mind-map notation (`GET /api/docs/MIND-NOTATION`; how to use it: `/api/docs/MIND-GUIDE`).
Append only: nothing is ever taken out of the log; a rename or a forget is a line appended.

| Route | What |
|---|---|
| `GET /api/mind/nodes/{name}` | its notes, its links (`out·in·both·undirected`, with labels), its lines; `memory_text` for a MEMORY file |
| `GET /api/mind/nodes/{name}/neighbors?depth=2&direction=out` | the nodes around it |
| `GET /api/mind/path?from=&to=` | the shortest way |
| `GET /api/mind/find?q=` · `/edges?label=` · `/notes?kind=date` · `/dates?days=30` | finding things |
| `POST /api/mind/query {q}` | the notation's own query lines (`\| sam \| x`) |
| `POST /api/mind/context {text}` | the part of the mind a text is about, as lines: what to give a model |
| `POST /api/mind/prompt {messages}` | the notation's prompt for a model, filled in, with its grammar |
| `POST /api/mind/add {from, to?, label?, notes?, undirected?}` (or `{facts: […]}`) | adds facts without the notation |
| `POST /api/mind/append {lines}` (or `{text}` with a ` ```mm ` block) | appends lines; a mistake adds nothing (`partial: true`: the rest) |
| `POST /api/mind/check` · `/note` · `/rename` · `/forget` · `/comment` · `/compact` | the rest of the changes |
| `GET /api/mind/stats` · `/nodes` · `/scopes` · `/graph` · `/layout` · `/problems` · `/log` · `/canonical` | the rest of it |

## Records: `peter/*` (and `pending/*`, read only)

JSON values by key (`item-1`, `settings.model`: letters, digits, spaces, dots, dashes,
underscores, up to 128), a file each, each with a **version** that goes up by one with every
write. Send the version you read and a write that would overwrite someone else's is turned down:
`409 version_conflict` (with the `version` it's at).

| `op` | Route | Takes | Gives |
|---|---|---|---|
| `list` | `GET …/records` | `prefix?`, `values?` (true), `limit?` | `records`: `[{key, version, created, updated, by, value}]` |
| `keys` | `GET …/keys` | `prefix?` | `keys` |
| `get` | `GET …/records/{key}` | | the record; `ETag: "version"`; `404` when there's none |
| `put` | `PUT …/records/{key}` (the body **is** the value: any JSON, or text as `text/plain`) | `expect?` (or `If-Match`) | `version`, `new` |
| `patch` | `PATCH …/records/{key}` (the body: the fields; `null` takes one out) | `expect?` | the record |
| `append` | `POST …/records/{key}/append` | `items` (a list) or `item`, `keep?` (the latest so many) | `length` |
| `delete` | `DELETE …/records/{key}` | `expect?` | `deleted` |

With `POST …/{store} {"op": "put", "key": …, "value": …}` the same; `"expect": 0` writes only
if there's none yet.

## What changed: `GET /api/changes`

`?after=N` (the last `seq` you saw; 0 the first time), `&wait=25` (seconds to wait when there's
nothing yet; at most 60), `&space=`, `&store=`. Gives `changes`: `[{seq, space, store, path, op,
name, client, at}]`, the oldest first, only for what you may read (and your own requests in
PENDING), and `next`: the call to make next. The latest thousand are kept while the app runs:
`oldest` says how far back that is.

## The rest

| Route | What |
|---|---|
| `GET /api/health` | whether it's up, the version, the folder, how much is in each store, what's waiting (no name needed) |
| `GET /api/spaces`, `GET /api/spaces/{space}` | the spaces and their stores, each with `your_access` |
| `POST /api/spaces/{space}/reset` | the space back as it came, what was in it to the Trash: its owner or Peter (`user`: the person alone, in the window) |
| `GET /api/import`, `POST /api/import` | what there is to bring in from Tool Mac Tool Run (`~/Desktop/TOOL-MAC-RUN`) and Peter (`~/Library/Application Support/Peter`), and bringing it in (Peter, or the person): copied, the originals left as they were |
| `GET /api/operations`, `/api/operations/{id}` | what was done (yours; Peter: every one), by the `request` id every answer has (also the `X-Request-Id` header) |
| `GET /api/doc` | this, as Markdown; `GET /api/docs`, `/api/docs/{name}`: the other docs (MIND-NOTATION, MIND-GUIDE, MEMORY-GUIDE) |
| `GET /` | a status page |

## Mistakes

Every mistake is `{"ok": false, "code", "error", "fix"?}` with its status: `400 bad_request`,
`bad_name`, `missing_op`, `unknown_op`, `bad_lines` (with `problems`) · `401 who_are_you`,
`bad_key` · `403 no_access`, `not_yours`, `read_only`, `reserved_name` · `404 not_found`,
`no_such_space`, `no_such_store` · `409 already_exists`, `version_conflict`, `already_decided`,
`name_taken` · `413 too_large`.
