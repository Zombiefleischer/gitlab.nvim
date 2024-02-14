local u = require("gitlab.utils")
local state = require("gitlab.state")
local M = {}

M.init = function()
  local bin_path = state.settings.bin_path
  local emoji_path = bin_path ..
      state.settings.file_separator ..
      "config" ..
      state.settings.file_separator ..
      "emojis.json"
  local emojis = u.read_file(emoji_path)
  if emojis == nil then
    u.notify("Could not read emoji file at " .. emoji_path, vim.log.levels.WARN)
  end

  local data_ok, data = pcall(vim.json.decode, emojis)
  if not data_ok then
    u.notify("Could not parse emoji file at " .. emoji_path, vim.log.levels.WARN)
  end

  state.emoji_map = data
end

-- Define the popup window options
M.popup_opts = {
  relative = 'cursor',
  row = -2,
  col = 0,
  width = 2, -- Width set dynamically later
  height = 1,
  style = 'minimal',
  border = 'single',
}


M.show_popup = function(char)
  -- Close existing popup if it's open
  if M.popup_win_id and vim.api.nvim_win_is_valid(M.popup_win_id) then
    vim.api.nvim_win_close(M.popup_win_id, true)
  end

  -- Create a buffer for the popup window
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set the content of the popup buffer to the character
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { char })

  -- Open the popup window and store its ID
  M.popup_win_id = vim.api.nvim_open_win(buf, false, M.popup_opts)
end

M.close_popup = function()
  if M.popup_win_id and vim.api.nvim_win_is_valid(M.popup_win_id) then
    vim.api.nvim_win_close(M.popup_win_id, true)
    M.popup_win_id = nil -- Reset the window ID
  end
end

M.init_popup = function(tree, bufnr)
  vim.api.nvim_create_autocmd({ "CursorHold" }, {
    callback = function()
      local node = tree:get_node()
      local emojis = require("gitlab.actions.discussions").emojis
      local note_emojis = emojis[node.root_note_id]

      local row, col = unpack(vim.api.nvim_win_get_cursor(0))
      row = row - 1 -- Adjust row because Lua is 1-indexed
      col = col - 2 -- Adjust to account for > at front of line

      if col < 1 then
        return
      end

      -- Get the text of the current line
      local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1]

      -- Correctly handle multi-byte characters, such as emojis
      local byteIndexStart = vim.str_byteindex(line, col)
      local byteIndexEnd = vim.str_byteindex(line, col + 1)

      -- Extract the character (or emoji) under the cursor
      local char = line:sub(byteIndexStart + 1, byteIndexEnd)

      for k, v in pairs(state.emoji_map) do
        if v.moji == char then
          local names = M.get_users_who_reacted_with_emoji(k, note_emojis)
          M.popup_opts.width = string.len(names)
          if M.popup_opts.width > 0 then
            M.show_popup(names)
          end
        end
      end
    end,
    buffer = bufnr
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    callback = function()
      M.close_popup()
    end,
    buffer = bufnr,
  })
end

---@param name string
---@return string
M.get_users_who_reacted_with_emoji = function(name, note_emojis)
  local result = ""
  print("Looking for name: ", name)
  for _, v in pairs(note_emojis) do
    if v.name == name then
      result = result .. v.user.name .. ", "
    end
  end
  return string.len(result) > 3 and result:sub(1, -3) or result
end

return M
