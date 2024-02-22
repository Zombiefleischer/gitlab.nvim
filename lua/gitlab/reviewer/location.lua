local state = require("gitlab.state")
local hunks = require("gitlab.hunks")
local M = {}

---Takes in information about the current changes, such as the file name, modification type of the diff, and the line numbers
---and builds the appropriate payload when creating a comment.
---@param current_file string
---@param modification_type string
---@param file_name string
---@param old_line number
---@param new_line number
---@param visual_range LineRange | nil
M.build_location_data = function(current_file, modification_type, file_name, old_line, new_line, visual_range)
  ---@type ReviewerInfo
  local payload = {
    file_name = file_name,
    new_line = nil,
    old_line = nil,
    range_info = nil,
  }

  -- Comment on new line: Include only new_line in payload.
  if modification_type == "added" then
    payload.old_line = nil
    payload.new_line = new_line
    -- Comment on deleted line: Include only old_line in payload.
  elseif modification_type == "deleted" then
    payload.old_line = old_line
    payload.new_line = nil
    -- The line was not found in any hunks, send both lines.
  elseif modification_type == "unmodified" or modification_type == "bad_file_unmodified" then
    payload.old_line = old_line
    payload.new_line = new_line
  end

  if visual_range == nil then
    return payload
  end

  -- Assume at top of visual range in the new buffer...
  local start_range_info = hunks.get_start_range(new_line, old_line, modification_type)
  local end_range_info = hunks.get_end_range(new_line, old_line, visual_range, current_file)

  payload.range_info = {
    start = {
      old_line = start_range_info.old_line,
      new_line = start_range_info.new_line,
      type = start_range_info.type,
    },
    ["end"] = {
      old_line = end_range_info.old_line,
      new_line = end_range_info.new_line,
      type = end_range_info.type,
    },
  }

  return payload
end

return M
