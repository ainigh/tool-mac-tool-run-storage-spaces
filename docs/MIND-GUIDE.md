# The mind guide

The mind is what's known, as names and the links between them: a text file (USER/MIND/mind.txt in STORAGE-SPACES) of lines in the **text mind-map notation** (MIND-NOTATION has every rule). It's **only ever added to**: new lines go at the end; nothing above is changed. Apps reach it at `/api/mind` on Storage Spaces (`http://127.0.0.1:8771`): Peter always, any other app once it's allowed. Tool Mac Tool Run's Mind board draws it.

## The lines, in a minute

```mm
| sam - writes | paper          a link, with a label (sam → paper)
| idea | draft | review         a chain: idea → draft → review
| idea - inspired by - | notes  no direction (a "- |" before the name)
| paper @date 2026-11-03        a note on a node (its kind first)
| draft - sent on @date 2026-11-03 | review   a note on a link
| the paper = paper             the same thing: merge (from here on, it's paper)
| notes =                       forget it (and its links)
| @ talk                        what follows is in the scope "talk"
| slides@talk                   a name in another scope; sam@ is the root scope
```

- A line starting with `|` is a statement; any other line is a comment.
- `|`, `-`, `@` and `=` are symbols only after a space: `well-known`, `2026-11-03`, `q&a` are plain text.
- Names are compared exactly (`Sam` and `sam` are two things): the API matches what you send to the mind's own names, so you needn't worry about it there.
- Two statements about the same pair make one edge: directions add up, labels and notes gather.
- An edit (`old = new`, `old =`) changes what came **before** it; a line after it with the old name is a new thing.

## Scopes

A scope is a topic, a project or a person: `| @ work` and everything after it is in `work` until the next scope line. Before any scope line is the **root** scope, where MEMORY's files are (PEOPLE, ORGANIZATIONS…). The notation has no line back to the root: write root names with an `@` after them (`PEOPLE@`) from inside a scope. Deleting or merging a scope is the person's to do; the API refuses it.

## Asking it, without the notation

| Question | Call |
|---|---|
| All about a thing | `GET /api/mind/nodes/ada` (looked up as a person means it: case, plurals, "the", near spellings) |
| What's around it | `GET /api/mind/nodes/ada/neighbors?depth=2` |
| How two things connect | `GET /api/mind/path?from=ada&to=lagos` |
| Things with some words | `GET /api/mind/find?q=rocket` |
| Every "works at" | `GET /api/mind/edges?label=works at` |
| Every todo | `GET /api/mind/notes?kind=todo` |
| What's coming up | `GET /api/mind/dates?days=30` |
| What a conversation touches | `POST /api/mind/context {"text": "…the messages…"}` |
| Everything | `GET /api/mind/graph`, `GET /api/mind/canonical` (one line a fact) |

## Asking it in the notation

`POST /api/mind/query {"q": "| sam | x"}`: a name that isn't in the mind is a **variable**.

```mmq
| sam | x            every edge from sam
| x - reviews | y    every edge labelled reviews
| paper @x           every note on paper
| paper @date        paper's notes of kind date
| x | y | lagos      every two-step way into lagos
| @ talk             the whole scope
```

## Adding to it, without the notation

```json
POST /api/mind/add
{"facts": [
  {"from": "Sam", "label": "writes", "to": "the paper"},
  {"from": "ana", "label": "reviews", "to": "the paper", "notes": ["date 2026-11-03"]},
  {"from": "sam", "notes": ["pref mornings"]}
], "client": "My Assistant"}
```

The answer says what was `added`, what was `known` already (left out), and any text it had to make safe (`rewritten`: a ` - ` in a note becomes ` – `). Also: `POST /api/mind/note {"name", "note"}`, `POST /api/mind/rename {"name", "to"}`, `POST /api/mind/forget {"name"}`.

## Adding to it in the notation

`POST /api/mind/append {"lines": ["| sam - moved to | lagos"]}`, or a model's reply as it came: `{"text": "…```mm\n| sam - moved to | lagos\n```…"}` (only the ```mm block's `|` lines are taken). Every line is checked first: **one mistake and nothing is written** (the answer has each mistake with its fix; `"partial": true` writes the rest). `POST /api/mind/check` says the same without writing.

Each addition is stamped with a comment line: when, and who (`— 2026-10-24 11:40 · My Assistant`).

## Letting a model keep it

The notation was made for a small model to write. `POST /api/mind/prompt {"messages": "…"}` gives the prompt (PROMPT-MIND-KEEPER), filled in with the part of the mind the messages touch; send the model's reply to `POST /api/mind/append {"text": "…"}`. See PROMPT-MIND-KEEPER.
