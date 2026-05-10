local render = require("parley.discussion_window.render")
local model = require("parley.model")

---@param opts? table
---@return parley.Comment
local function make_comment(opts)
  opts = opts or {}
  return model.new_comment({
    id = opts.id or "c1",
    author = opts.author or "alice",
    body = model.new_body({ text = opts.text or "Hello", format = "markdown" }),
    created_at = opts.created_at or "2024-01-01T10:00:00Z",
    updated_at = opts.updated_at or "2024-01-01T10:00:00Z",
    reactions = opts.reactions or {},
    is_own = opts.is_own or false,
    parent_comment_id = opts.parent_comment_id,
  })
end

---@param opts? table
---@return parley.Discussion
local function make_discussion(opts)
  opts = opts or {}
  return model.new_discussion({
    id = opts.id or "d1",
    file = opts.file or "src/foo.lua",
    line = opts.line or 3,
    resolved = opts.resolved or false,
    comments = opts.comments or { make_comment({ text = opts.text or "First comment" }) },
  })
end

describe("parley.discussion_window.render", function()
  local formatter

  before_each(function()
    formatter = function(timestamp)
      return "formatted:" .. timestamp
    end
  end)

  it("renders the first discussion with nested replies and reactions", function()
    local discussion = make_discussion({
      comments = {
        make_comment({
          id = "c1",
          text = "Root comment",
          reactions = {
            model.new_reaction({ type = "+1", count = 1, viewer_reacted = false }),
            model.new_reaction({ type = "heart", count = 2, viewer_reacted = true }),
          },
        }),
        make_comment({
          id = "c2",
          author = "bob",
          text = "Reply comment",
          parent_comment_id = "c1",
          created_at = "2024-01-01T10:00:01Z",
          updated_at = "2024-01-01T10:00:01Z",
        }),
      },
    })

    local lines, ranges, title = render.render_lines({ discussion }, { d1 = { stale = true } }, {
      format_timestamp = formatter,
    })

    assert.same({
      "- **alice** · formatted:2024-01-01T10:00:00Z",
      "  Root comment",
      "  ---",
      "  Reactions: 👍, ❤️ x2 (you)",
      "",
      "  - **bob** · formatted:2024-01-01T10:00:01Z",
      "    Reply comment",
    }, lines)
    assert.same({
      c1 = { start_line = 1, end_line = 4 },
      c2 = { start_line = 6, end_line = 7 },
    }, ranges)
    assert.equals("unresolved · stale anchor", title)
  end)

  it("builds reaction picker items with counts and viewer state", function()
    local items = render.reaction_picker_items(make_comment({
      reactions = {
        model.new_reaction({ type = "heart", count = 2, viewer_reacted = true }),
      },
    }))

    assert.same({ reaction = "+1", emoji = "👍", label = "+1", count = 0, viewer_reacted = false }, items[1])
    assert.same({ reaction = "heart", emoji = "❤️", label = "heart", count = 2, viewer_reacted = true }, items[5])
  end)
end)
