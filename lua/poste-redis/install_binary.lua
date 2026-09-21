--- Poste CLI binary installer.
--- Downloads prebuilt binary from GitHub Releases to stdpath("data")/poste/bin/.
--- Vendored from poste.nvim@5b3759e lua/poste/install.lua (family
--- dissolution) and trimmed: plugin_tag / schedule_version_sync /
--- installed_version / update are dropped — the git-tag version sync
--- matched the binary against the *plugin checkout's* tag, which is
--- meaningless in a sibling repo. Lives under install_binary.lua because
--- this repo's install.lua (tree-sitter parser compiler) predates it.
--- REPO stays beyondlex/poste.nvim: one binary for the whole family.
local M = {}

local REPO = "beyondlex/poste.nvim"
local BASE = vim.fn.stdpath("data") .. "/poste"
local BIN_DIR = BASE .. "/bin"
local VERSION_FILE = BASE .. "/.version"

--- Detect platform string matching release asset names.
local function detect_platform()
  local uname = vim.loop.os_uname()
  local sys = uname.sysname
  local machine = uname.machine
  if sys == "Linux" and machine == "x86_64" then return "x86_64-linux" end
  if sys == "Linux" and machine == "aarch64" then return "aarch64-linux" end
  if sys == "Darwin" and machine == "x86_64" then return "x86_64-macos" end
  if sys == "Darwin" and machine == "arm64" then return "aarch64-macos" end
  if sys:find("Windows") and machine == "x86_64" then return "x86_64-windows" end
  return nil
end

--- Full path to the binary (including .exe suffix on Windows).
local function binary_path()
  local plat = detect_platform()
  if plat and plat:find("windows") then
    return BIN_DIR .. "/poste.exe"
  end
  return BIN_DIR .. "/poste"
end

--- Render a path as a PowerShell string literal.
--- `vim.fn.system` in list form still hands everything after `-Command` to
--- PowerShell as a *command line*, so a `stdpath("data")` containing a space
--- (`C:\Users\Jane Smith\…`) split into two arguments there and the extract
--- step failed. Single quotes suppress `$`/backtick expansion; the only
--- escape inside them is '' for a literal '.
--- @param path string
--- @return string the path as a PowerShell single-quoted literal
function M.ps_literal(path)
  return "'" .. (path:gsub("'", "''")) .. "'"
end

--- Build the curl argv for one release download. Same rule as poste-db's copy.
--- Both downloads happen inside `ensure()`, which `setup()` calls, so each one
--- blocks Neovim's startup. Without an explicit ceiling a blackholed
--- connection — a captive portal, or a firewall that answers the SYN and drops
--- the rest — leaves the editor frozen until the OS socket timeout expires,
--- which is minutes and looks like a hung plugin load rather than a failed
--- download.
--- @param flags string curl's short flags, "-fL" or the silent "-sfL"
--- @param url string
--- @param out string path to write the body to
--- @param max_time integer seconds
--- @return string[] argv for `vim.fn.system` (list form, so no shell)
function M.curl_argv(flags, url, out, max_time)
  return {
    "curl", flags,
    "--connect-timeout", "10",
    "--max-time", tostring(max_time),
    url, "-o", out,
  }
end

--- Compare the downloaded archive's digest with the release's. Same rule as
--- poste-db's copy: hex SHA-256 is case-insensitive but the tools are not —
--- `sha256sum`/`shasum` print lowercase (what the release asset holds) while
--- `certutil -hashfile` prints uppercase, so an exact compare would call a good
--- download corrupted on the one Windows box that has no other hasher, and
--- delete it.
--- @param actual string digest computed from the downloaded file
--- @param expected string digest from the release asset
--- @return boolean
function M.checksum_matches(actual, expected)
  return actual:lower() == expected:lower()
end

--- Archive extension for the platform.
local function archive_ext(platform)
  if platform:find("windows") then return ".zip" end
  return ".tar.gz"
end

--- Download URL for a release asset.
--- @param platform string  e.g. "x86_64-linux"
--- @param version string   e.g. "latest" or "v0.1.0"
function M.download_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform)
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Checksum URL for a release asset.
function M.checksum_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform) .. ".sha256"
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, version, arch)
end

--- Verify SHA256 checksum of downloaded archive against release asset.
--- Returns true if checksum matches or verification is unavailable.
local function verify_checksum(archive_path, platform, version)
  local url = M.checksum_url(platform, version)
  local tmp = BIN_DIR .. "/checksum.tmp"

  vim.fn.system(M.curl_argv("-sfL", url, tmp, 20))
  if vim.v.shell_error ~= 0 then
    -- checksum file unavailable — skip verification
    pcall(os.remove, tmp)
    return true
  end

  local f = io.open(tmp, "r")
  if not f then
    pcall(os.remove, tmp)
    return true
  end
  local expected = f:read("*a"):match("^(%S+)")
  f:close()
  pcall(os.remove, tmp)

  if not expected then return true end

  -- hasher availability varies by platform (no sha256sum/shasum on Windows):
  -- without any hasher, skip verification like a missing checksum file
  -- rather than comparing garbage and rejecting a good download
  local actual
  if vim.fn.executable("sha256sum") == 1 then
    actual = vim.fn.system({ "sha256sum", archive_path }):match("^(%S+)")
  elseif vim.fn.executable("shasum") == 1 then
    actual = vim.fn.system({ "shasum", "-a", "256", archive_path }):match("^(%S+)")
  elseif vim.fn.executable("certutil") == 1 then
    -- certutil prints the 64-hex-char digest on its own line between banners
    local out = vim.fn.system({ "certutil", "-hashfile", archive_path, "SHA256" })
    for run in tostring(out):gmatch("%x+") do
      if #run == 64 then actual = run break end
    end
  end

  if not actual then
    vim.notify("[Poste] No SHA256 tool found — skipped checksum verification", vim.log.levels.WARN)
    return true
  end
  return M.checksum_matches(actual, expected)
end

--- Download and install the poste binary.
--- @param version string  tag or "latest" (default)
--- @return boolean        success
function M.download(version)
  version = version or "latest"
  local platform = detect_platform()
  if not platform then
    vim.notify(
      "[Poste] Unsupported platform: " .. vim.inspect(vim.loop.os_uname()),
      vim.log.levels.ERROR
    )
    return false
  end

  vim.fn.mkdir(BIN_DIR, "p")

  local url = M.download_url(platform, version)
  local ext = archive_ext(platform)
  local tmp_archive = BIN_DIR .. "/download" .. ext

  vim.notify("[Poste] Downloading " .. url, vim.log.levels.INFO)

  vim.fn.system(M.curl_argv("-fL", url, tmp_archive, 180))
  if vim.v.shell_error ~= 0 then
    vim.notify("[Poste] Download failed (exit " .. vim.v.shell_error .. ")", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    return false
  end

  if not verify_checksum(tmp_archive, platform, version) then
    vim.notify("[Poste] Checksum mismatch — download corrupted", vim.log.levels.ERROR)
    pcall(os.remove, tmp_archive)
    return false
  end

  if ext == ".zip" then
    vim.fn.system({ "powershell", "-Command",
      "Expand-Archive -Force -Path " .. M.ps_literal(tmp_archive)
      .. " -DestinationPath " .. M.ps_literal(BIN_DIR)
    })
  else
    vim.fn.system({ "tar", "xzf", tmp_archive, "-C", BIN_DIR })
  end

  pcall(os.remove, tmp_archive)

  if platform:find("windows") then
    local final_path = BIN_DIR .. "/poste.exe"
    -- tar/zip may create a subdirectory; flatten if needed
    if vim.fn.filereadable(final_path) ~= 1 then
      vim.fn.system({ "powershell", "-Command",
        "Get-ChildItem -Recurse -Filter poste.exe -Path " .. M.ps_literal(BIN_DIR)
        .. " | Move-Item -Destination " .. M.ps_literal(final_path) .. " -Force"
      })
    end
  else
    vim.fn.system({ "chmod", "+x", BIN_DIR .. "/poste" })
  end

  -- extraction was never checked: a corrupt archive / full disk used to fall
  -- through, stamp the .version file and report success with no binary present
  local extracted = BIN_DIR .. (platform:find("windows") and "/poste.exe" or "/poste")
  if vim.fn.filereadable(extracted) ~= 1 then
    vim.notify("[Poste] Extraction failed — binary missing from archive", vim.log.levels.ERROR)
    return false
  end

  local version_tag = version
  if not version_tag:match("^v") and version_tag ~= "latest" then
    version_tag = "v" .. version_tag
  end
  local f = io.open(VERSION_FILE, "w")
  if f then
    f:write(version_tag .. "\n")
    f:close()
  end

  vim.notify("[Poste] Installed " .. version_tag .. " (" .. platform .. ")", vim.log.levels.INFO)
  return true
end

--- Ensure the binary is available.
--- Called at plugin startup. Returns the binary path if found, nil otherwise.
--- The search belongs to `state.find_poste_binary()`: one rule, one copy. This
--- function's own copy of it had drifted (no runnability test, no
--- `$POSTE_BINARY`, no `$PATH`), so a readable-but-not-executable override was
--- returned and the download that would have replaced it skipped, while a
--- `poste` on `$PATH` — a documented install route — still triggered a release
--- download that then outranked the user's own build. All that is left here is
--- the one thing a lookup cannot do: fetch a binary when none is usable.
function M.ensure()
  local found = require("poste-redis.state").find_poste_binary()
  if found then return found end

  -- Fallback: attempt download
  local ok = M.download("latest")
  if not ok then
    vim.notify(
      "[Poste] Binary not found and download failed. "
        .. "Set `vim.g.poste_binary = \"/path/to/poste\"` in your config.",
      vim.log.levels.WARN
    )
    return nil
  end
  return binary_path()
end

return M
