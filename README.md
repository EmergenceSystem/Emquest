# Emquest

Emquest is the web gateway of the [Emergence](https://github.com/EmergenceSystem)
distributed discovery network — a streaming, multi-agent search interface built on
[em_filter](https://hex.pm/packages/em_filter)'s em-pop gossip protocol.

![Screenshot 1](https://github.com/EmergenceSystem/Emquest/blob/main/emquest.png)

---

## Philosophy

Emergence is a distributed discovery network. Filter agents connect via em-pop gossip
and each contributes a different type of result — web pages, DNS records, RSS/Atom feeds,
numbers, anything. There is no central index: results are fetched live from agents as
they respond.

Emquest is the web gateway. It fans out each query across every em-pop peer in parallel.
Results stream to the browser as they arrive. Deduplication by URL (or by label for
generic results) absorbs any overlap. The UI adapts automatically to whatever result
types agents return.

A network where anyone can run their own filter agents on a shared gossip ring — without
giving up local-only sources.

---

## Architecture

```
Browser
     │
     ▼
 emquest :8079            ← this project
  ├── GET  /              — search UI (streaming SSE)
  ├── POST /query         — SSE pipeline
  ├── GET  /network       — em-pop network view
  ├── GET  /network/peers — JSON peer list
  └── emquest_pop         — em-pop gossip node (port 9300)
     │
     ▼  gossip discovery + direct HTTP fan-out
 em-pop ring
  ├──▶ em_filter_example :9201   (numbers demo filter)
  ├──▶ dns_filter                (DNS lookups)
  ├──▶ web_filter                (web search)
  └──▶ … any em_filter agent
     │
     ▼  gossip bootstrap
 em_disco :9100
```

---

## Features

- **Live streaming** — result cards appear as each agent responds, then reorder once
  all results are in
- **Heterogeneous results** — web links, DNS records, generic cards, and any future
  agent type rendered automatically
- **em-pop fan-out** — peers discovered via gossip; top-K by semantic similarity
  queried in parallel for each sub-query
- **LLM query expansion** — long queries are broken into focused sub-queries via
  `queen:expand/1` before fan-out
- **Deduplication** — by URL for web results; by label for generic cards
- **Network view** — `GET /network` shows all discovered em-pop peers with routable
  status, auto-refreshes every 15 s
- **Shell client** — `emquest_cli:query/1` for direct use without the HTTP layer
- **Minimal runtime** — HTTP server is optional, disable it with a single env var

---

## Requirements

- Erlang/OTP 27+
- [rebar3](https://rebar3.org)
- [em_disco](https://github.com/EmergenceSystem/em_disco) running as a gossip bootstrap
  seed (or any em-pop node to seed from)
- At least one [em_filter](https://hex.pm/packages/em_filter) agent in the gossip ring
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
pop_port = 9100

[emquest]
port     = 8079
pop_port = 9300

[llm]
provider    = mistral
model       = mistral-small-latest
temperature = 0.3
```

The `[em_disco] pop_port` is the UDP gossip port emquest uses to seed its peer table
(contacts em_disco at startup). `[emquest] pop_port` is emquest's own gossip listen
port.

Supported LLM providers: `mistral`, `ollama`, `openai`, `claude`.

---

## Usage

### Full mode — HTTP server + shell client

```bash
rebar3 shell
```

Open [http://localhost:8079](http://localhost:8079) in your browser.

Type a query and hit **Enter**. Results stream in as agents respond. Once all agents
have replied, results are reordered and deduplicated.

**Network view:** [http://localhost:8079/network](http://localhost:8079/network) shows
all em-pop peers Emquest has discovered, with their host, query port, and routable
status. Refreshes automatically every 15 s.

### CLI only — no HTTP server

```bash
EMQUEST_HTTP=false rebar3 shell
```

No port is opened. Use the shell client directly:

```erlang
emquest_cli:query("google.com").
emquest_cli:query(<<"what is erlang">>).
```

---

## Project Structure

```
src/
  emquest_app.erl      — OTP application entry point, conditional Cowboy boot
  emquest_sup.erl      — top-level supervisor, HTTP listener + routing table
  emquest_handler.erl  — Cowboy handler: GET /, POST /query (SSE), GET /network,
                         GET /network/peers
  emquest_pop.erl      — em-pop gossip node manager; peers_for_query/2, all_peers/0
  emquest_cli.erl      — interactive shell client
  queen.erl            — LLM expand/1 for query expansion
priv/
  templates/
    index.html         — search single-page application
    network.html       — em-pop network view
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
| `url` + optional `label` + `value` | Clickable web result |
| `ips` + `domain` | DNS result — domain + IP badges |
| `label` + `value` (no url) | Generic card — label + value, deduplicated by label |

New agent types require no changes to Emquest — the UI adapts automatically.

---

## HTTP API

### POST /query

Streams Server-Sent Events:

| Event | Payload | Description |
|-------|---------|-------------|
| `status` | `{"message": "..."}` | Progress line |
| `item` | `{"sid": N, "item": {...}}` | Single result card |
| `reorder` | `{"sids": [...], "scores": {...}}` | Final deduped order |
| `error` | `{"message": "..."}` | Pipeline error |

### GET /network/peers

Returns the current em-pop peer table as a JSON array:

```json
[
  {"host": "127.0.0.1", "query_port": 9201, "routable": true},
  {"host": "192.168.1.5", "query_port": null, "routable": false}
]
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMQUEST_HTTP` | `true` | Set to `false` to disable HTTP and run CLI only |

---

## License

Apache 2.0
