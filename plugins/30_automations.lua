-- Automations: list, inspect, create, edit, switch on and off, run and delete
-- thurbox's scheduled agent runs, with each automation's recent run history.
--
-- Every read is `thurbox.automations`, which the kernel refreshes from the
-- database on its own worker; every write is an `automation` command, which a
-- command worker applies later and answers with `command.done` or
-- `command.failed`. Nothing here runs a program or touches the database, so a
-- slow disk cannot stall a frame. The pane declares `run` and never calls it:
-- thurbox requires it of a file that writes an exec automation's command, the
-- one write that authors something the machine will execute.
--
-- Placement: the `center` switch slot, beside the agent pane. The slot shows its
-- first occupant (the agent) and this pane while it has focus, so it needs no
-- `layout.lua` edit; the pill, the palette and `alt+a` are how it is found.
--
-- What it cannot do, because thurbox does not: cancel a run (a run is not
-- tracked while it is in flight), keep more than the ten most recent runs per
-- automation in the snapshot, keep more of an exec run's output than the tail
-- the host records, or retarget an automation (an edit keeps its target; a
-- duplicate is how a new target is made).

local model = require("thurbox-automations.lib.model")
local textinput = require("lib.textinput")
local theme = require("lib.theme")
local ui = require("lib.ui")
local widgets = require("lib.widgets")

local NAME = "automations"
local LIST = "automations.list"
local RUNS = "automations.runs"

--- Columns at which the list and the detail sit side by side.
local WIDE = 100
--- Lines of one run's detail drawn at most, however long it is.
local LOG_LIMIT = 200
--- The label column in the detail and the form.
local LABEL = 11
local KINDS = { "spawn", "send", "exec" }

-- Written by `render` and read by the scroll handlers, which have no `ctx`.
-- Upvalues, not `state`: a render that wrote `state` would not be pure.
local last_log_rows, last_log_width = 10, 60

-- ── reads ──────────────────────────────────────────────────────────────────

local function now()
  return (thurbox and thurbox.taken_at_ms) or 0
end

local function sessions()
  return (thurbox and thurbox.sessions) or {}
end

local function feature_on()
  local settings = thurbox and thurbox.settings
  local features = settings and settings.features
  return not features or features.automations ~= false
end

--- An automation carries its definition only from the thurbox release that
--- added create and edit; an older one publishes the summary alone.
local function editable(row)
  return row ~= nil and row.trigger ~= nil
end

--- Writing an exec automation's command needs the file to hold `run`: the
--- heartbeat runs that command, so thurbox gates writing it as it gates running
--- anything. The pane never calls `run` itself.
local function trusted()
  return thurbox ~= nil and thurbox.granted ~= nil and thurbox.granted.run == true
end

local UNTRUSTED = "writing an exec automation's command needs this pane trusted: "
  .. "Ctrl+, → ] → t on thurbox-automations (it never runs anything itself)"

local NEWER = "needs a newer thurbox (one whose automation command takes create and edit)"

local cache = {}

--- The automations the filter lets through, rebuilt only when the published
--- list, the sessions or the filter moved.
local function visible()
  local src = thurbox and thurbox.automations
  local query = state.filter or ""
  local sess = thurbox and thurbox.sessions
  if rawequal(src, cache.src) and rawequal(sess, cache.sessions) and cache.query == query then
    return cache.rows
  end
  local rows = {}
  for _, row in ipairs(src or {}) do
    if model.matches(row, query, sess) then
      rows[#rows + 1] = row
    end
  end
  cache.src, cache.sessions, cache.query, cache.rows = src, sess, query, rows
  return rows
end

local function find(id)
  for _, row in ipairs((thurbox and thurbox.automations) or {}) do
    if row.id == id then
      return row
    end
  end
  return nil
end

--- Identities are strings: they double as node ids, which the kernel reads as text.
local function auto_id(row)
  return "a" .. row.id
end

--- A run's identity. thurbox before the create/edit release publishes runs
--- without an id, so the start time stands in for one there.
local function run_id(run)
  return run.id and ("r" .. run.id) or ("t" .. tostring(run.started_at))
end

local function cursor()
  return ui.cursor(LIST, visible(), { id = auto_id })
end

local function selected()
  return cursor():item()
end

local function runs_of(row)
  return model.filter_runs(row and row.runs or {}, state.run_filter or "all")
end

--- One cursor per automation, so each opens on its own newest run rather than
--- on the row the previous one was left at.
local function run_cursor(row)
  return ui.cursor(RUNS .. "." .. (row and row.id or 0), runs_of(row), { id = run_id })
end

local function plural(n, word)
  return n .. " " .. word .. (n == 1 and "" or "s")
end

-- ── notices and writes in flight ────────────────────────────────────────────

local function notice(text, level)
  state.notice = { text = text, level = level or "info" }
end

--- Issue an automation command and remember it until its answer arrives.
local function write(row, op, label, opts)
  opts.number = row.id
  command("automation", opts)
  local pending = state.pending or {}
  pending["#" .. row.id] = { op = op, label = label, name = row.name }
  state.pending = pending
  state.notice = nil
end

local function pending_of(row)
  local pending = state.pending
  return pending and row and pending["#" .. row.id] or nil
end

-- ── the form ───────────────────────────────────────────────────────────────

local function field(value)
  return textinput.new(value or "")
end

--- The rows of a form, in tab order. `static` rows are shown, never focused.
local function form_rows(form)
  local rows = {
    { key = "name", label = "Name" },
    { key = "kind", label = "Kind", choice = true, static = form.id ~= nil },
    { key = "trigger", label = "Schedule" },
    { key = "time", label = "Time" },
    { key = "weekday", label = "Weekday" },
    { key = "timezone", label = "Timezone" },
  }
  local function add(row)
    rows[#rows + 1] = row
  end
  if form.kind == "send" then
    add({ key = "session", label = "Session", choice = true, static = form.id ~= nil })
    add({ key = "prompt", label = "Prompt" })
  elseif form.kind == "spawn" then
    add({ key = "repo", label = "Repository", static = form.id ~= nil })
    add({ key = "branch", label = "Branch", static = form.id ~= nil })
    add({ key = "base", label = "Base", static = form.id ~= nil })
    add({ key = "agent", label = "Agent", static = form.id ~= nil })
    add({ key = "prompt", label = "Prompt" })
  else
    add({ key = "command", label = "Command" })
  end
  add({ key = "enabled", label = "Enabled", choice = true })
  return rows
end

local function focusable(form)
  local out = {}
  for _, row in ipairs(form_rows(form)) do
    if not row.static then
      out[#out + 1] = row
    end
  end
  return out
end

local function focused_row(form)
  local list = focusable(form)
  return list[math.max(1, math.min(form.focus or 1, #list))]
end

--- The session a form names, by id, and its position in `thurbox.sessions`;
--- nil when no session has that id. By id rather than by position, so a list
--- that changes under an open form never moves a send to another session.
local function form_session(form)
  for index, session in ipairs(sessions()) do
    if session.id == form.session_id then
      return session, index
    end
  end
  return nil, 0
end

--- A form for a new automation, or prefilled from `row` — an edit when `edit`,
--- a duplicate otherwise.
local function open_form(row, edit)
  local repos = (thurbox and thurbox.repos) or {}
  local form = {
    kind = "spawn",
    focus = 1,
    enabled = true,
    session_id = sessions()[1] and sessions()[1].id or nil,
    fields = {
      name = field(""),
      trigger = field(""),
      time = field(""),
      weekday = field(""),
      timezone = field(""),
      prompt = field(""),
      repo = field(repos[1] and repos[1].path or ""),
      branch = field(""),
      base = field(""),
      agent = field(""),
      command = field(""),
    },
  }
  if row then
    local f = form.fields
    form.kind = row.action
    form.enabled = edit and row.enabled or false
    f.name = field(edit and row.name or (row.name .. " copy"))
    f.trigger = field(model.trigger_for_form(row.trigger))
    f.timezone = field(row.timezone)
    f.prompt = field(row.prompt)
    f.repo = field(row.repo)
    f.branch = field(row.branch)
    f.base = field(row.base)
    f.agent = field(row.agent)
    f.command = field(row.command)
    form.original_command = row.command
    -- A target that is gone stays named and unlisted rather than swapped for
    -- another session: the form asks for one to be picked.
    form.session_id = row.session or form.session_id
    if edit then
      form.id = row.id
    end
  end
  state.form = form
  state.mode = "form"
end

local function trimmed(form, key)
  return (form.fields[key].value or ""):match("^%s*(.-)%s*$")
end

--- The command options a form stands for, or nil and why not.
local function form_options(form)
  local opts = {
    action = form.id and "edit" or "create",
    number = form.id,
    name = trimmed(form, "name"),
    trigger = model.trigger_for_host(form.fields.trigger.value),
    flag = form.enabled,
  }
  local time = trimmed(form, "time")
  if time ~= "" then
    opts.time = time
  end
  local weekday = trimmed(form, "weekday")
  if weekday ~= "" then
    opts.weekday = model.weekday(weekday)
    if not opts.weekday then
      return nil, "weekday: a number 0-7 (0 and 7 are Sunday) or a day name such as mon"
    end
  end
  local timezone = trimmed(form, "timezone")
  if timezone ~= "" or form.id then
    opts.timezone = timezone
  end
  if form.kind == "exec" then
    local command = form.fields.command.value
    -- An edit that leaves the command alone does not send it, so renaming or
    -- rescheduling an exec automation needs no trust.
    if not (form.id and command == form.original_command) then
      if not trusted() then
        return nil, UNTRUSTED
      end
      opts.command = command
    end
  else
    opts.prompt = form.fields.prompt.value
  end
  if not form.id then
    if form.kind == "send" then
      local session = form_session(form)
      if not session then
        if #sessions() > 0 then
          return nil, "pick a session to send to with ◂ ▸"
        end
        return nil, "no session to send to: start one, or pick another kind"
      end
      opts.session = session.id
    elseif form.kind == "spawn" then
      opts.repo = trimmed(form, "repo")
      for _, key in ipairs({ "branch", "base", "agent" }) do
        local value = trimmed(form, key)
        if value ~= "" then
          opts[key] = value
        end
      end
    end
  end
  return opts
end

local function submit(form)
  local opts, why = form_options(form)
  if not opts then
    form.error = why
    state.form = form
    return
  end
  -- A thurbox without create and edit refuses the options as a Lua error.
  local ok = pcall(command, "automation", opts)
  if not ok then
    form.error = "Saving from this pane " .. NEWER .. "."
    state.form = form
    return
  end
  form.waiting = true
  form.error = nil
  form.subject = form.id and ("#" .. form.id) or opts.name
  state.form = form
end

local function cycle_choice(form, key, step)
  if key == "kind" then
    local at = 1
    for index, kind in ipairs(KINDS) do
      if kind == form.kind then
        at = index
      end
    end
    form.kind = KINDS[(at - 1 + step) % #KINDS + 1]
    form.focus = 2
  elseif key == "session" then
    local list = sessions()
    if #list > 0 then
      local _, at = form_session(form)
      -- From no session picked, right starts at the first and left at the last.
      local to = at == 0 and (step > 0 and 1 or #list) or (at - 1 + step) % #list + 1
      form.session_id = list[to].id
    end
  elseif key == "enabled" then
    form.enabled = not form.enabled
  end
end

local function form_key(key)
  local form = state.form
  if not form then
    state.mode = nil
    return true
  end
  if form.waiting then
    -- The answer is out. Esc only stops waiting for it — the write may still
    -- land, and the list will show it — so an answer lost to a reload cannot
    -- hold the form up for good.
    if key.key == "esc" then
      state.form, state.mode = nil, nil
      notice("stopped waiting; the list shows whether it was saved")
    end
    return true
  end
  local name = key.key
  if name == "esc" then
    state.form, state.mode = nil, nil
    return true
  end
  if name == "enter" then
    submit(form)
    return true
  end
  local list = focusable(form)
  if (name == "tab" and not key.shift) or name == "down" then
    form.focus = (form.focus or 1) % #list + 1
    state.form = form
    return true
  end
  if name == "backtab" or name == "up" then
    form.focus = ((form.focus or 1) - 2) % #list + 1
    state.form = form
    return true
  end
  local row = focused_row(form)
  if row.choice then
    if name == "left" or name == "right" or name == "space" then
      cycle_choice(form, row.key, name == "left" and -1 or 1)
      form.error = nil
      state.form = form
    end
    return true
  end
  if textinput.key(form.fields[row.key], key) then
    form.error = nil
    state.form = form
  end
  return true
end

-- ── browse actions ─────────────────────────────────────────────────────────

--- Where this thurbox cannot enable an automation properly, the way that can.
local function enable_by_cli(row)
  notice(
    "To re-enable: thurbox-cli automation edit "
      .. row.id
      .. " --enabled (this thurbox would leave it unscheduled)",
    "error"
  )
end

local function toggle_enabled()
  local row = selected()
  if not row then
    return
  end
  if row.enabled then
    write(row, "disable", "disabling", { flag = false })
  elseif not editable(row) then
    -- Before the create/edit release, enabling sets the flag and leaves the
    -- next run empty: the row would read as on and never fire.
    enable_by_cli(row)
  else
    write(row, "enable", "enabling", { flag = true })
  end
end

local function run_now()
  local row = selected()
  if not row then
    return
  end
  if not row.enabled and not editable(row) then
    enable_by_cli(row)
    return
  end
  if not row.enabled then
    -- thurbox's run-now marks the automation due AND enabled; doing that to a
    -- disabled one would quietly switch it back on for good.
    notice(row.name .. " is disabled: enable it first (run now would switch it back on)", "error")
    return
  end
  write(row, "run", "queuing a run", { force = true })
end

local function ask_delete()
  local row = selected()
  if row then
    state.confirm = { id = row.id, name = row.name, runs = #(row.runs or {}) }
    state.mode = "confirm"
  end
end

local function confirm_key(key)
  local ask = state.confirm
  state.confirm, state.mode = nil, nil
  if not ask then
    return true
  end
  if key.key == "y" then
    local row = find(ask.id)
    if not row then
      notice(ask.name .. " no longer exists; nothing was deleted")
      return true
    end
    write(row, "delete", "deleting", { reset = true })
  end
  return true
end

local function edit()
  local row = selected()
  if not row then
    return
  end
  if not editable(row) then
    notice("Editing " .. NEWER .. ".", "error")
    return
  end
  local pending = pending_of(row)
  if pending and pending.op ~= "run" then
    -- The form would start from the row as it was before that change, and
    -- saving would put it back. A run changes no definition.
    notice(row.name .. " has a change on its way; edit it once that lands", "error")
    return
  end
  open_form(row, true)
end

local function duplicate()
  local row = selected()
  if not row then
    return
  end
  if not editable(row) then
    notice("Duplicating " .. NEWER .. ".", "error")
    return
  end
  if (row.extra_repos or 0) > 0 then
    notice(
      "Cannot duplicate "
        .. row.name
        .. ": a pane cannot recreate its "
        .. (row.extra_repos == 1 and "extra repository" or (row.extra_repos .. " extra repositories"))
        .. "; use thurbox-cli automation create --add-repo",
      "error"
    )
    return
  end
  open_form(row, false)
end

local function scroll_log(step)
  local row = selected()
  local run = run_cursor(row):item()
  if not run then
    return
  end
  local lines, total =
    model.wrap(run.detail, last_log_width, LOG_LIMIT, widgets.len, widgets.keep_left)
  local drawn = #lines + (total > LOG_LIMIT and 1 or 0)
  local offset = state.log_for == run_id(run) and (state.log or 0) or 0
  local page = math.max(1, last_log_rows - 1)
  offset = math.max(0, math.min(drawn - last_log_rows, offset + step * page))
  state.log, state.log_for = offset, run_id(run)
end

local function filter_key(key)
  local f = state.filter_field or textinput.new(state.filter or "")
  if key.key == "esc" then
    state.filter, state.filter_field, state.mode = nil, nil, nil
    return true
  end
  if key.key == "enter" then
    state.filter_field, state.mode = nil, nil
    return true
  end
  if textinput.key(f, key) then
    state.filter_field = f
    state.filter = f.value
    ui.reset(LIST)
  end
  return true
end

-- ── drawing ────────────────────────────────────────────────────────────────

local function span(text, fg, bold)
  return { text = text, style = { fg = fg, bold = bold } }
end

local function kv(label, value, width, fg)
  return {
    span(" " .. widgets.pad(label, LABEL), theme.muted),
    span(widgets.truncate(value or "", math.max(1, width - LABEL - 2)), fg or theme.text),
  }
end

local function list_row(row, width)
  local mark = row.enabled and span("● ", theme.ok) or span("○ ", theme.muted)
  local when
  if not row.enabled then
    when = "off"
  elseif row.next_run_at then
    when = model.relative(row.next_run_at, now())
  else
    when = row.trigger and "never" or ""
  end
  local last = ""
  local last_fg = theme.muted
  if row.last_outcome then
    local glyph, role = model.run_mark(row.last_outcome)
    last, last_fg = glyph, theme[role]
  end
  if pending_of(row) then
    last, last_fg = "…", theme.warn
  end
  local name_w = math.max(4, math.floor((width - 4) * 0.4))
  local when_w = math.min(8, math.max(0, width - 4 - name_w))
  local sched_w = math.max(0, width - 4 - name_w - when_w - 2)
  local spans = {
    span(" "),
    mark,
    span(
      widgets.pad(widgets.truncate(row.name, name_w), name_w),
      row.enabled and theme.text or theme.muted
    ),
  }
  if sched_w > 2 then
    spans[#spans + 1] = span(
      " " .. widgets.pad(widgets.truncate(model.describe(row), sched_w - 1), sched_w - 1),
      theme.secondary
    )
  end
  if when_w > 2 then
    spans[#spans + 1] =
      span(" " .. widgets.pad(widgets.truncate(when, when_w - 1), when_w - 1), theme.muted)
  end
  spans[#spans + 1] = span(" " .. last, last_fg)
  return spans
end

local function list_panel(rows, width, height, focused)
  local list_cursor = ui.cursor(LIST, rows, { id = auto_id })
  local title = "Automations"
  if state.filter and state.filter ~= "" then
    title = title .. " · /" .. state.filter .. " (" .. #rows .. ")"
  elseif #rows > 0 then
    title = title .. " (" .. #rows .. ")"
  end
  local inner_w, inner_h = math.max(1, width - 2), math.max(1, height - 2)
  local empty
  if thurbox and thurbox.error then
    empty = { { span("Could not read automations: " .. thurbox.error, theme.bad) } }
  elseif state.filter and state.filter ~= "" then
    empty = "Nothing matches /" .. state.filter
  else
    empty = ui.empty({
      title = "No automations yet",
      width = inner_w,
      hint = "%s creates one",
      hint_action = "automations.new",
    })
  end
  return ui.panel({
    title = title,
    focused = focused and (state.focus or "list") == "list",
    body = ui.list({
      items = rows,
      cursor = list_cursor,
      width = inner_w,
      height = inner_h,
      on_overflow = "border",
      row = function(row)
        return list_row(row, inner_w)
      end,
      empty = empty,
    }),
  })
end

local function next_line(row)
  if not row.enabled then
    return "not scheduled (disabled)", theme.muted
  end
  if not row.next_run_at then
    if row.trigger then
      return "never again: the schedule has no future occurrence", theme.warn
    end
    return "—", theme.muted
  end
  if row.next_run_at <= now() then
    return "due: this machine's heartbeat fires it within a minute", theme.warn
  end
  return model.relative(row.next_run_at, now()) .. " · " .. model.utc(row.next_run_at), theme.text
end

local function info_lines(row, width)
  local lines = {}
  local function add(line)
    lines[#lines + 1] = line
  end
  local head = {
    span(" " .. widgets.truncate(row.name, math.max(1, width - 15)) .. "  ", theme.text, true),
    row.enabled and span("● enabled", theme.ok) or span("○ disabled", theme.muted),
  }
  local pending = pending_of(row)
  if pending then
    head[#head + 1] = span("  " .. pending.label .. "…", theme.warn)
  end
  add(head)
  local schedule = model.describe(row)
  if row.trigger then
    schedule = schedule .. " · " .. (row.timezone or "local time")
  end
  add(kv("Schedule", schedule, width))
  local target, gone = model.target(row, sessions())
  add(kv("Target", target, width, gone and theme.bad or theme.text))
  if row.action == "spawn" and row.base then
    add(kv("", "worktree off " .. row.base, width, theme.muted))
  end
  add(kv("Runs on", "this machine, from its heartbeat", width, theme.muted))
  local next_text, next_fg = next_line(row)
  add(kv("Next run", next_text, width, next_fg))
  if row.last_run_at then
    add(
      kv(
        "Last run",
        model.relative(row.last_run_at, now()) .. " · " .. model.utc(row.last_run_at),
        width
      )
    )
  elseif row.last_outcome then
    add(kv("Last run", row.last_outcome, width))
  end
  if row.action ~= "exec" and row.prompt then
    local first = row.prompt:match("^[^\n]*") or ""
    if first ~= row.prompt then
      first = first .. " …"
    end
    add(kv("Prompt", first, width))
  end
  if not editable(row) then
    add({
      span(" Showing the summary this thurbox publishes; editing " .. NEWER .. ".", theme.muted),
    })
  end
  return lines
end

local function run_row(run, width)
  local glyph, role = model.run_mark(run.status)
  local when = model.relative(run.started_at, now())
  local first = (run.detail or ""):match("^[^\n]*") or ""
  return {
    span(" " .. glyph .. " ", theme[role]),
    span(widgets.pad(when, 9), theme.muted),
    span(
      widgets.truncate(first, math.max(1, width - 13)),
      run.status == "error" and theme.bad or theme.text
    ),
  }
end

local function detail_panel(row, width, height, focused)
  local inner_w, inner_h = math.max(1, width - 2), math.max(1, height - 2)
  local children = {}
  if not row then
    children[1] = { type = "text", text = "" }
    return ui.panel({ title = "Detail", focused = false, body = children })
  end
  local info = info_lines(row, inner_w)
  local info_h = math.min(#info, math.max(1, inner_h - 4))
  children[#children + 1] = { type = "text", len = info_h, text = info }

  local filter = state.run_filter or "all"
  local all = row.runs or {}
  local runs = runs_of(row)
  local rc = run_cursor(row)
  local heading = "Runs · " .. plural(#all, "run")
  if #all >= 10 then
    heading = heading .. " (the 10 most recent)"
  end
  if filter ~= "all" then
    heading = heading .. " · " .. filter .. " only"
  end
  local left = inner_h - info_h
  if left >= 2 then
    children[#children + 1] = { type = "text", len = 1, text = { ui.rule(heading, inner_w) } }
    left = left - 1
    local runs_h = math.max(1, math.min(math.max(1, #runs), math.floor(left / 2)))
    children[#children + 1] = ui.list({
      items = runs,
      cursor = rc,
      width = inner_w,
      height = runs_h,
      len = runs_h,
      on_overflow = "rows",
      row = function(run)
        return run_row(run, inner_w)
      end,
      empty = #all == 0 and "No runs recorded yet" or ("No " .. filter .. " among the recent runs"),
    })
    left = left - runs_h
  end
  local run = rc:item()
  if run and left >= 2 then
    local title = (run.id and ("Run #" .. run.id) or "Run")
      .. " · "
      .. run.status
      .. " · "
      .. model.utc(run.started_at)
    children[#children + 1] = { type = "text", len = 1, text = { ui.rule(title, inner_w) } }
    left = left - 1
    local lines, total =
      model.wrap(run.detail, inner_w - 1, LOG_LIMIT, widgets.len, widgets.keep_left)
    if total > LOG_LIMIT then
      lines[#lines + 1] = "… " .. (total - LOG_LIMIT) .. " more lines not shown"
    end
    last_log_rows, last_log_width = left, inner_w - 1
    local offset = state.log_for == run_id(run) and (state.log or 0) or 0
    offset = math.max(0, math.min(offset, #lines - left))
    local shown = {}
    for index = offset + 1, math.min(#lines, offset + left) do
      shown[#shown + 1] =
        { span(" " .. lines[index], run.status == "error" and theme.text or theme.secondary) }
    end
    children[#children + 1] = { type = "text", len = left, text = shown }
  end
  return ui.panel({
    title = row.name,
    focused = focused and state.focus == "runs",
    body = { type = "box", children = children },
  })
end

local function form_panel(form, width)
  local inner_w = math.max(1, width - 2)
  local rows = form_rows(form)
  local focus = focused_row(form)
  local children = {}
  for _, row in ipairs(rows) do
    local is_focus = focus and focus.key == row.key and not form.waiting
    local label = span(
      (is_focus and "▸ " or "  ") .. widgets.pad(row.label, LABEL),
      is_focus and theme.accent or theme.muted
    )
    local value
    if row.key == "kind" then
      value = form.kind .. (row.static and "" or "   ◂ ▸")
    elseif row.key == "session" then
      local session = form_session(form)
      if row.static then
        value = (model.session_label(form.session_id, sessions()))
      else
        if session then
          value = session.name .. "   ◂ ▸"
        elseif #sessions() > 0 then
          value = "pick a session   ◂ ▸"
        else
          value = "no sessions to send to"
        end
      end
    elseif row.key == "enabled" then
      value = (form.enabled and "yes" or "no") .. "   ◂ ▸"
    end
    local right
    if value then
      right =
        { type = "text", text = { { span(value, row.static and theme.muted or theme.text) } } }
    elseif is_focus then
      local f = form.fields[row.key]
      right = {
        type = "input",
        value = f.value,
        cursor = f.cursor,
        focused = true,
        style = { fg = theme.text },
      }
    else
      right = {
        type = "text",
        text = { { span(form.fields[row.key].value, row.static and theme.muted or theme.text) } },
      }
    end
    children[#children + 1] = {
      type = "box",
      axis = "horizontal",
      len = 1,
      children = { { type = "text", len = LABEL + 2, text = { { label } } }, right },
    }
  end
  local help = {}
  if form.kind == "exec" and not trusted() then
    help[#help + 1] = "Untrusted: " .. UNTRUSTED .. "."
  end
  local schedule_help = {
    "Schedule: hourly · daily · weekdays · weekly (with Time, and Weekday for weekly),",
    "cron:<min hour dom month dow>, or at:YYYY-MM-DD HH:MM (UTC). Timezone: an IANA name; empty is local.",
  }
  for _, line in ipairs(schedule_help) do
    help[#help + 1] = line
  end
  children[#children + 1] = { type = "text", len = 1, text = "" }
  for _, line in ipairs(help) do
    children[#children + 1] = {
      type = "text",
      len = 1,
      text = { { span(" " .. widgets.truncate(line, inner_w - 1), theme.muted) } },
    }
  end
  local status
  if form.waiting then
    status = { span(" saving…", theme.warn) }
  elseif form.error then
    status = { span(" " .. form.error, theme.bad) }
  else
    status = {
      span(
        " enter saves · esc cancels · tab moves · ◂ ▸ changes a choice · ctrl+w deletes a word",
        theme.muted
      ),
    }
  end
  children[#children + 1] = { type = "text", len = 1, text = { status } }
  local title = form.id and ("Edit automation #" .. form.id) or "New automation"
  return ui.panel({ title = title, focused = true, body = { type = "box", children = children } })
end

local function status_line(width)
  local spans = {}
  if state.mode == "confirm" and state.confirm and find(state.confirm.id) then
    local ask = state.confirm
    local runs = ask.runs >= 10 and "its recorded runs"
      or ("its " .. plural(ask.runs, "recorded run"))
    spans = {
      span(" Delete " .. ask.name .. " and " .. runs .. "? ", theme.bad, true),
      span("y deletes · any other key keeps it", theme.muted),
    }
  elseif state.mode == "filter" then
    spans = {
      span(" /" .. (state.filter or ""), theme.accent),
      span("▏  enter keeps · esc clears", theme.muted),
    }
  elseif state.notice then
    spans = {
      span(
        " " .. state.notice.text,
        state.notice.level == "error" and theme.bad or theme.secondary
      ),
    }
  end
  if #spans == 0 then
    return nil
  end
  local out = {}
  local used = 0
  for _, s in ipairs(spans) do
    local room = width - used
    if room <= 0 then
      break
    end
    s.text = widgets.truncate(s.text, room)
    used = used + widgets.len(s.text)
    out[#out + 1] = s
  end
  return { type = "text", len = 1, text = { out } }
end

--- The key hints, resolved from the registry so a rebind moves them. Not
--- `ui.footer`: that is a modal's, with a Cancel pill this pane has no use for.
local FOOTER = {
  "automations.new",
  "automations.edit",
  "automations.duplicate",
  "automations.enable",
  "automations.run",
  "automations.delete",
  "automations.filter",
  "automations.focus_runs",
  "automations.run_filter",
}

local function footer(width)
  local spans, used = {}, 0
  for _, action in ipairs(FOOTER) do
    local chord, desc = ui.chord(action), ui.describe(action)
    if chord and desc then
      local cost = widgets.len(chord) + widgets.len(desc) + 3
      if used + cost > width then
        break
      end
      spans[#spans + 1] = span(" " .. chord, theme.hint)
      spans[#spans + 1] = span(" " .. desc .. " ", theme.muted)
      used = used + cost
    end
  end
  return { type = "text", len = 1, text = { spans } }
end

local function render(ctx)
  local width, height = math.max(1, ctx.width or 1), math.max(1, ctx.height or 1)
  if not (thurbox and thurbox.automations) or now() == 0 then
    return {
      type = "box",
      layout = "loading",
      children = {
        ui.panel({
          title = "Automations",
          focused = ctx.focused,
          body = { type = "text", text = " Reading automations…" },
        }),
      },
    }
  end
  local children = {}
  if not feature_on() then
    children[#children + 1] = {
      type = "text",
      len = 1,
      text = {
        {
          span(
            widgets.truncate(
              " Automations are switched off in settings ([features] automations): nothing fires and no heartbeat is armed.",
              width
            ),
            theme.warn
          ),
        },
      },
    }
  end
  local status = status_line(width)
  local bottom = (status and 1 or 0) + (height >= 8 and 1 or 0)
  local main_h = math.max(1, height - #children - bottom)
  local layout = width >= WIDE and "columns" or "stacked"
  local main
  if state.mode == "form" and state.form then
    main = form_panel(state.form, width)
    main.len = main_h
  else
    local rows = visible()
    local row = ui.cursor(LIST, rows, { id = auto_id }):item()
    if layout == "columns" then
      local list_w = math.max(20, math.floor(width * 0.42))
      local list = list_panel(rows, list_w, main_h, ctx.focused)
      list.len = list_w
      main = {
        type = "box",
        axis = "horizontal",
        len = main_h,
        children = { list, detail_panel(row, width - list_w, main_h, ctx.focused) },
      }
    else
      local list_h = math.max(3, math.min(#rows + 2, math.floor(main_h * 0.4)))
      local list = list_panel(rows, width, list_h, ctx.focused)
      list.len = list_h
      main = {
        type = "box",
        len = main_h,
        children = { list, detail_panel(row, width, math.max(1, main_h - list_h), ctx.focused) },
      }
    end
  end
  children[#children + 1] = main
  if status then
    children[#children + 1] = status
  end
  if height >= 8 then
    children[#children + 1] = footer(width)
  end
  return { type = "box", layout = layout, children = children }
end

-- ── the declaration ────────────────────────────────────────────────────────

local function browse(action)
  if action == "automations.next" or action == "automations.previous" then
    local step = action == "automations.next" and 1 or -1
    if state.focus == "runs" then
      run_cursor(selected()):move(step)
    else
      cursor():move(step)
    end
  elseif action == "automations.new" then
    open_form(nil, false)
  elseif action == "automations.edit" then
    edit()
  elseif action == "automations.duplicate" then
    duplicate()
  elseif action == "automations.enable" then
    toggle_enabled()
  elseif action == "automations.run" then
    run_now()
  elseif action == "automations.delete" then
    ask_delete()
  elseif action == "automations.filter" then
    state.mode = "filter"
    state.filter_field = textinput.new(state.filter or "")
  elseif action == "automations.focus_runs" then
    state.focus = state.focus == "runs" and "list" or "runs"
  elseif action == "automations.run_filter" then
    local at = 1
    for index, name in ipairs(model.RUN_FILTERS) do
      if name == (state.run_filter or "all") then
        at = index
      end
    end
    state.run_filter = model.RUN_FILTERS[at % #model.RUN_FILTERS + 1]
    local row = selected()
    ui.reset(RUNS .. "." .. (row and row.id or 0))
  elseif action == "automations.log_down" then
    scroll_log(1)
  elseif action == "automations.log_up" then
    scroll_log(-1)
  else
    return false
  end
  return true
end

return {
  name = NAME,
  -- The agent pane is the slot's first occupant and stays what the centre
  -- shows; this one is drawn while it has focus.
  slot = "center",
  order = 30,
  -- A pane, not a decoration: without this the focus command has nothing to
  -- land on and the slot keeps showing the agent.
  focusable = true,
  -- Reads `thurbox`, `state` and the theme, and writes nothing a render could
  -- not repeat: the cursor's own bookkeeping and two scroll upvalues.
  pure = true,
  -- Never called: thurbox requires `run` of a file that writes an exec
  -- automation's command. Untrusted, everything else works.
  capabilities = { "run" },
  pills = { { action = "automations.toggle", label = "Automations", priority = 20 } },
  events = { "command.done", "command.failed", "interface.reloaded" },
  commands = {
    { action = "automations.toggle", desc = "Automations: show or leave the automations pane" },
    { action = "automations.create", desc = "Automations: create an automation" },
  },
  keys = {
    -- Every F-key is taken by the kernel or another official pane; Alt+A is
    -- free in thurbox and in the agents it hosts, and global so it works from
    -- inside a focused terminal.
    {
      key = "alt+a",
      action = "automations.toggle",
      desc = "show or leave automations",
      scope = "global",
      group = "Automations",
    },
    { key = "j", action = "automations.next", desc = "next", group = "Automations" },
    { key = "down", action = "automations.next", desc = "next", group = "Automations" },
    { key = "k", action = "automations.previous", desc = "previous", group = "Automations" },
    { key = "up", action = "automations.previous", desc = "previous", group = "Automations" },
    { key = "n", action = "automations.new", desc = "new", group = "Automations" },
    { key = "e", action = "automations.edit", desc = "edit", group = "Automations" },
    { key = "c", action = "automations.duplicate", desc = "duplicate", group = "Automations" },
    { key = "space", action = "automations.enable", desc = "on/off", group = "Automations" },
    { key = "r", action = "automations.run", desc = "run now", group = "Automations" },
    { key = "x", action = "automations.delete", desc = "delete", group = "Automations" },
    { key = "delete", action = "automations.delete", desc = "delete", group = "Automations" },
    { key = "/", action = "automations.filter", desc = "filter", group = "Automations" },
    { key = "tab", action = "automations.focus_runs", desc = "list/runs", group = "Automations" },
    {
      key = "f",
      action = "automations.run_filter",
      desc = "all/errors/skipped",
      group = "Automations",
    },
    {
      key = "pagedown",
      action = "automations.log_down",
      desc = "scroll log",
      group = "Automations",
    },
    {
      key = "pageup",
      action = "automations.log_up",
      desc = "scroll log back",
      group = "Automations",
    },
  },

  render = render,

  on_action = function(action)
    if action == "automations.toggle" then
      command("focus", { text = NAME, toggle = true })
      return true
    end
    -- The palette's create, a separate action from the `n` key: it may arrive
    -- with a filter or a question left up, and a new form replaces either,
    -- whereas `n` typed into a filter is a letter.
    if action == "automations.create" then
      if thurbox and thurbox.focus ~= NAME then
        command("focus", { text = NAME })
      end
      if state.mode ~= "form" then
        state.confirm, state.filter_field = nil, nil
        open_form(nil, false)
      end
      return true
    end
    -- While a form, a filter or a question is up, the plain keys are text or an
    -- answer, so they go to `on_key` instead of their browse actions.
    if state.mode then
      return false
    end
    return browse(action)
  end,

  on_key = function(key)
    if state.mode == "form" then
      return form_key(key)
    elseif state.mode == "filter" then
      return filter_key(key)
    elseif state.mode == "confirm" then
      return confirm_key(key)
    end
    if key.key == "esc" then
      if state.filter and state.filter ~= "" then
        state.filter = nil
        return true
      end
      -- Declined, so Esc leaves the pane as it leaves any other.
      state.notice = nil
      return false
    end
    if key.key == "enter" then
      state.focus = state.focus == "runs" and "list" or "runs"
      return true
    end
    if key.key == "backtab" then
      state.focus = state.focus == "runs" and "list" or "runs"
      return true
    end
    return false
  end,

  on_event = function(name, payload)
    if name == "interface.reloaded" then
      -- A reload drops the events still queued, so the `…` marks of writes
      -- already answered may never clear: forget them. A form stays waiting —
      -- its command may still be on a worker and answer after the reload, and
      -- re-enabling Enter would invite saving it twice. Esc leaves it.
      state.pending = nil
      return
    end
    if payload.kind ~= "automation" then
      return
    end
    local subject = payload.subject
    local form = state.form
    if form and form.waiting and (subject == nil or subject == form.subject) then
      if name == "command.done" then
        local saved = trimmed(form, "name")
        state.form, state.mode = nil, nil
        notice("saved " .. saved)
      else
        form.waiting, form.error = false, payload.error or "the automation was not saved"
        state.form = form
      end
      return
    end
    local pending = state.pending or {}
    local key = subject
    if key == nil then
      key = next(pending)
    end
    local entry = key and pending[key]
    if not key or not entry then
      if name == "command.failed" then
        notice(payload.error or "an automation command failed", "error")
      end
      return
    end
    pending[key] = nil
    state.pending = pending
    if name == "command.failed" then
      notice(entry.name .. ": " .. (payload.error or (entry.op .. " failed")), "error")
    elseif entry.op == "run" then
      notice(entry.name .. " is due: this machine's heartbeat fires it within a minute")
    elseif entry.op == "delete" then
      notice("deleted " .. entry.name)
    end
  end,
}
