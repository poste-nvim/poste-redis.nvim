--- value viewer spec — per-type page commands + progressive pagination.
--- The session transport is stubbed in-process; no real redis.
local value = require("poste-redis.browser.value")
local buffer = require("poste-redis.buffer")
local session_conn = require("poste-redis.session_conn")

describe("poste-redis value viewer", function()
  local orig_execute

  before_each(function()
    orig_execute = session_conn.execute
  end)

  after_each(function()
    session_conn.execute = orig_execute
    buffer.close()
  end)

  local function make_node(key, typ)
    return {
      node_type = "key",
      meta = { key = key, url = "redis://stub:6379/0", connection = "stub", db = 0, type = typ },
    }
  end

  it("page_command builds per-type fetch commands", function()
    assert.same({ "HSCAN", "h", "0", "COUNT", "500" }, value._test.page_command("h", "hash", 0))
    assert.same({ "SSCAN", "s", "7", "COUNT", "500" }, value._test.page_command("s", "set", "7"))
    assert.same({ "LRANGE", "l", "500", "999" }, value._test.page_command("l", "list", "500"))
    assert.same({ "XRANGE", "st", "0", "+", "COUNT", "500" },
      value._test.page_command("st", "stream", "0"))
    assert.same({ "GET", "str" }, value._test.page_command("str", "string", nil))
  end)

  it("a multi-page hash advances past page 1 (done from the UPDATED cursor)", function()
    -- Regression: done was judged from the pre-update cursor, which is "0"
    -- on the very first call, so page 2 could never be fetched even though
    -- the page footer advertised "<Tab> next page"
    local pages_served = 0
    session_conn.execute = function(_url, _cmd, cbs)
      pages_served = pages_served + 1
      if pages_served == 1 then
        cbs.on_response({ value = { type = "map", entries = { { "a", "1" } },
          len = 2, cursor = "99" } })
      else
        cbs.on_response({ value = { type = "map", entries = { { "b", "2" } },
          len = 2, cursor = "0" } })
      end
      return "dispatched"
    end

    value.view(make_node("h", "hash"), nil, nil)
    assert.equals(1, #buffer._tabs(), "page 1 only before the switch")
    buffer.next_tab()  -- lands on the last (only) page: fetches page 2
    assert.equals(2, pages_served, "the next page must be fetched")
    assert.equals(2, #buffer._tabs())
    -- the viewer followed onto the newest page instead of snapping to page 1
    assert.equals(buffer._tabs()[2], buffer.active_tab())
  end)

  it("an exhausted cursor never fetches again", function()
    session_conn.execute = function(_url, _cmd, cbs)
      cbs.on_response({ value = { type = "map", entries = { { "a", "1" } },
        len = 1, cursor = "0" } })
      return "dispatched"
    end
    value.view(make_node("h", "hash"), nil, nil)
    buffer.next_tab()
    assert.equals(1, #buffer._tabs())
  end)
end)
