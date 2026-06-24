# Codex Host Status

Emoji system status for the Codex CLI.

Codex has a built-in `tui.status_line`, but today it only accepts fixed item IDs. This project wraps interactive Codex sessions in a tiny `tmux` status bar so you can see host metrics while working:

```text
🐍 base  🧠 45%  💰 2.94u  ⏱5h 24%  📅7d 4%  ⚙ CPU 4% 41C  🎮 GPU 2% 43C 0.6G  💾 RAM 10.1/47G  🕒 14:29
```

It keeps normal Codex subcommands such as `codex exec`, `codex doctor`, `codex sandbox`, and `codex --version` untouched.

## Requirements

- Linux
- Bash
- `tmux`
- Codex CLI
- `nvidia-smi`, optional, for NVIDIA GPU stats

## Install

```bash
git clone https://github.com/AlanineX/codex-host-status.git
cd codex-host-status
./install.sh
```

Make sure `~/.local/bin` is before the original Codex binary in `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r
```

Then start Codex normally:

```bash
codex
```

Existing Codex conversations do not gain the bar in place. Quit and resume them after installing.

## What It Shows

- `🐍`: active conda or Python virtual environment
- `🧠`: approximate current context-window usage
- `💰`: pseudo-cost units for comparing how much a thread has consumed; this is not real billing
- `⏱5h`: primary short-window Codex rate-limit usage
- `📅7d`: weekly Codex rate-limit usage
- `⚙ CPU`: CPU utilization and CPU temperature
- `🎮 GPU`: NVIDIA GPU utilization, temperature, and used VRAM
- `💾 RAM`: used and total system memory
- `🕒`: local time

## Configuration

Set these environment variables before launching `codex`:

```bash
export CODEX_STATUS_INTERVAL=5
export CODEX_STATUS_LEFT_LENGTH=180
export CODEX_STATUS_HISTORY_LIMIT=50000
export CODEX_HOST_STATUS_GPU_INDEX=0
export CODEX_HOST_STATUS_GPU_TTL=5
export CODEX_HOST_STATUS_CLOCK_FORMAT="%H:%M"
export CODEX_HOST_STATUS_TOKEN_TAIL=800
```

Useful toggles:

```bash
export CODEX_STATUS_TMUX=0          # bypass this wrapper
export CODEX_STATUS_NO_ALT_SCREEN=0 # do not inject --no-alt-screen
export CODEX_REAL_BIN=/usr/local/bin/codex
export CODEX_STATUS_ROLLOUT_PATH=/path/to/rollout.jsonl
```

To install only `codex-status` without replacing `~/.local/bin/codex`:

```bash
CODEX_STATUS_INSTALL_WRAPPER=0 ./install.sh
```

## Scrolling

The wrapper enables tmux mouse mode and launches interactive Codex with `--no-alt-screen` by default. Mouse wheel scrolling should move through the conversation transcript instead of cycling through prompt history.

In many terminals, text selection inside tmux uses `Shift` plus drag.

## Uninstall

```bash
./uninstall.sh
hash -r
```

## Why This Exists

Codex's native status line is the better long-term home for this feature. Until Codex supports command-backed custom status-line segments, this wrapper gives Linux terminal users a practical host-status bar without patching Codex itself.

Related upstream request: [openai/codex#17827](https://github.com/openai/codex/issues/17827).
