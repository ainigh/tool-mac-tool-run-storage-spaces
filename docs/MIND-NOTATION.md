

# Text mind-map notation

An append-only, line-based text format that compiles to a graph. Nodes are named and live in scopes; edges are directed or undirected and carry labels and notes. Four symbols, no escapes, and a grammar small enough for constrained decoding.

## 1. Lines

- The log is processed line by line, top to bottom. Every line is trimmed first.
- A line that begins with `|` is a **statement**. The leading `|` is the statement marker.
- A line that begins with anything else is a **comment**.
- Empty lines are ignored.

## 2. Symbols and text

The symbols are `|` `-` `@` `=`.

- A symbol is **active** only when it is preceded by whitespace or is the first character of the line. Anywhere else it is ordinary text: `well-known`, `a=b`, `2026-11-03`.
- An active symbol is followed by its text, which runs to the next active symbol or the end of the line.
- Names and texts are trimmed, and internal runs of whitespace collapse to one space.
- Consequently a name cannot contain ` |`, ` -`, ` @` or ` =` (whitespace followed by a symbol). There is nothing else to escape.
- One inactive symbol has meaning: an `@` inside a name qualifies it with a scope (section 5). Names should not otherwise contain `@`; put emails and handles in notes.

## 3. Grammar

```
Line  := '|' (Scope | Stmt)             ; a statement; any other line is a comment
Scope := '@' Text                        ; switch the current scope
       | '@' Text '=' ('@' Text)?        ; rename/merge a scope, or delete it
Stmt  := Path | Edit
Path  := Name (Link Name)* Note*         ; trailing notes attach to the last name
Link  := Seg* Term
Seg   := '-' Text                        ; a label on this edge
       | Note
Note  := '@' Text
Term  := '|'                             ; directed, left to right
       | '-' '|'                         ; undirected: an empty label directly before '|'
Edit  := Name '=' Name?                  ; rename, or delete when the right side is empty
Name  := Text ('@' Text?)?               ; this '@' is inactive: no space before it
```

Empty names, empty label texts (other than the undirected marker), empty note texts and empty scope names are errors.

## 4. Semantics

**Identity.** A node is identified by (scope, name). Names are compared after trimming and collapsing, case-sensitively. Equal names in the same scope are one node, wherever they appear.

**Edges.** Each link `|` makes exactly one edge between the names on either side of it; `| a | b | c` is `a→b` and `b→c`. A node may appear more than once in a path (cycles are allowed). A path with a single name declares that node.

**Direction.** `|` is directed left to right. `- |` is undirected. Only the `-` immediately before `|` affects direction; every other active `-` opens a label.

**Merge.** All statements about the same unordered pair of nodes produce one edge:

- direction is the union: undirected ∪ a→b = a→b; a→b ∪ b→a = both ways;
- labels and notes are ordered sets, in first-seen order, without duplicates.

**Notes.** A `@` note inside a link belongs to that edge; after the last name of a path, to that node. The notation stores notes as text only. Tools may interpret them (dates, tags, references, commands); the convention is to start a note with its kind: `@date 2026-11-03`, `@tag weekly`, `@ref https://…`.

**Edits.** `old = new` is a replacement over all *earlier* lines: every node equal to `old`, and every comment line in the same scope equal to `old`, becomes `new`. Later lines are not affected, so `old` written afterwards is a fresh node. Because identity is by name, renaming onto an existing node merges the two. A comment stays a comment after replacement; it never becomes a node. `=` is not an alias: it has no effect on what later lines mean.

`old =` replaces with nothing: a node with no name is removed together with its edges; a comment line with no text is removed. If a node and a comment share the same text, both are affected.

**Canonical form.** The compiled graph can be re-emitted as one statement per edge, one per node note, and the surviving comments, grouped by scope and sorted. This is lossless and is the "optimized" log.

## 5. Scopes

- `| @ name` makes `name` the **current scope** for all following lines until the next scope line. It may be repeated to return to a scope. Lines before any scope line are in the unnamed **root** scope.
- Comments belong to the current scope.
- An unqualified name means (current scope, name). `name@scope` means (scope, name), and `scope` must already exist; an unknown scope is an error. `name@` with nothing after the `@` means the root scope. Edges may cross scopes; an edge belongs to no scope and is removed with either of its nodes.
- Either side of an edit may be qualified: `| draft@paper = manuscript@paper`.
- `| @ a = @ b` moves every node and comment of `a` into `b` (equal names merge) and removes `a`. If `a` was the current scope, `b` becomes current.
- `| @ a =` removes scope `a` with all its nodes, edges and comments. If it was the current scope, root becomes current.

## 6. Conventions (not grammar)

- Labels read as phrasal verbs, left to right: `| draft - sent to | review`.
- One thought per line. Append; never edit history by hand.
- Prefer directed edges for steps and undirected edges for associations.
- One scope per topic, project or person. Cross-scope links always use the qualified name.
- When a model writes the log, use lowercase names and a fixed set of note kinds (`date`, `todo`, `pref`, `src`).

## 7. Example

```
plan for the paper
| idea | draft | review
| idea - inspired by - | notes
| notes - cites - supports | draft
| draft - sent on @date 2026-11-03 | review
| review | draft
| review @owner sam @tag weekly
| well-known | q&a
this line was a mistake
| this line was a mistake =
| draft = manuscript
| draft | manuscript
| notes =
| @ talk
| outline | slides
| manuscript@ - feeds | outline
| @ meeting
| sam | slides@talk
| @ talk = @ meeting
```

Line by line:

1. A comment (no leading `|`), in the root scope.
2. A chain of directed edges: `idea→draft`, `draft→review`.
3. An undirected edge labeled *inspired by*.
4. Two labels, *cites* and *supports*, on one directed edge.
5. A label and a date note on the edge `draft→review`.
6. The reverse of line 2's second edge; the merged edge is now two-way.
7. Two notes on the node `review`.
8. `-` and `&` inside words are plain text: nodes `well-known` and `q&a`.
9. A comment, deleted by the edit on line 10.
11. A rename: every `draft` above becomes `manuscript`.
12. A new, unrelated node `draft`, linked to `manuscript`.
13. `notes` and both of its edges are removed.
14. Scope `talk` becomes current.
15. `outline→slides`, both in `talk`.
16. A cross-scope edge from `manuscript` in root (`name@` with an empty scope means root) to `outline` in `talk`.
17. Scope `meeting` becomes current.
18. `sam` in `meeting` links to `slides` in `talk`.
19. `talk` is merged into `meeting`: `outline` and `slides` move, and the two cross-scope edges now point into `meeting`.

Result, root scope: nodes `idea`, `manuscript`, `review`, `well-known`, `q&a`, `draft`; edges `idea→manuscript`, `manuscript⇄review` (label *sent on*, note *date 2026-11-03*), `well-known→q&a`, `draft→manuscript`; notes *owner sam* and *tag weekly* on `review`; comment *plan for the paper*. Scope `meeting`: `outline→slides`, `sam→slides`, and `manuscript` (root) *feeds* `outline`.

## 8. Constrained decoding (GBNF)

For llama.cpp / Ollama. It generates statement lines only (no comments), one per line, with exactly one space around each symbol. The parser accepts anything this grammar produces.

```
root  ::= line+
line  ::= "| " (scope | path | edit) "\n"
scope ::= "@ " text (" =" (" @ " text)?)?
path  ::= name (link name)* note*
link  ::= seg* term
seg   ::= " - " text | note
note  ::= " @" text
term  ::= " | " | " - | "
edit  ::= name " =" (" " name)?
name  ::= text ("@" text?)?
text  ::= word (" " word)*
word  ::= [^ \n|@=-] [^ \n@]*
```

Tightenings that help a small model: allow at most one `seg` per link and two `note`s per path; drop `scope` and `edit` from `line` if the harness manages them; and replace the first `text` in `name` with an alternation of the current scope's node names plus one free branch, which stops name drift at the decoder.

## 9. Prompt for a small model

Written for Llama 3.2 3B at temperature 0, with the grammar above or with post-validation. Rules are deliberately short; the examples carry the format. `{scope}`, `{nodes}`, `{memory}` and `{messages}` are filled by the harness.

```
You keep a memory graph of this chat. After reading the recent messages, output ONLY the new lines to append, inside one ```mm block. If nothing new was said, output an empty block.

Line forms:
| name | name              a step or direction
| name - verb | name       a link with a short label, max 4 words
| name @kind text          a note on a node; kinds: date, todo, pref, src
| old = new                these two are the same thing; merge them
| old =                    forget this

Names are lowercase. Reuse a name from the list exactly when it is the same thing. Write only what was actually said. Never explain.

Example
messages:
user: I'm Sam. I'm writing a paper, Ana reviews it on Nov 3.
```mm
| sam - writes | paper
| ana - reviews | paper
| paper @date 2026-11-03 review by ana
```

Example
messages:
user: thanks, that's all for now
```mm
```

Example
nodes: sam, paper, the paper
messages:
user: the paper is actually a thesis
```mm
| the paper = paper
| paper = thesis
```

Scope: {scope}
Existing nodes: {nodes}
Memory:
{memory}
Recent messages:
{messages}
```

## 10. Implementation workflow

The notation is the contract between a script and the model. Most of the work can be done by the script; the model only has to turn text into a few lines.

**Before the model**

1. Pick the scope: one per conversation, project or person, chosen by the harness, not the model. Emit `| @ scope` yourself.
2. Compile the log and take the canonical form of the current scope. If it is large, keep only nodes whose names appear in the recent messages (plain substring match on normalized text) plus their one-hop neighbors, and cap by token count.
3. Build the node list from the same subset. Put it, the memory and the messages at the end of the prompt, in that order.
4. If decoding is constrained, generate the `name` alternation from the node list.

**After the model**

5. Keep only lines that start with `|`; discard anything else.
6. Normalize: lowercase names, collapse whitespace, rewrite `-|` and `- |` variants to `- |`, trim labels to the cap.
7. Parse. On an error, send the line and the error text back once ("line 2: `|` needs a name after it") and reparse; then give up on that line.
8. Resolve names against the scope: exact match first; then a near match (case, plural, article, small edit distance) is rewritten to the existing name, or turned into an `old = new` line for the model to confirm on the next turn.
9. Drop lines that add nothing to the canonical form (duplicate edges, repeated notes).
10. Append the surviving lines, prefixed by a comment with the turn number and time, then recompile. Keep the raw log; it is the audit trail.

**Querying with the same notation**

A fenced ```mmq block from the model is a query, not an append. It uses the path grammar; a name that is not in the graph is a variable, and the harness answers with the canonical lines that match:

```
| sam | x            every edge from sam
| x - reviews | y    every edge labeled "reviews"
| paper @x           every note on paper
| @ talk             the whole scope
```

This lets the model pull detail on demand instead of receiving the full memory each turn, and it needs no new syntax to learn.

**Maintenance**

- Compact occasionally: write the canonical form as the new log and archive the old one. Compaction loses the ability to replay edits, so keep the archive.
- Re-run the harness on the archive after changing normalization rules; the log is cheap to recompile.
- Treat a scope delete as a user action, never a model action.
