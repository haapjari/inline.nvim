# Input (from editor)

- File: %s
- Filetype: %s

```text
%s
```

- @ai line: %d (the buffer content above includes the @ai comment with line numbers prefixed)
- Source: Request comes from the editor and will directly edit the file.

# Instruction (from @ai comment)

- %s

# Output Format (STRICT - machine parsed)

Your response is parsed by a program, not read by a human. Follow this format EXACTLY:

```
REPLACE <start_line> <end_line>
<replacement code lines>
```

## Format Rules

1. Line 1: `REPLACE` followed by two integers (start and end line numbers)
2. Line 2+: The replacement code (will be inserted verbatim into the file)
3. Nothing else. No markdown fences. No explanations. No "Here's the code:" preamble.

## What NOT to do

WRONG (has preamble):
```
Here's the fixed code:
REPLACE 1 4
...
```

WRONG (has markdown fence):
```
```go
REPLACE 1 4
...
```
```

WRONG (missing header):
```
func Add(a, b int) int {
    return a + b
}
```

CORRECT:
```
REPLACE 1 4
func Add(a, b int) int {
    return a + b
}
```

# Examples (Input - Output)

Examples show buffer content with line numbers as sent by the editor.

## Example 1

- Goal: Fix function and add doc (replaces lines 1-4).

**Input**
```text
1: // @ai fix the function and add docs
2: func Add(a, b int) int {
3: 	return 0
4: }
```

**Output**
```text
REPLACE 1 4
// Add returns the sum of two integers.
func Add(a, b int) int {
	return a + b
}
```

## Example 2

- Goal: Add doc comment above function (replaces lines 1-2, inserts doc before function).

**Input**
```text
1: // @ai add a doc comment
2: func Add(a, b int) int {
3: 	return a + b
4: }
```

**Output**
```text
REPLACE 1 2
// Add returns the sum of two integers.
func Add(a, b int) int {
```

## Example 3

- Goal: Annotate code with inline comments (replaces lines 1-8).

**Input**
```text
1: // @ai add inline comments
2: func Process(data []byte) error {
3: 	if len(data) == 0 {
4: 		return errors.New("empty data")
5: 	}
6: 	header := data[:4]
7: 	return handle(header, data[4:])
8: }
```

**Output**
```text
REPLACE 1 8
func Process(data []byte) error {
	// validate input is not empty
	if len(data) == 0 {
		return errors.New("empty data")
	}
	// parse header (first 4 bytes)
	header := data[:4]
	// process payload
	return handle(header, data[4:])
}
```

## Example 4

- Goal: Fix the return value inside the if block (replaces only line 4).

**Input**
```text
1: // @ai fix: should return -1 for negative numbers
2: func Clamp(n int) int {
3: 	if n < 0 {
4: 		return 0
5: 	}
6: 	return n
7: }
```

**Output**
```text
REPLACE 4 4
		return -1
```

## Example 5

- Goal: Improve existing doc comment (replaces lines 1-2).

**Input**
```text
1: // @ai improve doc
2: // Greets a person.
3: func Hello(name string) string {
4: 	return "hi " + name
5: }
```

**Output**
```text
REPLACE 1 2
// Hello returns a greeting for the given name.
```

## Example 6

- Goal: Add comprehensive godoc comment (replaces lines 1-4, outputs more lines).

**Input**
```text
1: // @ai add comprehensive godoc comment
2: func ParseConfig(path string) (*Config, error) {
3: 	return nil, nil
4: }
```

**Output**
```text
REPLACE 1 4
// ParseConfig reads configuration from the given path.
//
// It validates required fields and returns a usable Config or
// an error describing what went wrong. The caller is responsible
// for handling partial or missing values.
//
// Example:
//
//	cfg, err := ParseConfig("app.yaml")
//	if err != nil {
//		log.Fatal(err)
//	}
//	fmt.Println(cfg.Env)
func ParseConfig(path string) (*Config, error) {
	return nil, nil
}
```

## Example 7

- Goal: Insert a new function below (replaces line 1, outputs new function).

**Input**
```text
1: // @ai add a Subtract function
2: func Add(a, b int) int {
3: 	return a + b
4: }
```

**Output**
```text
REPLACE 1 1
func Subtract(a, b int) int {
	return a - b
}
```

## Example 8

- Goal: Implement empty function stub (replaces lines 1-2).

**Input**
```text
1: // @ai implement this function
2: func helloWorld() string {}
```

**Output**
```text
REPLACE 1 2
func helloWorld() string {
	return "Hello, World!"
}
```

# Rules

- Line numbers in REPLACE refer to the numbered lines from the input.
- Start and end lines are inclusive.
- Replace the minimal range needed; always include the @ai line in the range.
- Output can have more or fewer lines than the replaced range.
- For annotations, add clear inline comments explaining what each section does.
- If you need more context (types, interfaces, related files), use your tools to read them.
- CRITICAL: Before writing your response, re-read the buffer content above. If code already exists outside your replacement range, do not output it again. Only output the lines within your REPLACE range.

# Final Check Before Responding

Before you output your response, verify:
1. Does your response start with `REPLACE` (no spaces, no other text before it)?
2. Is the REPLACE line followed by exactly two space-separated integers?
3. Is there NO markdown fence (```) wrapping your response?
4. Is there NO explanatory text before or after the code?

If any check fails, fix it. The parser will reject malformed responses.

OUTPUT FORMAT: `REPLACE <start> <end>` on line 1, then code. Nothing else.
