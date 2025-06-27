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
---@param namespace neotest.Position[] Any namespaces the position is within
---@return string
M.generate_treesitter_id = function(position)
  local cwd = async.fn.getcwd()
  local test_path = "." .. replace_paths(position.path, cwd, "")
  -- Treesitter starts line numbers from 0 so we subtract 1
  local id = test_path .. separator .. (tonumber(position.range[1]) + 1)

  return id
end

M.full_test_name = function(tree)
  local name = tree:data().name
  local parent_tree = tree:parent()
  if not parent_tree or parent_tree:data().type == "file" then return name end
  local parent_name = parent_tree:data().name

  -- Check if we have a context (parent namespace within the class)
  local context = ""
  local current = tree:parent()
  while current and current:data().type ~= "file" do
    if current:data().type == "namespace" and current:parent() and current:parent():data().type ~= "file" then
      context = current:data().name .. " "
      break
    end
    current = current:parent()
  end

  -- If we have a context, use the DSL format: ClassName#test_: context description
  -- Otherwise, use the traditional format: ClassName#test_method_name
  if context ~= "" then
    return parent_name .. "#test_: " .. context .. name
  else
    -- For regular DSL tests without context, convert to method name format
    local method_name = name
    if not method_name:match("^test_") then
      method_name = "test_" .. method_name:gsub(" ", "_")
    end
    return parent_name .. "#" .. method_name
  end
end

M.escaped_full_test_name = function(tree)
  local full_name = M.full_test_name(tree)
  return full_name:gsub("([?#])", "\\%1")
end

M.get_mappings = function(tree)
  -- get the mappings for the current node and its children
  local mappings = {}
  local function name_map(tree)
    local data = tree:data()
    if data.type == "test" then
      local full_name = M.full_test_name(tree)
      mappings[full_name] = data.id
    end

    for _, child in ipairs(tree:children()) do
      name_map(child)
    end
  end
  name_map(tree)

  return mappings
end

M.strip_ansi_escape_codes = function(str)
  return str:gsub("\27%[%d+m", "")
end

return M
