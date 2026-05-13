local utils = require("neotest-minitest.utils")
local Tree = require("neotest.types.tree")

describe("generate_treesitter_id", function()
  it("forms an id", function()
    local ts = {
      name = "'adds two numbers together'",
      path = vim.loop.cwd() .. "/tests/classic/classic_test.rb",
      range = {
        1,
        2,
        3,
        5,
      },
      type = "test",
    }

    assert.equals("./tests/classic/classic_test.rb::2", utils.generate_treesitter_id(ts))
  end)
end)

describe("full_spec_name", function()
  it("concatenates namespaces with :: separator", function()
    local tree = Tree.from_list({
      { id = "namespace1", name = "namespace1", type = "namespace" },
      {
        { id = "namespace2", name = "namespace2", type = "namespace" },
        {
          { id = "namespace3", name = "namespace3", type = "namespace" },
          {
            { id = "test", name = "example" },
          },
        },
      },
    }, function(pos)
      return pos.id
    end)

    assert.equals("namespace1::namespace2::namespace3", utils.full_spec_name(tree:children()[1]:children()[1]))
    assert.equals(
      "namespace1::namespace2::namespace3#test_0001_example",
      utils.full_spec_name(tree:children()[1]:children()[1]:children()[1])
    )
  end)

  it("includes a zero-padded test index", function()
    local tree = Tree.from_list({
      { id = "namespace1", name = "namespace1", type = "namespace" },
      {
        { id = "namespace2", name = "namespace2", type = "namespace" },
        {
          { id = "namespace3", name = "namespace3", type = "namespace" },
          {
            { id = "test1", name = "example1" },
          },
          {
            { id = "test2", name = "example2" },
          },
          {
            { id = "test3", name = "example3" },
          },
        },
      },
    }, function(pos)
      return pos.id
    end)
    assert.equals(
      "namespace1::namespace2::namespace3#test_0002_example2",
      utils.full_spec_name(tree:children()[1]:children()[1]:children()[2])
    )
  end)

  it("does not replace spaces with underscores", function()
    local tree = Tree.from_list({
      { id = "namespace1", name = "namespace1", type = "namespace" },
      {
        { id = "namespace2", name = "namespace2", type = "namespace" },
        {
          { id = "namespace3", name = "namespace3", type = "namespace" },
          {
            { id = "test", name = "this is a great test name" },
          },
        },
      },
    }, function(pos)
      return pos.id
    end)
    assert.equals(
      "namespace1::namespace2::namespace3#test_0001_this is a great test name",
      utils.full_spec_name(tree:children()[1]:children()[1]:children()[1])
    )
  end)
end)

describe("full_test_name", function()
  it("returns the name of the test", function()
    local tree = Tree.from_list({ id = "test", name = "test_example" }, function(pos)
      return pos.id
    end)
    assert.equals("test_example", utils.full_test_name(tree))
  end)

  it("returns the name of the test with the parent namespace", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "example" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace#test_example", utils.full_test_name(tree:children()[1]))
  end)

  it("prefixes the test with test_", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "example" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace#test_example", utils.full_test_name(tree:children()[1]))
  end)

  it("replaces spaces with underscores", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "this is a great test name" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace#test_this_is_a_great_test_name", utils.full_test_name(tree:children()[1]))
  end)

  it("shouldn't replace the quotes inside the test name", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "shouldn't remove our single quote" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace#test_shouldn't_remove_our_single_quote", utils.full_test_name(tree:children()[1]))
  end)
end)

local function fake_node(data, parents)
  parents = parents or {}
  local node = {}
  function node:data() return data end
  function node:iter_parents()
    local i = 0
    return function()
      i = i + 1
      return parents[i]
    end
  end
  return node
end

describe("full_shoulda_test_name", function()
  it("builds the class-level form using class name minus Test suffix", function()
    local class_ns = fake_node({ name = "ShouldaTest", type = "namespace" })
    local test_node = fake_node({ name = "do a thing", type = "test" }, { class_ns })

    assert.equal("ShouldaTest#test_: Shoulda should do a thing.", utils.full_shoulda_test_name(test_node))
  end)

  it("builds the context-nested form using the context chain", function()
    local class_ns = fake_node({ name = "ShouldaTest", type = "namespace" })
    local ctx_ns = fake_node({ name = "addition", type = "namespace" }, { class_ns })
    local test_node = fake_node({ name = "add two numbers", type = "test" }, { ctx_ns, class_ns })

    assert.equal("ShouldaTest#test_: addition should add two numbers.", utils.full_shoulda_test_name(test_node))
  end)

  it("joins nested context names with single spaces", function()
    local class_ns = fake_node({ name = "ShouldaTest", type = "namespace" })
    local outer = fake_node({ name = "outer", type = "namespace" }, { class_ns })
    local inner = fake_node({ name = "inner", type = "namespace" }, { outer, class_ns })
    local test_node = fake_node({ name = "X", type = "test" }, { inner, outer, class_ns })

    assert.equal("ShouldaTest#test_: outer inner should X.", utils.full_shoulda_test_name(test_node))
  end)
end)

describe("escaped_full_test_name", function()
  it("escapes # characters", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "#escaped_full_test_name should be escaped" },
    }, function(pos)
      return pos.id
    end)
    assert.equals(
      "namespace\\#test_\\#escaped_full_test_name_should_be_escaped",
      utils.escaped_full_test_name(tree:children()[1])
    )
  end)

  it("escapes ? characters", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "escaped? should be escaped" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace\\#test_escaped\\?_should_be_escaped", utils.escaped_full_test_name(tree:children()[1]))
  end)

  it("escapes multiple ? and # characters", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "test", name = "#escaped? should be escaped" },
    }, function(pos)
      return pos.id
    end)
    assert.equals("namespace\\#test_\\#escaped\\?_should_be_escaped", utils.escaped_full_test_name(tree:children()[1]))
  end)
end)

describe("get_mappings", function()
  it("gives full test name for nodes of tree", function()
    local tree = Tree.from_list({
      { id = "namespace", name = "namespace", type = "namespace" },
      { id = "namespace_test_example", name = "test_example", type = "test" },
    }, function(pos)
      return pos.id
    end)

    local mappings = utils.get_mappings(tree)

    assert.equals("namespace_test_example", mappings["namespace#test_example"])
  end)

  it("give test name with no nesting", function()
    local tree = Tree.from_list({
      { id = "test_id", name = "test", type = "test" },
    }, function(pos)
      return pos.id
    end)

    local mappings = utils.get_mappings(tree)

    assert.equals("test_id", mappings["test"])
  end)

  it("registers a shoulda-format key for each test", function()
    local tree = Tree.from_list({
      { id = "ShouldaTest", name = "ShouldaTest", type = "namespace" },
      { id = "ShouldaTest_do_a_thing", name = "do a thing", type = "test" },
    }, function(pos)
      return pos.id
    end)

    local mappings = utils.get_mappings(tree)

    assert.equals("ShouldaTest_do_a_thing", mappings["ShouldaTest#test_: Shoulda should do a thing."])
  end)
end)

describe("strip_ansi", function()
  it("strips ansi codes", function()
    local input = "This is \27[32mgreen\27[0m text!"

    assert.equals("This is green text!", utils.strip_ansi_escape_codes(input))
  end)
end)

describe("replace_module_namespace", function()
  it("removes module namespace", function()
    local input = "Foo::Bar"

    assert.equals("Bar", utils.replace_module_namespace(input))
  end)
end)
