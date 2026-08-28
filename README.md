# Echo (omarchy bar widget)

A Quickshell bar widget for Omarchy that shows **Echo's** usage, provider
balance, and a **model switcher** — all fed from a Hermes agent via a local
or remote usage bridge.

- **Balance** — Credits remaining with a usage meter, showing your available
  budget at a glance. Works with DeepSeek, OpenRouter, and OAuth providers.
- **Usage** — Today / 7-day / 30-day tokens and estimated cost, tokens by day,
  tokens by model, all from Hermes' real `state.db`.
- **Model switcher** — Curated model list grouped by provider. One click to
  switch. POSTs to the bridge, which rewrites `config.yaml` — new sessions use
  the new model immediately.
- **Dual mode** — Local (machine running Omarchy) or Remote (any reachable
  server). Toggle in settings.

## Requirements

- Omarchy (Quickshell) shell.
- Python 3 (shipped with all modern Linux distros).
- A running Hermes agent on the target machine (for Local mode) or a reachable
  server running the bridge (for Remote mode).

## Quick Install (Local mode)

```sh
omarchy plugin add https://github.com/r3pc0n/hermes-agent-widget.git --enable --yes
omarchy-restart-shell
```

The widget immediately starts a local bridge process that reads Hermes' data
directly. No extra setup needed.

To move the icon to the right side of the bar:

```sh
omarchy plugin enable echo.model right
```

## Remote mode (connect to another machine)

If your Hermes agent runs on a different machine (server, NAS, VPS), install
the bridge there with one command:

```sh
bash <(curl -s https://raw.githubusercontent.com/r3pc0n/hermes-agent-widget/main/install-bridge.sh)
```

This sets up a systemd user service that runs the bridge on port 8643.
The bridge reads `~/.hermes/state.db` and `~/.hermes/config.yaml` directly — no
Python package dependencies beyond the standard library.

Then in the widget settings:
1. Click the hamburger menu `☰`
2. Switch to **Remote**
3. Enter the bridge URL: `http://<server-ip>:8643`

### Using your Hermes agent to install the bridge

Simply give your Hermes agent this prompt:

> Install the Echo Usage Bridge on this machine so an Omarchy bar widget can
> pull usage data from my Hermes agent. Run:
>
> ```sh
> bash <(curl -s https://raw.githubusercontent.com/r3pc0n/hermes-agent-widget/main/install-bridge.sh)
> ```
>
> Then confirm the bridge is running on port 8643.

## Usage

- **Left click** the Hermes icon — open/close the panel
- **Middle click** — refresh now
- **Hamburger `☰`** in the panel — open settings
- In the panel: arrows move the model cursor, `Enter` applies it,
  `r` refreshes, `Esc`/`q` closes

### Switching between Local and Remote

Your widget defaults to **Local mode** — it connects to the bridge running
on the same machine as Omarchy (auto-started by the widget itself).

To switch to a remote Hermes agent:

1. Open the widget panel (left-click the Hermes icon)
2. Click `☰` to open settings
3. Tap **Remote** — the bridge URL field becomes editable
4. Enter the remote bridge URL, e.g. `http://192.168.1.50:8643`
5. The widget immediately fetches data from that address

To switch back to Local:
1. Open settings (`☰`)
2. Tap **Local** — the bridge URL reverts to `http://your-hermes:8643`
3. The widget fetches from the local bridge on the next refresh

The setting persists across shell restarts — you only set it once.

## Provider & balance support

| Provider | Usage data | Balance tracking |
|----------|-----------|------------------|
| DeepSeek (direct) | ✅ From Hermes' DB | ✅ Via DeepSeek API key in `~/.hermes/.env` |
| OpenRouter | ✅ From Hermes' DB | ✅ Via OpenRouter API key in `~/.hermes/.env` |
| OpenAI Codex / OAuth | ✅ From Hermes' DB | ⚠ Shows "Connected · usage only" |

For OAuth/subscription providers, token usage and estimated costs still work —
the widget just can't fetch a balance for that provider type.

## License

[MIT](LICENSE) © 2026 Sven Radetzky (original), fork by Echo.
