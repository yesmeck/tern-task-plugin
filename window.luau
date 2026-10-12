--!strict
-- Tasks: a task is a session with its own git worktree.
--
-- New task (palette, cmd+shift+n via settings.json): asks for a task name,
-- creates a worktree on a new branch named after it (from the focused pane's
-- HEAD) beside the main checkout, and opens a session named after the task
-- with its first tab in the worktree.
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
-- Window handlers run on the UI thread under a 50 ms budget, and one overrun
-- disables the handler until the plugins reload. So handlers only read
-- window state and start processes; git and the name prompt run in
-- callbacks.

-- How long to wait for a close to finish, e.g. while Tern asks to confirm
-- ending a running program.
local CLOSE_POLL_MS = 500
local CLOSE_POLL_TRIES = 240

type Task = { name: string, branch: string, path: string, main: string }

local function kv_key(session_id: number): string
	return "session:" .. tostring(session_id)
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

local function await_close(session_id: number, task: Task, tries: number)
	tern.timer(CLOSE_POLL_MS, function(cx)
		if cx == nil then
			return
		end
		if session_closed(cx, session_id) then
			tern.kv.set(kv_key(session_id), nil)
			remove_worktree(task)
		elseif tries > 1 then
			await_close(session_id, task, tries - 1)
		end
		-- Still open after the last try: the close was cancelled. The record
		-- stays, so a later Close session cleans up.
	end)
end

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
			cx:toast("success", "Task started: " .. task.name, task.path)
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
	end,
})

local function delete_task(cx: WindowCx, session_id: number, task: Task)
	if not tern.fs.exists(task.path) then
		-- Worktree already removed by hand: just close the session.
		tern.kv.set(kv_key(session_id), nil)
		cx.sessions:switch(session_id)
		cx:command("close_session")
		return
	end
	tern.process.run(
		{ "git", "status", "--porcelain" },
		{ cwd = task.path, timeout_ms = 10000 },
		function(r, cx)
			if cx == nil then
				return
			end
			if r.status ~= 0 then
				cx:toast("error", "Could not check " .. task.name, trim(r.stderr))
				return
			end
			if trim(r.stdout) ~= "" then
				cx:toast("error", "Task has uncommitted changes; commit or stash them first", task.path)
				return
			end
			cx.sessions:switch(session_id)
			cx:command("close_session") -- Tern's own, with its confirmation
			await_close(session_id, task, CLOSE_POLL_TRIES)
		end
	)
end

local function open_tasks(cx: WindowCx): { { id: number, task: Task } }
	local found = {}
	for _, s in cx.sessions:list() do
		local task: Task? = tern.kv.get(kv_key(s.id))
		if task ~= nil then
			task.name = task.name or task.branch -- records saved before tasks had names
			table.insert(found, { id = s.id, task = task })
		end
	end
	return found
end

tern.command({
	id = "delete_task",
	title = "Delete task",
	group = "Tasks",
	run = function(cx)
		local current = cx.sessions:current()
		local task: Task? = tern.kv.get(kv_key(current.id))
		if task ~= nil then
			task.name = task.name or task.branch
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

-- Bind cmd+shift+n to New task once, through Tern's settings API: Tern
-- rewrites settings.json from its own copy, so hand edits to the file while
-- it runs get lost. The kv flag keeps a later rebinding of yours in place.
local NEW_TASK_CHORD = "cmd+shift+n"
local NEW_TASK_ACTION = "plugin." .. tern.plugin.id .. ".new_task"

tern.timer(0, function(cx)
	if cx == nil or tern.kv.get("new_task_bound") then
		return
	end
	cx.settings:bind(NEW_TASK_CHORD, NEW_TASK_ACTION)
	tern.kv.set("new_task_bound", true)
	cx:toast("info", "⌘⇧N now starts a new task")
end)

tern.override("close_session", function(cx)
	local session = cx.sessions:current()
	local task: Task? = tern.kv.get(kv_key(session.id))
	if task ~= nil and not session.locked then
		task.name = task.name or task.branch -- records saved before tasks had names
		await_close(session.id, task, CLOSE_POLL_TRIES)
	end
	return false -- Tern's own Close session runs, confirmation included
end)
