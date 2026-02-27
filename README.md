# Emquest

Emergence web client — a streaming, multi-agent search interface built on the [Emergence](https://github.com/EmergenceSystem) distributed discovery system.

![Screenshot](https://github.com/EmergenceSystem/Emquest/blob/main/emquest.png)

Emquest fans out queries to all connected agents via [em_disco](https://github.com/EmergenceSystem/em_disco), aggregates heterogeneous results (web links, DNS records, or any future type), ranks them with an LLM, and streams everything to the browser as it arrives — no page reload, no waiting for all agents to finish before seeing the first result.

---

## Architecture

```
Browser / EmPy
     │
     ▼
 emquest :8079          ← this project
  ├── HTTP SSE stream   (POST /query)
  ├── emquest_cli       (rebar3 shell)
  └── queen             (LLM expand / rank / synthesize)
     │
     ▼
 em_disco :8080
  ├── agent_registry    (ETS)
  └── WebSocket fanout
     │
     ├──▶ dns_filter
     ├──▶ github_filter
     └──▶ … any em_agent
```

---

## Features

- **Live streaming** — result cards appear as each agent responds, then reorder once the LLM ranking is done
- **Heterogeneous results** — web links, DNS records, and any future agent type rendered automatically
- **LLM pipeline** — query expansion → agent fanout → deduplication → ranking → prose synthesis
- **Type-aware UI** — web results show title + URL + summary; DNS results show domain + record type badge + IP list
- **Shell client** — `emquest_cli:query/1` for direct use without the HTTP layer
- **Minimal runtime** — HTTP server is optional, disable it with a single env var

---

## Requirements

- Erlang/OTP 26+
- [rebar3](https://rebar3.org)
- [em_disco](https://github.com/EmergenceSystem/em_disco) running and reachable
- At least one [em_agent](https://github.com/EmergenceSystem/em_agent) connected to em_disco
- An LLM configured in `emergence.conf` (Mistral, Ollama, OpenAI, or Claude)

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

| OS      | Path |
|---------|------|
| Linux / macOS | `~/.config/emergence/emergence.conf` |
| Windows | `%APPDATA%\emergence\emergence.conf` |

**Example:**

```ini
[em_disco]
server_url = http://localhost:8080

[llm]
provider      = mistral
model         = mistral-small-latest
temperature   = 0.3
system_prompt = You are a search assistant. Be concise and precise.
```

Supported providers: `mistral`, `ollama`, `openai`, `claude`.

---

## Usage

### Full mode — HTTP server + shell client

```bash
rebar3 shell
```

Then open [http://localhost:8079](http://localhost:8079) in your browser.

Type a query and hit **Enter**. Results stream in as agents respond. The AI synthesis panel appears on the right once the LLM has processed the top results.

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

  ── DNS A ──
  google.com
  IPs: 172.217.22.78

  ── URL ──
  https://github.com/googlecombd
    googlecombd (User)

[emquest] 2 result(s)
```

### Python client (EmPy)

EmPy is a standalone Python client that queries em_disco directly, without the LLM layer.

```bash
python EmPy.py "google.com"
```

It reads the same `emergence.conf` for the `em_disco` server URL and requires no Erlang runtime.

---

## Project structure

```
src/
  emquest_app.erl      — OTP application, starts Cowboy conditionally
  emquest_sup.erl      — supervisor, HTTP listener setup
  emquest_handler.erl  — SSE streaming handler (GET / and POST /query)
  emquest_cli.erl      — shell client, calls em_disco:query/1 directly
  queen.erl            — LLM query expansion, ranking, synthesis
  emquest_sup.erl
priv/
  templates/index.html
  static/
    emergence.js       — SSE client, live card rendering
    style.css
EmPy.py               — standalone Python CLI client
```

---

## Result types

Emquest renders any result type returned by connected agents. Type detection is automatic based on the fields present in each result:

| Fields present | Rendered as |
|---------------|-------------|
| `url` + optional `title` + `resume` | Clickable web result — title (or URL if no title), URL line, summary |
| `ips` + `domain` | DNS result — domain with record type badge, IP badges |
| anything else | Generic — label + value |

New agent types require no changes to Emquest — the UI adapts automatically.

---

## SSE event protocol

`POST /query` streams newline-delimited Server-Sent Events:

| Event | Payload | Description |
|-------|---------|-------------|
| `status` | `{message}` | Progress log line |
| `item` | `{sid, item}` | Single result card, streamed immediately |
| `reorder` | `{sids, scores}` | Final ranked order + relevance scores |
| `answer` | `{message}` | LLM prose synthesis |
| `error` | `{message}` | Pipeline error |

---

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `EMQUEST_HTTP` | `true` | Set to `false` to disable the HTTP server and run CLI only |

---

## License

Apache 2.0
