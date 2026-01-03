-- tests for inline.nvim request queue behavior
-- run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local inline = require("inline")

describe("inline.nvim request queue", function()
  local test = inline._test

  -- reset state before each test
  before_each(function()
    test.clear_all_state()
  end)

  after_each(function()
    test.clear_all_state()
  end)

  describe("state accessors", function()
    it("initially has no busy buffers", function()
      assert.is_false(test.is_buffer_busy(1))
      assert.is_false(test.is_buffer_busy(999))
    end)

    it("initially has empty queues", function()
      assert.equals(0, test.get_queue_length(1))
      assert.equals(0, test.get_queue_length(999))
    end)

    it("get_buffer_queues returns empty table initially", function()
      local queues = test.get_buffer_queues()
      assert.is_table(queues)
      assert.is_nil(next(queues))
    end)

    it("get_busy_buffers returns empty table initially", function()
      local busy = test.get_busy_buffers()
      assert.is_table(busy)
      assert.is_nil(next(busy))
    end)
  end)

  describe("clear_all_state", function()
    it("resets all queue state", function()
      -- manually modify state
      local queues = test.get_buffer_queues()
      queues[1] = { { lnum = 5 } }
      local busy = test.get_busy_buffers()
      busy[1] = true

      -- verify state was modified
      assert.equals(1, test.get_queue_length(1))
      assert.is_true(test.is_buffer_busy(1))

      -- clear and verify
      test.clear_all_state()
      assert.equals(0, test.get_queue_length(1))
      assert.is_false(test.is_buffer_busy(1))
    end)
  end)

  describe("M.run() queueing behavior", function()
    -- these tests require a buffer with @ai comments
    local bufnr

    before_each(function()
      -- create a scratch buffer for testing
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
      vim.bo[bufnr].filetype = "lua"
    end)

    after_each(function()
      test.clear_all_state()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("rejects run when no @ai comment found", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "local x = 1",
        "local y = 2",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- capture notification
      local notified = false
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("no @ai comment found") then
          notified = true
        end
      end

      inline.run()

      vim.notify = orig_notify
      assert.is_true(notified)
    end)

    it("detects duplicate queued requests for same line", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "-- @ai: test instruction",
        "local x = 1",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- manually mark buffer as busy and add a request to queue
      local busy = test.get_busy_buffers()
      busy[bufnr] = true
      local queues = test.get_buffer_queues()
      queues[bufnr] = { { lnum = 1, original_line = "-- @ai: test instruction" } }

      -- capture notification
      local notified_already_queued = false
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("already queued") then
          notified_already_queued = true
        end
      end

      inline.run()

      vim.notify = orig_notify
      assert.is_true(notified_already_queued)
      -- queue should still have only 1 item
      assert.equals(1, test.get_queue_length(bufnr))
    end)

    it("rejects run when line is already processing", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "-- @ai: test instruction",
        "local x = 1",
      })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- simulate a spinner active on line 1 (indicates processing)
      -- we need to start a spinner to trigger is_processing check
      -- for this test, we'll check that M.run rejects duplicate line processing

      -- capture notification for "already processing"
      local notified_processing = false
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("already processing") then
          notified_processing = true
        end
      end

      -- first run will start processing (and fail due to no server)
      -- but that's okay, we're testing the guard
      inline.run()

      -- second run should detect the spinner and reject
      inline.run()

      vim.notify = orig_notify
      assert.is_true(notified_processing)
    end)
  end)

  describe("M.cancel() with queues", function()
    local bufnr

    before_each(function()
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(bufnr)
    end)

    after_each(function()
      test.clear_all_state()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("cancel all clears queues", function()
      -- set up queued requests
      local queues = test.get_buffer_queues()
      queues[bufnr] = {
        { lnum = 5, original_line = "-- @ai: test1" },
        { lnum = 10, original_line = "-- @ai: test2" },
      }
      local busy = test.get_busy_buffers()
      busy[bufnr] = true

      assert.equals(2, test.get_queue_length(bufnr))
      assert.is_true(test.is_buffer_busy(bufnr))

      inline.cancel({ all = true })

      assert.equals(0, test.get_queue_length(bufnr))
      assert.is_false(test.is_buffer_busy(bufnr))
    end)

    it("cancel at cursor removes queued request", function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "line 1",
        "line 2",
        "-- @ai: test instruction",
        "line 4",
        "line 5",
      })

      -- set up a queued request at line 3
      local queues = test.get_buffer_queues()
      queues[bufnr] = {
        { lnum = 3, original_line = "-- @ai: test instruction" },
      }
      local busy = test.get_busy_buffers()
      busy[bufnr] = true

      -- position cursor at line 3
      vim.api.nvim_win_set_cursor(0, { 3, 0 })

      -- capture notification
      local notified_cancelled = false
      local orig_notify = vim.notify
      vim.notify = function(msg, level)
        if msg:match("queued request cancelled") then
          notified_cancelled = true
        end
      end

      inline.cancel()

      vim.notify = orig_notify
      assert.is_true(notified_cancelled)
      assert.equals(0, test.get_queue_length(bufnr))
    end)
  end)
end)
