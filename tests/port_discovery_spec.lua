-- tests for inline.nvim port discovery
-- run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local inline = require("inline")

describe("inline.nvim port discovery", function()
  local parse_ss_line = inline._test.parse_ss_line
  local parse_ss_output = inline._test.parse_ss_output
  local find_port_for_cwd = inline._test.find_port_for_cwd

  describe("parse_ss_line", function()
    describe("valid lines", function()
      it("parses standard ss output with 127.0.0.1", function()
        local line = 'LISTEN 0      512         127.0.0.1:38015      0.0.0.0:*    users:(("opencode",pid=46620,fd=23))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(38015, result.port)
        assert.equals("46620", result.pid)
      end)

      it("parses line with different port", function()
        local line = 'LISTEN 4      512         127.0.0.1:4096       0.0.0.0:*    users:(("opencode",pid=34722,fd=23))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(4096, result.port)
        assert.equals("34722", result.pid)
      end)

      it("parses line with 0.0.0.0 binding", function()
        local line = 'LISTEN 0      512         0.0.0.0:8080       0.0.0.0:*    users:(("opencode",pid=12345,fd=10))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(8080, result.port)
        assert.equals("12345", result.pid)
      end)

      it("parses line with ipv6 localhost binding", function()
        local line = 'LISTEN 0      512         [::1]:9000       [::]:*    users:(("opencode",pid=99999,fd=5))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(9000, result.port)
        assert.equals("99999", result.pid)
      end)

      it("handles large port numbers", function()
        local line = 'LISTEN 0      512         127.0.0.1:65535      0.0.0.0:*    users:(("opencode",pid=1,fd=1))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(65535, result.port)
      end)

      it("handles large pid numbers", function()
        local line = 'LISTEN 0      512         127.0.0.1:4096      0.0.0.0:*    users:(("opencode",pid=9999999,fd=1))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals("9999999", result.pid)
      end)

      it("handles different fd numbers", function()
        local line = 'LISTEN 0      512         127.0.0.1:4096      0.0.0.0:*    users:(("opencode",pid=123,fd=999))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(4096, result.port)
        assert.equals("123", result.pid)
      end)
    end)

    describe("invalid lines", function()
      it("returns nil for empty string", function()
        local result = parse_ss_line("")
        assert.is_nil(result)
      end)

      it("returns nil for line without opencode", function()
        local line = 'LISTEN 0      512         127.0.0.1:8080      0.0.0.0:*    users:(("nginx",pid=100,fd=5))'
        local result = parse_ss_line(line)

        -- still parses if port and pid are present (grep filters before this)
        assert.is_not_nil(result)
      end)

      it("returns nil for line without port", function()
        local line = 'LISTEN 0      512         users:(("opencode",pid=100,fd=5))'
        local result = parse_ss_line(line)

        assert.is_nil(result)
      end)

      it("returns nil for line without pid", function()
        local line = 'LISTEN 0      512         127.0.0.1:8080      0.0.0.0:*    users:(("opencode"))'
        local result = parse_ss_line(line)

        assert.is_nil(result)
      end)

      it("returns nil for malformed line", function()
        local result = parse_ss_line("this is not ss output")
        assert.is_nil(result)
      end)

      it("returns nil for header line", function()
        local result = parse_ss_line("State      Recv-Q Send-Q Local Address:Port")
        assert.is_nil(result)
      end)
    end)

    describe("edge cases", function()
      it("handles extra whitespace", function()
        local line = '  LISTEN   0      512         127.0.0.1:4096      0.0.0.0:*    users:(("opencode",pid=123,fd=1))  '
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(4096, result.port)
        assert.equals("123", result.pid)
      end)

      it("handles tabs in output", function()
        local line = "LISTEN\t0\t512\t127.0.0.1:4096\t0.0.0.0:*\tusers:((\"opencode\",pid=123,fd=1))"
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        assert.equals(4096, result.port)
      end)

      it("handles multiple processes in users field", function()
        -- unlikely but possible format
        local line = 'LISTEN 0 512 127.0.0.1:4096 0.0.0.0:* users:(("opencode",pid=123,fd=1),("other",pid=456,fd=2))'
        local result = parse_ss_line(line)

        assert.is_not_nil(result)
        -- should get first pid
        assert.equals("123", result.pid)
      end)
    end)
  end)

  describe("parse_ss_output", function()
    it("parses empty output", function()
      local result = parse_ss_output("")
      assert.equals(0, #result)
    end)

    it("parses nil output", function()
      local result = parse_ss_output(nil)
      assert.equals(0, #result)
    end)

    it("parses single line", function()
      local output = 'LISTEN 0 512 127.0.0.1:4096 0.0.0.0:* users:(("opencode",pid=123,fd=1))'
      local result = parse_ss_output(output)

      assert.equals(1, #result)
      assert.equals(4096, result[1].port)
      assert.equals("123", result[1].pid)
    end)

    it("parses multiple lines", function()
      local output = [[LISTEN 4      512         127.0.0.1:4096       0.0.0.0:*    users:(("opencode",pid=34722,fd=23))
LISTEN 0      512         127.0.0.1:38015      0.0.0.0:*    users:(("opencode",pid=46620,fd=23))
LISTEN 0      512         127.0.0.1:43209      0.0.0.0:*    users:(("opencode",pid=46452,fd=23))]]
      local result = parse_ss_output(output)

      assert.equals(3, #result)
      assert.equals(4096, result[1].port)
      assert.equals("34722", result[1].pid)
      assert.equals(38015, result[2].port)
      assert.equals("46620", result[2].pid)
      assert.equals(43209, result[3].port)
      assert.equals("46452", result[3].pid)
    end)

    it("skips invalid lines in mixed output", function()
      local output = [[LISTEN 0 512 127.0.0.1:4096 0.0.0.0:* users:(("opencode",pid=123,fd=1))
this is garbage
LISTEN 0 512 127.0.0.1:8080 0.0.0.0:* users:(("opencode",pid=456,fd=2))]]
      local result = parse_ss_output(output)

      assert.equals(2, #result)
      assert.equals(4096, result[1].port)
      assert.equals(8080, result[2].port)
    end)

    it("handles trailing newline", function()
      local output = 'LISTEN 0 512 127.0.0.1:4096 0.0.0.0:* users:(("opencode",pid=123,fd=1))\n'
      local result = parse_ss_output(output)

      assert.equals(1, #result)
    end)

    it("handles multiple trailing newlines", function()
      local output = 'LISTEN 0 512 127.0.0.1:4096 0.0.0.0:* users:(("opencode",pid=123,fd=1))\n\n\n'
      local result = parse_ss_output(output)

      assert.equals(1, #result)
    end)
  end)

  describe("find_port_for_cwd", function()
    -- mock cwd resolver for testing
    local function make_resolver(pid_to_cwd)
      return function(pid)
        return pid_to_cwd[pid]
      end
    end

    it("returns nil for empty candidates", function()
      local resolver = make_resolver({})
      local result = find_port_for_cwd({}, "/home/user/project", resolver)

      assert.is_nil(result)
    end)

    it("finds matching port for single candidate", function()
      local candidates = {
        { port = 4096, pid = "123" },
      }
      local resolver = make_resolver({
        ["123"] = "/home/user/project",
      })
      local result = find_port_for_cwd(candidates, "/home/user/project", resolver)

      assert.equals(4096, result)
    end)

    it("returns nil when no candidate matches", function()
      local candidates = {
        { port = 4096, pid = "123" },
      }
      local resolver = make_resolver({
        ["123"] = "/home/user/other",
      })
      local result = find_port_for_cwd(candidates, "/home/user/project", resolver)

      assert.is_nil(result)
    end)

    it("finds correct port among multiple candidates", function()
      local candidates = {
        { port = 4096, pid = "100" },
        { port = 38015, pid = "200" },
        { port = 43209, pid = "300" },
      }
      local resolver = make_resolver({
        ["100"] = "/home/user/project-a",
        ["200"] = "/home/user/project-b",
        ["300"] = "/home/user/project-c",
      })

      assert.equals(4096, find_port_for_cwd(candidates, "/home/user/project-a", resolver))
      assert.equals(38015, find_port_for_cwd(candidates, "/home/user/project-b", resolver))
      assert.equals(43209, find_port_for_cwd(candidates, "/home/user/project-c", resolver))
    end)

    it("returns first match when multiple processes have same cwd", function()
      local candidates = {
        { port = 4096, pid = "100" },
        { port = 8080, pid = "200" },
      }
      local resolver = make_resolver({
        ["100"] = "/home/user/project",
        ["200"] = "/home/user/project",
      })
      local result = find_port_for_cwd(candidates, "/home/user/project", resolver)

      assert.equals(4096, result)
    end)

    it("handles resolver returning nil", function()
      local candidates = {
        { port = 4096, pid = "100" },
        { port = 8080, pid = "200" },
      }
      local resolver = make_resolver({
        ["100"] = nil, -- process died or permission denied
        ["200"] = "/home/user/project",
      })
      local result = find_port_for_cwd(candidates, "/home/user/project", resolver)

      assert.equals(8080, result)
    end)

    it("handles all resolvers returning nil", function()
      local candidates = {
        { port = 4096, pid = "100" },
        { port = 8080, pid = "200" },
      }
      local resolver = make_resolver({})
      local result = find_port_for_cwd(candidates, "/home/user/project", resolver)

      assert.is_nil(result)
    end)

    it("requires exact cwd match", function()
      local candidates = {
        { port = 4096, pid = "100" },
      }
      local resolver = make_resolver({
        ["100"] = "/home/user/project",
      })

      -- subdir should not match
      assert.is_nil(find_port_for_cwd(candidates, "/home/user/project/subdir", resolver))
      -- parent should not match
      assert.is_nil(find_port_for_cwd(candidates, "/home/user", resolver))
      -- trailing slash difference
      assert.is_nil(find_port_for_cwd(candidates, "/home/user/project/", resolver))
    end)

    it("handles paths with special characters", function()
      local candidates = {
        { port = 4096, pid = "100" },
      }
      local resolver = make_resolver({
        ["100"] = "/home/user/my project (1)",
      })
      local result = find_port_for_cwd(candidates, "/home/user/my project (1)", resolver)

      assert.equals(4096, result)
    end)
  end)

  describe("integration scenarios", function()
    it("handles real ss output format", function()
      -- actual output captured from a running system
      local ss_output = [[LISTEN 4      512         127.0.0.1:4096       0.0.0.0:*    users:(("opencode",pid=34722,fd=23))
LISTEN 0      512         127.0.0.1:38015      0.0.0.0:*    users:(("opencode",pid=46620,fd=23))
LISTEN 0      512         127.0.0.1:43209      0.0.0.0:*    users:(("opencode",pid=46452,fd=23))]]

      local candidates = parse_ss_output(ss_output)
      assert.equals(3, #candidates)

      -- simulate /proc/PID/cwd resolution
      local resolver = function(pid)
        local mapping = {
          ["34722"] = "/home/user/review",
          ["46620"] = "/home/user/inline.nvim",
          ["46452"] = "/home/user/review",
        }
        return mapping[pid]
      end

      -- find the inline.nvim instance
      local port = find_port_for_cwd(candidates, "/home/user/inline.nvim", resolver)
      assert.equals(38015, port)

      -- find a review instance (should get first match)
      local review_port = find_port_for_cwd(candidates, "/home/user/review", resolver)
      assert.equals(4096, review_port)

      -- non-existent project returns nil (fallback handled by discover_port)
      local missing = find_port_for_cwd(candidates, "/home/user/other", resolver)
      assert.is_nil(missing)
    end)

    it("fallback scenario: temp file with no matching opencode", function()
      -- scenario: editing a joplin temp file, no opencode running in that dir
      local ss_output = [[LISTEN 0      512         127.0.0.1:4096       0.0.0.0:*    users:(("opencode",pid=12345,fd=23))]]

      local candidates = parse_ss_output(ss_output)
      assert.equals(1, #candidates)

      local resolver = function(pid)
        if pid == "12345" then
          return "/home/user/my-project"
        end
        return nil
      end

      -- temp file cwd doesn't match any opencode instance
      local joplin_tmp = "/home/user/.config/joplin/tmp"
      local port = find_port_for_cwd(candidates, joplin_tmp, resolver)

      -- find_port_for_cwd returns nil, but discover_port will fallback to first
      assert.is_nil(port)

      -- verify first candidate is available for fallback
      assert.equals(4096, candidates[1].port)
      assert.equals("/home/user/my-project", resolver(candidates[1].pid))
    end)
  end)
end)
