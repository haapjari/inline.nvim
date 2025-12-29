---@brief [[
--- inline.nvim
---@brief ]]

---@class Inline
---@field run fun(opts?: InlineRunOpts): nil Run inline AI on nearest @ai comment
---@field status fun(): nil Check OpenCode server health
---@field setup fun(opts?: InlineConfig): nil Configure the plugin
---@field get_config fun(): InlineConfig Return current configuration
---@field show_config fun(): nil Display current configuration
local M = {}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

--- spinner animation frames for loading indicator
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

--- spinner animation interval in milliseconds
local SPINNER_INTERVAL_MS = 80

--- curl connection timeout in seconds
local CURL_TIMEOUT_SECS = 2

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

local defaults = {
  host = "127.0.0.1",
  port = 4096,
  provider = nil,
  model = nil,
  agent = "build",
  agents = {},
  keymap = nil,
  prompt = nil,
  cache_prompt = nil,
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
local function clear_prompt_cache()
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

---Execute curl command asynchronously.
---Uses jobstart to avoid blocking the UI thread.
---@param args string[] Curl command arguments
---@param callback fun(result: string|nil, err: string|nil) Called with stdout or error
local function curl_async(args, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}

  vim.fn.jobstart(args, {
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
        if exit_code ~= 0 then
          callback(nil, "curl failed: " .. table.concat(stderr_chunks, "\n"))
        else
          callback(table.concat(stdout_chunks, ""), nil)
        end
      end)
    end,
  })
end

---Check OpenCode server health status.
---@param callback fun(healthy: boolean, version_or_err: string) Called with health result
local function check_health(callback)
  local url = string.format("http://%s:%d/global/health", config.host, config.port)

  curl_async({
    "curl",
    "-s",
    "--connect-timeout",
    tostring(CURL_TIMEOUT_SECS),
    url,
  }, function(result, err)
    if err then
      callback(false, err)
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      callback(false, "invalid response")
      return
    end

    -- check health status in response
    if data.healthy then
      callback(true, data.version or "unknown")
    else
      callback(false, "server unhealthy")
    end
  end)
end

---Create a new OpenCode session.
---@param callback fun(session_id: string|nil, err: string|nil) Called with session ID or error
local function create_session(callback)
  local url = string.format("http://%s:%d/session", config.host, config.port)

  -- build request body with optional provider/model overrides
  local session_opts = vim.empty_dict()
  if config.provider then
    session_opts.provider = config.provider
  end
  if config.model then
    session_opts.model = config.model
  end

  local body = vim.fn.json_encode(session_opts)

  curl_async({
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
      callback(nil, err)
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      callback(nil, "json decode failed: " .. result)
      return
    end

    -- validate session id exists
    if not data.id then
      callback(nil, "no session id in response: " .. result)
      return
    end

    callback(data.id, nil)
  end)
end

---Send message to OpenCode session.
---@param session_id string Session identifier
---@param message string Message content
---@param agent string|nil Agent name (optional)
---@param callback fun(response: string|nil, err: string|nil) Called with response text or error
local function send_message(session_id, message, agent, callback)
  local url = string.format(
    "http://%s:%d/session/%s/message",
    config.host,
    config.port,
    session_id
  )

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

  curl_async({
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
      callback(nil, err)
      return
    end

    -- parse json response
    local ok, data = pcall(vim.fn.json_decode, result)
    if not ok then
      callback(nil, "json decode failed: " .. result)
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

    callback(nil, "no parts in response: " .. result)
  end)
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
---@param response string Raw response text
---@return number|nil start_line Start line for replacement
---@return number|nil end_line End line for replacement
---@return string[]|nil code_lines Lines to insert
---@return string|nil err Error message if parsing failed
local function parse_response(response)
  -- strip markdown fences if present
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

  -- parse REPLACE header from first line
  local start_line, end_line = lines[1]:match("^REPLACE%s+(%d+)%s+(%d+)$")
  if not start_line then
    return nil, nil, nil, "missing REPLACE header: " .. lines[1]
  end

  -- extract code lines (everything after header)
  local code_lines = {}
  for i = 2, #lines do
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
-- Public API
--------------------------------------------------------------------------------

---@class InlineRunOpts
---@field agent string|nil Agent override for this request

---Run inline AI completion for the nearest @ai comment.
---Finds the @ai comment above cursor, sends request to OpenCode,
---and replaces the specified line range with the response.
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

  -- prevent concurrent runs on same line
  if is_processing(bufnr, lnum) then
    vim.notify("already processing this line", vim.log.levels.WARN)
    return
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

  -- build the prompt with all context
  local message = build_prompt(filename, filetype, buffer_content, lnum, instruction)

  -- start visual feedback
  start_spinner(bufnr, lnum)

  -- async chain: health check -> create session -> send message
  check_health(function(healthy, version_or_err)
    if not healthy then
      stop_spinner(bufnr, lnum)
      vim.notify("opencode server not available: " .. version_or_err, vim.log.levels.ERROR)
      return
    end

    create_session(function(session_id, err)
      if not session_id then
        stop_spinner(bufnr, lnum)
        vim.notify("error creating session: " .. err, vim.log.levels.ERROR)
        return
      end

      send_message(session_id, message, agent, function(response, send_err)
        stop_spinner(bufnr, lnum)

        if not response then
          vim.notify("error: " .. send_err, vim.log.levels.ERROR)
          return
        end

        -- verify @ai line wasn't modified during async operation
        local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local current_ai_line = current_lines[lnum]
        if current_ai_line ~= original_ai_line then
          vim.notify("@ai line was modified, response discarded", vim.log.levels.WARN)
          return
        end

        -- insert response into buffer
        insert_response(bufnr, lnum, response)
      end)
    end)
  end)
end

---Check OpenCode server health and display status.
function M.status()
  vim.notify("checking opencode server...", vim.log.levels.INFO)

  check_health(function(healthy, version_or_err)
    if healthy then
      vim.notify(
        string.format("opencode server: ok (v%s) at %s:%d", version_or_err, config.host, config.port),
        vim.log.levels.INFO
      )
    else
      vim.notify(
        string.format("opencode server: not available (%s)", version_or_err),
        vim.log.levels.ERROR
      )
    end
  end)
end

---Configure inline.nvim and register commands/keymaps.
---@param opts InlineConfig|nil User configuration options
function M.setup(opts)
  opts = opts or {}

  -- merge user options over defaults
  config = vim.tbl_deep_extend("force", defaults, opts)

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
    "inline.nvim config:",
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

return M
