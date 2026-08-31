--- Highlight groups for poste-redis result panel and source buffers.
--- Links to existing treesitter/builtin groups; runs at setup and on
--- ColorScheme so user colorschemes don't clobber panel semantics.
local state = require("poste.state")

local M = {}

local function link_if_empty(name, target)
  local existing = vim.api.nvim_get_hl(0, { name = name })
  if vim.tbl_isempty(existing) then
    vim.api.nvim_set_hl(0, name, { link = target })
  end
end

function M.setup()
  -- Source buffer (regex fallback, M1): reuse builtin syntax groups.
  link_if_empty("PosteRedisComment", "Comment")
  link_if_empty("PosteRedisUse", "Keyword")
  link_if_empty("PosteRedisUseName", "Identifier")
  link_if_empty("PosteRedisContinuation", "Special")
  link_if_empty("PosteRedisString", "String")
  link_if_empty("PosteRedisNumber", "Number")
  link_if_empty("PosteRedisCommand", "Function")

  -- Result panel.
  link_if_empty("PosteRedisResultBorder", "FloatBorder")
  link_if_empty("PosteRedisResultSep", "NonText")
  link_if_empty("PosteRedisResultHeader", "Title")
  link_if_empty("PosteRedisResultMeta", "Comment")
  link_if_empty("PosteRedisResultError", "DiagnosticError")
  link_if_empty("PosteRedisResultWarning", "DiagnosticWarn")
  link_if_empty("PosteRedisResultOk", "DiagnosticOk")
  link_if_empty("PosteRedisResultNull", "Comment")
  link_if_empty("PosteRedisResultNumber", "Number")
  link_if_empty("PosteRedisResultString", "String")
  link_if_empty("PosteRedisResultKey", "Identifier")
  link_if_empty("PosteRedisResultScore", "Number")
  link_if_empty("PosteRedisResultRowNum", "LineNr")
  link_if_empty("PosteRedisResultTab", "Title")

  -- History sidebar.
  link_if_empty("PosteRedisHistorySuccess", "DiagnosticOk")
  link_if_empty("PosteRedisHistoryError", "DiagnosticError")

  state.apply_highlight_overrides({
    "PosteRedisComment", "PosteRedisUse", "PosteRedisUseName",
    "PosteRedisContinuation", "PosteRedisString", "PosteRedisNumber",
    "PosteRedisCommand",
    "PosteRedisResultBorder", "PosteRedisResultSep", "PosteRedisResultHeader",
    "PosteRedisResultMeta", "PosteRedisResultError", "PosteRedisResultWarning",
    "PosteRedisResultOk", "PosteRedisResultNull", "PosteRedisResultNumber",
    "PosteRedisResultString", "PosteRedisResultKey", "PosteRedisResultScore",
    "PosteRedisResultRowNum", "PosteRedisResultTab",
    "PosteRedisHistorySuccess", "PosteRedisHistoryError",
  })
end

return M
