local ok, async = pcall(require, "nio")
if not ok then async = require("neotest.async") end

local logger = require("neotest.logging")

local M = {}
local separator = "::"

--- Replace paths in a string
---@param str string
---@param what string
---@param with string
---@return string
local function replace_paths(str, what, with)
  -- Taken from: https://stackoverflow.com/a/29379912/3250992
  what = string.gsub(what, "[%(%)%.%+%-%*%?%[%]%^%$%%]", "%%%1") -- escape pattern
  with = string.gsub(with, "[%%]", "%%%%") -- escape replacement
  return string.gsub(str, what, with)
end

-- We are considering test class names without their module, but
-- Lua's built-in pattern matching isn't powerful enough to do so. Instead
-- we match on the full name, including module, and strip it off here.
--
-- @param test_name string
-- @return string
M.replace_module_namespace = function(test_name)
  return test_name.gsub(test_name, "%w+::", "")
end

---@param position neotest.Position The position to return an ID for
---@param parents neotest.Position[] Parent positions for the position
---@return string
M.generate_treesitter_id = function(position, parents)
  local cwd = async.fn.getcwd()
  local test_path = "." .. replace_paths(position.path, cwd, "")
  -- Treesitter starts line numbers from 0 so we subtract 1
  local id = test_path .. separator .. (tonumber(position.range[1]) + 1)

  return id
end

M.full_spec_name = function(tree)
  local name = ""
  local namespaces = {}
  local num_namespaces = 0

  if tree:data().type == "namespace" then
    table.insert(namespaces, 1, tree:data().name)
    num_namespaces = num_namespaces + 1
  else
    name = tree:data().name
  end

  for parent_node in tree:iter_parents() do
    local data = parent_node:data()
    if data.type == "namespace" then
      table.insert(namespaces, 1, parent_node:data().name)
      num_namespaces = num_namespaces + 1
    else
      break
    end
  end

  if num_namespaces == 0 then return name end

  -- build result
  local result = ""

  -- assemble namespaces
  result = table.concat(namespaces, "::")

  if name == "" then return result end

  -- add # separator
  result = result .. "#"
  -- add test_ prefix
  result = result .. "test_"
  -- add index
  for i, child_tree in ipairs(tree:parent():children()) do
    for _, node in child_tree:iter_nodes() do
      if node:data().id == tree:data().id then result = result .. string.format("%04d", i) end
    end
  end
  -- add _[name]
  result = result .. "_" .. name

  return result
end

M.full_test_name = function(tree)
  local name = tree:data().name
  local parent_tree = tree:parent()
  if not parent_tree or parent_tree:data().type == "file" then return name end
  local parent_name = parent_tree:data().name

  -- For rails and spec tests
  if not name:match("^test_") then name = "test_" .. name end

  return parent_name .. "#" .. name:gsub(" ", "_")
end

-- Returns the shoulda-context method name WITHOUT the trailing space that's part of
-- the Ruby symbol — callers using this for an --name regex append " $" themselves.
M.full_shoulda_test_name = function(tree)
  local name = tree:data().name
  local namespaces = {}

  for parent_node in tree:iter_parents() do
    local data = parent_node:data()
    if data.type == "namespace" then
      table.insert(namespaces, 1, data.name)
    else
      break
    end
  end

  if #namespaces == 0 then return name end

  local class_name = table.remove(namespaces, 1)

  local chain
  if #namespaces == 0 then
    chain = class_name:gsub("Test$", "")
  else
    chain = table.concat(namespaces, " ")
  end

  return class_name .. "#test_: " .. chain .. " should " .. name .. "."
end

M.escaped_full_test_name = function(tree)
  local full_name = M.full_test_name(tree)
  return full_name:gsub("([?#])", "\\%1")
end

M.escaped_full_shoulda_test_name = function(tree)
  -- `#` is the structural separator between class and method name, so it must remain
  -- literal in the regex. `?` is the only regex metachar that can appear in user-authored
  -- shoulda descriptions, so we escape it.
  return M.full_shoulda_test_name(tree):gsub("([?])", "\\%1")
end

-- shoulda-matchers description prefixes for matchers commonly used in Rails apps.
-- The returned string is the head of `matcher.description` — the runtime test method
-- name appends suffix text per matcher option (e.g. `optional: true`,
-- `class_name => Foo`), so we match by prefix rather than exact name.
local SHOULDA_MATCHERS = {
  belong_to = function(arg) return "belong to " .. arg end,
  have_many = function(arg) return "have many " .. arg end,
  have_one = function(arg) return "have one " .. arg end,
  have_and_belong_to_many = function(arg) return "have and belong to many " .. arg end,
  validate_presence_of = function(arg) return "validate that :" .. arg end,
  validate_uniqueness_of = function(arg) return "validate that :" .. arg end,
  validate_length_of = function(arg) return "validate that the length of :" .. arg end,
  validate_inclusion_of = function(arg) return "validate that :" .. arg end,
  validate_numericality_of = function(arg) return "validate that :" .. arg end,
  validate_acceptance_of = function(arg) return "validate that :" .. arg end,
  validate_absence_of = function(arg) return "validate that :" .. arg end,
  validate_format_of = function(arg) return "validate that :" .. arg end,
  define_enum_for = function(arg) return "define :" .. arg end,
  delegate_method = function(arg) return "delegate method ##{" .. arg end,
  have_db_column = function(arg) return "have db column named " .. arg end,
  have_db_index = function(arg) return "have a db index on " .. arg end,
  have_readonly_attribute = function(arg) return "have readonly attribute " .. arg end,
  have_secure_password = function() return "have a secure password" end,
  serialize = function(arg) return "serialize :" .. arg end,
  accept_nested_attributes_for = function(arg) return "accept nested attributes for " .. arg end,
}

-- Given the source text of a `should <call>` argument like `belong_to(:cycle).optional(true)`,
-- returns the description prefix that shoulda-matchers will use for the generated test
-- method, or nil if the matcher isn't recognized. Only the head of the chain is consumed —
-- chained options contribute additional suffix text that's allowed to vary at match time.
M.shoulda_matcher_prefix = function(name)
  local matcher, arg = name:match("^([%w_]+)%(:?([%w_]+)")
  if matcher then
    local builder = SHOULDA_MATCHERS[matcher]
    if builder then return builder(arg) end
  end

  -- `have_secure_password` and other no-arg matchers
  local no_arg = name:match("^([%w_]+)%(%)")
  if no_arg and SHOULDA_MATCHERS[no_arg] then return SHOULDA_MATCHERS[no_arg]() end

  return nil
end

-- `it_requires_authentication` → "require authentication", and similar.
M.it_requires_helper_prefix = function(name)
  local suffix = name:match("^it_requires_(.+)$")
  if not suffix then return nil end
  return "require " .. suffix:gsub("_", " ")
end

-- Returns the expected runtime-method prefix for a tree position whose `name` is either
-- a shoulda-matchers expression or an `it_requires_*` identifier. The prefix is the full
-- `<Class>#test_: <chain> should <description>` head; callers do `string.sub`-style prefix
-- matching against minitest verbose output to identify the runtime test, ignoring any
-- per-call suffix (matcher options or random hex).
M.full_shoulda_prefix = function(tree)
  local data = tree:data()
  local description
  if data.name:match("^it_requires_") then
    description = M.it_requires_helper_prefix(data.name)
  else
    description = M.shoulda_matcher_prefix(data.name)
  end
  if not description then return nil end

  local namespaces = {}
  for parent_node in tree:iter_parents() do
    if parent_node:data().type == "namespace" then
      table.insert(namespaces, 1, parent_node:data().name)
    else
      break
    end
  end
  if #namespaces == 0 then return nil end

  local class_name = table.remove(namespaces, 1)
  local chain
  if #namespaces == 0 then
    chain = class_name:gsub("Test$", "")
  else
    chain = table.concat(namespaces, " ")
  end

  return class_name .. "#test_: " .. chain .. " should " .. description
end

M.get_mappings = function(tree)
  -- Returns two tables. `mappings` is exact-match `runtime_name -> pos_id`. `prefixes`
  -- maps a prefix string to a pos_id and is consulted only after exact lookup fails —
  -- used for shoulda-matchers and `it_requires_*` helpers whose runtime method names
  -- carry a varying suffix (matcher options or random hex).
  local mappings = {}
  local prefixes = {}
  local function name_map(tree)
    local data = tree:data()
    if data.type == "test" then
      local full_spec_name = M.full_spec_name(tree)
      mappings[full_spec_name] = data.id

      local full_test_name = M.full_test_name(tree)
      mappings[full_test_name] = data.id

      local full_shoulda_test_name = M.full_shoulda_test_name(tree)
      mappings[full_shoulda_test_name] = data.id

      local prefix = M.full_shoulda_prefix(tree)
      if prefix then prefixes[prefix] = data.id end
    end

    for _, child in ipairs(tree:children()) do
      name_map(child)
    end
  end
  name_map(tree)

  return mappings, prefixes
end

M.strip_ansi_escape_codes = function(str)
  return str:gsub("\27%[%d+m", "")
end

return M
