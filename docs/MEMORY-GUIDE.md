# The memory guide

MEMORY (USER/MEMORY in STORAGE-SPACES on the Desktop) is an opinionated library: it comes with a file for each kind of thing worth remembering, and every file in it is a **node of the mind** (in the mind's root scope). The files hold the detail; the mind holds how things link. Apps reach it at `/api/memory` on Storage Spaces (`http://127.0.0.1:8771`): Peter always, any other app once it's allowed.

## The files it comes with

| File | What goes in it | How to write in it |
|---|---|---|
| PEOPLE | Who's who: how you know them, how to reach them, what matters to them | A section each: `## Ada Lovelace`, then lines |
| ORGANIZATIONS | Companies, teams, clubs, agencies: what each does, who you know there | A section each: `## Acme` |
| EVENT-DATES | Things that happen on a day | A line each, the day first: `- 2026-11-03 — Ana reviews the paper` |
| BIRTHDAYS | Birthdays and anniversaries | A line each, the day first: `- 03-14 — Ada Lovelace` (every year), `- 1988-07-02 — Sam` |
| LOCATIONS | Places: addresses, offices, where things are kept | A section each: `## Acme HQ` |
| IDEAS | Ideas worth keeping: where each came from, what would test it | A section each |
| LEVERAGE | What gives an edge: skills, assets, relationships, favours owed, timing | A section each |
| STRATEGIES | Plans: the goal, the steps, what's been tried | A section each |
| OTHERS | Anything that doesn't fit yet | A line each; when a kind of thing keeps coming up, give it a file of its own |

Each file starts with what it holds and an example (in a fence, so it's never taken for a real entry). Write below the line.

You can add files of your own (RECIPES, HEALTH, PROJECTS…): each becomes a node of the mind too. A memory file's name has to be one the mind can have as a node: words, with no `@` and no `-`, `|` or `=` after a space (EVENT-DATES is fine; "A - B" isn't).

Deleted one of the nine? `POST /api/memory/defaults` adds back any that are missing, changing nothing else.

## How the files and the mind fit

```mm
| PEOPLE | ada lovelace
| ada lovelace - works at | acme
| ORGANIZATIONS | acme
| ada lovelace @birthday 03-14
```

- A category (PEOPLE) links **to** each thing filed under it: that's how `members` finds the people.
- Things link to each other with a label that reads left to right (`works at`).
- Notes on a node start with their kind: `@date 2026-11-03`, `@birthday 03-14`, `@todo call back`, `@pref short emails`, `@src the 2026 conference`.

Renaming a memory file renames its node (a line `| OLD = NEW` is added). Deleting one leaves its node in the mind: what was learnt stays.

## Remembering, in one call

`POST /api/memory/remember` does both halves: a line in the file, and the links in the mind.

```json
{"category": "PEOPLE", "about": "Ada Lovelace",
 "text": "Met at the 2026 conference; prefers short emails",
 "links": [{"label": "works at", "to": "Acme", "category": "ORGANIZATIONS"}],
 "notes": ["birthday 03-14"], "client": "My Assistant"}
```

- `about` is matched to the mind's own name for it when there is one (`ADA LOVELACE` is `ada lovelace`); a new one is written in lower case.
- `text` goes in the file as `- Ada Lovelace: …` (several lines, or a `#` heading, go in as they are).
- Each link may file what it links to under a category too (`"category": "ORGANIZATIONS"`).

## Recalling

| Question | Call |
|---|---|
| What do we know about Ada? | `GET /api/memory/recall?name=ada` — her node (links, notes), the files she's under, every line that mentions her |
| Who are the people? | `GET /api/memory/categories/PEOPLE/members` |
| What's coming up? | `GET /api/memory/upcoming?days=30` — dated notes in the mind, and dated lines in the files (birthdays come round every year) |
| What's in each file? | `GET /api/memory/categories` |
| Every line with "lagos" | `GET /api/memory/search?q=lagos` |
| One file | `GET /api/memory/files/PEOPLE` (`?format=text` for the text alone) |

Every library route works on MEMORY too: `PUT /api/memory/files/{name}`, `POST /api/memory/files/{name}/append`, `DELETE`, `rename`, `copy`, the Trash.
