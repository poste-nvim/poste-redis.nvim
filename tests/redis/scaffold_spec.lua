-- poste-redis scaffold smoke spec — proves the harness (rtp, plenary, syntax)
-- loads. Real specs land with each work item.

describe("poste-redis scaffold", function()
  it("loads modules from the repo on rtp", function()
    assert.is_truthy(package.loaded["poste-redis.state"] or pcall(require, "poste-redis.state"))
  end)

  it("registers the poste_redis filetype detection script", function()
    local ftdetect = vim.fn.glob("ftdetect/poste_redis.vim")
    assert.truthy(ftdetect ~= "")
    local syntax = vim.fn.glob("syntax/poste_redis.vim")
    assert.truthy(syntax ~= "")
  end)

  it("overrides Neovim's builtin conf filetype for .redis files", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "/tmp/poste-redis-sample.redis")
    vim.api.nvim_set_current_buf(buf)

    vim.cmd("filetype detect")

    assert.equals("poste_redis", vim.bo[buf].filetype)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
