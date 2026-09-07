# Getting Started with Emergence

Emergence is a **distributed discovery network** on the BEAM. There is no central
index: independent **filter agents** each answer a kind of query, announce
themselves over a gossip ring, and a gateway (**Emquest**) fans every query out
to the relevant agents and streams their results back.

This guide takes you from zero to (1) running the network locally and (2) writing
your own filter agent — in Erlang or in one of seven other languages.

```
query
  │
  ▼
discovery / gossip (em_disco + em_pop)
  ├── agent A ─► source
  ├── agent B ─► source
  └── agent N ─► source
        │
        ▼
   aggregation ─► Emquest ─► browser
```

## 0. Try it first (no setup)

The public network runs at **https://emergence.roques.me** — search there, and
open **/drift** for the ambient feed. Everything below is about running your own
node and adding capabilities to the network.

## 1. Run the network locally

**Prerequisites:** Erlang/OTP 27+ and `rebar3`.

Open three terminals and start the three pieces. Each is `git clone` + `rebar3 shell`.

**a. `em_disco`** — the gossip seed (gossip on `:9100`, HTTP on `:9080`):

    git clone https://github.com/EmergenceSystem/em_disco && cd em_disco
    rebar3 shell

**b. `em_filter_example`** — a minimal agent (seeds `localhost:9100`, serves
queries on `:9201`):

    git clone https://github.com/EmergenceSystem/em_filter_example && cd em_filter_example
    rebar3 shell

**c. `Emquest`** — the gateway. Point it at the local disco via
`~/.config/emergence/emergence.conf` (`%APPDATA%\emergence\emergence.conf` on
Windows):

    [em_disco]
    pop_port = 9100

    [emquest]
    port     = 8079
    pop_port = 9300

Then:

    git clone https://github.com/EmergenceSystem/Emquest && cd Emquest
    rebar3 shell

Open **http://localhost:8079**, search `1`, and the example agent's numbers appear
as result cards — discovered purely through gossip. **http://localhost:8079/network**
lists every peer Emquest has found.

> Emquest has optional services for semantic ranking and caching (see its README).
> The core discover → query → result loop above works without them.

## 2. Write your own filter

A filter receives a query and returns a list of results. That is the whole
contract. Adding a capability to the network = build an agent, connect it,
announce it, let gossip discover it.

### The result contract (Embryo)

Return a list of objects; the UI renders whatever fields are present:

    { "url": "https://…", "title": "…", "resume": "…" }

`title` may instead be `label`, and `resume` may be `value` or `description`.
A result with no `url` renders as a generic card (good for DNS, numbers, facts…).

### In Erlang

Use [`em_filter`](https://hex.pm/packages/em_filter) (≥ 1.4.2) and copy
[`em_filter_example`](https://github.com/EmergenceSystem/em_filter_example) — a
complete ~1-file agent. Your handler is just:

    handle(Query, Memory) -> {json_encoded_results, Memory}.

### In another language

Ready-to-use SDKs, all byte-compatible with the mesh's crypto and result format:

| Language | Repo |
|----------|------|
| Python   | [em_filter_py](https://github.com/EmergenceSystem/em_filter_py) |
| Rust     | [em_filter_rs](https://github.com/EmergenceSystem/em_filter_rs) |
| Go       | [em_filter_go](https://github.com/EmergenceSystem/em_filter_go) |
| Java     | [em_filter_java](https://github.com/EmergenceSystem/em_filter_java) |
| C        | [em_filter_c](https://github.com/EmergenceSystem/em_filter_c) |
| C++      | [em_filter_cpp](https://github.com/EmergenceSystem/em_filter_cpp) |
| Haskell  | [em_filter_hs](https://github.com/EmergenceSystem/em_filter_hs) |

### Two ways to connect

Every SDK supports both transports; pick with `EM_FILTER_MODE`:

- **`relay` (default, NAT-friendly)** — your filter opens an *outbound* WebSocket
  to a disco and receives queries over it. **No inbound port, no public IP** —
  ideal behind a home router. The disco relays queries to you and returns your
  signed results.

      EM_FILTER_MODE=relay EM_DISCO_HOST=<disco-host> <run your filter>

- **`direct`** — your filter serves `POST /agent/query` and gossips its own
  address. Requires an inbound port Emquest can reach (good for servers). This is
  what the Erlang `em_filter` agents use.

Point `EM_DISCO_HOST` at `localhost` for a local disco, or at
**`disco.roques.me`** to join the **live public network** — your filter connects
outbound over `wss://disco.roques.me/ws/filter`, is discovered through gossip, and
Emquest verifies its signed results. For example, with the Python SDK:

    EM_FILTER_MODE=relay EM_DISCO_HOST=disco.roques.me python examples/echo_filter.py

## 3. Identity & trust

Discovery is not authorization — a rogue node can *find* the network but not be
*trusted* by it. The mesh enforces:

- **Cryptographic identity** — every agent has an ed25519 keypair; its id is
  `SHA-256(pubkey)[:16]`. Keys are created and persisted automatically.
- **Signed results** — every response is signed; Emquest runs with
  `require_signatures = true` and drops unsigned or unverifiable responses. (This
  is why an SDK/agent must be on `em_filter` ≥ 1.4 or a current SDK.)
- **TOFU binding** — the first pubkey seen for an id wins; a conflicting key is
  rejected.
- **Reputation & bans** — peers earn trust by answering usefully; abusers are
  bannable, and bans are root-signed and propagate across the mesh.
- **Gossip admission** — a non-root hub cannot inject peers pointing at private/
  loopback/metadata hosts, and cannot flood peers (per-source cap).

## Components

| Component | Role |
|-----------|------|
| [`em_filter`](https://github.com/EmergenceSystem/em_filter) | Erlang library for building agents (+ ed25519 identity, HTML helpers) |
| SDKs (`em_filter_{py,rs,go,java,c,cpp,hs}`) | Build agents in other languages |
| [`em_disco`](https://github.com/EmergenceSystem/em_disco) | Gossip seed + WS relay ingress |
| [`em_pop`](https://github.com/EmergenceSystem/em_pop) | Gossip / federation protocol (capability vectors) |
| [`Emquest`](https://github.com/EmergenceSystem/Emquest) | Web gateway, query fan-out, streaming UI |
| [`Embryo`](https://github.com/EmergenceSystem/Embryo) | Common result data structure |

Questions and feedback: open an issue on any repo, or the one closest to your topic.
