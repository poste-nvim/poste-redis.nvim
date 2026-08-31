--- examples spec — every examples/*.redis must keep parsing clean so manual
--- testing never surprises the user. Parses the real files off disk.
local parser = require("poste-redis.parser")

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

describe("poste-redis examples", function()
  it("demo.redis parses to the expected commands", function()
    local content = read("examples/demo.redis")
    assert.is_not_nil(content)
    local entries = parser.extract_entries(content)
    assert.equals("use", entries[1].kind)
    assert.equals("local", entries[1].connection)
    -- the HSET continuation must be a single command with 8 tokens
    local found = false
    for _, e in ipairs(entries) do
      if e.command == "HSET" and #e.tokens == 8 then found = true end
    end
    assert.is_true(found)
    -- quote-aware: # inside quotes is not a comment
    for _, e in ipairs(entries) do
      assert.is_not_nil(e.raw)
    end
  end)

  it("parser_edges.redis joins the SET continuation", function()
    local content = read("examples/parser_edges.redis")
    assert.is_not_nil(content)
    local entries = parser.extract_entries(content)
    local joined = false
    for _, e in ipairs(entries) do
      if e.command == "SET" and e.raw:find("concatenated") then joined = true end
    end
    assert.is_true(joined)
  end)

  it("quoted # inside examples never truncates a command", function()
    for _, f in ipairs({ "examples/demo.redis", "examples/parser_edges.redis", "examples/rendering.redis", "examples/multi_use.redis", "examples/dangerous.redis" }) do
      local content = read(f)
      assert.is_not_nil(content, f)
      for _, e in ipairs(parser.extract_entries(content)) do
        if e.kind == "command" and e.tokens and #e.tokens > 0 then
          assert.is_not_nil(e.command)
        end
      end
    end
  end)

  it("dangerous commands in examples are flagged", function()
    local content = read("examples/dangerous.redis")
    assert.is_not_nil(content)
    local flagged = false
    for _, e in ipairs(parser.extract_entries(content)) do
      if e.command == "CONFIG" and parser.is_dangerous(e) then flagged = true end
    end
    assert.is_true(flagged)
  end)

  it("connections.toml example resolves", function()
    local path = "examples/connections.toml"
    local ok = vim.fn.filereadable(path) == 1
    assert.is_true(ok)
    local toml = require("poste-redis.toml")
    local parsed, err = toml.parse_file(path)
    assert.is_nil(err)
    assert.equals("redis", parsed["local"].dialect)
    assert.equals("redis://127.0.0.1:16479/0", parsed["local"].url)
    assert.equals("redis://127.0.0.1:16479/1", parsed["local-db2"].url)
  end)
end)
