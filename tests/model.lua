-- The pure half: dates, schedules and labels, with no pane around them.
--
-- Run through `tests/run.sh`.

local REPO = assert(os.getenv("REPO"), "REPO=")
local h = dofile(REPO .. "/tests/harness.lua")
local model = require("thurbox-automations.lib.model")

local NOW = h.NOW

h.test("dates are UTC civil dates", function()
  h.eq(model.utc(0), "1970-01-01 00:00 UTC")
  h.eq(model.utc(NOW), "2026-01-05 12:00 UTC")
  h.eq(model.utc(951782400000), "2000-02-29 00:00 UTC", "a leap day")
end)

h.test("a UTC date reads back as the millis it came from", function()
  h.eq(model.parse_utc("2026-01-05 12:00"), NOW)
  h.eq(model.parse_utc("2000-02-29 00:00"), 951782400000)
  h.eq(model.parse_utc("2026-13-01 00:00"), nil)
  h.eq(model.parse_utc("tomorrow"), nil)
end)

h.test("relative times read the way the rest of the interface reads", function()
  h.eq(model.relative(NOW + 3 * 3600 * 1000, NOW), "in 3h")
  h.eq(model.relative(NOW + 90 * 1000, NOW), "in 1m")
  h.eq(model.relative(NOW - 5 * 60 * 1000, NOW), "5m ago")
  h.eq(model.relative(NOW - 3 * 86400 * 1000, NOW), "3d ago")
end)

h.test("common cron shapes are said in words, the rest verbatim", function()
  h.eq(model.describe_cron("0 9 * * 1-5"), "weekdays 09:00")
  h.eq(model.describe_cron("30 7 * * *"), "daily 07:30")
  h.eq(model.describe_cron("5 * * * *"), "hourly at :05")
  h.eq(model.describe_cron("0 18 * * 0"), "weekly Sun 18:00")
  h.eq(model.describe_cron("0 18 * * 7"), "weekly Sun 18:00")
  h.eq(model.describe_cron("*/15 * * * *"), "every 15m")
  h.eq(model.describe_cron("0 0 1 * *"), "cron 0 0 1 * *")
end)

h.test("a trigger the form accepts becomes one the host accepts", function()
  h.eq(model.trigger_for_host("at:2026-01-05 12:00"), "at:" .. NOW)
  h.eq(model.trigger_for_host("at:1767614400000"), "at:1767614400000")
  h.eq(model.trigger_for_host("  daily "), "daily")
  h.eq(model.trigger_for_host("cron:0 9 * * *"), "cron:0 9 * * *")
end)

h.test("a stored trigger is shown in the form's own spelling", function()
  h.eq(model.trigger_for_form("at:" .. NOW), "at:2026-01-05 12:00")
  h.eq(model.trigger_for_form("at:" .. (NOW + 1)), "at:" .. (NOW + 1), "not a whole minute")
  h.eq(model.trigger_for_form("cron:0 9 * * *"), "cron:0 9 * * *")
end)

h.test("weekdays by number or by name", function()
  h.eq(model.weekday("1"), 1)
  h.eq(model.weekday("sun"), 0)
  h.eq(model.weekday("Saturday"), 6)
  h.eq(model.weekday("8"), nil)
  h.eq(model.weekday("funday"), nil)
end)

h.finish()
