--- util spec — the shared helpers every module leans on: URL redaction,
--- credential-free host labels, winbar %-escaping, display-width truncation
--- and padding, clipboard formatting.
local util = require("poste-redis.util")

describe("poste-redis util", function()
  describe("redact_url", function()
    it("strips userinfo from redis URLs", function()
      assert.equals("redis://***@host:6379/0", util.redact_url("redis://user:pass@host:6379/0"))
      assert.equals("redis://***@host:6379/0", util.redact_url("redis://:pass@host:6379/0"))
    end)

    it("keeps URLs without userinfo intact", function()
      assert.equals("redis://host:6379/0", util.redact_url("redis://host:6379/0"))
    end)

    it("keeps the host AND path, handles non-strings and TLS", function()
      assert.equals("rediss://***@h/0", util.redact_url("rediss://u:p@h/0"))
      assert.equals(nil, util.redact_url(nil))
      -- a URL without userinfo passes through byte-for-byte (gsub no-op)
      assert.equals("redis://host:6379/db", util.redact_url("redis://host:6379/db"))
    end)
  end)

  describe("host_label", function()
    it("extracts the credential-free host from a redis URL", function()
      assert.equals("host:6379", util.host_label("redis://user:pass@host:6379/2"))
      assert.equals("host", util.host_label("rediss://host"))
      assert.equals("h:1", util.host_label("redis://h:1/0"))
    end)

    it("passes plain connection names through", function()
      assert.equals("local-db", util.host_label("local-db"))
    end)
  end)

  describe("escape_winbar", function()
    it("doubles % so %-encoding passes text through", function()
      assert.equals("GET 100%%", util.escape_winbar("GET 100%"))
      assert.equals("plain", util.escape_winbar("plain"))
    end)

    it("returns exactly one value (gsub's count must not leak)", function()
      local n = select("#", util.escape_winbar("a%b"))
      assert.equals(1, n)
    end)
  end)

  describe("truncate_display / pad_right", function()
    it("keeps short strings verbatim", function()
      assert.equals("abc", util.truncate_display("abc", 5))
      assert.equals("abc", util.truncate_display("abc", 3))
    end)

    it("truncates to the width with an ellipsis, never splitting UTF-8", function()
      local out = util.truncate_display("abcdef", 4)
      assert.equals(4, vim.fn.strdisplaywidth(out))
      assert.equals("…", out:sub(-3))
      local cjk = util.truncate_display("你好世界", 5)
      -- 2 glyphs (4 cells) + the 1-cell ellipsis: never half a glyph
      assert.equals(5, vim.fn.strdisplaywidth(cjk))
      assert.equals("你好…", cjk)
    end)

    it("pad_right pads by display width and never truncates", function()
      assert.equals("ab  ", util.pad_right("ab", 4))
      assert.equals("abc", util.pad_right("abc", 2))
    end)
  end)

  describe("to_clipboard", function()
    it("formats scalars for the clipboard", function()
      assert.equals("", util.to_clipboard(nil))
      assert.equals("true", util.to_clipboard(true))
      assert.equals("7", util.to_clipboard(7))
      assert.equals("s", util.to_clipboard("s"))
    end)

    it("encodes tables as compact JSON", function()
      assert.equals('{"a":1}', util.to_clipboard({ a = 1 }))
    end)

    it("keeps every digit of an exact large integer", function()
      -- 1e15 used to be the bound, so a microsecond timestamp — an exact
      -- double, and one of the commonest integers in redis — was yanked as
      -- "1.75e+15" instead of the 16 digits it actually holds
      assert.equals("1750000000000000", util.to_clipboard(1750000000000000))
      assert.equals("9007199254740991", util.to_clipboard(2^53 - 1))
    end)

    it("falls back to scientific form past the exact-integer range", function()
      -- beyond 2^53 the decode already rounded the value; printing full
      -- digits would advertise precision the number does not have
      assert.equals("1e+16", util.to_clipboard(1e16))
    end)
  end)

  describe("format_latency", function()
    it("renders ms below a second, seconds above", function()
      assert.equals("250 ms", util.format_latency(250))
      assert.equals("1.50 s", util.format_latency(1500))
      assert.equals("", util.format_latency(nil))
    end)
  end)

  describe("glob_escape", function()
    it("escapes redis glob metacharacters, leaves plain names alone", function()
      assert.equals("a\\*b", util.glob_escape("a*b"))
      assert.equals("a\\?b", util.glob_escape("a?b"))
      assert.equals("a\\[b\\]", util.glob_escape("a[b]"))
      assert.equals("a\\\\b", util.glob_escape("a\\b"))
      assert.equals("user:1", util.glob_escape("user:1"))
      assert.is_nil(util.glob_escape(nil))
    end)
  end)

  describe("is_hex_display", function()
    it("recognises the name marker the binary uses for non-UTF-8 names", function()
      -- redis_executor.rs key_display: `format!("hex:{}", hex_preview(b, 16))`
      assert.is_true(util.is_hex_display("hex:ff fe"))
      assert.is_true(util.is_hex_display("hex:c3 28"))
      -- one byte, and the 16-pair cap
      assert.is_true(util.is_hex_display("hex:0a"))
      assert.is_true(util.is_hex_display(
        "hex:00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f"))
    end)

    it("recognises the value marker, preview capped at 64 pairs", function()
      -- redis_executor.rs child_cell: `(binary) {bytes} bytes hex: {preview}`
      assert.is_true(util.is_hex_display("(binary) 4 bytes hex: 48 65 ff 00"))
      assert.is_true(util.is_hex_display("(binary) 900 bytes hex: " .. string.rep("ff ", 63) .. "ff"))
    end)

    it("does not match text that merely starts with the marker", function()
      -- the guard is a refusal, so a false positive costs an editable row; the
      -- patterns must stay as narrow as the marker really is
      assert.is_false(util.is_hex_display("hex:zz"))
      assert.is_false(util.is_hex_display("hex:ffz"))
      assert.is_false(util.is_hex_display("hex:ff  fe"))
      assert.is_false(util.is_hex_display("0xhex:ff"))
      assert.is_false(util.is_hex_display("(binary) 4 bytes"))
      assert.is_false(util.is_hex_display("hash:ff fe"))
      assert.is_false(util.is_hex_display(""))
      assert.is_false(util.is_hex_display(nil))
      assert.is_false(util.is_hex_display(7))
      assert.is_false(util.is_hex_display({ "hex:ff fe" }))
    end)
  end)

  describe("render_command", function()
    it("joins clean tokens verbatim", function()
      assert.equals("DEL user:1", util.render_command({ "DEL", "user:1" }))
      assert.equals("DEL user:*", util.render_command({ "DEL", "user:*" }))
    end)

    it("quotes tokens containing whitespace so the line reads back as one arg", function()
      assert.equals('DEL "a b"', util.render_command({ "DEL", "a b" }))
      assert.equals('SET k "v 1"', util.render_command({ "SET", "k", "v 1" }))
    end)

    it("escapes embedded quotes and backslashes inside quoted tokens", function()
      assert.equals('SET k "a\\"b"', util.render_command({ "SET", "k", 'a"b' }))
      assert.equals('SET k "a\\\\b"', util.render_command({ "SET", "k", "a\\b" }))
    end)

    it("quotes empty tokens so they stay one arg", function()
      assert.equals('HSET k f ""', util.render_command({ "HSET", "k", "f", "" }))
    end)

    it("escapes control characters inside quoted tokens (one buffer line)", function()
      -- a binary-safe key decodes to a real newline; nvim_buf_set_lines
      -- rejects lines with embedded newlines, so the quoted form escapes it
      assert.equals('DEL "a\\nb"', util.render_command({ "DEL", "a\nb" }))
      assert.equals('DEL "a\\rb"', util.render_command({ "DEL", "a\rb" }))
      assert.equals('DEL "a\\tb"', util.render_command({ "DEL", "a\tb" }))
      assert.equals('DEL "a\\x00b"', util.render_command({ "DEL", "a\0b" }))
      -- the escaped form round-trips through the parser's unquote
      local parser = require("poste-redis.parser")
      local tokens = parser.command_tokens(util.render_command({ "DEL", "a\nb" }))
      assert.equals("a\nb", tokens[2])
    end)

    it("a literal backslash-n is not re-escaped into a newline", function()
      -- token chars: a, \, n, b — the backslash doubles FIRST, so the later
      -- control pass cannot mistake the produced `\n` pair for input
      assert.equals('DEL "a\\\\nb"', util.render_command({ "DEL", "a\\nb" }))
    end)
  end)

  describe("append_new", function()
    it("keeps the first occurrence and marks it seen", function()
      local dst, seen = {}, {}
      util.append_new(dst, seen, { "a:b", "a:c" })
      util.append_new(dst, seen, { "a:b", "a:d" })  -- a:b repeated on page 2
      assert.same({ "a:b", "a:c", "a:d" }, dst)
      assert.is_true(seen["a:b"])
    end)

    it("drops non-string entries and tolerates a missing page", function()
      local dst, seen = {}, {}
      util.append_new(dst, seen, { "ok", { "nested" }, 7, vim.NIL })
      util.append_new(dst, seen, nil)
      assert.same({ "ok" }, dst)
    end)
  end)

  describe("escape_for_line", function()
    it("replaces line breaks and tabs", function()
      assert.equals("a⏎b", util.escape_for_line("a\r\nb"))
      assert.equals("a⏎b", util.escape_for_line("a\nb"))
      assert.equals("a  b", util.escape_for_line("a\tb"))
    end)

    it("maps a NUL byte to a visible escape", function()
      -- a \x00-escaped key decodes to a real NUL; Neovim coerces a NUL in a
      -- buffer line to a newline, so the escape keeps the row in one piece
      assert.equals("a\\0b", util.escape_for_line("a\0b"))
    end)

    it("returns only the string, never gsub's count", function()
      -- format.lua builds text lines as `{ cell(v) }`; a second return value
      -- here would land in the list as a phantom line (and nvim_buf_set_lines
      -- rejects a number where it expects a string)
      assert.equals(1, select("#", util.escape_for_line("a\nb")))
      assert.equals(1, select("#", util.escape_for_line("plain")))
      assert.equals(1, select("#", util.escape_for_line(42)))
    end)
  end)
end)
