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

  vim.fn.system({ "curl", "-sfL", url, "-o", tmp })
  if vim.v.shell_error ~= 0 then
    -- checksum file unavailable — skip verification
    pcall(os.remove, tmp)
    return true
  end

  local f = io.open(tmp, "r")
  if not f then return true end
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
  return actual == expected
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

  vim.fn.system({ "curl", "-fL", url, "-o", tmp_archive })
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
      "Expand-Archive", "-Force",
      "-Path", tmp_archive,
      "-DestinationPath", BIN_DIR
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
        "Get-ChildItem -Recurse -Filter poste.exe " ..
        "-Path " .. BIN_DIR .. " | Move-Item -Destination " .. BIN_DIR .. "/poste.exe -Force"
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
--- Checks (in order): vim.g.poste_binary, user config, local dev build,
--- default data path, then attempted download.
function M.ensure()
  -- 0. Global override (same first-class source as state.find_poste_binary):
  --    a user pointing vim.g.poste_binary at a worktree/dev build must not
  --    trigger a release download at startup.
  local g = vim.g.poste_binary
  if g and g ~= "" and vim.fn.filereadable(g) == 1 then
    return vim.fn.fnamemodify(g, ":p")
  end

  -- 1. User-configured path (state.config.poste_binary).
  local state = require("poste-redis.state")
  if state.config.poste_binary ~= "" then
    local p = state.config.poste_binary
    if vim.fn.filereadable(p) == 1 then
      return vim.fn.fnamemodify(p, ":p")
    end
  end

  -- 2. Local dev build relative to plugin install dir (works when poste is added
  --    to rtp from a repo checkout, regardless of Neovim's CWD)
  local src = debug.getinfo(1, "S").source
  local plugin_root = src:sub(1, 1) == "@" and src:sub(2):match("^(.+/)lua/poste%-redis/")
  if plugin_root then
    for _, p in ipairs({
      plugin_root .. "target/debug/poste",
      plugin_root .. "target/release/poste",
    }) do
      if vim.fn.filereadable(p) == 1 then
        return vim.fn.fnamemodify(p, ":p")
      end
    end
  end

  -- 3. CWD-relative local dev build (in-repo development from poste dir)
  for _, path in ipairs({ "./target/debug/poste", "./target/release/poste" }) do
    if vim.fn.filereadable(path) == 1 then
      return vim.fn.fnamemodify(path, ":p")
    end
  end

  -- 4. Default installed path (stdpath data)
  local bp = binary_path()
  if vim.fn.filereadable(bp) == 1 then
    return bp
  end

  -- 5. Fallback: attempt download
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
