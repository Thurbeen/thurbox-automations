-- The pane, driven as a user drives it: published snapshots in, keys and
-- events through the handlers the kernel calls, and the node tree and the
-- commands it issued out.
--
-- Run through `tests/run.sh`.

local REPO = assert(os.getenv("REPO"), "REPO=")
local h = dofile(REPO .. "/tests/harness.lua")

local NOW = h.NOW
local HOUR = 3600 * 1000

local function nightly()
  return {
    id = 3,
    name = "nightly-review",
    schedule = "0 9 * * 1-5",
    action = "spawn",
    enabled = true,
    trigger = "cron:0 9 * * 1-5",
    timezone = "Europe/Zurich",
    prompt = "Review open pull requests and summarise them",
    repo = "/home/user/src/app",
    branch = "auto/review",
    base = "main",
    agent = "claude",
    extra_repos = 0,
    created_at = NOW - 30 * 24 * HOUR,
    updated_at = NOW - 2 * 24 * HOUR,
    last_run_at = NOW - 24 * HOUR,
    next_run_at = NOW + 3 * HOUR,
    last_outcome = "success",
    last_detail = "spawned app/auto-review",
    runs = {
      {
        id = 40,
        started_at = NOW - 24 * HOUR,
        status = "success",
        detail = "spawned app/auto-review",
        session = "s9",
      },
    },
  }
end

local function sync()
  return {
    id = 2,
    name = "sync-tasks",
    schedule = "*/15 * * * *",
    action = "exec",
    enabled = true,
    trigger = "cron:*/15 * * * *",
    prompt = "",
    command = "tracker-sync --quiet",
    extra_repos = 0,
    created_at = NOW - 10 * 24 * HOUR,
    updated_at = NOW - 10 * 24 * HOUR,
    last_run_at = NOW - 10 * 60 * 1000,
    next_run_at = NOW + 5 * 60 * 1000,
    last_outcome = "error",
    last_detail = "exit 2: connection refused",
    runs = {
      {
        id = 33,
        started_at = NOW - 10 * 60 * 1000,
        status = "error",
        detail = "exit 2: connection refused\nretrying in 30s\ngave up after 3 attempts",
      },
      { id = 32, started_at = NOW - 25 * 60 * 1000, status = "success", detail = "ok" },
      {
        id = 31,
        started_at = NOW - 40 * 60 * 1000,
        status = "skipped",
        detail = "previous run still active",
      },
    },
  }
end

local function standup()
  return {
    id = 1,
    name = "standup-ping",
    schedule = "once",
    action = "send",
    enabled = false,
    trigger = "at:" .. (NOW + 24 * HOUR),
    prompt = "Post the standup summary",
    session = "s1",
    extra_repos = 0,
    created_at = NOW - 3 * HOUR,
    updated_at = NOW - 3 * HOUR,
    runs = {},
  }
end

local SESSIONS = { { id = "s1", name = "api-refactor", repo = "app" } }

local function world(extra)
  local opts = {
    automations = { nightly(), sync(), standup() },
    sessions = SESSIONS,
    repos = { { path = "/home/user/src/app", name = "app" } },
    agents = { { name = "claude", command = "claude" }, { name = "codex", command = "codex" } },
  }
  for k, v in pairs(extra or {}) do
    opts[k] = v
  end
  h.publish(opts)
end

--- Empty the focused field the way a user can in thurbox: Ctrl+U is the global
--- restore chord there, so it never reaches a pane's field.
local function clear_field()
  for _ = 1, 80 do
    h.press("backspace")
  end
end

local function only_command()
  local issued = h.commands()
  h.eq(#issued, 1, "commands issued")
  return issued[1]
end

-- ── states before there is anything to manage ──────────────────────────────

h.test("the pane asks only for run, and runs nothing", function()
  -- `run` is what thurbox requires before a pane may write an exec
  -- automation's command; the pane itself never calls it.
  h.eq(#h.pane().capabilities, 1, "one capability")
  h.eq(h.pane().capabilities[1], "run")
  h.eq(h.pane().name, "automations")
  h.eq(h.pane().slot, "center")
  h.eq(h.pane().pure, true, "a pure render")
  h.eq(h.pane().focusable, true, "focus is how a switch slot shows it")
  assert((h.pane().order or 100) > 20, "after the agent pane, which stays the slot's default")
  world()
  h.render()
  h.eq(_G.run, nil, "no run in the environment")
end)

h.test("it is reachable by a key, a pill and the palette", function()
  local pane = h.pane()
  local toggle
  for _, binding in ipairs(pane.keys) do
    if binding.action == "automations.toggle" then
      toggle = binding
    end
  end
  assert(toggle, "a toggle key")
  h.eq(toggle.scope, "global")
  h.eq(toggle.key, "alt+a")
  h.eq(pane.pills[1].action, "automations.toggle")
  local palette = {}
  for _, entry in ipairs(pane.commands) do
    palette[entry.action] = true
  end
  assert(palette["automations.toggle"] and palette["automations.create"], "palette entries")
  h.action("automations.toggle")
  local issued = only_command()
  h.eq(issued.kind, "focus")
  h.eq(issued.args.text, "automations")
  h.eq(issued.args.toggle, true)
end)

h.test("loading: nothing has been read yet", function()
  h.publish({ automations = h.NIL, taken_at_ms = 0 })
  h.contains(h.screen(), "Reading automations")
end)

h.test("a database error is shown, not an empty list", function()
  h.publish({ automations = {}, error = "database is locked" })
  local screen = h.screen()
  h.contains(screen, "database is locked")
  h.absent(screen, "No automations yet")
end)

h.test("empty: says so and names the key that creates one", function()
  h.publish({ automations = {} })
  local screen = h.screen()
  h.contains(screen, "No automations yet")
  h.contains(screen, "n")
end)

h.test("the feature switch off is said out loud", function()
  world({ settings = { features = { automations = false } } })
  h.contains(h.screen(), "switched off")
end)

-- ── the list and the detail ────────────────────────────────────────────────

h.test("the list shows status, schedule, target and timing", function()
  world()
  local screen = h.screen(140, 30)
  h.contains(screen, "nightly-review")
  h.contains(screen, "weekdays 09:00")
  h.contains(screen, "in 3h")
  h.contains(screen, "sync-tasks")
  h.contains(screen, "every 15m")
  h.contains(screen, "standup-ping")
  h.contains(screen, "off")
end)

h.test("the detail shows the definition of the selected automation", function()
  world()
  local screen = h.screen(140, 30)
  h.contains(screen, "Europe/Zurich")
  h.contains(screen, "spawn in app")
  h.contains(screen, "auto/review")
  h.contains(screen, "claude")
  h.contains(screen, "Review open pull requests")
  h.contains(screen, "2026-01-05 15:00 UTC", "the absolute next run")
  h.contains(screen, "this machine", "where it runs")
end)

h.test("a send names its session, and says when the session is gone", function()
  world()
  h.press("j")
  h.press("j")
  local screen = h.screen(140, 30)
  h.contains(screen, "api-refactor")
  h.contains(screen, "once")
  world({ sessions = {} })
  h.contains(h.screen(140, 30), "gone")
end)

h.test("narrow screens stack the list over the detail", function()
  world()
  local wide = h.render(140, 30)
  local narrow = h.render(60, 30)
  h.eq(wide.layout, "columns")
  h.eq(narrow.layout, "stacked")
  -- And nothing breaks at absurd sizes.
  h.render(1, 1)
  h.render(12, 4)
end)

h.test("the filter narrows the list and survives a reload", function()
  world()
  h.press("/")
  h.type("sync")
  h.press("enter")
  local screen = h.screen(140, 30)
  h.contains(screen, "sync-tasks")
  h.absent(screen, "nightly-review")
  h.load()
  h.absent(h.screen(140, 30), "nightly-review", "the filter is kept in state")
  h.press("esc")
  h.contains(h.screen(140, 30), "nightly-review", "esc clears it")
end)

-- ── writes ─────────────────────────────────────────────────────────────────

h.test("space disables and enables, and shows the write in flight", function()
  world()
  h.press("space")
  local issued = only_command()
  h.eq(issued.kind, "automation")
  h.eq(issued.args.number, 3)
  h.eq(issued.args.flag, false)
  h.contains(h.screen(140, 30), "disabling")
  h.event("command.done", { kind = "automation", subject = "#3" })
  h.absent(h.screen(140, 30), "disabling")
  h.press("j")
  h.press("j")
  h.press("space")
  issued = only_command()
  h.eq(issued.args.number, 1)
  h.eq(issued.args.flag, true)
end)

h.test("a refused write is shown beside the automation it was for", function()
  world()
  h.press("space")
  h.commands()
  h.event("command.failed", {
    kind = "automation",
    subject = "#3",
    error = "`at:1` never fires again; give it a schedule in the future",
  })
  h.contains(h.screen(140, 30), "never fires again")
end)

h.test("run now queues an enabled automation and refuses a disabled one", function()
  world()
  h.press("r")
  local issued = only_command()
  h.eq(issued.args.number, 3)
  h.eq(issued.args.force, true)
  h.eq(issued.args.flag, nil, "run does not touch the enabled flag")
  h.event("command.done", { kind = "automation", subject = "#3" })
  h.contains(h.screen(140, 30), "heartbeat")
  h.press("j")
  h.press("j")
  h.press("r")
  h.eq(#h.commands(), 0, "a disabled automation is not run")
  h.contains(h.screen(140, 30), "enable it first")
end)

h.test("delete asks first, and only yes deletes", function()
  world()
  h.press("x")
  h.eq(#h.commands(), 0, "nothing deleted yet")
  local screen = h.screen(140, 30)
  h.contains(screen, "Delete nightly-review")
  h.contains(screen, "1 recorded run")
  h.press("n")
  h.eq(#h.commands(), 0, "no is no")
  h.absent(h.screen(140, 30), "Delete nightly-review")
  h.press("x")
  h.press("y")
  local issued = only_command()
  h.eq(issued.args.number, 3)
  h.eq(issued.args.reset, true)
end)

h.test("a selection that disappears is never acted on", function()
  world()
  h.press("j") -- sync-tasks, id 2
  h.press("x")
  -- Deleted elsewhere while the question was up.
  h.publish({ automations = { nightly(), standup() }, sessions = SESSIONS })
  local screen = h.screen(140, 30)
  h.absent(screen, "Delete sync-tasks", "the question goes with the row")
  h.press("y")
  h.eq(#h.commands(), 0, "nothing issued against a vanished id")
  -- The cursor lands on a neighbour, and acting acts on that neighbour.
  h.press("space")
  local issued = only_command()
  assert(issued.args.number == 1 or issued.args.number == 3, "a live neighbour")
  -- A late answer about the vanished row is harmless.
  h.event("command.failed", { kind = "automation", subject = "#2", error = "gone" })
  h.render()
end)

-- ── create and edit ────────────────────────────────────────────────────────

--- Move the form's focus to the field labelled `label`.
local function to_field(label)
  for _ = 1, 20 do
    local screen = h.screen(140, 40)
    if screen:find("▸ " .. label, 1, true) then
      return
    end
    h.press("tab")
  end
  error("no field " .. label)
end

h.test("a new exec automation is created with typed fields", function()
  world({ granted = { run = true } })
  h.press("n")
  h.type("nightly-sync")
  to_field("Kind")
  h.press("right")
  h.press("right")
  h.contains(h.screen(140, 40), "exec")
  to_field("Schedule")
  h.type("weekdays")
  to_field("Time")
  h.type("09:00")
  to_field("Timezone")
  h.type("UTC")
  to_field("Command")
  h.type("tracker-sync --all $(whoami)")
  h.press("enter")
  local issued = only_command()
  h.eq(issued.kind, "automation")
  local a = issued.args
  h.eq(a.action, "create")
  h.eq(a.name, "nightly-sync")
  h.eq(a.trigger, "weekdays")
  h.eq(a.time, "09:00")
  h.eq(a.timezone, "UTC")
  h.eq(a.command, "tracker-sync --all $(whoami)", "passed verbatim, never to a shell")
  h.eq(a.flag, true)
  h.eq(a.repo, nil)
  h.eq(a.prompt, nil)
  h.contains(h.screen(140, 40), "saving")
end)

h.test("an invalid definition keeps the form and says why", function()
  world()
  h.press("n")
  h.type("broken")
  to_field("Schedule")
  h.type("cron:61 * * * *")
  to_field("Prompt")
  h.type("hello")
  h.press("enter")
  h.commands()
  h.event("command.failed", {
    kind = "automation",
    subject = "broken",
    error = "invalid cron expression `61 * * * *`: Invalid pattern",
  })
  local screen = h.screen(140, 40)
  h.contains(screen, "invalid cron expression")
  h.contains(screen, "broken", "what was typed is still there")
  -- And the form can be corrected and sent again.
  to_field("Schedule")
  clear_field()
  h.type("daily")
  h.press("enter")
  h.eq(only_command().args.trigger, "daily")
  h.event("command.done", { kind = "automation", subject = "broken" })
  h.absent(h.screen(140, 40), "▸ Name", "the form closes once it is saved")
end)

h.test("a weekday the host cannot read is caught before sending", function()
  world()
  h.press("n")
  h.type("weekly")
  to_field("Schedule")
  h.type("weekly")
  to_field("Weekday")
  h.type("funday")
  h.press("enter")
  h.eq(#h.commands(), 0, "nothing sent")
  h.contains(h.screen(140, 40), "weekday")
end)

h.test("a half-typed form survives a reload", function()
  world()
  h.press("n")
  h.type("half")
  h.load()
  local screen = h.screen(140, 40)
  h.contains(screen, "half")
  h.contains(screen, "▸ Name")
end)

h.test("edit starts from the stored definition and keeps the target", function()
  world()
  h.press("e")
  local screen = h.screen(140, 40)
  h.contains(screen, "nightly-review")
  h.contains(screen, "cron:0 9 * * 1-5")
  h.contains(screen, "Europe/Zurich")
  h.contains(screen, "/home/user/src/app", "the target is shown")
  clear_field()
  h.type("morning-review")
  h.press("enter")
  local a = only_command().args
  h.eq(a.action, "edit")
  h.eq(a.number, 3)
  h.eq(a.name, "morning-review")
  h.eq(a.trigger, "cron:0 9 * * 1-5")
  h.eq(a.timezone, "Europe/Zurich")
  h.eq(a.prompt, "Review open pull requests and summarise them")
  h.eq(a.repo, nil, "an edit never retargets")
  h.eq(a.flag, true)
end)

h.test("duplicate opens a create prefilled from the selection, disabled", function()
  world()
  h.press("c")
  local screen = h.screen(140, 40)
  h.contains(screen, "nightly-review copy")
  h.press("enter")
  local a = only_command().args
  h.eq(a.action, "create")
  h.eq(a.repo, "/home/user/src/app")
  h.eq(a.branch, "auto/review")
  h.eq(a.flag, false, "a copy starts disabled so it does not double-fire")
end)

h.test("a multi-repo spawn is not duplicated with its repositories missing", function()
  local multi = nightly()
  multi.extra_repos = 2
  world({ automations = { multi } })
  h.press("c")
  h.eq(#h.commands(), 0)
  h.contains(h.screen(140, 40), "2 extra repositories")
end)

h.test("an older thurbox: management is read-only and says why", function()
  local old = sync()
  old.trigger, old.next_run_at, old.command = nil, nil, nil
  world({ automations = { old } })
  h.old_host(true)
  h.press("e")
  h.eq(#h.commands(), 0)
  h.contains(h.screen(140, 40), "newer thurbox")
  h.press("n")
  h.type("x")
  to_field("Schedule")
  h.type("daily")
  to_field("Prompt")
  h.type("y")
  h.press("enter")
  h.eq(#h.commands(), 0)
  h.contains(h.screen(140, 40), "newer thurbox")
  -- Enable, run and delete are older than the editor and still work.
  h.press("esc")
  h.press("space")
  h.eq(only_command().args.flag, false)
end)

-- ── found in review ────────────────────────────────────────────────────────

h.test("thurbox 2.56.5 run rows carry no id, and the pane still draws them", function()
  local old = sync()
  old.trigger, old.next_run_at, old.command = nil, nil, nil
  for _, run in ipairs(old.runs) do
    run.id = nil
  end
  world({ automations = { old } })
  local screen = h.screen(140, 40)
  h.contains(screen, "connection refused")
  h.press("tab")
  h.press("j")
  h.contains(h.screen(140, 40), "ok", "the second run is selectable")
end)

h.test("enter does not answer the delete question", function()
  world()
  h.press("x")
  h.press("enter")
  h.eq(#h.commands(), 0, "only y deletes")
end)

h.test("the palette's create works whatever mode the pane was left in", function()
  world()
  h.press("/")
  h.action("automations.create")
  h.contains(h.screen(140, 40), "New automation")
end)

h.test("each automation opens on its newest run", function()
  local other = sync()
  other.id, other.name = 5, "sync-other"
  for i, run in ipairs(other.runs) do
    run.id = 50 + i
  end
  world({ automations = { sync(), other } })
  h.press("tab")
  h.press("j")
  h.press("j") -- sync-tasks' oldest run
  h.press("tab")
  h.press("j") -- sync-other
  h.contains(h.screen(140, 40), "Run #51", "its newest, not the row the other was left at")
end)

h.test("a save whose answer never comes can still be left", function()
  world()
  h.press("n")
  h.type("lost")
  h.press("enter")
  h.commands()
  h.contains(h.screen(140, 40), "saving")
  h.press("esc")
  h.absent(h.screen(140, 40), "New automation", "esc leaves a waiting form")
end)

h.test("a reload forgets answers that will never come", function()
  world()
  h.press("space")
  h.commands()
  h.contains(h.screen(140, 40), "disabling")
  h.event("interface.reloaded", { reason = "file changed" })
  h.absent(h.screen(140, 40), "disabling")
end)

h.test("a reload does not invite saving the same automation twice", function()
  world()
  h.press("n")
  h.type("slow")
  h.press("enter")
  h.commands()
  h.event("interface.reloaded", { reason = "file changed" })
  h.press("enter")
  h.eq(#h.commands(), 0, "still waiting: a command still on a worker answers after a reload")
  h.event("command.done", { kind = "automation", subject = "slow" })
  h.absent(h.screen(140, 40), "New automation", "the late answer closes it")
end)

h.test("duplicating a send whose session is gone asks for a new one", function()
  world({ sessions = { { id = "s2", name = "other-work", repo = "app" } } })
  h.press("j")
  h.press("j") -- standup-ping, sends to s1, which is gone
  h.press("c")
  h.press("enter")
  h.eq(#h.commands(), 0, "never sent to a session nobody chose")
  h.contains(h.screen(140, 40), "session")
end)

h.test("shift+tab moves between the list and the runs too", function()
  world()
  h.press("j")
  h.press("backtab")
  h.press("j")
  h.contains(h.screen(140, 40), "Run #32", "the runs had focus")
end)

h.test("untrusted, an exec automation is not written and the pane says how to trust it", function()
  world()
  h.press("n")
  h.type("sync")
  to_field("Kind")
  h.press("right")
  h.press("right")
  to_field("Schedule")
  h.type("hourly")
  to_field("Command")
  h.type("make sync")
  h.press("enter")
  h.eq(#h.commands(), 0, "nothing sent")
  h.contains(h.screen(140, 40), "trust")
  -- Editing an exec automation's command needs the same; its other fields do not.
  h.press("esc")
  h.press("j") -- sync-tasks, an exec automation
  h.press("e")
  to_field("Command")
  h.type(" --all")
  h.press("enter")
  h.eq(#h.commands(), 0, "a changed command is not sent untrusted")
  to_field("Command")
  for _ = 1, 6 do
    h.press("backspace")
  end
  to_field("Name")
  h.type("-renamed")
  h.press("enter")
  local a = only_command().args
  h.eq(a.name, "sync-tasks-renamed")
  h.eq(a.command, nil, "an unchanged command is not sent at all")
end)

-- ── found in the final-head review ────────────────────────────────────────

h.test("an older thurbox does not re-enable an automation it would never fire", function()
  -- Before the create/edit release, enabling sets the flag and leaves
  -- next_run_at empty, so the row reads as on and is never scheduled.
  local old = standup()
  old.trigger = nil
  world({ automations = { old } })
  h.press("space")
  h.eq(#h.commands(), 0, "nothing sent")
  h.contains(h.screen(140, 40), "automation edit")
  -- Disabling still works there.
  local on = sync()
  on.trigger = nil
  world({ automations = { on } })
  h.press("space")
  h.eq(only_command().args.flag, false)
end)

h.test("a send keeps the session it names when the session list changes", function()
  local three = {
    { id = "s1", name = "alpha", repo = "app" },
    { id = "s2", name = "beta", repo = "app" },
    { id = "s3", name = "gamma", repo = "app" },
  }
  local send = standup()
  send.session = "s2"
  world({ automations = { send }, sessions = three })
  h.press("c")
  world({ automations = { send }, sessions = { three[2], three[3] } })
  h.press("enter")
  h.eq(only_command().args.session, "s2", "still beta, not whatever took its index")
end)

h.test("an edit is not opened over a change still on its way", function()
  world()
  h.press("space")
  h.commands()
  h.press("e")
  h.absent(h.screen(140, 40), "Edit automation", "the edit would carry the old enabled flag")
  h.event("command.done", { kind = "automation", subject = "#3" })
  h.press("e")
  h.contains(h.screen(140, 40), "Edit automation")
end)

h.test("on an older thurbox each run keeps its own log scroll", function()
  local noisy = sync()
  local lines = {}
  for i = 1, 300 do
    lines[i] = "line " .. i
  end
  noisy.runs = {
    { started_at = h.NOW - 1000, status = "error", detail = table.concat(lines, "\n") },
    { started_at = h.NOW - 2000, status = "error", detail = table.concat(lines, "\n") },
  }
  world({ automations = { noisy } })
  h.press("tab")
  h.press("pagedown")
  h.press("j")
  h.contains(h.screen(140, 40), "\n line 2\n", "the second run opens at its top")
end)

h.test("from no session picked, left picks the last session and right the first", function()
  local three = {
    { id = "s1", name = "alpha", repo = "app" },
    { id = "s2", name = "beta", repo = "app" },
    { id = "s3", name = "gamma", repo = "app" },
  }
  world({ automations = { standup() }, sessions = three })
  h.press("j")
  h.press("j")
  h.press("c") -- standup sends to s1; make it gone
  world({ automations = { standup() }, sessions = { three[2], three[3] } })
  to_field("Session")
  h.press("left")
  h.contains(h.screen(140, 40), "gamma", "the last one")
end)

h.test("a duplicate switched to send starts on the first session", function()
  world()
  h.press("c") -- nightly-review, a spawn
  to_field("Kind")
  h.press("right") -- send
  h.contains(h.screen(140, 40), "api-refactor", "not left unpicked")
end)

h.test("a run in flight does not block an edit", function()
  world()
  h.press("r")
  h.commands()
  h.press("e")
  h.contains(h.screen(140, 40), "Edit automation", "run now changes no definition")
end)

h.test("on an older thurbox, run now on a disabled row names the way to enable it", function()
  local old = standup()
  old.trigger = nil
  world({ automations = { old } })
  h.press("r")
  h.eq(#h.commands(), 0)
  h.contains(h.screen(140, 40), "automation edit")
end)

-- ── run history and its log ─────────────────────────────────────────────────

h.test("run history shows failures and their full detail", function()
  world()
  h.press("j") -- sync-tasks
  local screen = h.screen(140, 40)
  h.contains(screen, "connection refused")
  h.contains(screen, "3 runs")
  h.press("tab") -- into the runs
  screen = h.screen(140, 40)
  h.contains(screen, "gave up after 3 attempts", "the selected run's whole detail")
  h.press("f")
  screen = h.screen(140, 40)
  h.contains(screen, "errors")
  h.absent(screen, "previous run still active", "the skipped run is filtered out")
  h.press("f")
  h.contains(h.screen(140, 40), "previous run still active", "skipped runs")
end)

h.test("a long log is bounded and scrolls", function()
  local noisy = sync()
  local lines = {}
  for i = 1, 600 do
    lines[i] = "line " .. i
  end
  noisy.runs =
    { { id = 9, started_at = NOW - 1000, status = "error", detail = table.concat(lines, "\n") } }
  world({ automations = { noisy } })
  h.press("tab")
  local screen = h.screen(140, 40)
  h.contains(screen, "\n line 2\n", "the log starts at the top")
  h.absent(screen, "line 600")
  h.press("pagedown")
  h.absent(h.screen(140, 40), "\n line 2\n", "scrolled")
  for _ = 1, 100 do
    h.press("pagedown")
  end
  screen = h.screen(140, 40)
  h.contains(screen, "more lines not shown")
  h.absent(screen, "line 600", "past the bound nothing is drawn")
end)

h.test("render never writes", function()
  world()
  for _, size in ipairs({ { 140, 40 }, { 60, 30 }, { 20, 5 } }) do
    h.render(size[1], size[2])
  end
  h.press("n")
  h.render(140, 40)
  h.press("esc")
  h.press("x")
  h.render(60, 20)
end)

h.finish()
