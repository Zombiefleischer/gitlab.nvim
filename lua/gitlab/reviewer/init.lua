-- This Module contains all of the reviewer code for diffview
local u = require("gitlab.utils")
local state = require("gitlab.state")
local git = require("gitlab.git")
local hunks = require("gitlab.hunks")
local async_ok, async = pcall(require, "diffview.async")
local diffview_lib = require("diffview.lib")

local M = {
  bufnr = nil,
  tabnr = nil,
  stored_win = nil,
}

-- Checks for legacy installations, only Diffview is supported.
M.init = function()
  if state.settings.reviewer ~= "diffview" then
    vim.notify(
      string.format("gitlab.nvim could not find reviewer %s, only diffview is supported", state.settings.reviewer),
      vim.log.levels.ERROR
    )
  end
end

-- Opens the reviewer window.
M.open = function()
  local diff_refs = state.INFO.diff_refs
  if diff_refs == nil then
    u.notify("Gitlab did not provide diff refs required to review this MR", vim.log.levels.ERROR)
    return
  end

  if diff_refs.base_sha == "" or diff_refs.head_sha == "" then
    u.notify("Merge request contains no changes", vim.log.levels.ERROR)
    return
  end

  local diffview_open_command = "DiffviewOpen"
  local has_clean_tree = git.has_clean_tree()
  if state.settings.reviewer_settings.diffview.imply_local and has_clean_tree then
    diffview_open_command = diffview_open_command .. " --imply-local"
  end

  vim.api.nvim_command(string.format("%s %s..%s", diffview_open_command, diff_refs.base_sha, diff_refs.head_sha))
  M.tabnr = vim.api.nvim_get_current_tabpage()

  if state.settings.reviewer_settings.diffview.imply_local and not has_clean_tree then
    u.notify(
      "There are uncommited changes in the working tree, cannot use 'imply_local' setting for gitlab reviews.\n Stash or commit all changes to use.",
      vim.log.levels.WARN
    )
  end

  if state.INFO.has_conflicts then
    u.notify("This merge request has conflicts!", vim.log.levels.WARN)
  end

  -- Register Diffview hook for close event to set tab page # to nil
  local on_diffview_closed = function(view)
    if view.tabpage == M.tabnr then
      M.tabnr = nil
    end
  end
  require("diffview.config").user_emitter:on("view_closed", function(_, ...)
    on_diffview_closed(...)
  end)

  if state.settings.discussion_tree.auto_open then
    local discussions = require("gitlab.actions.discussions")
    discussions.close()
    discussions.toggle()
  end
end

-- Closes the reviewer and cleans up
M.close = function()
  vim.cmd("DiffviewClose")
  local discussions = require("gitlab.actions.discussions")
  discussions.close()
end

-- Jumps to the location provided in the reviewer window
---@param file_name string
---@param new_line number|nil
---@param old_line number|nil
---@param opts table
M.jump = function(file_name, new_line, old_line, opts)
  if M.tabnr == nil then
    u.notify("Can't jump to Diffvew. Is it open?", vim.log.levels.ERROR)
    return
  end
  vim.api.nvim_set_current_tabpage(M.tabnr)
  vim.cmd("DiffviewFocusFiles")
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end
  local files = view.panel:ordered_file_list()
  local layout = view.cur_layout
  for _, file in ipairs(files) do
    if file.path == file_name then
      if not async_ok then
        u.notify("Could not load Diffview async", vim.log.levels.ERROR)
        return
      end
      async.await(view:set_file(file))
      -- TODO: Ranged comments on unchanged lines will have both a
      -- new line and a old line.
      --
      -- The same is true when the user leaves a single-line comment
      -- on an unchanged line in the "b" buffer.
      --
      -- We need to distinguish them somehow from
      -- range comments (which also have this) so that we can know
      -- which buffer to jump to. Right now, we jump to the wrong
      -- buffer for ranged comments on unchanged lines.
      if new_line ~= nil and not opts.is_undefined_type then
        layout.b:focus()
        vim.api.nvim_win_set_cursor(0, { new_line, 0 })
      elseif old_line ~= nil then
        layout.a:focus()
        vim.api.nvim_win_set_cursor(0, { old_line, 0 })
      end
      break
    end
  end
end

---Get the data from diffview, such as line information and file name. May be used by
---other modules such as the comment module to create line codes or set diagnostics
---@return DiffviewInfo | nil
M.get_reviewer_data = function()
  if M.tabnr == nil then
    u.notify("Diffview reviewer must be initialized first", vim.log.levels.ERROR)
    return
  end

  -- Check if we are in the diffview tab
  local tabnr = vim.api.nvim_get_current_tabpage()
  if tabnr ~= M.tabnr then
    u.notify("Line location can only be determined within reviewer window", vim.log.levels.ERROR)
    return
  end

  -- Check if we are in the diffview buffer
  local view = diffview_lib.get_current_view()
  if view == nil then
    u.notify("Could not find Diffview view", vim.log.levels.ERROR)
    return
  end

  local layout = view.cur_layout
  local old_win = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local new_win = u.get_window_id_by_buffer_id(layout.b.file.bufnr)

  if old_win == nil or new_win == nil then
    u.notify("Error getting window IDs for current files", vim.log.levels.ERROR)
    return
  end

  local current_file = M.get_current_file()
  if current_file == nil then
    u.notify("Error getting current file from Diffview", vim.log.levels.ERROR)
    return
  end

  local new_line = vim.api.nvim_win_get_cursor(new_win)[1]
  local old_line = vim.api.nvim_win_get_cursor(old_win)[1]
  local modification_type = hunks.get_modification_type(old_line, new_line, current_file)
  if modification_type == nil then
    u.notify("Error parsing hunks for modification type", vim.log.levels.ERROR)
    return
  end

  if modification_type == "bad_file_unmodified" then
    u.notify("Comments on unmodified lines will be placed in the old file", vim.log.levels.WARN)
  end

  local current_bufnr = M.is_current_sha() and layout.b.file.bufnr or layout.a.file.bufnr
  local opposite_bufnr = M.is_current_sha() and layout.a.file.bufnr or layout.b.file.bufnr
  local old_sha_win_id = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local new_sha_win_id = u.get_window_id_by_buffer_id(layout.b.file.bufnr)

  return {
    file_name = layout.a.file.path,
    old_line_from_buf = old_line,
    new_line_from_buf = new_line,
    modification_type = modification_type,
    new_sha_win_id = new_sha_win_id,
    current_bufnr = current_bufnr,
    old_sha_win_id = old_sha_win_id,
    opposite_bufnr = opposite_bufnr,
  }
end

---Return whether user is focused on the new version of the file
---@return boolean
M.is_current_sha = function()
  local view = diffview_lib.get_current_view()
  local layout = view.cur_layout
  local b_win = u.get_window_id_by_buffer_id(layout.b.file.bufnr)
  local a_win = u.get_window_id_by_buffer_id(layout.a.file.bufnr)
  local current_win = vim.fn.win_getid()

  -- Handle cases where user navigates tabs in the middle of making a comment
  if a_win ~= current_win and b_win ~= current_win then
    current_win = M.stored_win
    M.stored_win = nil
  end
  return current_win == b_win
end

---Checks whether the lines in the two buffers are the same
---@return boolean
M.lines_are_same = function(layout, a_cursor, b_cursor)
  local line_a = u.get_line_content(layout.a.file.bufnr, a_cursor)
  local line_b = u.get_line_content(layout.b.file.bufnr, b_cursor)
  return line_a == line_b
end

---Get currently shown file
---@return string|nil
M.get_current_file = function()
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  return view.panel.cur_file.path
end

-- Places a sign on the line for currently reviewed file.
---@param signs SignTable[] table of signs. See :h sign_placelist
---@param type string "new" if diagnostic should be in file after changes else "old"
M.place_sign = function(signs, type)
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  if type == "new" then
    for _, sign in ipairs(signs) do
      sign.buffer = view.cur_layout.b.file.bufnr
    end
  elseif type == "old" then
    for _, sign in ipairs(signs) do
      sign.buffer = view.cur_layout.a.file.bufnr
    end
  end
  vim.fn.sign_placelist(signs)
end

---Set diagnostics in currently reviewed file.
---@param namespace integer namespace for diagnostics
---@param diagnostics table see :h vim.diagnostic.set
---@param type string "new" if diagnostic should be in file after changes else "old"
---@param opts table? see :h vim.diagnostic.set
M.set_diagnostics = function(namespace, diagnostics, type, opts)
  local view = diffview_lib.get_current_view()
  if not view then
    return
  end
  if type == "new" and view.cur_layout.b.file.bufnr then
    vim.diagnostic.set(namespace, view.cur_layout.b.file.bufnr, diagnostics, opts)
  elseif type == "old" and view.cur_layout.a.file.bufnr then
    vim.diagnostic.set(namespace, view.cur_layout.a.file.bufnr, diagnostics, opts)
  end
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_file_changed = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.file_changed", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewDiffBufWinEnter" },
    group = group,
    callback = function(...)
      M.stored_win = vim.api.nvim_get_current_win()
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

---Diffview exposes events which can be used to setup autocommands.
---@param callback fun(opts: table) - for more information about opts see callback in :h nvim_create_autocmd
M.set_callback_for_reviewer_leave = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.leave", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewViewLeave", "DiffviewViewClosed" },
    group = group,
    callback = function(...)
      if M.tabnr == vim.api.nvim_get_current_tabpage() then
        callback(...)
      end
    end,
  })
end

M.set_callback_for_reviewer_enter = function(callback)
  local group = vim.api.nvim_create_augroup("gitlab.diffview.autocommand.enter", {})
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffviewViewOpened" },
    group = group,
    callback = function(...)
      callback(...)
    end,
  })
end

return M
