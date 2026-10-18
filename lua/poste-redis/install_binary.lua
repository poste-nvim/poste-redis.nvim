--- Poste CLI binary installer.
--- Downloads prebuilt binary from GitHub Releases to stdpath("data")/poste/bin/.
--- Vendored from poste.nvim@5b3759e lua/poste/install.lua (family
--- dissolution) and trimmed: plugin_tag / schedule_version_sync /
--- installed_version / update are dropped — the git-tag version sync
--- matched the binary against the *plugin checkout's* tag, which is
--- meaningless in a sibling repo. Lives under install_binary.lua because
--- this repo's install.lua (tree-sitter parser compiler) predates it.
--- REPO stays poste-nvim/poste.nvim: one binary for the whole family.
---
--- The download runs as a background job, never synchronously: this sits on
--- the setup() path, and the old `vim.fn.system` copy froze startup for the
--- whole transfer — seconds on a good network, up to 180s (the curl ceiling)
--- on a black-holed one, once per session until a binary existed. The chain
--- is archive download → checksum download (two network hops, both jobs) →
--- verify + extract (local tools, milliseconds, synchronous in the callback).
local M = {}

local REPO = "poste-nvim/poste.nvim"
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

--- Build the curl argv for one release download.
--- The ceilings bound a *background* job now: how long a stuck curl lingers
--- (a captive portal or firewall that answers the SYN and drops the rest
--- would otherwise keep the process alive until the OS socket timeout) and
--- how late the failure notification can arrive.
--- @param flags string curl's short flags, "-fL" or the silent "-sfL"
--- @param url string
--- @param out string path to write the body to
--- @param max_time integer seconds
--- @return string[] argv for jobstart (list form, so no shell)
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
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, arch)
end

--- Checksum URL for a release asset.
function M.checksum_url(platform, version)
  version = version or "latest"
  local arch = "poste-" .. platform .. archive_ext(platform) .. ".sha256"
  if version == "latest" then
    return string.format("https://github.com/%s/releases/latest/download/%s", REPO, arch)
  end
  return string.format("https://github.com/%s/releases/download/%s/%s", REPO, arch)
end

--- SHA-256 of a local file via whatever hasher exists. Local and milliseconds,
--- so it stays synchronous inside the job callbacks; nil when no hasher —
--- availability varies by platform (no sha256sum/shasum on Windows).
local function sha256_of(path)
  if vim.fn.executable("sha256sum") == 1 then
    return vim.fn.system({ "sha256sum", path }):match("^(%S+)")
  elseif vim.fn.executable("shasum") == 1 then
    return vim.fn.system({ "shasum", "-a", "256", path }):match("^(%S+)")
  elseif vim.fn.executable("certutil") == 1 then
    -- certutil prints the 64-hex-char digest on its own line between banners
    local out = vim.fn.system({ "certutil", "-hashfile", path, "SHA256" })
    for run in tostring(out):gmatch("%x+") do
      if #run == 64 then return run end
    end
  end
  return nil
end

--- jobstart raises E475 when argv[0] is missing (curl not on PATH) — a box
--- without curl must end in the graceful "download failed" notify, not a
--- plugin-load exception (health.lua's own warning promises "auto-download
--- will fail", not "load will crash").
--- @return integer|nil job id, nil when the job could not be spawned
local function spawn_curl(argv, on_exit)
  local ok, id = pcall(vim.fn.jobstart, argv, {
    on_exit = on_exit,
    on_stderr = function() end, -- curl's progress meter; explicit discard
  })
  if not ok then return nil end
  if not id or id <= 0 then return nil end
  return id
end

--- Wrap a job callback so a bug in the chain surfaces as a notify, not as an
--- error raised inside Neovim's job event handler.
local function guard(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then vim.notify("[Poste] installer error: " .. tostring(err), vim.log.levels.ERROR) end
  end
end

--- Neovim kills in-flight jobs on exit; their on_exit then reports a bogus
--- "failed" download (exit 143 = SIGTERM). Failure notices are for network
--- problems, and only Neovim's own teardown kills curl, so a signal death
--- (code >= 128) stays quiet. v:exiting is not usable as an extra signal
--- here: it is not reliably zero inside plenary's per-spec child processes.
--- Extracting anyway is still correct: the binary lands for the next launch.
local function reportable_exit(code)
  return code > 0 and code < 128
end

--- Final leg, run in the checksum job's callback: compare digests, extract
--- with local tools, stamp the version file. `expected` nil skips verification
--- (unchanged rule: the checksum file may be missing — assets older than the
--- .sha256 era — and a missing hasher must not reject a good download).
--- @param platform string
--- @param version string
--- @param tmp_archive string
--- @param expected string|nil
--- @param done function ok:boolean
local function finish_install(platform, version, tmp_archive, expected, done)
  if expected then
    local actual = sha256_of(tmp_archive)
    if not actual then
      vim.notify("[Poste] No SHA256 tool found — skipped checksum verification", vim.log.levels.WARN)
    elseif not M.checksum_matches(actual, expected) then
      pcall(os.remove, tmp_archive)
      vim.notify("[Poste] Checksum mismatch — download corrupted", vim.log.levels.ERROR)
      done(false)
      return
    end
  end

  if platform:find("windows") then
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
    done(false)
    return
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
  done(true)
end

--- Second network hop, run in the archive job's callback: fetch the release's
--- checksum file (silent, bounded) and hand the digest to finish_install.
--- @param platform string
--- @param version string
--- @param tmp_archive string
--- @param done function ok:boolean
local function verify_checksum(platform, version, tmp_archive, done)
  local url = M.checksum_url(platform, version)
  local tmp = BIN_DIR .. "/checksum.tmp"
  local started = spawn_curl(M.curl_argv("-sfL", url, tmp, 20), guard(function(_, code)
    local expected
    if code == 0 then
      local f = io.open(tmp, "r")
      if f then
        expected = f:read("*a"):match("^(%S+)")
        f:close()
      end
    end
    pcall(os.remove, tmp)
    finish_install(platform, version, tmp_archive, expected, done)
  end))
  if not started then
    -- curl vanished between the two hops — skip verification like a missing
    -- checksum file rather than failing a download that already succeeded
    pcall(os.remove, tmp)
    finish_install(platform, version, tmp_archive, nil, done)
  end
end

--- Download and install the poste binary as a background job. Returns before
--- the network answers; the outcome arrives through notifications and, when
--- given, the on_done callback (pcall'd, invoked exactly once, on the main
--- loop).
--- @param version string  tag or "latest" (default)
--- @param on_done function|nil  called with true on success, false on failure
--- @return boolean  true when the download job was started, false when it
---   failed before spawning (unsupported platform, BIN_DIR unwritable, no curl)
function M.download(version, on_done)
  version = version or "latest"
  local done = function(ok)
    if on_done then pcall(on_done, ok) end
  end

  local platform = detect_platform()
  if not platform then
    vim.notify(
      "[Poste] Unsupported platform: " .. vim.inspect(vim.loop.os_uname()),
      vim.log.levels.ERROR
    )
    done(false)
    return false
  end

  -- pcall'd: a read-only or full stdpath("data") must degrade to the notify —
  -- this used to be a bare mkdir whose exception aborted plugin load
  local ok_mkdir, mkdir_err = pcall(vim.fn.mkdir, BIN_DIR, "p")
  if not ok_mkdir then
    vim.notify("[Poste] Cannot create " .. BIN_DIR .. ": " .. tostring(mkdir_err),
      vim.log.levels.ERROR)
    done(false)
    return false
  end

  local url = M.download_url(platform, version)
  local ext = archive_ext(platform)
  local tmp_archive = BIN_DIR .. "/download" .. ext
  -- a previous interrupted run (nvim quit mid-download) may have left a partial
  pcall(os.remove, tmp_archive)

  vim.notify("[Poste] Downloading " .. url, vim.log.levels.INFO)

  local started = spawn_curl(M.curl_argv("-fL", url, tmp_archive, 180), guard(function(_, code)
    if code ~= 0 then
      pcall(os.remove, tmp_archive)
      if reportable_exit(code) then
        vim.notify("[Poste] Download failed (exit " .. code .. ")", vim.log.levels.ERROR)
      end
      done(false)
      return
    end
    verify_checksum(platform, version, tmp_archive, done)
  end))
  if not started then
    pcall(os.remove, tmp_archive)
    vim.notify("[Poste] Download failed — curl is not available on PATH", vim.log.levels.ERROR)
    done(false)
    return false
  end
  return true
end

--- Ensure the binary is available.
--- Called at plugin startup. Returns the binary path if one is already usable,
--- nil otherwise — in which case a release download starts in the background
--- and its outcome is announced by notification. Nothing here waits on the
--- network: until the "Installed" notification lands, commands that need the
--- binary report it missing and should be retried after it arrives.
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

  -- Fallback: background download; notify-only failure keeps the startup path
  -- free of any network wait. Each session retries once (no persisted marker):
  -- a failed launch must self-heal on the next one rather than need a marker
  -- file deleted.
  M.download("latest")
  return nil
end

return M
