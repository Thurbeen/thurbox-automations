-- The pure half of the pane: dates, schedules, targets and logs, as text.
--
-- Nothing here reads `thurbox`, `state` or `store`; every input is an argument,
-- so `tests/model.lua` can pin it without a pane around it.
--
-- A plugin has no clock and no `os.date` (the VM ships no `os`), so dates are
-- computed here from Unix milliseconds, in UTC, and "now" is always the
-- snapshot's own instant, passed in. The kernel stores an automation's times
-- as UTC milliseconds; a schedule's timezone decides WHEN it fires, which the
-- kernel has already worked out into `next_run_at`.

local model = {}

local MINUTE = 60 * 1000
local DAY = 24 * 60 * MINUTE

-- ── dates ──────────────────────────────────────────────────────────────────

--- Floor division, spelled out: the interface's own Lua never uses `//`, and
--- neither do the formatter and linter configurations it ships.
local function div(a, b)
  return math.floor(a / b)
end

--- Days since 1970-01-01 → civil date (Howard Hinnant's `civil_from_days`).
local function civil_from_days(z)
  z = z + 719468
  local era = div(z >= 0 and z or z - 146096, 146097)
  local doe = z - era * 146097
  local yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100))
  local mp = div(5 * doy + 2, 153)
  local d = doy - div(153 * mp + 2, 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

--- Civil date → days since 1970-01-01 (`days_from_civil`).
local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = div(y >= 0 and y or y - 399, 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = div(153 * mp + 2, 5) + d - 1
  local doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy
  return era * 146097 + doe - 719468
end

local function days_in_month(y, m)
  local leap = (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
  local days = { 31, leap and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return days[m]
end

--- `YYYY-MM-DD HH:MM` without the zone, for a field the user edits.
local function utc_bare(millis)
  local days = div(millis, DAY)
  local rest = millis - days * DAY
  local y, m, d = civil_from_days(days)
  local minutes = div(rest, MINUTE)
  return string.format("%04d-%02d-%02d %02d:%02d", y, m, d, div(minutes, 60), minutes % 60)
end

--- A timestamp as `YYYY-MM-DD HH:MM UTC`.
---@param millis integer
---@return string
function model.utc(millis)
  return utc_bare(math.floor(millis)) .. " UTC"
end

--- `YYYY-MM-DD HH:MM`, read as UTC, back to milliseconds; nil when it is not a
--- real date.
---@param text string
---@return integer?
function model.parse_utc(text)
  local y, m, d, hh, mm =
    string.match(text or "", "^%s*(%d%d%d%d)-(%d%d)-(%d%d)[ T](%d%d):(%d%d)%s*$")
  if not y then
    return nil
  end
  y, m, d, hh, mm = tonumber(y), tonumber(m), tonumber(d), tonumber(hh), tonumber(mm)
  if m < 1 or m > 12 or d < 1 or d > days_in_month(y, m) or hh > 23 or mm > 59 then
    return nil
  end
  return days_from_civil(y, m, d) * DAY + (hh * 60 + mm) * MINUTE
end

--- `in 3h` / `5m ago` / `now`, against the snapshot's instant.
---@param millis integer
---@param now integer
---@return string
function model.relative(millis, now)
  local diff = millis - now
  local seconds = div(math.abs(diff), 1000)
  if seconds == 0 then
    return "now"
  end
  local amount
  if seconds < 60 then
    amount = seconds .. "s"
  elseif seconds < 3600 then
    amount = div(seconds, 60) .. "m"
  elseif seconds < 86400 then
    amount = div(seconds, 3600) .. "h"
  else
    amount = div(seconds, 86400) .. "d"
  end
  return diff > 0 and ("in " .. amount) or (amount .. " ago")
end

-- ── schedules ──────────────────────────────────────────────────────────────

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function number(field)
  return field:match("^%d+$") and tonumber(field) or nil
end

--- The common cron shapes in words; anything else verbatim, so a schedule is
--- never described as something it is not.
---@param expr string
---@return string
function model.describe_cron(expr)
  local fields = {}
  for field in string.gmatch(expr or "", "%S+") do
    fields[#fields + 1] = field
  end
  if #fields == 5 then
    local minute, hour, dom, month, dow = fields[1], fields[2], fields[3], fields[4], fields[5]
    local m, hr = number(minute), number(hour)
    if dom == "*" and month == "*" then
      if m and hr and m < 60 and hr < 24 then
        local at = string.format("%02d:%02d", hr, m)
        if dow == "*" then
          return "daily " .. at
        elseif dow == "1-5" then
          return "weekdays " .. at
        elseif number(dow) and number(dow) <= 7 then
          return "weekly " .. DAYS[number(dow) % 7 + 1] .. " " .. at
        end
      elseif m and m < 60 and hour == "*" and dow == "*" then
        return string.format("hourly at :%02d", m)
      end
      local every = minute:match("^%*/(%d+)$")
      if every and hour == "*" and dow == "*" then
        return "every " .. every .. "m"
      end
    end
  end
  return "cron " .. (expr or "")
end

--- What the schedule says, short: for the list, and the detail's first line.
---@param row thurbox.Automation
---@return string
function model.describe(row)
  local trigger = row.trigger
  if trigger and trigger:match("^at:") then
    local at = tonumber(trigger:sub(4))
    return at and ("once " .. model.utc(at)) or "once"
  end
  if row.schedule == "once" then
    return "once"
  end
  return model.describe_cron(row.schedule)
end

--- The schedule as the form shows it: a one-shot as a UTC date when it falls
--- on a whole minute, which is what the form takes back.
---@param trigger string
---@return string
function model.trigger_for_form(trigger)
  local at = trigger and tonumber(trigger:match("^at:(%d+)$") or "")
  if at and at % MINUTE == 0 then
    return "at:" .. utc_bare(at)
  end
  return trigger or ""
end

--- The form's schedule as the host reads it: `at:YYYY-MM-DD HH:MM` (UTC)
--- becomes the `at:<millis>` the host stores; everything else passes through
--- for the host to judge.
---@param text string
---@return string
function model.trigger_for_host(text)
  text = (text or ""):match("^%s*(.-)%s*$")
  local date = text:match("^at:%s*(%d%d%d%d%-.*)$")
  if date then
    local at = model.parse_utc(date)
    if at then
      return "at:" .. at
    end
  end
  return text
end

local WEEKDAYS = {
  sun = 0,
  sunday = 0,
  mon = 1,
  monday = 1,
  tue = 2,
  tuesday = 2,
  wed = 3,
  wednesday = 3,
  thu = 4,
  thursday = 4,
  fri = 5,
  friday = 5,
  sat = 6,
  saturday = 6,
}

--- A weekday as the host takes it (0..7, 0 and 7 both Sunday), from a number
--- or a name; nil when it is neither.
---@param text string
---@return integer?
function model.weekday(text)
  text = (text or ""):lower():match("^%s*(.-)%s*$")
  local n = number(text)
  if n then
    return n <= 7 and n or nil
  end
  return WEEKDAYS[text]
end

-- ── targets ────────────────────────────────────────────────────────────────

local function basename(path)
  return (path or ""):gsub("[/\\]+$", ""):match("([^/\\]+)$") or path or ""
end

--- A session by name, or its id's head and `(gone)` when no session has it.
---@param id string?
---@param sessions thurbox.Session[]
---@return string label
---@return boolean gone
function model.session_label(id, sessions)
  if not id then
    return "a session", false
  end
  for _, session in ipairs(sessions or {}) do
    if session.id == id then
      return session.name, false
    end
  end
  return id:sub(1, 8) .. " (gone)", true
end

--- What an automation acts on, in a line, and whether that target is gone.
---@param row thurbox.Automation
---@param sessions thurbox.Session[]
---@return string label
---@return boolean gone
function model.target(row, sessions)
  if row.action == "send" then
    local label, gone = model.session_label(row.session, sessions)
    return "send to " .. label, gone
  elseif row.action == "spawn" then
    if not row.repo then
      return "spawn a session", false
    end
    local parts = { "spawn in " .. basename(row.repo) }
    if row.branch then
      parts[#parts + 1] = row.branch
    end
    if row.agent then
      parts[#parts + 1] = row.agent
    end
    local label = table.concat(parts, " · ")
    if (row.extra_repos or 0) > 0 then
      label = label .. " +" .. row.extra_repos .. " repos"
    end
    return label, false
  elseif row.action == "exec" then
    return row.command and ("$ " .. row.command) or "run a command", false
  end
  return row.action or "?", false
end

--- Does `row` match the filter text? Name, schedule and target, ignoring case.
---@param row thurbox.Automation
---@param query string
---@param sessions thurbox.Session[]
---@return boolean
function model.matches(row, query, sessions)
  if not query or query == "" then
    return true
  end
  local needle = query:lower()
  local hay = table
    .concat({
      row.name or "",
      model.describe(row),
      (model.target(row, sessions)),
      row.action or "",
    }, "\n")
    :lower()
  return hay:find(needle, 1, true) ~= nil
end

-- ── runs ───────────────────────────────────────────────────────────────────

--- The run filters, in the order `f` cycles them.
model.RUN_FILTERS = { "all", "errors", "skipped" }

---@param runs thurbox.AutomationRun[]
---@param filter string
---@return thurbox.AutomationRun[]
function model.filter_runs(runs, filter)
  if filter == "errors" or filter == "skipped" then
    local wanted = filter == "errors" and "error" or "skipped"
    local out = {}
    for _, run in ipairs(runs or {}) do
      if run.status == wanted then
        out[#out + 1] = run
      end
    end
    return out
  end
  return runs or {}
end

--- A run's status as a glyph and the theme role that colours it.
function model.run_mark(status)
  if status == "success" then
    return "✓", "ok"
  elseif status == "skipped" then
    return "–", "muted"
  end
  return "✗", "bad"
end

--- Split `text` into lines no wider than `width` columns, keeping at most
--- `limit` of them. Returns the lines and how many the whole text has, so a
--- caller can say what it left out.
---@param text string
---@param width integer
---@param limit integer
---@param measure fun(s: string): integer
---@param cut fun(s: string, cols: integer): string
---@return string[] lines
---@return integer total
function model.wrap(text, width, limit, measure, cut)
  width = math.max(1, width)
  -- A run's detail is a tail the host already capped, but the cost of a render
  -- must not depend on anyone keeping that promise.
  text = (text or ""):sub(1, 65536)
  local out, total = {}, 0
  for raw in (text .. "\n"):gmatch("(.-)\r?\n") do
    raw = raw:gsub("\t", "  ")
    repeat
      total = total + 1
      local piece = raw
      if measure(raw) > width then
        piece = cut(raw, width)
        if piece == "" then
          piece = raw:sub(1, 1)
        end
      end
      if #out < limit then
        out[#out + 1] = piece
      end
      raw = raw:sub(#piece + 1)
    until raw == ""
  end
  return out, total
end

return model
