---@brief [[
--- inline.nvim
---@brief ]]

---@class Inline
---@field version string Plugin version
---@field run fun(opts?: InlineRunOpts): nil Run inline AI on nearest @ai comment
---@field status fun(): nil Check OpenCode server health
---@field setup fun(opts?: InlineConfig): nil Configure the plugin
---@field get_config fun(): InlineConfig Return current configuration
---@field show_config fun(): nil Display current configuration
local M = {}

M.version = "0.0.9"

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- spinner animation frames for loading indicator
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- spinner animation interval in milliseconds
local SPINNER_INTERVAL_MS = 80

--- curl connection timeout in seconds (for health check)
local CURL_CONNECT_TIMEOUT_SECS = 2

--- default request timeout in seconds (for LLM operations)
local DEFAULT_REQUEST_TIMEOUT_SECS = 300

--- timeout error message prefix for detection
local TIMEOUT_ERROR_PREFIX = "timeout:"

--------------------------------------------------------------------------------
-- Namespaces
--------------------------------------------------------------------------------

--- namespace for spinner extmarks
local spinner_ns = vim.api.nvim_create_namespace("inline_spinner")

--------------------------------------------------------------------------------
-- Default Configuration
--------------------------------------------------------------------------------

---@class InlineConfig
---@field host string OpenCode server hostname
---@field port number OpenCode server port
---@field provider string|nil LLM provider (nil uses OpenCode default)
---@field model string|nil LLM model (nil uses OpenCode default)
---@field agent string Default agent name
---@field agents table<string, string> Filetype to agent mapping
---@field keymap string|false|nil Keymap binding (false to disable)
---@field prompt string|nil Custom prompt template path
---@field cache_prompt boolean|nil Cache prompt template in memory
---@field timeout number|nil Request timeout in seconds (default 300)

local defaults = {
  host = "127.0.0.1",
  port = nil, -- nil = auto-discover from running OpenCode process
  provider = nil,
  model = nil,
  agent = "build",
  agents = {},
  keymap = nil,
  prompt = nil,
  cache_prompt = nil,
  timeout = nil,
}

--------------------------------------------------------------------------------
-- Module State
--------------------------------------------------------------------------------

--- active configuration (merged defaults + user opts)
local config = vim.deepcopy(defaults)

--- cached prompt template content
local prompt_cache = nil

---@class SpinnerState
---@field frame number Current animation frame index
---@field bufnr number Buffer number
---@field lnum number Line number (1-indexed)
---@field extmark_id number Extmark identifier
---@field timer number Timer handle

--- active spinners keyed by "bufnr:lnum"
---@type table<string, SpinnerState>
local spinners = {}

---@class JobState
---@field job_id number Neovim job id
---@field bufnr number Buffer number
---@field lnum number Line number (1-indexed)
---@field timeout_timer number|nil Timeout timer handle

--- active jobs keyed by "bufnr:lnum"
---@type table<string, JobState>
local active_jobs = {}

---@class QueuedRequest
---@field bufnr number Buffer number
---@field lnum number Line number (1-indexed)
---@field instruction string The @ai instruction text
---@field original_line string Original content of the @ai line
---@field buffer_content string Numbered buffer content at queue time
---@field filename string Buffer filename
---@field filetype string Buffer filetype
---@field agent string Agent to use
---@field opts InlineRunOpts|nil Options passed to run()

--- pending request queues keyed by buffer number
---@type table<number, QueuedRequest[]>
local buffer_queues = {}

--- buffers currently processing a request
---@type table<number, boolean>
local busy_buffers = {}

--- cached discovered port (nil = not yet discovered)
---@type number|nil
local discovered_port = nil

--------------------------------------------------------------------------------
-- Port Discovery Functions (private)
--------------------------------------------------------------------------------

---@class PortCandidate
---@field port number Port number
---@field pid string Process ID

---Parse a single line of ss output to extract port and pid.
---Expected format: "LISTEN ... 127.0.0.1:PORT ... users:(("opencode",pid=XXXXX,fd=NN))"
---@param line string Single line from ss -tlnp output
---@return PortCandidate|nil candidate Parsed candidate or nil if line doesn't match
local function parse_ss_line(line)
  -- extract port from address like "127.0.0.1:4096" or "[::1]:4096" or "0.0.0.0:4096"
  local port = line:match("127%.0%.0%.1:(%d+)")
    or line:match("%[::1%]:(%d+)")
    or line:match("0%.0%.0%.0:(%d+)")

  -- extract pid from users:(("opencode",pid=XXXXX,fd=NN))
  local pid = line:match('pid=(%d+)')

  if port and pid then
    return { port = tonumber(port), pid = pid }
  end

  return nil
end

---Parse ss output to extract all opencode port candidates.
---@param ss_output string Full output from ss -tlnp | grep opencode
---@return PortCandidate[] candidates List of port/pid pairs
local function parse_ss_output(ss_output)
  local candidates = {}

  if not ss_output or ss_output == "" then
    return candidates
  end

  for line in ss_output:gmatch("[^\n]+") do
    local candidate = parse_ss_line(line)
    if candidate then
      table.insert(candidates, candidate)
    end
  end

  return candidates
end

---Find port matching a target cwd from list of candidates.
---@param candidates PortCandidate[] List of port/pid pairs
---@param target_cwd string Target working directory to match
---@param cwd_resolver fun(pid: string): string|nil Function to resolve pid to cwd
---@return number|nil port Matching port or nil if not found
local function find_port_for_cwd(candidates, target_cwd, cwd_resolver)
  for _, candidate in ipairs(candidates) do
    local proc_cwd = cwd_resolver(candidate.pid)
    if proc_cwd and proc_cwd == target_cwd then
      return candidate.port
    end
  end
  return nil
end

---Read process cwd from /proc filesystem.
---@param pid string Process ID
---@return string|nil cwd Working directory or nil if not readable
local function read_proc_cwd(pid)
  local proc_cwd_path = string.format("/proc/%s/cwd", pid)
  local handle = io.popen(string.format("readlink %s 2>/dev/null", proc_cwd_path))
  if not handle then
    return nil
  end

  local cwd = handle:read("*a")
  handle:close()

  if cwd then
    return cwd:gsub("%s+$", "") -- trim trailing whitespace
  end

  return nil
end

---Quick synchronous health check for port validation during discovery.
---Uses short timeout to avoid blocking UI.
---@param host string Host to check
---@param port number Port to check
---@return boolean healthy True if server responds
local function check_port_health_sync(host, port)
  local url = string.format("http://%s:%d/global/health", host, port)
  local cmd = string.format(
    "curl -s --connect-timeout 1 --max-time 2 %s 2>/dev/null",
    url
  )

  local handle = io.popen(cmd)
  if not handle then
    return false
  end

  local result = handle:read("*a")
  handle:close()

  if not result or result == "" then
    return false
  end

  -- check for valid json with healthy status
  local ok, data = pcall(vim.fn.json_decode, result)
  return ok and data and data.healthy == true
end

---Discover OpenCode server port by matching process cwd to current directory.
---Uses `ss` to find listening ports and `/proc/<pid>/cwd` to match working directory.
---Falls back to first available instance if no exact match found.
---@return number|nil port Discovered port or nil if not found
---@return string|nil fallback_cwd If using fallback, the cwd of that instance (nil if exact match)
---@return string|nil err Error message if discovery failed
local function discover_port()
  -- get current working directory (where nvim was started)
  local cwd = vim.fn.getcwd()

  -- use ss to find opencode processes listening on ports
  local handle = io.popen("ss -tlnp 2>/dev/null | grep opencode")
  if not handle then
    return nil, "failed to run ss command"
  end

  local output = handle:read("*a")
  handle:close()

  if not output or output == "" then
    return nil, "no opencode process found listening"
  end

  -- parse and find matching port
  local candidates = parse_ss_output(output)
  if #candidates == 0 then
    return nil, nil, "no opencode process found listening"
  end

  local port = find_port_for_cwd(candidates, cwd, read_proc_cwd)
  if port then
    return port, nil, nil
  end

  -- no exact match - try each candidate until one responds
  for _, candidate in ipairs(candidates) do
    if check_port_health_sync(config.host, candidate.port) then
      local fallback_cwd = read_proc_cwd(candidate.pid)
      return candidate.port, fallback_cwd, nil
    end
  end

  return nil, nil, "no responsive opencode instance found"
end

---Get the port to use for OpenCode connections.
---Returns configured port if set, otherwise discovers from running process.
---Caches discovered port for subsequent calls.
---@return number|nil port Port number or nil if unavailable
---@return string|nil err Error message if port unavailable
local function get_port()
  -- use configured port if explicitly set
  if config.port then
    return config.port, nil
  end

  -- return cached discovered port if available
  if discovered_port then
    return discovered_port, nil
  end

  -- attempt discovery
  local port, fallback_cwd, err = discover_port()
  if err then
    return nil, err
  end

  if port then
    discovered_port = port

    -- warn if using fallback instance
    if fallback_cwd then
      vim.schedule(function()
        vim.notify(
          string.format("using opencode from: %s", fallback_cwd),
          vim.log.levels.WARN
        )
      end)
    end

    return port, nil
  end

  return nil, "no opencode process found"
end

---Clear the discovered port cache.
---Forces re-discovery on next request.
local function clear_port_cache() -- luacheck: ignore 211 (exposed via _test)
  discovered_port = nil
end

--------------------------------------------------------------------------------
-- Spinner Functions (private)
--------------------------------------------------------------------------------

---Build a stable key for spinner lookup.
---@param bufnr number Buffer number
---@param lnum number Line number (1-indexed)
---@return string key Format "bufnr:lnum"
local function spinner_key(bufnr, lnum)
  return bufnr .. ":" .. lnum
end

-- forward declaration for stop_spinner (needed by start_spinner)
local stop_spinner

---Check if a spinner is active at the given location.
---@param bufnr number Buffer number
---@param lnum number Line number (1-indexed)
---@return boolean is_active True if spinner exists at location
local function is_processing(bufnr, lnum)
  return spinners[spinner_key(bufnr, lnum)] ~= nil
end

---Start spinner animation at the given line.
---Creates an extmark with animated braille spinner and a repeating timer.
---@param bufnr number Buffer number
---@param lnum number Line number (1-indexed)
local function start_spinner(bufnr, lnum)
  local key = spinner_key(bufnr, lnum)

  -- stop any existing spinner at this location to avoid timer overlap
  if spinners[key] then
    stop_spinner(bufnr, lnum)
  end

  -- initialize spinner state
  local s = { frame = 1, bufnr = bufnr, lnum = lnum }

  -- create extmark at end of line with first spinner frame
  s.extmark_id = vim.api.nvim_buf_set_extmark(bufnr, spinner_ns, lnum - 1, 0, {
    virt_text = { { " " .. SPINNER_FRAMES[1], "Comment" } },
    virt_text_pos = "eol",
  })

  -- start repeating timer for frame animation
  s.timer = vim.fn.timer_start(SPINNER_INTERVAL_MS, function()
    -- bail if spinner was stopped externally
    if not spinners[key] then
      return
    end

    -- advance to next frame (wrap around)
    s.frame = (s.frame % #SPINNER_FRAMES) + 1

    -- update extmark with new frame (pcall guards against deleted buffer)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, spinner_ns, lnum - 1, 0, {
      id = s.extmark_id,
      virt_text = { { " " .. SPINNER_FRAMES[s.frame], "Comment" } },
      virt_text_pos = "eol",
    })
  end, { ["repeat"] = -1 })

  spinners[key] = s
end

---Stop and cleanup spinner at the given location.
---@param bufnr number Buffer number
---@param lnum number Line number (1-indexed)
stop_spinner = function(bufnr, lnum)
  local key = spinner_key(bufnr, lnum)
  local s = spinners[key]
  if not s then
    return
  end

  -- stop the animation timer
  if s.timer then
    vim.fn.timer_stop(s.timer)
  end

  -- remove the extmark (pcall guards against deleted buffer)
  if s.extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, spinner_ns, s.extmark_id)
  end

  spinners[key] = nil
end

--------------------------------------------------------------------------------
-- Prompt Functions (private)
--------------------------------------------------------------------------------

---Resolve path to the bundled default prompt template.
---Uses debug.getinfo to find plugin installation directory.
---@return string path Absolute path to prompts/default.md
local function get_default_prompt_path()
  -- get path of this source file and strip leading "@"
  local source = debug.getinfo(1, "S").source:sub(2)
  -- navigate up from lua/inline/init.lua to plugin root
  local plugin_dir = vim.fn.fnamemodify(source, ":h:h:h")
  return plugin_dir .. "/prompts/default.md"
end

---Read prompt template from disk.
---@param path string Path to prompt file
---@return string|nil content File contents or nil on error
---@return string|nil err Error message or nil on success
local function load_prompt(path)
  path = vim.fn.expand(path)

  if vim.fn.filereadable(path) ~= 1 then
    return nil, "file not found: " .. path
  end

  local lines = vim.fn.readfile(path)
  if not lines or #lines == 0 then
    return nil, "file empty: " .. path
  end

  return table.concat(lines, "\n"), nil
end

---Get the active prompt template, with optional caching.
---@return string|nil template Prompt template or nil on error
local function get_prompt_template()
  -- return cached template if caching enabled and cache exists
  if config.cache_prompt and prompt_cache then
    return prompt_cache
  end

  -- determine which file to load (user override or bundled default)
  local path = config.prompt or get_default_prompt_path()
  local content, err = load_prompt(path)

  if not content then
    vim.notify("inline.nvim: " .. err, vim.log.levels.ERROR)
    return nil
  end

  -- store in cache if caching enabled
  if config.cache_prompt then
    prompt_cache = content
  end

  return content
end

---Clear the cached prompt template.
---Forces reload from disk on next get_prompt_template call.
local function clear_prompt_cache() -- luacheck: ignore 211 (unused for now, public API planned)
  prompt_cache = nil
end

---Build formatted prompt for AI request.
---@param filename string Current buffer filename
---@param filetype string Current buffer filetype
---@param buffer_content string Buffer content with line numbers
---@param lnum number Line number of @ai comment
---@param instruction string User instruction from @ai comment
---@return string|nil prompt Formatted prompt or nil on error
local function build_prompt(filename, filetype, buffer_content, lnum, instruction)
  local template = get_prompt_template()
  if not template then
    return nil
  end
  return string.format(template, filename, filetype, buffer_content, lnum, instruction)
end

--------------------------------------------------------------------------------
-- Agent Functions (private)
--------------------------------------------------------------------------------

---Resolve agent name for current buffer.
---Checks filetype-specific mapping first, falls back to default.
---@return string agent Agent name to use
local function get_agent()
  local ft = vim.bo.filetype

  -- check filetype-specific agent mapping
  if config.agents and config.agents[ft] then
    return config.agents[ft]
  end

  return config.agent
end

--------------------------------------------------------------------------------
-- HTTP Functions (private)
--------------------------------------------------------------------------------

---@class CurlAsyncOpts
---@field timeout number|nil Request timeout in seconds (adds --max-time to curl)

---Execute curl command asynchronously.
---Uses jobstart to avoid blocking the UI thread.
---@param args string[] Curl command arguments
---@param callback fun(result: string|nil, err: string|nil) Called with stdout or error
---@param opts CurlAsyncOpts|nil Options for this request
---@return number job_id Job handle for cancellation
local function curl_async(args, callback, opts)
  opts = opts or {}
  local stdout_chunks = {}
  local stderr_chunks = {}
  local timed_out = false

  -- add timeout to curl args if specified
  local final_args = vim.deepcopy(args)
  if opts.timeout then
    table.insert(final_args, 2, "--max-time")
    table.insert(final_args, 3, tostring(opts.timeout))
  end

  local job_id = vim.fn.jobstart(final_args, {
    stdout_buffered = true,
    stderr_buffered = true,

    -- collect stdout chunks
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(stdout_chunks, chunk)
        end
      end
    end,

    -- collect stderr chunks
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(stderr_chunks, chunk)
        end
      end
    end,

    -- handle completion
    on_exit = function(_, exit_code)
      -- schedule callback to run in main loop (safe for vim api calls)
      vim.schedule(function()
        if timed_out then
          callback(nil, TIMEOUT_ERROR_PREFIX .. " request timed out after " .. opts.timeout .. "s")
        elseif exit_code == 28 then
          -- curl exit code 28 = operation timeout
          callback(nil, TIMEOUT_ERROR_PREFIX .. " request timed out")
        elseif exit_code ~= 0 then
          local stderr = table.concat(stderr_chunks, "\n")
          -- check for timeout-related errors in stderr
          if stderr:match("timed out") or stderr:match("Operation timed out") then
            callback(nil, TIMEOUT_ERROR_PREFIX .. " " .. stderr)
          else
            callback(nil, "curl failed (exit " .. exit_code .. "): " .. stderr)
          end
        else
          callback(table.concat(stdout_chunks, ""), nil)
        end
      end)
    end,
  })

  return job_id
end

---Cancel an active job by job_id.
---@param job_id number Job handle from jobstart
local function cancel_job(job_id)
  if job_id and job_id > 0 then
    pcall(vim.fn.jobstop, job_id)
  end
end

---Check OpenCode server health status.
---@param callback fun(healthy: boolean, version_or_err: string) Called with health result
---@return number|nil job_id Job handle for cancellation, nil if port discovery failed
local function check_health(callback)
  local port, port_err = get_port()
  if not port then
    -- schedule callback to maintain async contract
    vim.schedule(function()
      callback(false, port_err or "could not discover opencode port")
    end)
    return nil
  end

  local url = string.format("http://%s:%d/global/health", config.host, port)

  return curl_async({
    "curl",
    "-s",
    "--connect-timeout",
    tostring(CURL_CONNECT_TIMEOUT_SECS),
    url,
  }, function(result, err)
    if err then
      -- provide friendlier error messages
      if err:match("^" .. TIMEOUT_ERROR_PREFIX) then
        callback(false, "server not responding (timeout)")
      elseif err:match("Connection refused") then
        callback(false, "server not running (connection refused)")
      else
        callback(false, err)
      end
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      callback(false, "invalid response from server")
      return
    end

    -- check health status in response
    if data.healthy then
      callback(true, data.version or "unknown")
    else
      callback(false, "server reports unhealthy status")
    end
  end, { timeout = CURL_CONNECT_TIMEOUT_SECS })
end

---Create a new OpenCode session.
---@param callback fun(session_id: string|nil, err: string|nil) Called with session ID or error
---@return number|nil job_id Job handle for cancellation, nil if port discovery failed
local function create_session(callback)
  local port, port_err = get_port()
  if not port then
    vim.schedule(function()
      callback(nil, port_err or "could not discover opencode port")
    end)
    return nil
  end

  local url = string.format("http://%s:%d/session", config.host, port)
  local timeout = config.timeout or DEFAULT_REQUEST_TIMEOUT_SECS

  -- build request body with optional provider/model overrides
  local session_opts = vim.empty_dict()
  if config.provider then
    session_opts.provider = config.provider
  end
  if config.model then
    session_opts.model = config.model
  end

  local body = vim.fn.json_encode(session_opts)

  return curl_async({
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
    url,
  }, function(result, err)
    if err then
      -- provide friendlier error messages
      if err:match("^" .. TIMEOUT_ERROR_PREFIX) then
        callback(nil, "session creation timed out")
      else
        callback(nil, err)
      end
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      -- check if it looks like an error response
      if result:match("invalid") or result:match("error") then
        callback(nil, "server error: " .. result:sub(1, 200))
      else
        callback(nil, "invalid json response from server")
      end
      return
    end

    -- check for error in response (invalid provider/model)
    if data.error then
      callback(nil, "server error: " .. (data.error.message or data.error or "unknown"))
      return
    end

    -- validate session id exists
    if not data.id then
      callback(nil, "no session id in response")
      return
    end

    callback(data.id, nil)
  end, { timeout = timeout })
end

---Send message to OpenCode session.
---@param session_id string Session identifier
---@param message string Message content
---@param agent string|nil Agent name (optional)
---@param callback fun(response: string|nil, err: string|nil) Called with response text or error
---@return number|nil job_id Job handle for cancellation, nil if port discovery failed
local function send_message(session_id, message, agent, callback)
  local port, port_err = get_port()
  if not port then
    vim.schedule(function()
      callback(nil, port_err or "could not discover opencode port")
    end)
    return nil
  end

  local url = string.format(
    "http://%s:%d/session/%s/message",
    config.host,
    port,
    session_id
  )
  local timeout = config.timeout or DEFAULT_REQUEST_TIMEOUT_SECS

  -- build request payload
  local msg_opts = {
    parts = {
      { type = "text", text = message },
    },
  }

  -- include agent if specified
  if agent and agent ~= "" then
    msg_opts.agent = agent
  end

  local body = vim.fn.json_encode(msg_opts)

  return curl_async({
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-d",
    body,
    url,
  }, function(result, err)
    if err then
      -- provide friendlier error messages
      if err:match("^" .. TIMEOUT_ERROR_PREFIX) then
        callback(nil, "request timed out (LLM may be slow or server crashed)")
      else
        callback(nil, err)
      end
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      -- check if it looks like an error response
      if result:match("error") or result:match("crash") then
        callback(nil, "server error: " .. result:sub(1, 200))
      else
        callback(nil, "invalid json response from server")
      end
      return
    end

    -- check for error in response
    if data.error then
      callback(nil, "server error: " .. (data.error.message or data.error or "unknown"))
      return
    end

    -- extract text from response parts
    if data.parts then
      local texts = {}
      for _, part in ipairs(data.parts) do
        if part.type == "text" and part.text then
          table.insert(texts, part.text)
        end
      end
      callback(table.concat(texts, "\n"), nil)
      return
    end

    callback(nil, "no content in response")
  end, { timeout = timeout })
end

--------------------------------------------------------------------------------
-- Comment Parsing Functions (private)
--------------------------------------------------------------------------------

---Get comment delimiters from vim commentstring.
---Falls back to "//" style if commentstring is empty or invalid.
---@return string prefix Comment prefix (e.g., "//", "#", "--")
---@return string suffix Comment suffix (e.g., "" or "-->")
local function get_comment_delimiters()
  local cs = vim.bo.commentstring

  -- fallback for empty commentstring
  if not cs or cs == "" then
    return "//", ""
  end

  -- parse commentstring format like "// %s" or "<!-- %s -->"
  local prefix, suffix = cs:match("^(.-)%%s(.*)$")
  if prefix then
    -- trim trailing whitespace from prefix, leading from suffix
    prefix = prefix:match("^(.-)%s*$") or prefix
    suffix = suffix:match("^%s*(.-)$") or suffix
    return prefix, suffix
  end

  return "//", ""
end

---Escape Lua pattern metacharacters for literal matching.
---@param str string String to escape
---@return string escaped String with metacharacters escaped
local function escape_pattern(str)
  return str:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

---Find nearest @ai instruction comment above cursor.
---Searches backwards from cursor position to find @ai directive.
---@return string|nil instruction Instruction text or nil if not found
---@return number|nil lnum Line number (1-indexed) or nil if not found
local function find_ai_comment()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- get comment delimiters for current filetype
  local prefix, suffix = get_comment_delimiters()
  local escaped_prefix = escape_pattern(prefix)
  local escaped_suffix = escape_pattern(suffix)

  -- build pattern based on comment style
  local pattern
  if suffix ~= "" then
    -- block comment style: <!-- @ai: instruction -->
    pattern = "^%s*" .. escaped_prefix .. "%s*@[aA][iI]:?%s*(.-)%s*" .. escaped_suffix .. "%s*$"
  else
    -- line comment style: // @ai: instruction
    pattern = "^%s*" .. escaped_prefix .. "%s*@[aA][iI]:?%s*(.*)$"
  end

  -- search backwards from cursor
  for i = cursor_lnum, 1, -1 do
    local line = lines[i]
    local instruction = line:match(pattern)
    if instruction then
      return instruction, i
    end
  end

  return nil, nil
end

--------------------------------------------------------------------------------
-- Response Parsing Functions (private)
--------------------------------------------------------------------------------

---Strip markdown code fences from response text.
---Removes opening fence (with optional language) and closing fence.
---@param text string Response text possibly wrapped in fences
---@return string text Text with fences removed
local function strip_code_fences(text)
  -- remove opening fence: ```lang\n or ```\n
  text = text:gsub("^```[%w]*\n", "")
  -- remove closing fence: \n```
  text = text:gsub("\n```$", "")
  return text
end

---Parse AI response in REPLACE format.
---Expected format: "REPLACE start_line end_line\ncode..."
---Handles common model quirks: markdown fences, preamble text, extra whitespace.
---@param response string Raw response text
---@return number|nil start_line Start line for replacement
---@return number|nil end_line End line for replacement
---@return string[]|nil code_lines Lines to insert
---@return string|nil err Error message if parsing failed
local function parse_response(response)
  -- strip markdown fences if present (handles ```text, ```lua, etc.)
  response = strip_code_fences(response)

  -- split into lines
  local lines = {}
  for line in response:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end

  -- trim trailing empty lines
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines == 0 then
    return nil, nil, nil, "empty response"
  end

  -- find the REPLACE header line (may not be first if model added preamble)
  -- patterns to try, in order of strictness:
  -- 1. exact format: "REPLACE 1 4"
  -- 2. with extra whitespace: "  REPLACE  1  4  "
  -- 3. case-insensitive: "Replace 1 4"
  local replace_line_idx = nil
  local start_line, end_line

  for i, line in ipairs(lines) do
    -- try strict match first (trimmed)
    local trimmed = line:match("^%s*(.-)%s*$")
    start_line, end_line = trimmed:match("^REPLACE%s+(%d+)%s+(%d+)$")
    if start_line then
      replace_line_idx = i
      break
    end

    -- try case-insensitive match
    start_line, end_line = trimmed:match("^[Rr][Ee][Pp][Ll][Aa][Cc][Ee]%s+(%d+)%s+(%d+)$")
    if start_line then
      replace_line_idx = i
      break
    end
  end

  if not replace_line_idx then
    -- provide helpful error with first non-empty line
    local first_content = ""
    for _, line in ipairs(lines) do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        first_content = trimmed:sub(1, 50)
        break
      end
    end
    return nil, nil, nil, "missing REPLACE header, got: " .. first_content
  end

  -- warn if there was preamble (but still proceed)
  if replace_line_idx > 1 then
    local preamble_lines = replace_line_idx - 1
    vim.schedule(function()
      vim.notify(
        string.format("ignored %d preamble line(s) before REPLACE header", preamble_lines),
        vim.log.levels.DEBUG
      )
    end)
  end

  -- extract code lines (everything after REPLACE header)
  local code_lines = {}
  for i = replace_line_idx + 1, #lines do
    table.insert(code_lines, lines[i])
  end

  return tonumber(start_line), tonumber(end_line), code_lines, nil
end

---Insert parsed response into buffer.
---Falls back to single-line replacement if parsing fails.
---@param bufnr number Buffer number
---@param fallback_lnum number Fallback line for single-line replacement
---@param response string AI response text
local function insert_response(bufnr, fallback_lnum, response)
  local start_line, end_line, code_lines, err = parse_response(response)

  if err then
    -- fallback: replace just the @ai line with raw response
    vim.notify(
      "warning: " .. err .. ", falling back to single line replace",
      vim.log.levels.WARN
    )

    -- split response into lines for insertion
    local lines = {}
    for line in response:gmatch("([^\n]*)\n?") do
      if line ~= "" or #lines > 0 then
        table.insert(lines, line)
      end
    end

    -- trim trailing empty lines
    while #lines > 0 and lines[#lines] == "" do
      table.remove(lines)
    end

    -- replace single line (0-indexed api)
    vim.api.nvim_buf_set_lines(bufnr, fallback_lnum - 1, fallback_lnum, false, lines)
    return
  end

  -- replace the specified range (convert to 0-indexed)
  vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, code_lines)
end

--------------------------------------------------------------------------------
-- Queue Functions (private)
--------------------------------------------------------------------------------

-- forward declaration for execute_request (needed by process_next_in_queue)
local execute_request

---Process the next queued request for a buffer.
---Called after a request completes, errors, or is cancelled.
---@param bufnr number Buffer number
local function process_next_in_queue(bufnr)
  local queue = buffer_queues[bufnr]
  if not queue or #queue == 0 then
    -- no pending requests, mark buffer as not busy
    busy_buffers[bufnr] = nil
    return
  end

  -- get next request from queue
  local request = table.remove(queue, 1)

  -- verify buffer still exists
  if not vim.api.nvim_buf_is_valid(request.bufnr) then
    -- buffer was closed, skip this request and try next
    process_next_in_queue(bufnr)
    return
  end

  -- re-verify the @ai line still matches what we captured
  local current_lines = vim.api.nvim_buf_get_lines(request.bufnr, 0, -1, false)
  local current_line = current_lines[request.lnum]
  if current_line ~= request.original_line then
    vim.notify(
      string.format("queued request for line %d skipped: line was modified", request.lnum),
      vim.log.levels.WARN
    )
    -- try next request in queue
    process_next_in_queue(bufnr)
    return
  end

  -- re-capture buffer content since it may have changed
  local numbered_lines = {}
  for i, line in ipairs(current_lines) do
    table.insert(numbered_lines, string.format("%d: %s", i, line))
  end
  request.buffer_content = table.concat(numbered_lines, "\n")

  -- execute the queued request
  execute_request(request)
end

---Execute a request (either immediate or from queue).
---@param request QueuedRequest Request to execute
execute_request = function(request)
  local bufnr = request.bufnr
  local lnum = request.lnum

  -- mark buffer as busy
  busy_buffers[bufnr] = true

  -- build the prompt with all context
  local message = build_prompt(
    request.filename,
    request.filetype,
    request.buffer_content,
    lnum,
    request.instruction
  )

  -- start visual feedback
  start_spinner(bufnr, lnum)

  local key = spinner_key(bufnr, lnum)

  ---Cleanup function to stop spinner, remove job tracking, and process queue
  local function cleanup()
    stop_spinner(bufnr, lnum)
    active_jobs[key] = nil
    -- process next request in queue (or mark buffer as not busy)
    process_next_in_queue(bufnr)
  end

  -- async chain: health check -> create session -> send message
  local job_id = check_health(function(healthy, version_or_err)
    -- check if cancelled
    if not active_jobs[key] then
      process_next_in_queue(bufnr)
      return
    end

    if not healthy then
      cleanup()
      vim.notify("opencode server not available: " .. version_or_err, vim.log.levels.ERROR)
      return
    end

    local session_job_id = create_session(function(session_id, err)
      -- check if cancelled
      if not active_jobs[key] then
        process_next_in_queue(bufnr)
        return
      end

      if not session_id then
        cleanup()
        vim.notify("session creation failed: " .. err, vim.log.levels.ERROR)
        return
      end

      local msg_job_id = send_message(
        session_id, message, request.agent, function(response, send_err)
        -- check if cancelled
        if not active_jobs[key] then
          process_next_in_queue(bufnr)
          return
        end

        cleanup()

        if not response then
          vim.notify("request failed: " .. send_err, vim.log.levels.ERROR)
          return
        end

        -- verify @ai line wasn't modified during async operation
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local current_ai_line = current_lines[lnum]
        if current_ai_line ~= request.original_line then
          vim.notify("@ai line was modified, response discarded", vim.log.levels.WARN)
          return
        end

        -- insert response into buffer
        insert_response(bufnr, lnum, response)
      end)

      -- update job tracking to message job
      if active_jobs[key] then
        active_jobs[key].job_id = msg_job_id
      end
    end)

    -- update job tracking to session job
    if active_jobs[key] then
      active_jobs[key].job_id = session_job_id
    end
  end)

  -- track the active job for cancellation
  active_jobs[key] = {
    job_id = job_id,
    bufnr = bufnr,
    lnum = lnum,
  }
end

---Queue a request for later execution.
---@param request QueuedRequest Request to queue
local function queue_request(request)
  local bufnr = request.bufnr
  if not buffer_queues[bufnr] then
    buffer_queues[bufnr] = {}
  end
  table.insert(buffer_queues[bufnr], request)

  local queue_position = #buffer_queues[bufnr]
  vim.notify(
    string.format("request queued (position %d)", queue_position),
    vim.log.levels.INFO
  )
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

---@class InlineRunOpts
---@field agent string|nil Agent override for this request

---Run inline AI completion for the nearest @ai comment.
---Finds the @ai comment above cursor, sends request to OpenCode,
---and replaces the specified line range with the response.
---If buffer is busy, request is queued for later execution.
---@param opts InlineRunOpts|nil Options for this run
function M.run(opts)
  opts = opts or {}

  -- find @ai comment above cursor
  local instruction, lnum = find_ai_comment()
  if not instruction or instruction == "" then
    vim.notify("no @ai comment found", vim.log.levels.WARN)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- prevent duplicate runs on same line (already processing or already queued)
  if is_processing(bufnr, lnum) then
    vim.notify("already processing this line", vim.log.levels.WARN)
    return
  end

  -- check if this line is already in the queue
  local queue = buffer_queues[bufnr]
  if queue then
    for _, req in ipairs(queue) do
      if req.lnum == lnum then
        vim.notify("this line is already queued", vim.log.levels.WARN)
        return
      end
    end
  end

  -- capture buffer context before async operations
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local original_ai_line = lines[lnum]

  -- build numbered line content for context
  local numbered_lines = {}
  for i, line in ipairs(lines) do
    table.insert(numbered_lines, string.format("%d: %s", i, line))
  end
  local buffer_content = table.concat(numbered_lines, "\n")

  local filename = vim.fn.expand("%:t")
  local filetype = vim.bo.filetype

  -- resolve agent: command override > buffer-local > filetype mapping > default
  local agent = opts.agent or vim.b.inline_agent or get_agent()

  -- build the request
  ---@type QueuedRequest
  local request = {
    bufnr = bufnr,
    lnum = lnum,
    instruction = instruction,
    original_line = original_ai_line,
    buffer_content = buffer_content,
    filename = filename,
    filetype = filetype,
    agent = agent,
    opts = opts,
  }

  -- if buffer is busy, queue the request
  if busy_buffers[bufnr] then
    queue_request(request)
    return
  end

  -- execute immediately
  execute_request(request)
end

---Check OpenCode server health and display status.
function M.status()
  vim.notify("checking opencode server...", vim.log.levels.INFO)

  check_health(function(healthy, version_or_err)
    if healthy then
      local msg = string.format(
        "opencode server: ok (v%s) at %s:%d", version_or_err, config.host, config.port
      )
      vim.notify(msg, vim.log.levels.INFO)
    else
      vim.notify(
        string.format("opencode server: not available (%s)", version_or_err),
        vim.log.levels.ERROR
      )
    end
  end)
end

---Cancel active request at cursor position or all requests.
---@param opts { all: boolean|nil }|nil Options for cancel
function M.cancel(opts)
  opts = opts or {}

  if opts.all then
    -- cancel all active requests and clear all queues
    local count = 0
    local queued_count = 0

    -- cancel active jobs
    for key, job_state in pairs(active_jobs) do
      cancel_job(job_state.job_id)
      stop_spinner(job_state.bufnr, job_state.lnum)
      active_jobs[key] = nil
      count = count + 1
    end

    -- clear all queues
    for bufnr, queue in pairs(buffer_queues) do
      queued_count = queued_count + #queue
      buffer_queues[bufnr] = nil
      busy_buffers[bufnr] = nil
    end

    if count > 0 or queued_count > 0 then
      local msg = string.format("cancelled %d active, %d queued request(s)", count, queued_count)
      vim.notify(msg, vim.log.levels.INFO)
    else
      vim.notify("no active or queued requests to cancel", vim.log.levels.WARN)
    end
    return
  end

  -- cancel request at cursor position
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor_lnum = vim.api.nvim_win_get_cursor(0)[1]

  -- search backwards for active request (same as find_ai_comment logic)
  for i = cursor_lnum, 1, -1 do
    local key = spinner_key(bufnr, i)
    local job_state = active_jobs[key]
    if job_state then
      cancel_job(job_state.job_id)
      stop_spinner(job_state.bufnr, job_state.lnum)
      active_jobs[key] = nil
      vim.notify("request cancelled", vim.log.levels.INFO)
      -- process next request in queue for this buffer
      process_next_in_queue(bufnr)
      return
    end
  end

  -- check if cursor is on a queued request
  local queue = buffer_queues[bufnr]
  if queue then
    for idx, req in ipairs(queue) do
      if req.lnum == cursor_lnum then
        table.remove(queue, idx)
        vim.notify("queued request cancelled", vim.log.levels.INFO)
        return
      end
    end
  end

  vim.notify("no active or queued request found at or above cursor", vim.log.levels.WARN)
end

---Validate configuration and return list of errors.
---@param cfg InlineConfig Configuration to validate
---@return string[] errors List of validation errors (empty if valid)
local function validate_config(cfg)
  local errors = {}

  -- validate host
  if type(cfg.host) ~= "string" or cfg.host == "" then
    table.insert(errors, "host must be a non-empty string")
  end

  -- validate port (nil = auto-discover, or must be valid port number)
  if cfg.port ~= nil and (type(cfg.port) ~= "number" or cfg.port < 1 or cfg.port > 65535) then
    table.insert(errors, "port must be nil (auto-discover) or a number between 1 and 65535")
  end

  -- validate timeout if specified
  if cfg.timeout ~= nil then
    if type(cfg.timeout) ~= "number" or cfg.timeout < 1 then
      table.insert(errors, "timeout must be a positive number (seconds)")
    end
  end

  -- validate provider if specified (basic check - not empty string)
  if cfg.provider ~= nil and (type(cfg.provider) ~= "string" or cfg.provider == "") then
    table.insert(errors, "provider must be a non-empty string or nil")
  end

  -- validate model if specified
  if cfg.model ~= nil and (type(cfg.model) ~= "string" or cfg.model == "") then
    table.insert(errors, "model must be a non-empty string or nil")
  end

  -- validate agent
  if type(cfg.agent) ~= "string" or cfg.agent == "" then
    table.insert(errors, "agent must be a non-empty string")
  end

  return errors
end

---Configure inline.nvim and register commands/keymaps.
---@param opts InlineConfig|nil User configuration options
function M.setup(opts)
  opts = opts or {}

  -- merge user options over defaults
  config = vim.tbl_deep_extend("force", defaults, opts)

  -- validate configuration
  local errors = validate_config(config)
  if #errors > 0 then
    vim.notify(
      "inline.nvim: configuration errors:\n  " .. table.concat(errors, "\n  "),
      vim.log.levels.ERROR
    )
    -- don't return - still set up commands so user can fix and retry
  end

  -- register :InlineRun command with optional agent override
  vim.api.nvim_create_user_command("InlineRun", function(cmd_opts)
    local agent_override = nil
    if cmd_opts.args and cmd_opts.args ~= "" then
      agent_override = cmd_opts.args:match("^agent=(.+)$")
    end
    M.run({ agent = agent_override })
  end, {
    desc = "Run inline AI on @ai comment",
    nargs = "?",
    complete = function()
      -- suggest available agents
      local agents = { "build", "plan", "general", "explore" }

      -- add user-configured agents
      if config.agents then
        for _, agent in pairs(config.agents) do
          table.insert(agents, agent)
        end
      end

      -- format as agent=<name> completions
      local completions = {}
      for _, a in ipairs(agents) do
        table.insert(completions, "agent=" .. a)
      end
      return completions
    end,
  })

  -- register :InlineStatus command
  vim.api.nvim_create_user_command("InlineStatus", function()
    M.status()
  end, { desc = "Check OpenCode server status" })

  -- register :InlineConfig command
  vim.api.nvim_create_user_command("InlineConfig", function()
    M.show_config()
  end, { desc = "Show inline.nvim configuration" })

  -- register :InlineCancel command
  vim.api.nvim_create_user_command("InlineCancel", function(cmd_opts)
    local all = cmd_opts.bang
    M.cancel({ all = all })
  end, {
    desc = "Cancel active inline AI request (use ! to cancel all)",
    bang = true,
  })

  -- register :InlineValidateConfig command
  vim.api.nvim_create_user_command("InlineValidateConfig", function()
    M.validate_config()
  end, { desc = "Validate configuration against models.dev" })

  -- set up keymap (unless disabled)
  if config.keymap ~= false then
    local key = config.keymap or "<leader>ai"
    vim.keymap.set("n", key, "<cmd>InlineRun<cr>", { desc = "Run inline AI" })
  end
end

---Get the current configuration table.
---@return InlineConfig config Current configuration
function M.get_config()
  return config
end

---Display current configuration via vim.notify.
function M.show_config()
  local lines = {
    "inline.nvim v" .. M.version,
    "",
    "config:",
    string.format("  host: %s", config.host),
    string.format("  port: %s", config.port),
    string.format("  provider: %s", config.provider or "(opencode default)"),
    string.format("  model: %s", config.model or "(opencode default)"),
    string.format("  agent: %s", config.agent),
    string.format(
      "  keymap: %s",
      config.keymap == false and "(disabled)" or (config.keymap or "<leader>ai")
    ),
  }

  -- append per-filetype agent mappings if configured
  if config.agents and next(config.agents) then
    table.insert(lines, "  agents:")
    for ft, agent in pairs(config.agents) do
      table.insert(lines, string.format("    %s: %s", ft, agent))
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- models.dev API URL for provider validation
local MODELS_DEV_API = "https://models.dev/api.json"

---Validate configuration against models.dev provider list.
---Fetches known providers and checks if configured provider is valid.
function M.validate_config()
  vim.notify("validating configuration against models.dev...", vim.log.levels.INFO)

  -- step 1: local validation
  local errors = validate_config(config)
  if #errors > 0 then
    vim.notify(
      "local validation failed:\n  " .. table.concat(errors, "\n  "),
      vim.log.levels.ERROR
    )
    return
  end

  -- step 2: check opencode server health
  check_health(function(healthy, version_or_err)
    if not healthy then
      vim.notify(
        "opencode server check failed: " .. version_or_err,
        vim.log.levels.ERROR
      )
      return
    end

    vim.notify("  opencode server: ok (v" .. version_or_err .. ")", vim.log.levels.INFO)

    -- step 3: validate provider against models.dev (if provider is configured)
    if not config.provider then
      vim.notify("  provider: using opencode default (skipping validation)", vim.log.levels.INFO)
      vim.notify("configuration valid", vim.log.levels.INFO)
      return
    end

    -- fetch models.dev API
    curl_async({
      "curl",
      "-s",
      "--connect-timeout",
      "5",
      MODELS_DEV_API,
    }, function(result, err)
      if err then
        vim.notify(
          "  provider: could not fetch models.dev (" .. err .. ")",
          vim.log.levels.WARN
        )
        vim.notify("configuration valid (provider not verified)", vim.log.levels.INFO)
        return
      end

      -- parse json and extract provider keys
      local ok, data = pcall(vim.fn.json_decode, result)
      if not ok then
        vim.notify("  provider: could not parse models.dev response", vim.log.levels.WARN)
        vim.notify("configuration valid (provider not verified)", vim.log.levels.INFO)
        return
      end

      -- check if provider exists in models.dev
      if data[config.provider] then
        vim.notify(
          "  provider: '" .. config.provider .. "' is valid",
          vim.log.levels.INFO
        )

        -- optionally validate model if configured
        if config.model then
          local provider_data = data[config.provider]
          if provider_data.models and provider_data.models[config.model] then
            vim.notify(
              "  model: '" .. config.model .. "' is valid",
              vim.log.levels.INFO
            )
          else
            vim.notify(
              "  model: '" .. config.model .. "' not found in " .. config.provider,
              vim.log.levels.WARN
            )
          end
        end

        vim.notify("configuration valid", vim.log.levels.INFO)
      else
        -- provider not found - list similar ones
        local suggestions = {}
        for provider_name, _ in pairs(data) do
          if provider_name:find(config.provider, 1, true) or
             config.provider:find(provider_name, 1, true) then
            table.insert(suggestions, provider_name)
          end
        end

        local msg = "  provider: '" .. config.provider .. "' not found in models.dev"
        if #suggestions > 0 then
          msg = msg .. "\n  did you mean: " .. table.concat(suggestions, ", ") .. "?"
        end
        vim.notify(msg, vim.log.levels.WARN)
        vim.notify("configuration has warnings", vim.log.levels.WARN)
      end
    end, { timeout = 10 })
  end)
end

--------------------------------------------------------------------------------
-- Test Interface (exposed for unit testing only)
--------------------------------------------------------------------------------

--- Internal functions exposed for testing.
--- Not part of the public API - may change without notice.
---@class InlineTestInterface
---@field parse_response fun(response: string): number|nil, number|nil, string[]|nil, string|nil
---@field strip_code_fences fun(text: string): string
---@field parse_ss_line fun(line: string): PortCandidate|nil
---@field parse_ss_output fun(ss_output: string): PortCandidate[]
---@field find_port_for_cwd fun(candidates: PortCandidate[], target_cwd: string, resolver: function): number|nil
---@field get_buffer_queues fun(): table<number, QueuedRequest[]>
---@field get_busy_buffers fun(): table<number, boolean>
---@field is_buffer_busy fun(bufnr: number): boolean
---@field get_queue_length fun(bufnr: number): number
---@field clear_all_state fun(): nil
---@field clear_port_cache fun(): nil
M._test = {
  parse_response = parse_response,
  strip_code_fences = strip_code_fences,

  -- port discovery functions
  parse_ss_line = parse_ss_line,
  parse_ss_output = parse_ss_output,
  find_port_for_cwd = find_port_for_cwd,

  -- queue state accessors for testing
  get_buffer_queues = function()
    return buffer_queues
  end,
  get_busy_buffers = function()
    return busy_buffers
  end,
  is_buffer_busy = function(bufnr)
    return busy_buffers[bufnr] == true
  end,
  get_queue_length = function(bufnr)
    local queue = buffer_queues[bufnr]
    return queue and #queue or 0
  end,
  -- reset all state for clean test isolation
  clear_all_state = function()
    buffer_queues = {}
    busy_buffers = {}
    for key, job_state in pairs(active_jobs) do
      pcall(cancel_job, job_state.job_id)
      pcall(stop_spinner, job_state.bufnr, job_state.lnum)
      active_jobs[key] = nil
    end
    spinners = {}
  end,
  -- clear cached port for testing
  clear_port_cache = function()
    discovered_port = nil
  end,
}

return M
