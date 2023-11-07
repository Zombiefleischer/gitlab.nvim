-- This module is responsible for calling APIs in sequence. It provides
-- an abstraction around the APIs that lets us ensure state.
local server = require("gitlab.server")
local job = require("gitlab.job")
local state = require("gitlab.state")
local u = require("gitlab.utils")

local M = {}

local async = {
  cb = nil,
}

function async:new(o)
  o = o or {}
  setmetatable(o, self)
  self.__index = self
  return o
end

function async:init(cb)
  self.cb = cb
end

function async:fetch(dependencies, i, argTable)
  if i > #dependencies then
    self.cb(argTable)
    return
  end

  local dependency = dependencies[i]

  -- Do not call endpoint unless refresh is required
  if state[dependency.state] ~= nil and not dependency.refresh then
    self:fetch(dependencies, i + 1, argTable)
    return
  end

  job.run_job(dependency.endpoint, "GET", dependency.body, function(data)
    state[dependency.state] = data[dependency.key]
    self:fetch(dependencies, i + 1, argTable)
  end)
end

-- Will call APIs in sequence and set global state
M.sequence = function(dependencies, cb)
  return function(argTable)
    local handler = async:new()
    handler:init(cb)

    if not state.is_gitlab_project then
      u.notify("The gitlab.nvim state was not set. Do you have a .gitlab.nvim file configured?", vim.log.levels.ERROR)
      return
    end

    if state.go_server_running then
      handler:fetch(dependencies, 1, argTable)
      return
    end

    server.start(function()
      state.go_server_running = true
      handler:fetch(dependencies, 1, argTable)
    end)
  end
end

return M
