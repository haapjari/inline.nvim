-- tests for inline.nvim response parsing
-- run with: nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

local inline = require("inline")

describe("inline.nvim response parsing", function()
  local parse_response = inline._test.parse_response
  local strip_code_fences = inline._test.strip_code_fences

  describe("strip_code_fences", function()
    it("removes opening fence with language", function()
      local input = "```lua\nlocal x = 1\n```"
      local result = strip_code_fences(input)
      assert.equals("local x = 1", result)
    end)

    it("removes opening fence without language", function()
      local input = "```\nlocal x = 1\n```"
      local result = strip_code_fences(input)
      assert.equals("local x = 1", result)
    end)

    it("handles text without fences", function()
      local input = "local x = 1"
      local result = strip_code_fences(input)
      assert.equals("local x = 1", result)
    end)

    it("removes fence with text language marker", function()
      local input = "```text\nREPLACE 1 4\ncode\n```"
      local result = strip_code_fences(input)
      assert.equals("REPLACE 1 4\ncode", result)
    end)
  end)

  describe("parse_response", function()
    describe("valid responses", function()
      it("parses basic REPLACE format", function()
        local response = "REPLACE 1 4\nfunc Add(a, b int) int {\n\treturn a + b\n}"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(3, #code_lines)
        assert.equals("func Add(a, b int) int {", code_lines[1])
        assert.equals("\treturn a + b", code_lines[2])
        assert.equals("}", code_lines[3])
      end)

      it("parses single line replacement", function()
        local response = "REPLACE 4 4\n\t\treturn -1"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(4, start_line)
        assert.equals(4, end_line)
        assert.equals(1, #code_lines)
        assert.equals("\t\treturn -1", code_lines[1])
      end)

      it("handles empty code (delete operation)", function()
        local response = "REPLACE 1 3"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(3, end_line)
        assert.equals(0, #code_lines)
      end)

      it("handles large line numbers", function()
        local response = "REPLACE 150 200\ncode here"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(150, start_line)
        assert.equals(200, end_line)
        assert.equals(1, #code_lines)
      end)
    end)

    describe("handles model quirks", function()
      it("handles markdown fences around response", function()
        local response = "```text\nREPLACE 1 4\nfunc Add() int {\n\treturn 1\n}\n```"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(3, #code_lines)
      end)

      it("handles preamble text before REPLACE", function()
        local response = "Here's the code:\nREPLACE 1 4\nfunc Add() int {\n\treturn 1\n}"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(3, #code_lines)
        assert.equals("func Add() int {", code_lines[1])
      end)

      it("handles multiple preamble lines", function()
        local response = "I'll fix this for you.\n\nHere's the corrected code:\n\nREPLACE 1 2\nfixed code"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(2, end_line)
        assert.equals(1, #code_lines)
        assert.equals("fixed code", code_lines[1])
      end)

      it("handles leading whitespace on REPLACE line", function()
        local response = "  REPLACE 1 4\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
      end)

      it("handles trailing whitespace on REPLACE line", function()
        local response = "REPLACE 1 4  \ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
      end)

      it("handles case-insensitive REPLACE", function()
        local response = "Replace 1 4\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
      end)

      it("handles lowercase replace", function()
        local response = "replace 1 4\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
      end)

      it("handles mixed case REPLACE", function()
        local response = "RePlAcE 5 10\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(5, start_line)
        assert.equals(10, end_line)
      end)

      it("strips trailing empty lines", function()
        local response = "REPLACE 1 2\ncode\n\n\n"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, #code_lines)
        assert.equals("code", code_lines[1])
      end)

      it("preserves intentional empty lines in code", function()
        local response = "REPLACE 1 4\nfunc A() {\n\n\treturn\n}"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(4, #code_lines)
        assert.equals("func A() {", code_lines[1])
        assert.equals("", code_lines[2])
        assert.equals("\treturn", code_lines[3])
        assert.equals("}", code_lines[4])
      end)
    end)

    describe("error cases", function()
      it("returns error for empty response", function()
        local start_line, end_line, code_lines, err = parse_response("")

        assert.is_nil(start_line)
        assert.is_nil(end_line)
        assert.is_nil(code_lines)
        assert.equals("empty response", err)
      end)

      it("returns error for whitespace-only response", function()
        local start_line, end_line, code_lines, err = parse_response("   \n\n   ")

        assert.is_nil(start_line)
        assert.is_nil(end_line)
        assert.is_nil(code_lines)
        -- whitespace-only lines still result in missing header error
        assert.matches("missing REPLACE header", err)
      end)

      it("returns error when REPLACE header is missing", function()
        local response = "func Add() int {\n\treturn 1\n}"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(start_line)
        assert.is_nil(end_line)
        assert.is_nil(code_lines)
        assert.is_not_nil(err)
        assert.matches("missing REPLACE header", err)
      end)

      it("returns error for REPLACE without line numbers", function()
        local response = "REPLACE\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(start_line)
        assert.matches("missing REPLACE header", err)
      end)

      it("returns error for REPLACE with only one line number", function()
        local response = "REPLACE 1\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(start_line)
        assert.matches("missing REPLACE header", err)
      end)

      it("returns error for REPLACE with non-numeric arguments", function()
        local response = "REPLACE one four\ncode"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(start_line)
        assert.matches("missing REPLACE header", err)
      end)

      it("includes first content in error message", function()
        local response = "This is my answer:\nfunc Add() int {}"
        local _, _, _, err = parse_response(response)

        assert.matches("got: This is my answer:", err)
      end)

      it("truncates long first line in error", function()
        local long_line = string.rep("a", 100)
        local response = long_line .. "\ncode"
        local _, _, _, err = parse_response(response)

        -- should be truncated to ~50 chars
        assert.is_not_nil(err)
        assert.is_true(#err < 100)
      end)
    end)

    describe("edge cases", function()
      it("handles CRLF line endings", function()
        local response = "REPLACE 1 2\r\ncode line 1\r\ncode line 2"
        -- note: gmatch with [^\n]* will include \r, which is fine for our use case
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(2, end_line)
      end)

      it("handles REPLACE followed by extra text on same line", function()
        -- this should NOT match because there's extra text after the numbers
        local response = "REPLACE 1 4 extra text\ncode"
        local start_line, _, _, err = parse_response(response)

        assert.is_nil(start_line)
        assert.matches("missing REPLACE header", err)
      end)

      it("does not match REPLACE within code", function()
        -- REPLACE should only match at start of line (after trimming)
        local response = "REPLACE 1 4\ncode with REPLACE 5 6 inside"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(1, #code_lines)
        assert.equals("code with REPLACE 5 6 inside", code_lines[1])
      end)

      it("uses first REPLACE header when multiple present", function()
        -- if model outputs multiple REPLACE headers, use the first one
        local response = "REPLACE 1 4\ncode\nREPLACE 10 20\nmore code"
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        -- second REPLACE becomes part of code
        assert.equals(3, #code_lines)
        assert.equals("code", code_lines[1])
        assert.equals("REPLACE 10 20", code_lines[2])
        assert.equals("more code", code_lines[3])
      end)

      it("handles zero as start line", function()
        -- edge case: line 0 (unusual but should parse)
        local response = "REPLACE 0 5\ncode"
        local start_line, end_line, _, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(0, start_line)
        assert.equals(5, end_line)
      end)
    end)

    describe("real-world model outputs", function()
      it("handles typical clean response", function()
        local response = [[REPLACE 1 4
// Add returns the sum of two integers.
func Add(a, b int) int {
	return a + b
}]]
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(4, #code_lines)
        assert.equals("// Add returns the sum of two integers.", code_lines[1])
      end)

      it("handles response with chatty preamble", function()
        local response = [[I'll help you fix this function. Here's the corrected version:

REPLACE 1 4
func Add(a, b int) int {
	return a + b
}]]
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(3, #code_lines)
      end)

      it("handles response wrapped in markdown code block", function()
        local response = [[```
REPLACE 1 4
func Add(a, b int) int {
	return a + b
}
```]]
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
        assert.equals(3, #code_lines)
      end)

      it("handles response with language-specific code block", function()
        local response = [[```go
REPLACE 1 4
func Add(a, b int) int {
	return a + b
}
```]]
        local start_line, end_line, code_lines, err = parse_response(response)

        assert.is_nil(err)
        assert.equals(1, start_line)
        assert.equals(4, end_line)
      end)
    end)
  end)
end)
