local lib = require("neotest.lib")
local logger = require("neotest.logging")
local async = require("neotest.async")

local config = require("neotest-minitest.config")
local utils = require("neotest-minitest.utils")

---@class neotest.Adapter
---@field name string
local NeotestAdapter = { name = "neotest-minitest" }

---Find the project root directory given a current directory to work from.
---Should no root be found, the adapter can still be used in a non-project context if a test file matches.
---@async
---@param dir string @Directory to treat as cwd
---@return string | nil @Absolute root dir of test suite
NeotestAdapter.root = lib.files.match_root_pattern("Gemfile", ".gitignore")

---@async
---@param file_path string
---@return boolean
function NeotestAdapter.is_test_file(file_path)
  return vim.endswith(file_path, "_test.rb") or string.match(file_path, "/test_.+%.rb$") ~= nil
end

---Filter directories when searching for test files
---@async
---@param name string Name of directory
---@param rel_path string Path to directory, relative to root
---@param root string Root directory of project
---@return boolean
function NeotestAdapter.filter_dir(name, rel_path, root)
  return name ~= "vendor"
end

---Given a file path, parse all the tests within it.
---@async
---@param file_path string Absolute file path
---@return neotest.Tree | nil
function NeotestAdapter.discover_positions(file_path)
  local query = [[
    ; Classes that inherit from Minitest::Test
    ((
      class
      name: (constant) @namespace.name
      (superclass (scope_resolution) @superclass (#match? @superclass "^Minitest::Test"))
    )) @namespace.definition

    ; System tests that inherit from ApplicationSystemTestCase
    ((
        class 
        name: [
          (constant) @namespace.name 
          (scope_resolution scope: (constant) name: (constant) @namespace.name)
        ]
        (superclass) @superclass (#match? @superclass "(ApplicationSystemTestCase)$" )
    )) @namespace.definition

    ; Methods that begin with test_
    ((
      method
      name: (identifier) @test.name (#match? @test.name "^test_")
    )) @test.definition

    ; rails unit classes
    ((
        class
        name: [
          (constant) @namespace.name
          (scope_resolution scope: (constant) name: (constant) @namespace.name)
        ]
        (superclass (scope_resolution) @superclass (#match? @superclass "(::IntegrationTest|::TestCase|::SystemTestCase)$"))
    )) @namespace.definition

    ((
      call
      method: (identifier) @func_name (#match? @func_name "^(describe|context)$")
      arguments: (argument_list (string (string_content) @namespace.name))
    )) @namespace.definition

    ((
      call
      method: (identifier) @namespace.name (#match? @namespace.name "^(describe|context)$")
      .
      block: (_)
    )) @namespace.definition

    ((
      call
      method: (identifier) @func_name (#match? @func_name "^(test)$")
      arguments: (argument_list (string (string_content) @test.name))
    )) @test.definition

    ((
      call
      method: (identifier) @func_name (#match? @func_name "^(it)$")
      arguments: (argument_list (string (string_content) @test.name))
    )) @test.definition

    ((
      call
      method: (identifier) @func_name (#match? @func_name "^(should)$")
      arguments: (argument_list (string (string_content) @test.name))
    )) @test.definition

    ; shoulda-matchers form: `should belong_to(:cycle)`, `should have_many(...)`, etc.
    ; Matched by accepting a method-call (or chained calls) instead of a string literal.
    ((
      call
      method: (identifier) @func_name (#match? @func_name "^(should)$")
      arguments: (argument_list (call) @test.name)
    )) @test.definition

    ; Project-specific class-method test helpers, e.g. `it_requires_authentication { ... }`.
    ; The identifier itself is captured as the test name; downstream code derives the
    ; runtime description (e.g. "require authentication") from the suffix.
    ((
      call
      method: (identifier) @test.name (#match? @test.name "^it_requires_[a-z_]+$")
      block: (_)
    )) @test.definition
  ]]

  return lib.treesitter.parse_positions(file_path, query, {
    nested_tests = true,
    require_namespaces = true,
    position_id = "require('neotest-minitest.utils').generate_treesitter_id",
  })
end

---@param args neotest.RunArgs
---@return nil | neotest.RunSpec | neotest.RunSpec[]
function NeotestAdapter.build_spec(args)
  local script_args = {}
  local position = args.tree:data()
  local results_path = config.results_path()
  local spec_path = config.transform_spec_path(position.path)

  local name_mappings, prefix_mappings = utils.get_mappings(args.tree)

  local function run_by_filename()
    table.insert(script_args, spec_path)
  end

  local function run_by_name()
    local run_patterns = utils.full_shoulda_run_patterns(args.tree)
    table.insert(script_args, spec_path)
    table.insert(script_args, "--name")

    local pattern
    if run_patterns then
      -- shoulda-matcher / it_requires_* form: the position name is the matcher source
      -- expression, which can span multiple lines and contain unbalanced parens, colons,
      -- quotes, etc. Piping that through full_spec_name / full_test_name /
      -- full_shoulda_test_name produces malformed regex alternatives that minitest can't
      -- match against anything (or worse, fails to parse). The runtime test method name
      -- has no relationship to the source expression for these forms anyway — only the
      -- description-derived prefix patterns do. Use those alone.
      local alts = {}
      for _, run_pattern in ipairs(run_patterns) do
        table.insert(alts, run_pattern:gsub("([?])", "\\%1"))
      end
      pattern = "/" .. table.concat(alts, "|") .. "/"
    else
      local full_spec_name = utils.full_spec_name(args.tree)
      local full_test_name = utils.escaped_full_test_name(args.tree)
      local full_shoulda_test_name = utils.escaped_full_shoulda_test_name(args.tree)
      -- https://chriskottom.com/articles/command-line-flags-for-minitest-in-the-raw/
      -- Shoulda-context method symbols end with a literal space (e.g. :"test_: X should
      -- Y. "). Minitest compares the filter regex against "#{klass}##{method}", so the
      -- suffix alternative must end with that trailing space.
      pattern = "/^"
        .. full_spec_name
        .. "|"
        .. full_test_name
        .. "|"
        .. full_shoulda_test_name
        .. " $/"
    end
    table.insert(script_args, pattern)
  end

  -- When true, replaces config.get_test_cmd() with `bundle exec bin/rails test` for
  -- dir runs. Set inside run_dir() if the project root contains a bin/rails stub.
  local use_rails_test_runner = false

  local function run_dir()
    local tree = args.tree
    local root = tree:root():data().path
    local rails_bin = root .. "/bin/rails"

    if vim.loop.fs_stat(rails_bin) then
      -- Rails project: defer to `bin/rails test <files>`. This routes through
      -- Rails' own test runner, which shares Rails boot across files, manages
      -- fixtures, and supports parallel workers — none of which work cleanly
      -- under bare `ruby -Itest -e '<require loop>'` once the test tree gets
      -- past trivial size (the require-storm deadlocks against PTY in pry/
      -- parallel-executor setup for larger Rails apps).
      use_rails_test_runner = true
      for _, node in tree:iter_nodes() do
        if node:data().type == "file" then
          table.insert(script_args, node:data().path)
        end
      end
      return
    end

    -- Non-Rails project: emulate Rake::TestTask with loader=:direct and
    -- rake_test_loader.
    table.insert(script_args, "-e")
    table.insert(script_args, "while (f = ARGV.shift) != '--'; require f; end")

    -- Instruct Ruby to stop parsing options
    table.insert(script_args, "--")

    for _, node in tree:iter_nodes() do
      if node:data().type == "file" then
        local path = node:data().path
        table.insert(script_args, path)
      end
    end

    -- Mark the end of test files
    table.insert(script_args, "--")
  end

  local function dap_strategy(command)
    local port = math.random(49152, 65535)
    port = config.port or port

    local rdbg_args = {
      "-O",
      "--port",
      port,
      "-c",
      "-e",
      "cont",
      "--",
    }

    for i = 1, #command do
      rdbg_args[#rdbg_args + 1] = command[i]
    end

    return {
      name = "Neotest Debugger",
      type = "ruby",
      bundle = "bundle",
      localfs = true,
      request = "attach",
      args = rdbg_args,
      command = "rdbg",
      cwd = "${workspaceFolder}",
      port = port,
    }
  end

  if position.type == "file" then run_by_filename() end

  if position.type == "test" or position.type == "namespace" then run_by_name() end

  if position.type == "dir" then run_dir() end

  local cmd_prefix
  if use_rails_test_runner then
    cmd_prefix = { "bundle", "exec", "bin/rails", "test" }
  else
    cmd_prefix = config.get_test_cmd()
  end

  local command = vim.iter({
    cmd_prefix,
    script_args,
    "-v",
  }):flatten():totable()

  local stream = NeotestAdapter._make_status_stream(name_mappings, prefix_mappings)

  if args.strategy == "dap" then
    return {
      command = command,
      context = {
        results_path = results_path,
        pos_id = position.id,
        name_mappings = name_mappings,
        prefix_mappings = prefix_mappings,
      },
      strategy = dap_strategy(command),
      stream = stream,
    }
  else
    return {
      cwd = nil,
      command = command,
      context = {
        results_path = results_path,
        pos_id = position.id,
        name_mappings = name_mappings,
        prefix_mappings = prefix_mappings,
      },
      stream = stream,
    }
  end
end

local iter_test_output_error = function(output)
  local header_pattern = "Failure:%s*"
  local filepath_pattern = "%s+%[([^%]]+)]:%s*"
  local result_pattern = "Expected:%s*(.-)%s*Actual:%s*(.-)%s"

  -- keep track of last test error position
  local last_pos = 0

  return function()
    -- find error header
    local h_start, h_end = string.find(output, header_pattern, last_pos)
    if h_start == nil or h_end == nil then return nil, nil, nil, nil end

    -- find file path
    local f_start, f_end = string.find(output, filepath_pattern, h_end)
    if f_start == nil or f_end == nil then return nil, nil, nil, nil end

    -- extract file path
    local filepath = string.match(output, filepath_pattern, f_start)

    -- extract test name
    local test_name = string.sub(output, h_end + 1, f_start - 1)

    -- find expected and result
    local expected, actual = string.match(output, result_pattern, f_end)

    -- keep track of last test error position
    last_pos = f_end

    return test_name, filepath, expected, actual
  end
end

-- Matches both vanilla minitest verbose output (`Class#m = 0.00 s = .`) and
-- minitest-reporters' default verbose output (`Class#m 0.40 = .`). The leading
-- `=` and the `s` time-unit suffix are optional.
local status_line_pattern = "%s*=?%s*[%d.]+%s*s?%s*=%s*([FE.])"

local iter_test_output_status = function(output)
  local pattern = status_line_pattern

  -- keep track of last test result position
  local last_pos = 0

  return function()
    -- find test result
    local r_start, r_end = string.find(output, pattern, last_pos)
    if r_start == nil or r_end == nil then return nil, nil end

    -- extract status from test results
    local test_status = string.match(output, pattern, r_start)

    -- find test name
    --
    -- iterate backwards through output until we find a newline or start of output.
    local n_start = 0
    for i = r_start, 0, -1 do
      if string.sub(output, i, i) == "\n" then
        n_start = i + 1
        break
      end
    end
    local test_name = string.sub(output, n_start, r_start - 1)

    -- keep track of last test result position
    last_pos = r_end

    return test_name, test_status
  end
end

-- Tries an exact lookup in name_mappings first (after stripping module prefixes if
-- needed). Falls back to scanning prefix_mappings for any prefix that is a literal
-- prefix of the test_name. Returns the matching pos_id or nil.
local function lookup_pos_id(test_name, name_mappings, prefix_mappings)
  local pos_id = name_mappings[test_name]
  if pos_id then return pos_id end

  local stripped = utils.replace_module_namespace(test_name)
  if name_mappings[stripped] then return name_mappings[stripped] end

  if prefix_mappings then
    for prefix, prefix_pos_id in pairs(prefix_mappings) do
      if test_name:sub(1, #prefix) == prefix or stripped:sub(1, #prefix) == prefix then
        return prefix_pos_id
      end
    end
  end

  return nil
end

function NeotestAdapter._parse_test_output(output, name_mappings, prefix_mappings)
  local results = {}
  local error_pattern = "Error:%s*([%w:#_]+):%s*(.-)\n[%w%W]-%.rb:(%d+):"
  local traceback_pattern = "(%d+:[^:]+:%d+:in `[^']+')%s+([^:]+):(%d+):(in `[^']+':[^\n]+)"

  for _, _, line_str, message in string.gmatch(output, traceback_pattern) do
    local line = tonumber(line_str)
    for _, pos_id in pairs(name_mappings) do
      results[pos_id] = {
        status = "failed",
        errors = {
          {
            message = message,
            line = line - 1,
          },
        },
      }
    end
  end

  for test_name, status in iter_test_output_status(output) do
    local pos_id = lookup_pos_id(test_name, name_mappings, prefix_mappings)

    if pos_id then
      local new_status = status == "." and "passed" or "failed"
      -- Composite helpers like `it_requires_all_auth` map several runtime tests to a
      -- single pos_id. Preserve "failed" if it was already set so any sub-test failure
      -- propagates to the line, rather than the last-processed sub-test winning.
      if not results[pos_id] or results[pos_id].status ~= "failed" then
        results[pos_id] = { status = new_status }
      end
    end
  end

  for test_name, filepath, expected, actual in iter_test_output_error(output) do
    local message = string.format("Expected: %s\n  Actual: %s", expected, actual)

    local pos_id = lookup_pos_id(test_name, name_mappings, prefix_mappings)

    local line = tonumber(string.match(filepath, ":(%d+)$"))
    if results[pos_id] then
      results[pos_id].status = "failed"
      results[pos_id].errors = {
        {
          message = message,
          line = line - 1,
        },
      }
    end
  end

  for test_name, message, line_str in string.gmatch(output, error_pattern) do
    local line = tonumber(line_str)
    local pos_id = lookup_pos_id(test_name, name_mappings, prefix_mappings)
    if pos_id and results[pos_id] then
      results[pos_id].status = "failed"
      results[pos_id].errors = {
        {
          message = message,
          line = line - 1, -- neovim lines are 0 indexed
        },
      }
    end
  end

  return results
end

-- Builds the iterator passed as `spec.stream` to neotest's runner. Each iteration
-- consumes the next chunk from `output_stream` (which yields stdout as the test
-- process emits it), parses any complete lines for per-test status, and returns a
-- partial results table. Returning nil ends the iteration (process exit / EOF).
--
-- Per-test errors and tracebacks are intentionally not surfaced here — they're
-- multi-line and require the full output to parse safely. NeotestAdapter.results
-- runs on the captured output file at process exit and fills those in.
function NeotestAdapter._make_status_stream(name_mappings, prefix_mappings)
  return function(output_stream)
    local buffer = ""

    return function()
      local data = output_stream()
      if data == nil then return nil end
      if type(data) == "table" then data = table.concat(data, "\n") end

      buffer = buffer .. data

      local lines = {}
      local pos = 1
      while true do
        local nl = buffer:find("\n", pos, true)
        if not nl then break end
        lines[#lines + 1] = buffer:sub(pos, nl - 1)
        pos = nl + 1
      end
      buffer = buffer:sub(pos)

      local results = {}
      for _, raw_line in ipairs(lines) do
        local line = utils.strip_ansi_escape_codes(raw_line)
        local r_start, _, status = line:find(status_line_pattern)
        if r_start and status then
          local test_name = line:sub(1, r_start - 1)
          local pos_id = lookup_pos_id(test_name, name_mappings, prefix_mappings)
          if pos_id then
            local new_status = status == "." and "passed" or "failed"
            -- Same "failed sticks" semantic as _parse_test_output; needed so a composite
            -- helper position that's already failed mid-stream doesn't flip back to
            -- passed when a later sub-test passes.
            if not results[pos_id] or results[pos_id].status ~= "failed" then
              results[pos_id] = { status = new_status }
            end
          end
        end
      end

      return results
    end
  end
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function NeotestAdapter.results(spec, result, tree)
  local success, output = pcall(lib.files.read, result.output)
  if not success then
    logger.error("neotest-minitest: could not read output: " .. output)
    return {}
  end

  output = utils.strip_ansi_escape_codes(output)
  local results = NeotestAdapter._parse_test_output(
    output,
    spec.context.name_mappings,
    spec.context.prefix_mappings
  )

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(NeotestAdapter, {
  __call = function(_, opts)
    if is_callable(opts.test_cmd) then
      config.get_test_cmd = opts.test_cmd
    elseif opts.test_cmd then
      config.get_test_cmd = function()
        return opts.test_cmd
      end
    end
    if is_callable(opts.transform_spec_path) then
      config.transform_spec_path = opts.transform_spec_path
    elseif opts.transform_spec_path then
      config.transform_spec_path = function()
        return opts.transform_spec_path
      end
    end
    if is_callable(opts.results_path) then
      config.results_path = opts.results_path
    elseif opts.results_path then
      config.results_path = function()
        return opts.results_path
      end
    end
    return NeotestAdapter
  end,
})

return NeotestAdapter
