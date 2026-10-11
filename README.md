# thurbox-automations

A [thurbox](https://github.com/Thurbeen/thurbox) pane for your scheduled automations.

[![Check](https://github.com/Thurbeen/thurbox-automations/actions/workflows/check.yml/badge.svg)](https://github.com/Thurbeen/thurbox-automations/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

![The automations pane in thurbox's Doom theme: the list, a failed run's output filtered to errors, run now, an automation switched off, and a delete confirmed](media/demo.gif)

- **See every automation at once** — on or off, its schedule, its next run and
  how its last run ended.
- **Find out why a run failed** — each run's output, filtered to errors in one key.
- **Manage them in place** — run now, switch on or off, create, edit, duplicate
  or delete, without leaving thurbox.

The GIF is thurbox v2.56.5 running synthetic automations. That release publishes no
next run or definition, hence the "needs a newer thurbox" line in the detail.

## Installation

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-automations
thurbox-cli plugin check
```

Needs **thurbox 2.56.5 or newer**. Creating, editing and duplicating, and showing
an automation's next run, prompt and target, need a thurbox with the `automation`
create/edit command ([Thurbeen/thurbox#1383](https://github.com/Thurbeen/thurbox/pull/1383));
until then the pane says so and sends nothing.

`thurbox-cli plugin update` moves it forward; `thurbox-cli plugin remove automations`
takes it out.

## Getting Started

1. **`Alt+A`** opens the pane (or the **Automations** pill, or `Ctrl+P` →
   "Automations"). `Alt+A` again or `Esc` goes back.
2. **Read the list.** `j` / `k` move; the detail follows the selected row.
3. **Check its runs.** `Tab` moves into the run history and shows the selected run's
   output; `f` cycles all runs, errors only and skipped only.
4. **Act on it.** `r` runs it now, `Space` switches it on or off, `x` deletes it
   after a `y`.

The pane takes the `center` slot beside the agent, so no `layout.lua` edit is
needed. Below 100 columns the list stacks over the detail.

## Keys

| Key | Does |
|---|---|
| `j` `k` `↑` `↓` | move through the list, or through the runs after `Tab` |
| `Tab` / `Enter` | switch between the list and the run history |
| `/` | filter by name, schedule or target; `Esc` clears it |
| `f` | all runs, errors only, skipped only |
| `PgDn` / `PgUp` | scroll the selected run's output |
| `r` | run now: this machine's heartbeat fires it within a minute |
| `Space` | switch on or off |
| `n` / `e` / `c` | new, edit, duplicate (the copy starts disabled) |
| `x` / `Delete` | delete it and its run history, after a `y` |

In the form, `Tab` moves between fields, `◂ ▸` change a choice, `Enter` saves and
`Esc` cancels. A schedule is `hourly`, `daily`, `weekdays`, `weekly`, `cron:<expr>`
or `at:YYYY-MM-DD HH:MM` (UTC). Rebind any key in settings (`Ctrl+,`).

## Trust

The pane reads the snapshot thurbox publishes and writes only through thurbox's
typed `automation` command: no shell, file or database access from Lua.
Everything works untrusted except writing an **exec** automation's command,
which your machine will run. To allow that: `Ctrl+,` → `]` → select
`thurbox-automations/plugins/30_automations.lua` → `t`.

## Limits

These are thurbox's, and the pane shows them rather than hiding them:

- **No cancel** — thurbox does not track a run in flight.
- **Ten runs of history** — `thurbox-cli automation runs <id> --limit N` reads
  further back.
- **Exec output is a tail** — the last 500 characters of stdout and of stderr.
- **No retargeting** — an edit keeps the target; duplicate it to change one.
- **Run now needs it on** — thurbox would switch it on, so the pane asks first.

## Documentation

- [Automations](https://thurbox.thurbeen.eu/docs/features.html#automations) —
  triggers, actions and the heartbeat that fires them.
- [Writing a pane](https://github.com/Thurbeen/thurbox/blob/main/docs/PLUGINS.md)
  and the [plugin catalog](https://thurbox.thurbeen.eu/plugins.html).

## Contributing

```bash
THURBOX_REPO=/path/to/thurbox scripts/check.sh        # the gate: lint, tests, isolated install
THURBOX_BIN=/path/to/thurbox/bin tests/e2e.sh         # the pane in a real thurbox
scripts/record-demo.sh                                # re-record media/demo.gif
```

`scripts/record-demo.sh` installs the committed plugin into a throwaway profile,
seeds synthetic automations, sets the built-in `doom` theme and drives thurbox
with real keys under asciinema and agg. It refuses to write a GIF that shows a
home directory or the recording user's name.

## License

MIT — see [LICENSE](LICENSE).
