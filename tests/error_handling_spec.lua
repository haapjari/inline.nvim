-- tests for inline.nvim error handling
-- run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local inline = require("inline")

describe("inline.nvim error handling", function()
  before_each(function()
    -- reset config before each test
    inline.setup({})
  end)

  describe("config validation", function()
    it("accepts valid configuration", function()
      -- should not produce errors
      local notified_error = false
      local original_notify = vim.notify
      vim.notify = function(_msg, level)
        if level == vim.log.levels.ERROR then
          notified_error = true
        end
      end

      inline.setup({
        host = "127.0.0.1",
        port = 4096,
        provider = "anthropic",
        model = "claude-3-5-sonnet",
        agent = "build",
        timeout = 60,
      })

      vim.notify = original_notify
      assert.is_false(notified_error)
    end)

    it("rejects invalid port (negative)", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ port = -1 })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("port must be a number between 1 and 65535", error_msg)
    end)

    it("rejects invalid port (too high)", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ port = 70000 })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("port must be a number between 1 and 65535", error_msg)
    end)

    it("rejects empty host", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ host = "" })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("host must be a non%-empty string", error_msg)
    end)

    it("rejects empty provider string", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ provider = "" })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("provider must be a non%-empty string or nil", error_msg)
    end)

    it("accepts nil provider", function()
      local notified_error = false
      local original_notify = vim.notify
      vim.notify = function(_msg, level)
        if level == vim.log.levels.ERROR then
          notified_error = true
        end
      end

      inline.setup({ provider = nil })

      vim.notify = original_notify
      assert.is_false(notified_error)
    end)

    it("rejects invalid timeout (negative)", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ timeout = -5 })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("timeout must be a positive number", error_msg)
    end)

    it("rejects invalid timeout (zero)", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ timeout = 0 })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("timeout must be a positive number", error_msg)
    end)

    it("rejects empty agent", function()
      local error_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        end
      end

      inline.setup({ agent = "" })

      vim.notify = original_notify
      assert.is_not_nil(error_msg)
      assert.matches("agent must be a non%-empty string", error_msg)
    end)
  end)

  describe("timeout configuration", function()
    it("stores timeout in config", function()
      inline.setup({ timeout = 120 })
      local cfg = inline.get_config()
      assert.equals(120, cfg.timeout)
    end)

    it("uses default timeout when not specified", function()
      inline.setup({})
      local cfg = inline.get_config()
      assert.is_nil(cfg.timeout) -- nil means use DEFAULT_REQUEST_TIMEOUT_SECS
    end)
  end)

  describe("cancel command", function()
    it("handles cancel when no active requests", function()
      local warn_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warn_msg = msg
        end
      end

      inline.cancel({ all = true })

      vim.notify = original_notify
      assert.is_not_nil(warn_msg)
      assert.matches("no active or queued requests to cancel", warn_msg)
    end)

    it("handles cancel at cursor with no active request", function()
      -- create a test buffer
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1", "line 2" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local warn_msg = nil
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN then
          warn_msg = msg
        end
      end

      inline.cancel({})

      vim.notify = original_notify
      assert.is_not_nil(warn_msg)
      assert.matches("no active or queued request found", warn_msg)

      -- cleanup
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)

--- Get a free port by binding to port 0 and releasing it.
--- The OS assigns an available port which we then close.
---@return number port A port that is guaranteed to be free
local function get_free_port()
  local socket = vim.uv.new_tcp()
  socket:bind("127.0.0.1", 0)
  local addr = socket:getsockname()
  local port = addr.port
  socket:close()
  return port
end

describe("inline.nvim server errors", function()
  describe("health check", function()
    it("reports connection refused gracefully", function()
      -- get a free port that definitely has no server
      local free_port = get_free_port()

      inline.setup({
        host = "127.0.0.1",
        port = free_port,
        timeout = 1,
      })

      local error_msg = nil
      local original_notify = vim.notify

      vim.notify = function(msg, level)
        if level == vim.log.levels.ERROR then
          error_msg = msg
        elseif level == vim.log.levels.INFO and msg:match("not available") then
          error_msg = msg
        end
      end

      -- run status check (which uses check_health)
      inline.status()

      -- wait for async operation (up to 3 seconds)
      vim.wait(3000, function()
        return error_msg ~= nil
      end, 100)

      vim.notify = original_notify

      -- should have received some error message about server not available
      assert.is_not_nil(error_msg)
    end)
  end)
end)

describe("inline.nvim run errors", function()
  before_each(function()
    inline.setup({})
  end)

  it("warns when no @ai comment found", function()
    -- create a test buffer without @ai comment
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "function test()",
      "  -- no ai comment here",
      "end",
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local warn_msg = nil
    local original_notify = vim.notify
    vim.notify = function(msg, level)
      if level == vim.log.levels.WARN then
        warn_msg = msg
      end
    end

    inline.run()

    vim.notify = original_notify
    assert.is_not_nil(warn_msg)
    assert.matches("no @ai comment found", warn_msg)

    -- cleanup
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
