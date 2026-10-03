--- grid_edit truncation guards — writes that would put a display-capped
--- PREFIX back as the whole value are refused. The binary caps every string
--- reply at --max-bytes and (since the matching executor change) flags those
--- rows per item: item_truncated for list/set cells, value_truncated for hash
--- values. The pure-function guards are driven here through hand-built tabs;
--- no real redis, no transport.
local grid_edit = require("poste-redis.browser.grid_edit")
local session_conn = require("poste-redis.session_conn")

describe("poste-redis grid_edit truncation guards", function()
  local notified
  local writes
  local orig_notify
  local orig_execute
  local orig_input

  before_each(function()
    notified = {}
    writes = {}
    orig_notify = vim.notify
    orig_execute = session_conn.execute
    orig_input = vim.ui.input
    vim.notify = function(msg, level, _opts)
      notified[#notified + 1] = { msg = msg, level = level }
    end
    session_conn.execute = function(_url, cmd, cbs)
      writes[#writes + 1] = cmd
      if cbs.on_response then
        -- the verified list write probes LINDEX first and proceeds only when
        -- the reply still equals the rendered cell
        if cmd[1] == "LINDEX" then
          cbs.on_response({ value = { type = "string", value = "short" } })
        else
          cbs.on_response({ value = { type = "string", value = "OK" } })
        end
      end
      return "dispatched"
    end
  end)

  after_each(function()
    vim.notify = orig_notify
    vim.ui.input = orig_input
    session_conn.execute = orig_execute
  end)

  --- A hand-built tab bound to a key, cursor on a content cell of `row`.
  --- meta.connection is a URL (connections.resolve passes URLs through) so
  --- the spec needs no connections.toml on disk.
  local function make_tab(type_name, value, row)
    return {
      kind = "table",
      meta = { connection = "redis://stub:6379/0", key = "k", value = value, db = 0 },
      page = 1,
      page_size = 50,
      cursor = { row = row, col = 2 },
      grid = {
        rows = {
          { 1, "short", "1" },
          { 2, "short", "2" },
        },
      },
      pmeta = { row_count = 2, col_count = 3 },
    }
  end

  it("refuses editing a list row whose element was capped", function()
    -- LSET with the cell text would store the prefix as the whole value; the
    -- LINDEX verification passes (probe and cell are capped identically), so
    -- the per-item flag is the only signal.
    local tab = make_tab("list",
      { type = "list", value = { "a", "b" }, item_truncated = { false, true } }, 2)
    vim.ui.input = function(_opts, cb) cb("typed text") end
    grid_edit.edit_cell(tab)
    assert.equals(0, #writes, "no write may reach the transport")
    assert.equals(1, #notified)
    assert.matches("display cap", notified[1].msg)
  end)

  it("edits a list row that was not capped", function()
    local tab = make_tab("list",
      { type = "list", value = { "a", "b" }, item_truncated = { false, false } }, 2)
    vim.ui.input = function(_opts, cb) cb("typed") end
    grid_edit.edit_cell(tab)
    assert.equals(2, #writes, "LINDEX probe, then the verified LSET")
    assert.equals("LINDEX", writes[1][1])
    assert.equals("LSET", writes[2][1])
  end)

  it("refuses editing a hash row whose VALUE was capped (value and rename)", function()
    -- the value column edit stores the prefix; the field RENAME stores the
    -- same capped cell in the NEW field and deletes the full one — both are
    -- the row, so both refuse
    local tab = make_tab("hash",
      { type = "hash", entries = { { "f", "v" } }, value_truncated = { true } }, 1)
    tab.grid.rows[1] = { 1, "f", "old value" }
    vim.ui.input = function(_opts, cb) cb("new-name") end
    grid_edit.edit_cell(tab)
    assert.equals(0, #writes, "the rename must not run")
    assert.matches("display cap", notified[1].msg)
  end)

  it("edits a hash row whose value was not capped", function()
    local tab = make_tab("hash",
      { type = "hash", entries = { { "f", "v" } }, value_truncated = { false } }, 1)
    tab.grid.rows[1] = { 1, "f", "old value" }
    vim.ui.input = function(_opts, cb) cb("new-name") end
    grid_edit.edit_cell(tab)
    assert.equals(3, #writes, "HEXISTS guard probe, HSET new, HDEL old")
    assert.equals("HEXISTS", writes[1][1])
    assert.equals("HSET", writes[2][1])
    assert.equals("HDEL", writes[3][1])
  end)

  it("refuses deleting a set row whose member was capped", function()
    -- SREM <raw> with the prefix matches nothing: the server answers 0 and
    -- the refresh leaves the row, an OK-flavored no-op
    local tab = make_tab("set",
      { type = "set", value = { "m" }, item_truncated = { true } }, 1)
    tab.grid.rows[1] = { 1, "m" }
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function() return 1 end
    grid_edit.delete_row(tab)
    vim.fn.confirm = orig_confirm
    assert.equals(0, #writes, "SREM must not run")
    assert.matches("not the member", notified[1].msg)
  end)

  it("deleting a capped LIST row still runs (index-addressed, deletes whole)", function()
    local tab = make_tab("list",
      { type = "list", value = { "short" }, item_truncated = { true } }, 1)
    tab.grid.rows[1] = { 1, "short" }
    local orig_confirm = vim.fn.confirm
    vim.fn.confirm = function() return 1 end
    grid_edit.delete_row(tab)
    vim.fn.confirm = orig_confirm
    assert.equals(3, #writes, "LINDEX probe, LSET sentinel, LREM")
    assert.equals("LINDEX", writes[1][1])
    assert.equals("LSET", writes[2][1])
    assert.equals("LREM", writes[3][1])
  end)

  it("a RESP3 map tab edits as the hash it is (add_row must not SET over it)", function()
    -- value.type "map" is the RESP3 spelling of a hash. Left unrecognized it
    -- fell through add_row's verb fallback to `SET key <v> KEEPTTL`, replacing
    -- the whole collection with a string; the edit branches refused it as an
    -- unsupported type. Normalized to hash, HSET runs.
    local tab = make_tab("map",
      { type = "map", entries = { { "f", "v" } }, len = 1 }, 1)
    tab.grid.rows[1] = { 1, "f", "old" }
    vim.ui.input = function(_opts, cb) cb("new-name") end
    grid_edit.edit_cell(tab)
    -- the cursor sits on the field column, so this is the rename: the hash
    -- guard probe + HSET new + HDEL old — the hash path, not a refusal and
    -- not a SET
    assert.equals(3, #writes)
    assert.equals("HEXISTS", writes[1][1])
    assert.equals("HSET", writes[2][1])
    assert.equals("HDEL", writes[3][1])

    local add_tab = make_tab("map",
      { type = "map", entries = { { "f", "v" } }, len = 1 }, 1)
    add_tab.grid.rows[1] = { 1, "f", "old" }
    vim.ui.input = function(opts, cb)
      if opts.prompt:find("New field") then cb("g") else cb("1") end
    end
    grid_edit.add_row(add_tab)
    assert.truthy(#writes >= 1)
    assert.equals("HEXISTS", writes[1][1], "the add probes the guard, never SET")
  end)
end)
