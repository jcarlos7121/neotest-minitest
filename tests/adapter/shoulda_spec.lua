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
ShouldaTest#test_: Shoulda should do a thing.  = 0.00 s = .
ShouldaTest#test_: addition should add two numbers.  = 0.00 s = .
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

    it("falls back to prefix matching for shoulda-matchers", function()
      local output =
        "Patients::Cycles::TissueTest#test_: associations should belong to cycle optional: true.  = 0.04 s = .\n"
        .. "Patients::Cycles::TissueTest#test_: enums should define :current_disposition as an enum backed by an enum.  = 0.04 s = F\n"

      local results = plugin._parse_test_output(output, {}, {
        ["TissueTest#test_: associations should belong to cycle"] = "pos_belong",
        ["TissueTest#test_: enums should define :current_disposition"] = "pos_enum",
      })

      assert.equal("passed", results["pos_belong"].status)
      assert.equal("failed", results["pos_enum"].status)
    end)

    it("falls back to prefix matching for it_requires_* helpers (with random hex suffix)", function()
      local output =
        "TissueObservationsControllerTest#test_: update should require authentication - bd6bdc1bd62ef5d7c386a77f.  = 0.05 s = F\n"
        .. "TissueObservationsControllerTest#test_: update should require authorization - d0544478e23d1b87104cee3e.  = 0.08 s = .\n"

      local results = plugin._parse_test_output(output, {}, {
        ["TissueObservationsControllerTest#test_: update should require authentication"] = "pos_authn",
        ["TissueObservationsControllerTest#test_: update should require authorization"] = "pos_authz",
      })

      assert.equal("failed", results["pos_authn"].status)
      assert.equal("passed", results["pos_authz"].status)
    end)
  end)
end)
