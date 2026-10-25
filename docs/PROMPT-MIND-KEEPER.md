# Prompt: a small model keeping the mind

The text mind-map notation was made so a small model (Llama 3.2 3B at temperature 0 does) can keep a memory graph of a conversation: it only has to turn what was said into a few lines. The app does the rest: picks what part of the mind to show it, checks its lines, leaves out what's known, and appends.

## The loop

1. **Ask for the prompt**, with the recent messages:

   ```json
   POST /api/mind/prompt
   {"messages": "user: I'm Sam. I'm writing a paper, Ana reviews it on Nov 3.", "client": "Mind Keeper"}
   ```

   The answer's `prompt` is the whole prompt (below), filled in: the scope, the names the messages touch (`nodes`), the lines about them (`memory`), the messages. `grammar` is the notation's grammar (GBNF), for llama.cpp or Ollama to hold the model to it.

2. **Run the model** on `prompt` (with `grammar`, if you can). Its reply is one ```mm block.

3. **Append the reply as it is**:

   ```json
   POST /api/mind/append
   {"text": "<the model's whole reply>", "client": "Mind Keeper"}
   ```

   Only the block's lines that start with `|` are taken. Each is checked; if one has a mistake, nothing is written and the answer says which line and the fix. Send that back to the model once ("line 2: `|` needs a name after it"), then give up on that line (or send `"partial": true` to write the good ones). Lines the mind already knows are left out (`known`).

4. Next turn, again.

## The prompt

````text
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
````

## Tightening it for a very small model

- Allow at most one label per link and two notes per line.
- Leave scope lines and edits out of the grammar if your harness manages them (the app refuses scope deletes from any app anyway).
- Replace the first word of a name in the grammar with the list of `nodes`, plus one free branch: it stops names drifting ("the paper", "paper", "papers").

## MEMORY's files are nodes too

PEOPLE, ORGANIZATIONS, EVENT-DATES, BIRTHDAYS… are nodes in the root scope. Add to the nodes list the ones that fit, and a line like `| PEOPLE | ana` files Ana under PEOPLE (that's how `GET /api/memory/categories/PEOPLE/members` finds her).
