# Emquest

Emquest is the web gateway of the [Emergence](https://github.com/EmergenceSystem)
distributed discovery network — a streaming, multi-agent search interface built on
[em_disco](https://github.com/EmergenceSystem/em_disco).

![Screenshot](https://github.com/EmergenceSystem/Emquest/blob/main/emquest.png)

---

## Philosophy

Emergence is a distributed discovery network. Agents connect to a shared bus
(`em_disco`) and each contributes a different type of result — web pages, DNS records,
RSS/Atom feeds, GitHub repositories, anything. There is no central index: results are
fetched live from agents as they respond.

Emquest is the web gateway. It fans out each query across every connected disco node
and every sub-query in parallel — a cartesian product of `nodes × sub-queries`. Results
stream to the browser as they arrive. Deduplication by URL absorbs any overlap between
nodes or sub-queries. The UI adapts automatically to whatever result types agents return.

A network where anyone can run their own agents on a shared discovery bus — without
giving up local-only sources.

---

## Architecture

```
Browser / EmPy / MCP client
     │
     ▼
 emquest :8079          ← this project
  ├── HTTP SSE stream   (POST /query)
  ├── emquest_cli       (rebar3 shell)
  └── queen             (LLM query expansion)
     │
     ▼  fan-out: N disco nodes × M sub-queries (all parallel)
 em_disco :8080+
  ├── agent_registry    (ETS)
  └── WebSocket bus
     │
     ├──▶ dns_filter
     ├──▶ web_filter
     ├──▶ atom_filter
     ├──▶ reddit_filter
     └──▶ … any em_agent (em_filter contract)
```

---

## Features

- **Live streaming** — result cards appear as each agent responds, then reorder once
  all results are in
- **Heterogeneous results** — web links, DNS records, RSS/Atom entries, and any future
  agent type rendered automatically
- **Cartesian fan-out** — N disco nodes × M sub-queries all queried in parallel;
  deduplication by URL absorbs overlap
- **LLM query expansion** — long queries are broken into focused sub-queries via
  `queen:expand/1` before fan-out
- **Type-aware UI** — web results show title + URL + summary; DNS results show domain +
  record type badge + IP list
- **Shell client** — `emquest_cli:query/1` for direct use without the HTTP layer
- **Minimal runtime** — HTTP server is optional, disable it with a single env var

---

## Requirements

- Erlang/OTP 27+
- [rebar3](https://rebar3.org)
- [em_disco](https://github.com/EmergenceSystem/em_disco) running and reachable
- At least one [em_agent](https://github.com/EmergenceSystem/em_agent) connected to
  em_disco
- *(Optional)* An LLM configured in `emergence.conf` for query expansion

---

## Installation

```bash
git clone https://github.com/EmergenceSystem/Emquest
cd Emquest
rebar3 compile
```

---

## Configuration

Emquest shares the same config file as the rest of the Emergence ecosystem.

**Location:**

| OS | Path |
|----|------|
| Linux / macOS | `~/.config/emergence/emergence.conf` |
| Windows | `%APPDATA%\emergence\emergence.conf` |

**Example:**

```ini
[em_disco]
nodes = localhost:8080, em-disco.roques.me

[llm]
provider    = mistral
model       = mistral-small-latest
temperature = 0.3
```

Supported LLM providers: `mistral`, `ollama`, `openai`, `claude`.

Node URL resolution:

| Entry | Resolved as |
|-------|-------------|
| `localhost` | `http://localhost:8080` |
| `localhost:9000` | `http://localhost:9000` |
| `em-disco.roques.me` | `https://em-disco.roques.me` |
| `em-disco.roques.me:8080` | `http://em-disco.roques.me:8080` |

---

## Usage

### Full mode — HTTP server + shell client

```bash
rebar3 shell
```

Open [http://localhost:8079](http://localhost:8079) in your browser.

Type a query and hit **Enter**. Results stream in as agents respond. Once all agents
have replied, results are reordered and deduplicated.

### CLI only — no HTTP server

```bash
EMQUEST_HTTP=false rebar3 shell
```

No port is opened. Use the shell client directly:

```erlang
emquest_cli:query("google.com").
emquest_cli:query(<<"what is erlang">>).
```

Output example:

```
[emquest] querying: google.com

  ── DNS ──
  google.com
  IPs: 172.217.22.78

  ── URL ──
  https://github.com/googlecombd
    googlecombd (User)

[emquest] 2 result(s)
```

### Python client (EmPy)

EmPy is a standalone Python client that queries em_disco directly.

```bash
python EmPy.py "google.com"
```

Reads the same `emergence.conf` for the em_disco server URL. Requires no Erlang
runtime.

---

## Project Structure

```
src/
  emquest_app.erl      — OTP application entry point, conditional Cowboy boot
  emquest_sup.erl      — top-level supervisor, HTTP listener + routing table
  emquest_handler.erl  — Cowboy SSE handler (GET / and POST /query), full pipeline
  emquest_cli.erl      — interactive shell client, calls emquest HTTP API
  queen.erl            — LLM expand/1 for query expansion; rank/2 and synthesize/2
                         exported for external clients, not used in default pipeline
priv/
  templates/index.html — single-page application shell
  static/
    emergence.js       — SSE client, live card rendering, reorder animation
    style.css          — dark terminal UI
EmPy.py               — standalone Python CLI client
```

---

## Result Types

Emquest renders any result type returned by connected agents. Type detection is
automatic based on the fields present in each result:

| Fields present | Rendered as |
|---------------|-------------|
| `url` + optional `title` + `resume` | Clickable web result — title (or URL if no title), URL line, summary |
| `ips` + `domain` | DNS result — domain with record type badge, IP badges |
| anything else | Generic — label + value |

New agent types require no changes to Emquest — the UI adapts automatically.

---

## SSE Event Protocol

`POST /query` streams newline-delimited Server-Sent Events:

| Event | Payload | Description |
|-------|---------|-------------|
| `status` | `{"message": "..."}` | Progress line (expanding, querying, collecting) |
| `item` | `{"sid": N, "item": {...}}` | Single result card, streamed immediately as received |
| `reorder` | `{"sids": [...], "scores": {...}}` | Final deduped order after all agents respond; duplicates removed from the browser |
| `error` | `{"message": "..."}` | Pipeline error |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMQUEST_HTTP` | `true` | Set to `false` to disable HTTP and run CLI only |

---

## License

Apache 2.0
