local plugin = require("neotest-minitest")
local async = require("nio.tests")

describe("Shoulda Test", function()
  assert:set_parameter("TableFormatLevel", -1)
  describe("discover_positions", function()
    async.it("discovers should declarations at class level and inside context", function()
      local test_path = vim.loop.cwd() .. "/tests/minitest_examples/shoulda_test.rb"
      local positions = plugin.discover_positions(test_path):to_list()
      local expected_positions = {
        {
          id = test_path,
          name = "shoulda_test.rb",
          path = test_path,
          range = { 0, 0, 17, 0 },
          type = "file",
        },
        {
          {
            id = "./tests/minitest_examples/shoulda_test.rb::7",
            name = "ShouldaTest",
            path = test_path,
            range = { 6, 0, 16, 3 },
            type = "namespace",
          },
          {
            {
              id = "./tests/minitest_examples/shoulda_test.rb::8",
              name = "do a thing",
              path = test_path,
              range = { 7, 2, 9, 5 },
              type = "test",
            },
          },
          {
            {
              id = "./tests/minitest_examples/shoulda_test.rb::12",
              name = "addition",
              path = test_path,
              range = { 11, 2, 15, 5 },
              type = "namespace",
            },
            {
              {
                id = "./tests/minitest_examples/shoulda_test.rb::13",
                name = "add two numbers",
                path = test_path,
                range = { 12, 4, 14, 7 },
                type = "test",
              },
            },
          },
        },
      }

      assert.are.same(expected_positions, positions)
    end)
  end)

  describe("_parse_test_output", function()
    it("maps shoulda-format output lines to position ids", function()
      local output = [[
ShouldaTest#test_: Shoulda should do a thing. = 0.00 s = .
ShouldaTest#test_: addition should add two numbers. = 0.00 s = .
      ]]

      local results = plugin._parse_test_output(output, {
        ["ShouldaTest#test_: Shoulda should do a thing."] = "pos_top",
        ["ShouldaTest#test_: addition should add two numbers."] = "pos_nested",
      })

      assert.are.same({
        ["pos_top"] = { status = "passed" },
        ["pos_nested"] = { status = "passed" },
      }, results)
    end)
  end)
end)
