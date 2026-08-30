-- poste-redis scaffold smoke spec — proves the harness (rtp, plenary, syntax)
-- loads. Real specs land with each work item.

describe("poste-redis scaffold", function()
  it("loads modules from the repo on rtp", function()
    assert.is_truthy(package.loaded["poste.state"] or pcall(require, "poste.state"))
  end)

  it("registers the poste_redis filetype detection script", function()
    local ftdetect = vim.fn.glob("ftdetect/poste_redis.vim")
    assert.truthy(ftdetect ~= "")
    local syntax = vim.fn.glob("syntax/poste_redis.vim")
    assert.truthy(syntax ~= "")
  end)
end)
