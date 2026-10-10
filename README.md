# thurbox-automations

A pane for thurbox's automations: list them, see when each fires next and how
its recent runs went, read a failed run's output, and create, edit, duplicate,
switch on and off, run or delete one, all without leaving the interface.

![The automations pane: the list, a failed exec run and its output, a new automation created through the form, an invalid schedule refused, and a delete confirmed](media/demo.gif)

The GIF and the captures below are recorded by `tests/e2e.sh` from a real
thurbox in a throwaway profile, with seeded automations that run `printf` and
`exit`.

## Requirements

- **thurbox 2.56.5 or newer** to load the pane, list automations, show their run
  history, and switch them on and off, run them and delete them.
- **A thurbox that includes the `automation` create/edit command
  ([Thurbeen/thurbox#1383](https://github.com/Thurbeen/thurbox/pull/1383))**
  to create, edit and duplicate, and to show an automation's definition (prompt,
  target, timezone, next and last run). On an older release the pane says
  "needs a newer thurbox" where those actions would be and sends nothing.

Nothing else: no binary and no extension. Trust is needed for one thing only,
writing an exec automation's command; see [Permissions](#permissions).

## Install

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-automations
thurbox-cli plugin check
```

`install` clones this repository into your interface directory as
`thurbox-automations/` and records it in `plugins.toml`; `plugin update` moves
it forward and `plugin remove automations` takes it out. Nothing runs at
install time.

## Where it is

It takes the `center` slot beside the agent pane, as a switch-slot alternate:
the agent stays what the centre shows, and this pane is drawn while it has
focus. So there is **no `layout.lua` edit**. Three ways in:

- **`Alt+A`** opens it and, pressed again, goes back where you were. It is a
  global chord, so it works from inside a focused terminal. Every F-key is
  already taken by thurbox or another official pane.
- The **Automations** pill in the action band.
- **`Ctrl+P`** → "Automations: show or leave the automations pane" or
  "Automations: create an automation".

`Esc` also leaves, as it does for any pane. Rebind any of its keys in settings
(`Ctrl+,`); the footer hints follow the rebinding.

At 100 columns and wider the list and the detail sit side by side; narrower,
the list stacks over the detail:

```text
┏ ▸ Automations (3) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ ● flaky-export               cron 0 0 1 1 *                in 82d  ✗ ┃
┃ ● sync-tasks                 cron 0 0 1 1 *                in 82d  ✓ ┃
┃ ○ nightly-review             weekdays 09:00                off       ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
╭ flaky-export ────────────────────────────────────────────────────────╮
│ flaky-export  ● enabled                                              │
│ Schedule   cron 0 0 1 1 * · local time                               │
│ Target     $ echo 'export failed: connection refused' >&2; exit 2    │
│ Runs on    this machine, from its heartbeat                          │
│ Next run   in 82d · 2026-12-31 23:00 UTC                             │
│ Last run   now · 2026-10-10 16:49 UTC                                │
│── Runs · 1 run ──────────────────────────────────────────────────────│
│ ✗ now      exit 2: export failed: connection refused                 │
│── Run #2 · error · 2026-10-10 16:49 UTC ─────────────────────────────│
│ exit 2: export failed: connection refused                            │
```

## What it does

| Key | In the list |
|---|---|
| `j` `k` `↑` `↓` | move through the list, or through the runs after `Tab` |
| `Tab` / `Enter` | move between the list and the run history |
| `n` | new automation (spawn, send or exec) |
| `e` | edit the selected one: name, schedule, timezone, prompt (or an exec's command), enabled |
| `c` | duplicate it into a new form, disabled so the copy does not fire twice |
| `Space` | switch it on or off |
| `r` | run now: marks it due, and this machine's heartbeat fires it within a minute |
| `x` / `Delete` | delete it and its run history, after a `y` |
| `/` | filter by name, schedule or target; `Esc` clears it |
| `f` | show all runs, only errors, or only skipped runs |
| `PgDn` / `PgUp` | scroll the selected run's output |

In the form, `Tab` and the arrows move between fields, `◂ ▸` change a choice,
`Enter` saves and `Esc` cancels. A schedule is a preset (`hourly`, `daily`,
`weekdays` or `weekly`, with Time and, for `weekly`, Weekday), `cron:<expr>`, or
`at:YYYY-MM-DD HH:MM` in UTC for a one-shot. thurbox checks every field; when
it refuses one, the form stays open with what you typed and its reason, such
as an invalid cron expression or an unknown timezone. `Ctrl+U` is thurbox's
global restore chord and never reaches a field, so empty one with backspace or
`Ctrl+W`.

Each list row shows whether the automation is on, its schedule, when it fires
next, and how its last run ended. A write in flight shows as `…`, and its
failure is reported in the pane. A selection that disappears because another
pane, the CLI or a run deleted it is never acted on: a pending delete question
goes with the row.

## Permissions

Every read is `thurbox.automations`, the snapshot thurbox refreshes on its own
worker. Every change is an `automation` command with typed fields, applied by a
thurbox command worker, so no name, prompt or command you type passes through a
shell on its way to the database. Rendering never touches the database, the disk
or a program.

The pane declares the **`run` capability and never calls it**. thurbox requires
it of any pane that writes an exec automation's command, because the heartbeat
runs that command. Untrusted, the pane lists, inspects, switches on and off,
runs, deletes, duplicates and edits automations, and creates send and spawn ones;
creating an exec automation or changing an exec's command says how to trust it:
`Ctrl+,` → `]` → select `thurbox-automations/plugins/30_automations.lua` → `t`.
thurbox refuses the write itself too, so the pane's own check is not the only
one.

What an automation *does* when it fires is thurbox's, and unchanged by this
pane: a `send` types its prompt into a session, a `spawn` starts a session in a
repository, and an `exec` runs its command through `sh -c` (`cmd /C` on
Windows). Writing an exec automation is writing a command your machine will
run, so treat this pane like `thurbox-cli automation create`.

## What it cannot do

These are thurbox's limits, stated rather than papered over:

- **No cancel.** thurbox does not track a run while it is in flight, so there is
  nothing to cancel.
- **History is the ten most recent runs** per automation, as the snapshot
  carries them. `thurbox-cli automation runs <id> --limit N` reads further back.
- **An exec run's "log" is a tail.** thurbox records the last 500 characters of
  its stdout and of its stderr. The pane shows all of that, wrapped and
  scrollable, and draws at most 200 lines of any run.
- **No retargeting.** An edit keeps the target: the session, or the repository,
  branch, base and agent. Duplicate it and change the copy instead. A multi-repo
  spawn cannot be duplicated from the pane, because the create command carries
  no extra repositories; use `thurbox-cli automation create --add-repo`.
- **Run now switches a disabled automation on** in thurbox, so the pane refuses
  it on a disabled one and asks you to enable it first.

## Machines and platforms

Automations live in this machine's database and are fired by this machine's
heartbeat (`thurbox-cli automation tick`, armed by thurbox when the
`[features] automations` setting is on). A `send` can target a session on any
host thurbox reaches; a `spawn` and an `exec` run here. So the pane has no host
picker. When the feature is switched off, the pane says that nothing fires.

The pane is plain Lua with no platform code. It is tested on Linux, and CI
loads it on Windows with native thurbox. Exec commands run in the platform
shell, so a command you write has to suit that machine.

## Development

```bash
THURBOX_REPO=/path/to/thurbox scripts/check.sh     # the gate: lint, tests, isolated install
THURBOX_BIN=/path/to/thurbox/target/debug tests/e2e.sh   # the pane in a real thurbox
RECORD=media/demo.gif THURBOX_BIN=… tests/e2e.sh         # and re-record the GIF
```

`tests/pane.lua` drives the pane's handlers against the interface's real `lib/`
with a faked snapshot. `tests/e2e.sh` installs the committed plugin into a
throwaway profile (its own HOME, config, data and tmux socket directory), seeds
automations through `thurbox-cli`, drives the TUI with real key presses, and
checks the database after each step.

## License

MIT
