local actions = require("parley.discussion_actions")
local contexts = require("parley.services.write_context")
local write = require("parley.services.write")
local ui = require("parley.ui_states.discussion")

describe("issue command selection", function()
  local saved, ctx, selected, choose, sent
  before_each(function()
    saved = { package.loaded["parley.discussion_window"], contexts.get, write.set_issue_state, write._notify }
    ctx = {
      provider = {
        capabilities = function()
          return { resolve = { available = true } }
        end,
      },
      review = { pr = { id = "1" }, head_sha = "head" },
    }
    contexts.get = function()
      return ctx
    end
    selected, choose, sent = nil, nil, {}
    write._notify = function() end
    write.set_issue_state = function(buf, id, action)
      sent[#sent + 1] = { buf, id, action }
      return true
    end
    package.loaded["parley.discussion_window"] = {
      resolve_source_bufnr = function()
        return 7
      end,
      current_discussion = function()
        return selected
      end,
      open_current_line = function(_, opts)
        choose = opts.on_select
        return true
      end,
    }
  end)
  after_each(function()
    ui.clear(7)
    package.loaded["parley.discussion_window"], contexts.get, write.set_issue_state, write._notify =
      saved[1], saved[2], saved[3], saved[4]
  end)
  it("acts on the selected thread from a float", function()
    selected = { id = "root" }
    assert.is_true(actions.run(99, "resolve"))
    assert.same({ { 7, "root", "resolve" } }, sent)
    assert.is_nil(choose)
  end)
  it("uses the existing line picker when no thread is selected", function()
    assert.is_true(actions.run(7, "resolve"))
    assert.same({}, sent)
    choose({ id = "chosen" })
    assert.same({ { 7, "chosen", "resolve" } }, sent)
  end)
  it("does not replace a disappeared selected thread with a cursor-line target", function()
    ui.set(7, { current_discussion_id = "removed" })
    assert.is_false(actions.run(7, "resolve"))
    assert.is_nil(choose)
    assert.same({}, sent)
  end)
  it("rejects a stale picker selection", function()
    actions.run(7, "resolve")
    ctx = { provider = ctx.provider, review = { pr = { id = "2" }, head_sha = "head" } }
    assert.is_false(choose({ id = "chosen" }))
    assert.same({}, sent)
  end)
  it("dispatches resolve and reopen commands", function()
    local old = actions.run
    local calls = {}
    actions.run = function(_, action)
      calls[#calls + 1] = action
    end
    local parley = require("parley")
    parley._dispatch_parley({ "discussion", "resolve" }, 7)
    parley._dispatch_parley({ "discussion", "reopen" }, 7)
    actions.run = old
    assert.same({ "resolve", "unresolve" }, calls)
  end)
end)
