-- Mock Tern at the API boundary; no real panes, programs, or worktrees change.
local state
local commands, overrides = {}, {}
local now = 1000
local os = { time = function() return now end }
local function require(_name)
	return { repository_key = function(id) return "dashboard_repo:" .. id end }
end
local tern = {
	ui = {}, plugin = { id = "worktree-sessions" },
	kv = {
		get = function(key) return state.kv[key] end,
		set = function(key, value) state.kv[key] = value end,
	},
	json = { array = function(value) return value end },
	fs = { exists = function() return state.exists end },
	process = { run = function(argv, opts, callback)
		table.insert(state.processes, { argv = argv, callback = callback })
	end },
	timer = function(ms, callback) table.insert(state.timers, { ms = ms, callback = callback }) end,
	command = function(def) commands[def.id] = def.run end,
	override = function(id, callback) overrides[id] = callback end,
	on = function() end, route = { link = function() end },
}
local cx = { session = {}, sessions = {}, layout = {}, agents = {} }
function cx.sessions:list() return state.sessions end
function cx.sessions:current()
	for _, s in state.sessions do if s.current then return s end end
	error("no current session")
end
function cx.sessions:switch(id)
	local found = false
	for _, s in state.sessions do
		s.current = s.id == id
		found = found or s.current
	end
	assert(found, "unknown session")
end
function cx.sessions:create(opts)
	local id = state.nextId
	state.nextId += 1
	local s = { id = id, name = opts.name, tabs = 1, locked = false }
	table.insert(state.sessions, s)
	state.tabIds[id] = { id * 10 }
	self:switch(id)
	state.createdCwd = opts.cwd
	return s
end
function cx.sessions:rename(id, name)
	for _, s in state.sessions do if s.id == id then s.name = name end end
end
function cx.session:sessions()
	local result = {}
	for _, s in state.sessions do
		table.insert(result, { id = s.id, name = s.name, current = s.current, tabs = state.tabIds[s.id] or {} })
	end
	return result
end
function cx.session:panes() return state.panes end
function cx.session:focused() return state.focused end
function cx.layout:focus(id) state.focused = id end
function cx.layout:arrange(opts)
	state.arranged = opts
	if state.failMove then return nil, "cannot move" end
	for _, pane in state.panes do
		if table.find(opts.tabs[1].blocks, pane.pane) then
			for _, tabs in state.tabIds do
				local i = table.find(tabs, pane.tab)
				if i then table.remove(tabs, i) end
			end
			pane.tab = opts.session * 10
		end
	end
	return {}
end
function cx.agents:start(opts) state.agent = opts end
function cx:toast() end
function cx:command(id)
	assert(id == "close_session")
	state.closeRequests += 1
	if state.confirm then
		local current = self.sessions:current()
		if #state.sessions == 1 then current.tabs = 0 else
			for i, s in state.sessions do if s == current then table.remove(state.sessions, i) break end end
			state.sessions[1].current = true
		end
	end
end
local function reset()
	state = { kv = {}, sessions = { { id = 1, name = "Home", current = true, tabs = 1, locked = false } },
		tabIds = { [1] = { 10 } }, panes = {}, timers = {}, processes = {}, nextId = 2,
		exists = true, confirm = true, closeRequests = 0 }
end
reset()
-- INSERT PLUGIN
local task = { name = "Fix login", branch = "fix-login", path = "/work/fix-login", main = "/repo" }
local function flush()
	local timers = state.timers
	state.timers = {}
	for _, timer in timers do timer.callback(cx) end
end
local function count_removals()
	local n = 0
	for _, p in state.processes do
		if p.argv[2] == "worktree" and p.argv[3] == "remove" then n += 1 end
	end
	return n
end
local passed = 0
local function test(name, fn)
	reset()
	fn()
	passed += 1
	print("PASS " .. name)
end

test("new task owns a new session and starts its agent in the worktree", function()
	plugin.open(cx, table.clone(task))
	assert(state.kv["session:2"].path == task.path)
	assert(state.kv["tab:20"] == nil and state.createdCwd == task.path)
	assert(state.agent.cwd == task.path and state.agent.how == "replace_if_alone")
	state.sessions[2].tabs = 3
	assert(#plugin.tasks(cx) == 1 and plugin.tasks(cx)[1].id == 2)
end)

test("dashboard opens a session and status renames that session", function()
	plugin.open(cx, table.clone(task))
	cx.sessions:switch(1)
	plugin.action("open", "2", cx)
	assert(cx.sessions:current().id == 2)
	plugin.stats[2] = { changes = 2, ahead = 0, last = "now" }
	plugin.prs[2] = false
	plugin.names(cx)
	assert(state.sessions[2].name == "Fix login · ±2")
end)

test("dirty worktree prevents deletion", function()
	state.kv["session:1"] = task
	plugin.delete(cx, 1, task)
	state.processes[1].callback({ status = 0, stdout = " M file" }, cx)
	assert(state.closeRequests == 0 and count_removals() == 0)
end)

test("confirmed deletion removes only the closed task and returns to origin", function()
	plugin.open(cx, table.clone(task))
	cx.sessions:switch(1)
	state.processes = {}
	plugin.delete(cx, 2, task)
	state.processes[1].callback({ status = 0, stdout = "" }, cx)
	flush()
	assert(state.kv["session:2"] == nil and count_removals() == 1)
	assert(cx.sessions:current().id == 1)
end)

test("cancelled close retains ownership and worktree", function()
	state.kv["session:1"] = task
	state.exists, state.confirm = false, false
	plugin.delete(cx, 1, task)
	flush()
	assert(state.kv["session:1"] == task and count_removals() == 0)
	now += 121
	flush()
	assert(#state.timers == 0 and state.kv["session:1"] == task)
end)

test("locked session is never deleted", function()
	state.kv["session:1"] = task
	state.sessions[1].locked = true
	state.exists = false
	plugin.delete(cx, 1, task)
	overrides.close_session(cx)
	assert(state.closeRequests == 0 and #state.timers == 0)
end)

test("final session close cleans up after its tabs are gone", function()
	state.kv["session:1"] = task
	assert(overrides.close_session(cx) == false)
	cx:command("close_session")
	flush()
	assert(state.kv["session:1"] == nil and count_removals() == 1)
end)

test("missing worktree closes session without git removal", function()
	state.kv["session:1"] = task
	state.exists = false
	plugin.delete(cx, 1, task)
	flush()
	assert(state.kv["session:1"] == nil and count_removals() == 0)
end)

test("closing a tab or an already empty session does not request cleanup", function()
	assert(overrides.close_tab == nil)
	state.kv["session:1"] = task
	state.sessions[1].tabs = 0
	overrides.close_session(cx)
	assert(#state.timers == 0 and count_removals() == 0 and state.kv["session:1"] == nil)
end)

test("single legacy tab is adopted idempotently", function()
	state.kv["tab:10"] = task
	plugin.migrate(cx)
	assert(state.kv["session:1"] == task and state.kv["tab:10"] == nil)
	flush()
	assert(#state.sessions == 1 and state.sessions[1].name == task.name)
end)

test("shared legacy tasks migrate separately with their running panes", function()
	state.kv["tab:10"] = task
	state.kv["tab:11"] = table.clone(task)
	state.tabIds[1] = { 10, 11 }
	state.panes = { { pane = 100, tab = 10 }, { pane = 101, tab = 10 }, { pane = 110, tab = 11 } }
	plugin.migrate(cx)
	assert(#state.arranged.tabs[1].blocks == 2)
	flush()
	assert(state.kv["session:2"] == task and state.kv["session:1"] ~= nil)
	assert(state.kv["tab:10"] == nil and state.kv["tab:11"] == nil)
	assert(#plugin.tasks(cx) == 2 and state.closeRequests == 0)
end)

test("failed migration preserves old ownership and running panes", function()
	state.kv["tab:10"] = task
	state.tabIds[1] = { 10, 11 }
	state.panes = { { pane = 100, tab = 10 } }
	state.failMove = true
	plugin.migrate(cx)
	assert(state.kv["tab:10"] == task and state.kv["session:2"] == nil)
	assert(state.panes[1].tab == 10 and state.closeRequests == 0)
end)
print(passed .. " tests passed")
