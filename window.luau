--!strict
-- Tasks: a task is a session with its own git worktree.
--
-- New task (palette, cmd+shift+n): asks for a task name, creates a worktree
-- on a new branch named after it (from the focused pane's HEAD) beside the
-- main checkout, and opens a session named after the task with its first tab
-- in the worktree.
--
--   task name:      Fix login redirect
--   branch:         fix-login-redirect
--   worktree:       ~/workspaces/resvu-platform-agent-fix-login-redirect
--   session:        Fix login redirect
--
-- Delete task: the current session's task, or one picked from the open
-- tasks. Refuses while the worktree has uncommitted or untracked changes;
-- otherwise closes the session (with Tern's usual confirmation) and then
-- removes the worktree and branch.
--
-- Close session on a task's session: once it has closed, removes the
-- worktree and deletes the branch. git refuses both when they would lose work
-- (uncommitted changes, unmerged commits); the worktree or branch is then
-- kept and a toast says why. Other sessions close as usual, and New session
-- is Tern's own.
--
-- Task dashboard: a canvas listing the open tasks with their git state and
-- Open / Delete buttons, plus New task and Refresh. It refreshes itself
-- while open.
--
-- Window handlers run on the UI thread under a 50 ms budget, and one overrun
-- disables the handler until the plugins reload. So handlers only read
-- window state and start processes; git and the name prompt run in
-- callbacks.

local ui = tern.ui

-- How long to wait for a close to finish, e.g. while Tern asks to confirm
-- ending a running program.
local CLOSE_POLL_MS = 500
local CLOSE_POLL_TRIES = 240

local DASHBOARD_TITLE = "Tasks"
local DASHBOARD_REFRESH_MS = 15000

type Task = { name: string, branch: string, path: string, main: string }
type OpenTask = { id: number, task: Task, current: boolean }
-- Git state of a task's worktree, as the dashboard shows it.
type Stats = { changes: number, ahead: number, last: string } | { missing: true }

local stats: { [number]: Stats } = {}

local function kv_key(session_id: number): string
	return "session:" .. tostring(session_id)
end

local function read_task(session_id: number): Task?
	local task: Task? = tern.kv.get(kv_key(session_id))
	if task ~= nil then
		task.name = task.name or task.branch -- records saved before tasks had names
	end
	return task
end

local function open_tasks(cx: WindowCx): { OpenTask }
	local found = {}
	for _, s in cx.sessions:list() do
		local task = read_task(s.id)
		if task ~= nil then
			table.insert(found, { id = s.id, task = task, current = s.current })
		end
	end
	return found
end

local function focused_cwd(cx: WindowCx): string?
	local id = cx.session:focused()
	if id == nil then
		return nil
	end
	for _, pane in cx.session:panes() do
		if pane.pane == id and pane.cwd ~= "" then
			return pane.cwd
		end
	end
	return nil
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- "Fix login redirect" -> "fix-login-redirect"; "DEV-123 Fix/Login" ->
-- "dev-123-fix/login". Slashes survive so branch prefixes still work.
local function slug(name: string): string
	local s = string.lower(name)
	s = string.gsub(s, "[^%w%./_-]+", "-")
	s = string.gsub(s, "%-+", "-")
	s = string.gsub(s, "^[-./]+", "")
	s = string.gsub(s, "[-./]+$", "")
	return s
end

---------------------------------------------------------------------------
-- Dashboard

local function dashboard_pane(cx: WindowCx): number?
	for _, c in cx.canvas:list() do
		if c.owner == tern.plugin.id and c.title == DASHBOARD_TITLE then
			return c.pane
		end
	end
	return nil
end

local function button(text: string, act: string, class: string?): Node
	return ui.el("button", { class = class, text = text, actions = { click = act } })
end

local function task_card(t: OpenTask): Node
	local s = stats[t.id]
	local badges: { Node } = {}
	if t.current then
		table.insert(badges, ui.badge("current", "accent"))
	end
	local last = "…"
	if s == nil then
		table.insert(badges, ui.badge("checking…", "pending"))
	elseif (s :: any).missing then
		table.insert(badges, ui.badge("worktree missing", "error"))
		last = "—"
	else
		local st = s :: { changes: number, ahead: number, last: string }
		if st.changes > 0 then
			table.insert(badges, ui.badge(st.changes .. " uncommitted", "warning"))
		else
			table.insert(badges, ui.badge("clean", "success"))
		end
		if st.ahead > 0 then
			table.insert(badges, ui.badge(st.ahead .. (if st.ahead == 1 then " commit" else " commits"), "info"))
		end
		last = st.last
	end
	return ui.card({ ui.span(t.task.name, "strong") }, {
		ui.row(badges),
		ui.kv({
			{ "branch", ui.span(t.task.branch, "code") },
			{ "worktree", ui.path(t.task.path) },
			{ "last commit", last },
		}),
		ui.row({
			button("Open", "open=" .. tostring(t.id)),
			button("Delete", "delete=" .. tostring(t.id), "danger"),
		}),
	})
end

local function dashboard_view(cx: WindowCx): Node
	local tasks = open_tasks(cx)
	local children: { Node } = {
		ui.row({ button("New task", "new"), button("Refresh", "refresh") }),
	}
	if #tasks == 0 then
		table.insert(children, ui.md("No open tasks. **New task** starts one."))
	end
	for _, t in tasks do
		table.insert(children, task_card(t))
	end
	return ui.col(children)
end

local function render_dashboard(cx: WindowCx)
	local pane = dashboard_pane(cx)
	if pane ~= nil then
		cx.canvas:set(pane, { view = dashboard_view(cx) })
	end
end

-- One process for every task, so a refresh spawns once however many tasks
-- are open. Arguments come in (id, path, main, branch) groups; each prints
--   id<TAB>uncommitted files<TAB>commits not in main's HEAD<TAB>last commit age
-- or "id<TAB>missing" when the worktree is gone.
local STATS_SCRIPT = [[
while [ $# -ge 4 ]; do
	id=$1 path=$2 main=$3 branch=$4
	shift 4
	if [ -d "$path" ]; then
		changes=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
		ahead=$(git -C "$main" rev-list --count "HEAD..$branch" 2>/dev/null || echo 0)
		last=$(git -C "$path" log -1 --format=%cr 2>/dev/null)
		printf '%s\t%s\t%s\t%s\n' "$id" "$changes" "$ahead" "$last"
	else
		printf '%s\tmissing\n' "$id"
	fi
done
]]

local function refresh_dashboard(cx: WindowCx)
	if dashboard_pane(cx) == nil then
		return
	end
	render_dashboard(cx)
	local argv = { "sh", "-c", STATS_SCRIPT, "sh" }
	for _, t in open_tasks(cx) do
		table.insert(argv, tostring(t.id))
		table.insert(argv, t.task.path)
		table.insert(argv, t.task.main)
		table.insert(argv, t.task.branch)
	end
	if #argv == 4 then
		return
	end
	tern.process.run(argv, { timeout_ms = 20000 }, function(r, cx2)
		if cx2 == nil then
			return
		end
		for _, line in string.split(r.stdout, "\n") do
			local f = string.split(line, "\t")
			local id = tonumber(f[1] or "")
			if id ~= nil then
				if f[2] == "missing" then
					stats[id] = { missing = true }
				elseif #f >= 4 then
					stats[id] = { changes = tonumber(f[2]) or 0, ahead = tonumber(f[3]) or 0, last = f[4] }
				end
			end
		end
		render_dashboard(cx2)
	end)
end

local refresh_loop_running = false

local function start_refresh_loop()
	if refresh_loop_running then
		return
	end
	refresh_loop_running = true
	local function tick()
		tern.timer(DASHBOARD_REFRESH_MS, function(cx)
			if cx == nil or dashboard_pane(cx) == nil then
				refresh_loop_running = false
				return
			end
			refresh_dashboard(cx)
			tick()
		end)
	end
	tick()
end

---------------------------------------------------------------------------
-- Removing a task

local function remove_worktree(task: Task)
	tern.process.run(
		{ "git", "worktree", "remove", task.path },
		{ cwd = task.main, timeout_ms = 60000 },
		function(r, cx)
			if cx == nil then
				return
			end
			if r.status ~= 0 then
				cx:toast("error", "Kept worktree for " .. task.name, trim(r.stderr))
				refresh_dashboard(cx)
				return
			end
			tern.process.run(
				{ "git", "branch", "-d", task.branch },
				{ cwd = task.main, timeout_ms = 10000 },
				function(r2, cx2)
					if cx2 == nil then
						return
					end
					if r2.status ~= 0 then
						cx2:toast("info", "Removed worktree, kept branch " .. task.branch, trim(r2.stderr))
					else
						cx2:toast("success", "Task closed: " .. task.name, "removed " .. task.path)
					end
					refresh_dashboard(cx2)
				end
			)
		end
	)
end

-- Closing the only session leaves it in place with no tabs, so that counts
-- as closed too.
local function session_closed(cx: WindowCx, session_id: number): boolean
	for _, s in cx.sessions:list() do
		if s.id == session_id then
			return s.tabs == 0
		end
	end
	return true
end

-- return_to: the session to show again once the close is done (Delete task
-- from the dashboard switches away to close the task's session).
local function await_close(session_id: number, task: Task, tries: number, return_to: number?)
	tern.timer(CLOSE_POLL_MS, function(cx)
		if cx == nil then
			return
		end
		if session_closed(cx, session_id) then
			tern.kv.set(kv_key(session_id), nil)
			stats[session_id] = nil
			if return_to ~= nil then
				pcall(function()
					cx.sessions:switch(return_to)
				end)
			end
			remove_worktree(task)
		elseif tries > 1 then
			await_close(session_id, task, tries - 1, return_to)
		end
		-- Still open after the last try: the close was cancelled. The record
		-- stays, so a later Close session cleans up.
	end)
end

local function delete_task(cx: WindowCx, session_id: number, task: Task)
	local current = cx.sessions:current().id
	local return_to = if current ~= session_id then current else nil
	if not tern.fs.exists(task.path) then
		-- Worktree already removed by hand: just close the session.
		tern.kv.set(kv_key(session_id), nil)
		cx.sessions:switch(session_id)
		cx:command("close_session")
		if return_to ~= nil then
			cx.sessions:switch(return_to)
		end
		return
	end
	tern.process.run(
		{ "git", "status", "--porcelain" },
		{ cwd = task.path, timeout_ms = 10000 },
		function(r, cx2)
			if cx2 == nil then
				return
			end
			if r.status ~= 0 then
				cx2:toast("error", "Could not check " .. task.name, trim(r.stderr))
				return
			end
			if trim(r.stdout) ~= "" then
				cx2:toast("error", "Task has uncommitted changes; commit or stash them first", task.path)
				return
			end
			cx2.sessions:switch(session_id)
			cx2:command("close_session") -- Tern's own, with its confirmation
			await_close(session_id, task, CLOSE_POLL_TRIES, return_to)
		end
	)
end

---------------------------------------------------------------------------
-- Starting a task

local function start_task(cwd: string, task: Task)
	tern.process.run(
		{ "git", "worktree", "add", "-b", task.branch, task.path },
		{ cwd = cwd, timeout_ms = 60000 },
		function(r, cx)
			if cx == nil then
				return
			end
			if r.status ~= 0 then
				cx:toast("error", "Could not create the task's worktree", trim(r.stderr))
				return
			end
			local session = cx.sessions:create({ name = task.name, cwd = task.path })
			tern.kv.set(kv_key(session.id), task)
			tern.kv.set("last_main", task.main)
			cx:toast("success", "Task started: " .. task.name, task.path)
			refresh_dashboard(cx)
		end
	)
end

local function ask_task_name(cx: WindowCx, cwd: string, main: string)
	cx:prompt({
		placeholder = "Task name",
		action = "start task",
	}):next(function(answer, _err, cx2)
		if cx2 == nil or answer == nil then
			return -- dismissed
		end
		local name = trim(answer)
		if name == "" then
			return
		end
		local branch = slug(name)
		if branch == "" then
			cx2:toast("error", "Task name needs a letter or digit", name)
			return
		end
		-- Catches what slug() lets through but git refuses ("..", "a//b", …).
		tern.process.run(
			{ "git", "check-ref-format", "--branch", branch },
			{ cwd = cwd, timeout_ms = 5000 },
			function(r, cx3)
				if cx3 == nil then
					return
				end
				if r.status ~= 0 then
					cx3:toast("error", "Task name doesn't make a valid branch name", branch)
					return
				end
				cx3:toast("info", "Starting task " .. name .. "…", branch)
				start_task(cwd, {
					name = name,
					branch = branch,
					-- Beside the main checkout whichever worktree the task was
					-- started from; fix/login becomes the suffix fix-login.
					path = main .. "-" .. string.gsub(branch, "/", "-"),
					main = main,
				})
			end
		)
	end)
end

-- Finds the repository holding cwd, then asks for the task name.
local function new_task_from(cx: WindowCx, cwd: string)
	local started = pcall(
		tern.process.run,
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd, timeout_ms = 5000 },
		function(r, cx2)
			if cx2 == nil then
				return
			end
			if r.status ~= 0 then
				cx2:toast("error", "New task needs a pane inside a git repository", cwd)
				return
			end
			-- <main>/.git -> <main>
			ask_task_name(cx2, cwd, (string.gsub(trim(r.stdout), "/%.git$", "")))
		end
	)
	if not started then
		cx:toast("error", "Could not run git", cwd)
	end
end

---------------------------------------------------------------------------
-- Commands and hooks

tern.command({
	id = "new_task",
	title = "New task",
	group = "Tasks",
	run = function(cx)
		local cwd = focused_cwd(cx)
		if cwd == nil then
			cx:toast("error", "New task needs a pane inside a git repository")
			return
		end
		new_task_from(cx, cwd)
	end,
})

tern.command({
	id = "delete_task",
	title = "Delete task",
	group = "Tasks",
	run = function(cx)
		local current = cx.sessions:current()
		local task = read_task(current.id)
		if task ~= nil then
			delete_task(cx, current.id, task)
			return
		end
		local tasks = open_tasks(cx)
		if #tasks == 0 then
			cx:toast("info", "No open tasks")
			return
		end
		local items = {}
		for _, t in tasks do
			table.insert(items, { label = t.task.name, detail = t.task.branch, id = t.id, task = t.task })
		end
		cx:pick({ items = items, placeholder = "Delete which task?", action = "delete" }):next(function(item, _err, cx2)
			if cx2 == nil or item == nil then
				return
			end
			delete_task(cx2, item.id, item.task)
		end)
	end,
})

tern.command({
	id = "task_dashboard",
	title = "Task dashboard",
	group = "Tasks",
	run = function(cx)
		local pane = dashboard_pane(cx)
		if pane ~= nil then
			pcall(function()
				cx.layout:focus(pane :: number)
			end)
		else
			local opened, err = cx.canvas:open({
				title = DASHBOARD_TITLE,
				about = "Open tasks (a session with its own git worktree each). Open switches to a task's session; Delete closes it and removes its worktree and branch.",
				view = dashboard_view(cx),
				how = "tab",
			})
			if opened == nil then
				cx:toast("error", "Could not open the task dashboard", err)
				return
			end
		end
		refresh_dashboard(cx)
		start_refresh_loop()
	end,
})

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx)
	if ev.owner ~= tern.plugin.id then
		return false
	end
	local id = tonumber(ev.value or "")
	if ev.act == "refresh" then
		refresh_dashboard(cx)
	elseif ev.act == "new" then
		local main: string? = tern.kv.get("last_main")
		if main == nil then
			cx:toast("info", "Start the first task with New task from a pane inside the repository")
		else
			new_task_from(cx, main)
		end
	elseif ev.act == "open" and id ~= nil then
		cx.sessions:switch(id)
	elseif ev.act == "delete" and id ~= nil then
		local task = read_task(id)
		if task ~= nil then
			delete_task(cx, id, task)
		end
	else
		return false
	end
	return true
end)

tern.override("close_session", function(cx)
	local session = cx.sessions:current()
	local task = read_task(session.id)
	if task ~= nil and not session.locked then
		await_close(session.id, task, CLOSE_POLL_TRIES)
	end
	return false -- Tern's own Close session runs, confirmation included
end)

---------------------------------------------------------------------------
-- On load

-- Bind cmd+shift+n to New task once, through Tern's settings API: Tern
-- rewrites settings.json from its own copy, so hand edits to the file while
-- it runs get lost. The kv flag keeps a later rebinding of yours in place.
local NEW_TASK_CHORD = "cmd+shift+n"
local NEW_TASK_ACTION = "plugin." .. tern.plugin.id .. ".new_task"

tern.timer(0, function(cx)
	if cx == nil then
		return
	end
	if not tern.kv.get("new_task_bound") then
		cx.settings:bind(NEW_TASK_CHORD, NEW_TASK_ACTION)
		tern.kv.set("new_task_bound", true)
		cx:toast("info", "⌘⇧N now starts a new task")
	end
	-- Canvases outlive plugin reloads; pick a dashboard left open back up.
	if dashboard_pane(cx) ~= nil then
		refresh_dashboard(cx)
		start_refresh_loop()
	end
end)
