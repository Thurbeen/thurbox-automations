-- The plugin VM, as far as the pane can tell.
--
-- Loads the pane file the way the kernel does — one chunk returning one table —
-- against the interface's REAL `lib/` (from `$UI`, a thurbox checkout's `ui/`),
-- so measurement, the list window and the cursor behave exactly as they do on
-- screen. Only what the kernel injects is faked: `thurbox` (the snapshot),
-- `state` and `store` (copy-on-read, as in the VM), `command` (recorded, never
-- applied) and `text` (column arithmetic, `tests/text.lua`). `run` is never
-- defined: the pane asks for no capability, and a call to it would fail here
-- exactly as it would in the VM.
--
-- Keys are dispatched as the kernel dispatches them: a chord the pane DECLARED
-- goes to `on_action` first, and reaches `on_key` only when that declines.

local REPO = assert(os.getenv("REPO"), "REPO= the plugin checkout")
local UI = assert(os.getenv("UI"), "UI= a thurbox checkout's ui/ directory")

dofile(REPO .. "/tests/text.lua")

local harness = {}

-- ── state and store: a copy on every read ───────────────────────────────────

local function deep_copy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deep_copy(v)
  end
  return out
end

local function shared_table(backing)
  return setmetatable({}, {
    __index = function(_, key)
      return deep_copy(backing[key])
    end,
    __newindex = function(_, key, value)
      backing[key] = deep_copy(value)
    end,
  })
end

local state_backing, store_backing = {}, {}
_G.state = shared_table(state_backing)
_G.store = shared_table(store_backing)

-- ── command: recorded, in order ─────────────────────────────────────────────

local issued = {}
--- A host that predates the create/edit verbs refuses them as a Lua error,
--- which is what `command` does with a command it cannot parse.
local old_host = false
_G.command = function(kind, args)
  args = args or {}
  if
    old_host
    and kind == "automation"
    and (args.action == "create" or args.action == "edit")
    and args.number == nil
  then
    error('command "automation" needs an id')
  end
  issued[#issued + 1] = { kind = kind, args = deep_copy(args) }
end

--- Every command since the last call, and forget them.
function harness.commands()
  local out = issued
  issued = {}
  return out
end

--- Pretend to be a thurbox release without the automation create/edit verbs.
function harness.old_host(yes)
  old_host = yes
end

-- ── require: the interface's lib/, and this plugin's own modules ────────────

local real_require, loaded = require, {}
_G.require = function(name)
  if loaded[name] then
    return loaded[name]
  end
  local path
  if name:match("^thurbox%-automations%.") then
    path = REPO .. "/" .. name:gsub("^thurbox%-automations%.", ""):gsub("%.", "/") .. ".lua"
  elseif name:match("^lib%.") then
    path = UI .. "/" .. name:gsub("%.", "/") .. ".lua"
  else
    return real_require(name)
  end
  local value = assert(loadfile(path), "cannot load " .. path)()
  loaded[name] = value
  return value
end

-- ── the snapshot ────────────────────────────────────────────────────────────

local roles = setmetatable({}, {
  __index = function(_, name)
    return "#" .. string.format("%06x", #name * 111111 % 0xffffff)
  end,
})

local pane
local registry = { keys = {}, commands = {}, settings = {}, sections = {} }

--- Publish a snapshot. `opts` overrides any top-level field; `automations`
--- defaults to none, `taken_at_ms` to a fixed instant.
function harness.publish(opts)
  opts = opts or {}
  local snapshot = {
    automations = {},
    sessions = {},
    repos = {},
    agents = {},
    agent_default = "claude",
    settings = { features = { automations = true } },
    theme = { name = "test", roles = roles },
    registry = registry,
    commands = {},
    taken_at_ms = harness.NOW,
    focus = "automations",
    platform = { os = "linux", arch = "x86_64" },
    granted = {},
    runs = {},
  }
  for key, value in pairs(opts) do
    if value == harness.NIL then
      snapshot[key] = nil
    else
      snapshot[key] = value
    end
  end
  _G.thurbox = snapshot
end

--- A value `publish` reads as "leave this field out".
harness.NIL = setmetatable({}, {})

--- 2026-01-05 12:00:00 UTC, a Monday.
harness.NOW = 1767614400000

-- ── loading ────────────────────────────────────────────────────────────────

--- (Re)load the pane file, as a save or `F10` would. `state` survives, which
--- is what a reload keeps.
function harness.load()
  local chunk = assert(loadfile(REPO .. "/plugins/30_automations.lua"))
  for name in pairs(loaded) do
    if name:match("^thurbox%-automations%.") then
      loaded[name] = nil
    end
  end
  pane = chunk()
  registry.keys = {}
  for _, binding in ipairs(pane.keys or {}) do
    registry.keys[#registry.keys + 1] = {
      key = binding.key,
      action = binding.action,
      desc = binding.desc,
      plugin = pane.name,
    }
  end
  return pane
end

function harness.pane()
  return pane
end

--- Forget `state` and `store`, for a test that starts from nothing.
function harness.reset()
  for key in pairs(state_backing) do
    state_backing[key] = nil
  end
  for key in pairs(store_backing) do
    store_backing[key] = nil
  end
  issued = {}
  old_host = false
end

-- ── rendering ──────────────────────────────────────────────────────────────

--- Render and return the node. `render` must not write: a command issued from
--- it fails the test, because a pure pane cannot do that.
function harness.render(width, height, focused)
  local before = #issued
  local node = pane.render({
    width = width or 120,
    height = height or 30,
    focused = focused ~= false,
    elapsed = 0,
    frame = 1,
  })
  assert(#issued == before, "render issued a command")
  return node
end

local function spans_text(spans)
  if type(spans) == "string" then
    return spans
  end
  local out = {}
  for _, span in ipairs(spans or {}) do
    out[#out + 1] = type(span) == "table" and (span.text or "") or tostring(span)
  end
  return table.concat(out)
end

--- Every line of text in a node tree, in tree order: frame titles, text lines,
--- input values. Not a picture — `tests/e2e.sh` takes those — but enough to say
--- what the pane chose to show.
function harness.lines(node, out)
  out = out or {}
  if type(node) ~= "table" then
    return out
  end
  if node.frame and node.frame.title then
    out[#out + 1] = spans_text(node.frame.title)
  end
  if node.type == "input" then
    out[#out + 1] = (node.label or "") .. (node.value or "")
  end
  local text = node.text
  if type(text) == "string" then
    out[#out + 1] = text
  elseif type(text) == "table" then
    for _, line in ipairs(text) do
      out[#out + 1] = spans_text(line)
    end
  end
  for _, child in ipairs(node.children or {}) do
    harness.lines(child, out)
  end
  return out
end

--- The whole tree as one string, lines joined by newlines.
function harness.screen(width, height)
  return table.concat(harness.lines(harness.render(width, height)), "\n")
end

-- ── input ──────────────────────────────────────────────────────────────────

local NAMED = {
  enter = true,
  esc = true,
  tab = true,
  backtab = true,
  backspace = true,
  up = true,
  down = true,
  left = true,
  right = true,
  pageup = true,
  pagedown = true,
  home = true,
  ["end"] = true,
  space = true,
}

--- Press one key: `"j"`, `"enter"`, `"ctrl+u"`. A chord the pane declared is an
--- action first, as the kernel's registry makes it.
function harness.press(chord)
  for _, binding in ipairs(pane.keys or {}) do
    if binding.key == chord and pane.on_action and pane.on_action(binding.action) then
      return true
    end
  end
  local key = { key = chord, ctrl = false, alt = false, shift = false }
  local mod, rest = chord:match("^(%a+)%+(.+)$")
  if mod then
    key.key = rest
    key[mod] = true
    if utf8.len(rest) == 1 then
      key.char = rest
    end
  elseif chord == "space" then
    key.char = " "
  elseif not NAMED[chord] then
    -- `to_press`: the name is the lowercased character, the character itself
    -- is kept, and a capital is a shifted press.
    key.key = chord:lower()
    key.char = chord
    key.shift = chord ~= chord:lower()
  end
  return pane.on_key and pane.on_key(key) or false
end

--- Type text, one character at a time, as plain keys.
function harness.type(text)
  for _, code in utf8.codes(text) do
    local ch = utf8.char(code)
    if ch == " " then
      harness.press("space")
    else
      harness.press(ch)
    end
  end
end

--- Deliver an event the pane subscribed to.
function harness.event(name, payload)
  local subscribed = false
  for _, wanted in ipairs(pane.events or {}) do
    subscribed = subscribed or wanted == name
  end
  assert(subscribed, "the pane does not subscribe to " .. name)
  pane.on_event(name, payload)
end

function harness.action(name)
  return pane.on_action(name)
end

-- ── assertions ─────────────────────────────────────────────────────────────

local failures, passed, current = 0, 0, ""

function harness.test(name, body)
  current = name
  harness.reset()
  harness.publish()
  harness.load()
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
    io.write("ok   ", name, "\n")
  else
    failures = failures + 1
    io.write("FAIL ", name, "\n", tostring(err), "\n")
  end
end

function harness.contains(haystack, needle, why)
  if not string.find(haystack, needle, 1, true) then
    error(
      string.format("%sexpected to find %q in:\n%s", why and (why .. ": ") or "", needle, haystack),
      2
    )
  end
end

function harness.absent(haystack, needle, why)
  if string.find(haystack, needle, 1, true) then
    error(
      string.format("%sdid not expect %q in:\n%s", why and (why .. ": ") or "", needle, haystack),
      2
    )
  end
end

function harness.eq(actual, expected, why)
  if actual ~= expected then
    error(
      string.format(
        "%sexpected %s, got %s",
        why and (why .. ": ") or "",
        tostring(expected),
        tostring(actual)
      ),
      2
    )
  end
end

function harness.finish()
  io.write(string.format("\n%d passed, %d failed (%s)\n", passed, failures, current and "done"))
  os.exit(failures == 0 and 0 or 1)
end

return harness
