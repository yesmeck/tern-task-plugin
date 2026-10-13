--!strict
-- Tasks: a task is a session with its own git worktree.
--
-- New task (palette, cmd+shift+n): asks for a task name, creates a worktree
-- on a new branch named after it (from the base branch setting, else the
-- repository's default branch) under the worktree folder setting (default
-- ~/tern/worktrees), and opens a session named after the task running only
-- the default agent in the worktree.
--
--   task name:      Fix login redirect
--   branch:         fix-login-redirect
--   worktree:       ~/tern/worktrees/resvu-platform-agent/fix-login-redirect
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
-- kept and a toast says why. A task session Tern closes because its last
-- pane exited keeps both. Other sessions close as usual, and New session
-- is Tern's own.
--
-- Session names: each task's session is named "<task> · <status>", e.g.
-- "Fix login · #3413 ✓ · ±2" (PR, checks, uncommitted files), kept up to
-- date in the background.
--
-- Task dashboard: a native block of the repository's tasks, in columns by pull
-- request (In progress: none yet, Draft, In review, Done: merged or closed),
-- each card with its git state, PR checks and review, and Open / Delete
-- buttons. Task state refreshes in the background: git every 15 s, GitHub
-- (gh) every minute.
--
-- Window handlers run on the UI thread under a 50 ms budget, and one overrun
-- disables the handler until the plugins reload. So handlers only read
-- window state and start processes; git and the name prompt run in
-- callbacks.

local ui = tern.ui
local Dashboard = require("./dashboard")


-- How long after Close session or Delete task a session closing still counts
-- as asked for, e.g. while Tern asks to confirm ending a running program.
local CLOSE_INTENT_S = 120
local CLOSE_POLL_MS = 250

local DASHBOARD_KIND = tern.plugin.id .. ".dashboard"
local DASHBOARD_LINK_PREFIX = tern.plugin.id .. "://dashboard/"
local DASHBOARD_REFRESH_MS = 15000
local STARTUP_REFRESH_DELAY_MS = 3000
-- Start the default agent in a new task's session.
local OPEN_AGENT = true
-- Append each task's status to its session name ("Fix login · #3413 ✓ · ±2").
local STATUS_IN_SESSION_NAMES = true
-- Pull requests every 4th refresh (once a minute), as GitHub rate-limits.
local PR_REFRESH_EVERY = 4

-- base: the ref the branch was created from (nil: the starting pane's HEAD).
type Task = { name: string, branch: string, path: string, main: string, base: string? }
-- id: the session owning the task and its worktree.
type OpenTask = { id: number, task: Task, current: boolean }
type Stats = Dashboard.Stats
type Pr = Dashboard.Pr

local stats: { [number]: Stats } = {}
-- false: gh found no pull request for the branch.
local prs: { [number]: Pr | false } = {}

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

-- The tab holding the focused pane.
local function current_tab(cx: WindowCx): number?
	local pane = cx.session:focused()
	if pane == nil then
		return nil
	end
	return cx.session:tab_of(pane)
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
		if pane.pane == id and pane.block ~= DASHBOARD_KIND and pane.cwd ~= "" then
			return pane.cwd
		end
	end
	return nil
end

-- The focused pane's directory, or else that of another pane in the
-- focused tab, then in the current session's other tabs. A dashboard's
-- inherited launch directory is not a source repository.
local function window_cwd(cx: WindowCx): string?
	local cwd = focused_cwd(cx)
	if cwd ~= nil then
		return cwd
	end
	local here = current_tab(cx)
	local tabs: { number } = {}
	for _, s in cx.session:sessions() do
		if s.current then
			tabs = s.tabs
		end
	end
	local fallback: string? = nil
	for _, pane in cx.session:panes() do
		if pane.block ~= DASHBOARD_KIND and pane.cwd ~= "" and pane.cwd ~= nil and pane.tab ~= nil then
			if pane.tab == here then
				return pane.cwd
			elseif fallback == nil and table.find(tabs, pane.tab :: number) ~= nil then
				fallback = pane.cwd
			end
		end
	end
	return fallback
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
-- Settings, per repository (keyed by the main checkout's path)

type RepoSettings = {
	-- Ref new tasks branch from, e.g. "origin/cycle-86"; "HEAD": the focused
	-- pane's current branch; nil: the repository's default branch.
	base: string?,
}

local function settings_key(main: string): string
	return "settings:" .. main
end

local function repo_settings(main: string): RepoSettings
	return tern.kv.get(settings_key(main)) or {}
end

local function set_base(main: string, base: string?)
	local settings = repo_settings(main)
	settings.base = base
	tern.kv.set(settings_key(main), settings)
end

-- Settings for every repository.
local DEFAULT_WORKTREE_ROOT = "~/tern/worktrees"

type GlobalSettings = {
	-- Folder holding every task's worktree, as <root>/<repository>/<branch>.
	worktree_root: string?,
}

local function global_settings(): GlobalSettings
	return tern.kv.get("settings") or {}
end

local function worktree_root(): string
	return global_settings().worktree_root or DEFAULT_WORKTREE_ROOT
end

local function set_worktree_root(root: string?)
	local settings = global_settings()
	settings.worktree_root = root
	tern.kv.set("settings", settings)
end

local function expand_home(path: string): string
	if path == "~" or string.sub(path, 1, 2) == "~/" then
		return (tern.getenv("HOME") or "") .. string.sub(path, 2)
	end
	return path
end

-- <root>/<repository>/<branch>, with the branch's slashes as dashes:
-- ~/tern/worktrees/resvu-platform-agent/fix-login.
local function task_path(main: string, branch: string): string
	local repository = string.match(main, "([^/]+)$") or "repository"
	return expand_home(worktree_root()) .. "/" .. repository .. "/" .. (string.gsub(branch, "/", "-"))
end

---------------------------------------------------------------------------
-- Dashboard

-- The current session's dashboard, or else one in another session. Panes
-- list every session's, so only_current limits it to the current one.
local function dashboard_pane(cx: WindowCx, only_current: boolean?): number?
	local tabs: { number }? = nil
	local other: number? = nil
	for _, pane in cx.session:panes() do
		if pane.block == DASHBOARD_KIND then
			if tabs == nil then
				tabs = {}
				for _, s in cx.session:sessions() do
					if s.current then
						tabs = s.tabs
					end
				end
			end
			if pane.tab ~= nil and table.find(tabs :: { number }, pane.tab :: number) ~= nil then
				return pane.pane
			elseif other == nil then
				other = pane.pane
			end
		end
	end
	return if only_current then nil else other
end

-- variant: "primary" or "danger" (see the board CSS).
local function button(text: string, act: string, variant: string?): Node
	local class = if variant then "tk-btn " .. variant else "tk-btn"
	return ui.el("button", { class = class, text = text, actions = { click = act } })
end


-- The repository selected for this dashboard pane; nil shows every task.
-- Native blocks mirror the same selection in every window.
local dashboard_main: string? = nil

local function board_tasks(cx: WindowCx): { OpenTask }
	local main = dashboard_main
	local tasks = open_tasks(cx)
	if main == nil then
		return tasks
	end
	local found = {}
	for _, t in tasks do
		if t.task.main == main then
			table.insert(found, t)
		end
	end
	return found
end

local function dashboard_snapshot(cx: WindowCx): Dashboard.Snapshot
	local snapshot: Dashboard.Snapshot = { main = dashboard_main, tasks = tern.json.array({}) }
	for _, t in board_tasks(cx) do
		table.insert(snapshot.tasks, {
			id = t.id,
			name = t.task.name,
			branch = t.task.branch,
			path = t.task.path,
			current = t.current,
			stats = stats[t.id],
			pr = prs[t.id],
		})
	end
	return snapshot
end

local drawn_pane: number? = nil
local drawn_snapshot: string? = nil
local legacy_dashboards: { { pane: number, position: number? } } = {}

local function finish_dashboard_migration(cx: WindowCx, pane: number)
	if #legacy_dashboards == 0 then
		return
	end
	local tab = cx.session:tab_of(pane)
	local position = legacy_dashboards[1].position
	if tab ~= nil and position ~= nil then
		cx.layout:order_tab(tab, position)
	end
	for _, old in legacy_dashboards do
		cx.layout:close(old.pane)
	end
	legacy_dashboards = {}
end

local function render_dashboard(cx: WindowCx, select_repo: boolean?)
	-- A repository picked from this session must not refilter another
	-- session's board; a dashboard opened here takes dashboard_main.
	local pane = dashboard_pane(cx, select_repo)
	if pane == nil then
		return
	end
	finish_dashboard_migration(cx, pane)
	if not select_repo then
		local selection = tern.kv.get(Dashboard.repository_key(pane))
		if selection ~= nil then
			dashboard_main = selection.main
		end
	end
	local snapshot = tern.json.encode(dashboard_snapshot(cx))
	if not select_repo and pane == drawn_pane and snapshot == drawn_snapshot then
		return
	end
	cx.session:event(pane, { ev = "action", id = "main", act = "snapshot", value = snapshot, select = select_repo == true })
	drawn_pane, drawn_snapshot = pane, snapshot
end

local function open_dashboard_tab(cx: WindowCx, focus: boolean)
	-- Daemon-backed launches can be queued and return no id. Discover the
	-- actual pane from pane_created rather than treating nil as a failure.
	cx:new_block(DASHBOARD_KIND, { tern.json.encode(dashboard_snapshot(cx)) }, "tab", { focus = focus })
end

tern.on("pane_created", function(ev: PaneEvent, cx: WindowCx)
	local pane = cx.session:pane(ev.pane)
	if pane ~= nil and pane.block == DASHBOARD_KIND then
		render_dashboard(cx)
	end
end)

-- Retire only the old dashboard canvases, once a native dashboard exists.
-- Settings remain canvases; no other owner's panes are changed.
local function migrate_dashboard_canvas(cx: WindowCx)
	local focus = false
	for _, canvas in cx.canvas:list() do
		if canvas.owner == tern.plugin.id and canvas.title == "Tasks" then
			local old = { pane = canvas.pane, position = nil :: number? }
			local old_tab = cx.session:tab_of(canvas.pane)
			for i, tab in cx.session:tabs() do
				if tab.id == old_tab then
					old.position = i
					break
				end
			end
			table.insert(legacy_dashboards, old)
			focus = focus or cx.session:focused() == canvas.pane
		end
	end
	if #legacy_dashboards > 0 then
		local pane = dashboard_pane(cx)
		if pane ~= nil then
			finish_dashboard_migration(cx, pane)
		else
			open_dashboard_tab(cx, focus)
		end
	end
end

-- The main checkout of a task whose worktree or main checkout holds cwd,
-- so the board can open filtered before git answers.
local function known_main(cx: WindowCx, cwd: string): string?
	for _, t in open_tasks(cx) do
		for _, dir in { t.task.path, t.task.main } do
			if cwd == dir or string.sub(cwd, 1, #dir + 1) == dir .. "/" then
				return t.task.main
			end
		end
	end
	return nil
end

-- Points the board at the repository holding the window's directory
-- (window_cwd): a known task's at once, then git's answer.
local function set_dashboard_repo(cx: WindowCx)
	local cwd = window_cwd(cx)
	if cwd == nil then
		return -- no directory to go by: keep showing what the board shows
	end
	local main = known_main(cx, cwd)
	if main ~= nil then
		dashboard_main = main
		render_dashboard(cx, true)
	end
	pcall(
		tern.process.run,
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd, timeout_ms = 5000 },
		function(r, cx2)
			if cx2 == nil then
				return
			end
			-- Outside a repository: show every task.
			local main = if r.status == 0 then (string.gsub(trim(r.stdout), "/%.git$", "")) else nil
			dashboard_main = main
			render_dashboard(cx2, true)
		end
	)
end

---------------------------------------------------------------------------
-- Status in session names

local NAME_SEPARATOR = " · "
local CHECK_MARKS = { pass = "✓", fail = "✗", pending = "●" }

-- " · #3413 draft ✓ · ±2": the PR (number, draft, checks; merged or closed
-- instead once it's done), then uncommitted files. "" when there's nothing
-- to say.
local function status_suffix(id: number): string
	local parts = {}
	local pr: any = prs[id]
	if pr then
		local label = "#" .. pr.number
		if pr.state == "MERGED" or pr.state == "CLOSED" then
			label ..= " " .. string.lower(pr.state)
		else
			if pr.draft then
				label ..= " draft"
			end
			local mark = CHECK_MARKS[pr.checks]
			if mark then
				label ..= " " .. mark
			end
		end
		table.insert(parts, label)
	end
	local st: any = stats[id]
	if st and st.missing then
		table.insert(parts, "worktree missing")
	elseif st and st.changes > 0 then
		table.insert(parts, "±" .. st.changes)
	end
	if #parts == 0 then
		return ""
	end
	return NAME_SEPARATOR .. table.concat(parts, NAME_SEPARATOR)
end

-- Renames each task's session to "<task name><status suffix>", only when
-- that changes it. The part before the first separator is the task's name,
-- so renaming a session by hand renames its task.
local function apply_session_names(cx: WindowCx)
	if not STATUS_IN_SESSION_NAMES then
		return
	end
	for _, s in cx.sessions:list() do
		local task = read_task(s.id)
		-- Wait for both answers, so a reload doesn't strip the suffix and
		-- put it back a moment later.
		if task ~= nil and stats[s.id] ~= nil and prs[s.id] ~= nil then
			local base = string.match(s.name, "^(.-)" .. NAME_SEPARATOR) or s.name
			if base ~= "" and base ~= task.name then
				task.name = base
				tern.kv.set(kv_key(s.id), task)
			end
			local wanted = task.name .. status_suffix(s.id)
			if s.name ~= wanted then
				cx.sessions:rename(s.id, wanted)
			end
		end
	end
end

local function task_args(cx: WindowCx, fields: (Task) -> { string }): { string }
	local args = {}
	for _, t in open_tasks(cx) do
		table.insert(args, tostring(t.id))
		for _, f in fields(t.task) do
			table.insert(args, f)
		end
	end
	return args
end

-- One process for every task, so a refresh spawns once however many tasks
-- are open. Arguments come in (id, path, main, branch, base) groups; each
-- prints
--   id<TAB>uncommitted files<TAB>commits not in base<TAB>last commit age
-- or "id<TAB>missing" when the worktree is gone.
local STATS_SCRIPT = [[
while [ $# -ge 5 ]; do
	id=$1 path=$2 main=$3 branch=$4 base=$5
	shift 5
	if [ -d "$path" ]; then
		changes=$(git -C "$path" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
		ahead=$(git -C "$main" rev-list --count "$base..$branch" 2>/dev/null || echo 0)
		last=$(git -C "$path" log -1 --format=%cr 2>/dev/null)
		printf '%s\t%s\t%s\t%s\n' "$id" "$changes" "$ahead" "$last"
	else
		printf '%s\tmissing\n' "$id"
	fi
done
]]

-- Each task's PR, looked up by branch in parallel. Arguments come in
-- (id, main, branch) groups; each prints
--   id<TAB>number<TAB>state<TAB>draft<TAB>url<TAB>reviewDecision<TAB>checks
-- or "id<TAB>none" when the branch has no PR, or "id<TAB>error" when gh
-- failed (offline, not logged in), which leaves the last answer shown.
-- A Tern window started from the Dock has a short PATH, hence the additions.
local PR_SCRIPT = [[
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1
jq='.[0] // empty | [.number, .state, .isDraft, .url, (.reviewDecision // ""),
  (.statusCheckRollup
    | map(if .__typename == "CheckRun"
          then (if .status != "COMPLETED" then "pending"
                elif (.conclusion == "SUCCESS" or .conclusion == "SKIPPED" or .conclusion == "NEUTRAL") then "pass"
                else "fail" end)
          else (if (.state == "PENDING" or .state == "EXPECTED") then "pending"
                elif .state == "SUCCESS" then "pass" else "fail" end) end)
    | if length == 0 then "none" elif index("fail") then "fail"
      elif index("pending") then "pending" else "pass" end)] | @tsv'
while [ $# -ge 3 ]; do
	id=$1 main=$2 branch=$3
	shift 3
	(
		out=$(cd "$main" && gh pr list --state all --head "$branch" --limit 1 \
			--json number,state,isDraft,url,reviewDecision,statusCheckRollup --jq "$jq" 2>/dev/null)
		if [ $? -ne 0 ]; then
			printf '%s\terror\n' "$id"
		elif [ -z "$out" ]; then
			printf '%s\tnone\n' "$id"
		else
			printf '%s\t%s\n' "$id" "$out"
		fi
	) &
done
wait
]]

local function refresh_stats(cx: WindowCx)
	local args = task_args(cx, function(task)
		-- Tasks without a recorded base compare with the main checkout's HEAD.
		return { task.path, task.main, task.branch, task.base or "HEAD" }
	end)
	if #args == 0 then
		return
	end
	local argv = { "sh", "-c", STATS_SCRIPT, "sh" }
	table.move(args, 1, #args, #argv + 1, argv)
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
		apply_session_names(cx2)
	end)
end

local function refresh_prs(cx: WindowCx)
	local args = task_args(cx, function(task)
		return { task.main, task.branch }
	end)
	if #args == 0 then
		return
	end
	local argv = { "sh", "-c", PR_SCRIPT, "sh" }
	table.move(args, 1, #args, #argv + 1, argv)
	tern.process.run(argv, { timeout_ms = 60000 }, function(r, cx2)
		if cx2 == nil then
			return
		end
		for _, line in string.split(r.stdout, "\n") do
			local f = string.split(line, "\t")
			local id = tonumber(f[1] or "")
			if id ~= nil then
				if f[2] == "none" then
					prs[id] = false
				elseif #f >= 7 then
					prs[id] = {
						number = f[2],
						state = f[3],
						draft = f[4] == "true",
						url = f[5],
						review = f[6],
						checks = f[7],
					}
				end
				-- "error": keep whatever was shown before.
			end
		end
		render_dashboard(cx2)
		apply_session_names(cx2)
	end)
end

-- Refreshes every task's git and PR state, for the dashboard and the
-- session names. with_prs: also ask GitHub, which is slower and
-- rate-limited, so the refresh loop does it only every few ticks. redraw:
-- false leaves drawing to the process callbacks (the refresh loop's timer
-- only starts work).
local function refresh_tasks(cx: WindowCx, with_prs: boolean?, redraw: boolean?)
	if redraw ~= false then
		render_dashboard(cx)
	end
	refresh_stats(cx)
	if with_prs ~= false then
		refresh_prs(cx)
	end
end

local refresh_loop_running = false

local function start_refresh_loop()
	if refresh_loop_running then
		return
	end
	refresh_loop_running = true
	local ticks = 0
	local function tick()
		tern.timer(DASHBOARD_REFRESH_MS, function(cx)
			if cx == nil then
				refresh_loop_running = false
				return
			end
			ticks += 1
			refresh_tasks(cx, ticks % PR_REFRESH_EVERY == 0, false)
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
				refresh_tasks(cx)
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
					refresh_tasks(cx2)
				end
			)
		end
	)
end

-- Poll only an explicitly requested session close. Closing individual tabs or
-- an agent exiting must never remove a task's worktree.
local function session_closed(cx: WindowCx, id: number): boolean
	for _, session in cx.sessions:list() do
		if session.id == id then
			return session.tabs == 0 -- closing the final session leaves it empty
		end
	end
	return true
end

type Closing = { at: number, remove: boolean, return_to: number? }
local closing: { [number]: Closing } = {}

local function await_close(id: number, intent: Closing)
	tern.timer(CLOSE_POLL_MS, function(cx)
		if cx == nil or closing[id] ~= intent then
			return
		end
		if session_closed(cx, id) then
			closing[id] = nil
			local task = read_task(id)
			tern.kv.set(kv_key(id), nil)
			stats[id], prs[id] = nil, nil
			if intent.return_to ~= nil then
				pcall(function()
					cx.sessions:switch(intent.return_to)
				end)
			end
			if task ~= nil and intent.remove then
				remove_worktree(task)
			else
				refresh_tasks(cx)
			end
		elseif os.time() - intent.at < CLOSE_INTENT_S then
			await_close(id, intent)
		else
			closing[id] = nil -- confirmation cancelled or still unanswered
		end
	end)
end

local function close_task_session(cx: WindowCx, id: number, remove: boolean)
	for _, session in cx.sessions:list() do
		if session.id == id then
			if session.locked then
				cx:toast("info", "Unlock the task's session before deleting it")
				return
			end
			local current = cx.sessions:current().id
			local intent: Closing = {
				at = os.time(),
				remove = remove,
				return_to = if current ~= id then current else nil,
			}
			closing[id] = intent
			cx.sessions:switch(id)
			cx:command("close_session") -- built-in confirmation; overrides are bypassed
			await_close(id, intent)
			return
		end
	end
end

local function delete_task(cx: WindowCx, id: number, task: Task)
	if not tern.fs.exists(task.path) then
		close_task_session(cx, id, false)
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
			close_task_session(cx2, id, true)
		end
	)
end

---------------------------------------------------------------------------
-- Starting a task

-- Creates the branch and worktree. Without a base, uses the repository's
-- default branch: origin's (origin/HEAD, else origin/main or origin/master),
-- else a local main or master, else the starting pane's HEAD. From a
-- remote-tracking base (origin/…), fetches that branch first so the task
-- starts from its latest commit, and leaves the new branch without an
-- upstream so a push goes to its own name. Prints the base it used.
local WORKTREE_ADD_SCRIPT = [[
branch=$1 path=$2 base=$3
mkdir -p "$(dirname "$path")" || exit 1
if [ -z "$base" ]; then
	base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
fi
for ref in refs/remotes/origin/main refs/remotes/origin/master refs/heads/main refs/heads/master; do
	[ -n "$base" ] && break
	git show-ref --verify --quiet "$ref" && base=${ref#refs/*/}
done
base=${base:-HEAD}
full=$(git rev-parse --symbolic-full-name "$base" 2>/dev/null)
case "$full" in
refs/remotes/*)
	rest=${full#refs/remotes/}
	git fetch --quiet "${rest%%/*}" "${rest#*/}" || echo "could not fetch $base; using the local copy" >&2
	;;
esac
git worktree add --no-track -b "$branch" "$path" "$base" >&2 || exit 1
echo "$base"
]]

-- The base as the settings screen and toasts name it.
local function base_label(base: string?): string
	if base == nil then
		return "the repository's default branch"
	elseif base == "HEAD" then
		return "the focused pane's current branch"
	end
	return base
end

-- Opens the session for a task whose worktree is ready, with the agent in it.
local function open_task_session(cx: WindowCx, task: Task)
	local session = cx.sessions:create({ name = task.name, cwd = task.path })
	tern.kv.set(kv_key(session.id), task)
	tern.kv.set("last_main", task.main)
	cx:toast("success", "Task started: " .. task.name, task.path)
	refresh_tasks(cx)
	if OPEN_AGENT then
		-- The default agent in the worktree, taking the place of the new
		-- session's lone shell. Failing that, Tern's own
		-- New agent block beside the shell. Last, so little runs after the
		-- heaviest step.
		local started = pcall(function()
			cx.agents:start({ prompt = "", cwd = task.path, how = "replace_if_alone" })
		end)
		if not started then
			cx:command("new_agent_block")
		end
	end
end

-- The task whose worktree is being created, kept until its session opens: a
-- reload drops the callback of the process creating it (a linked plugin
-- reloads on any change in its folder, .git included, so a task started in
-- the plugin's own repository always reloads it), and the next load finishes
-- the task from this record.
local PENDING_KEY = "pending_task"
-- Give up on a pending task after this many seconds, or sooner when its
-- worktree never shows up.
local PENDING_MAX_S = 300
local PENDING_MISSING_S = 30

local function start_task(cwd: string, task: Task)
	tern.kv.set(PENDING_KEY, { task = task, since = os.time() })
	tern.process.run(
		{ "sh", "-c", WORKTREE_ADD_SCRIPT, "sh", task.branch, task.path, task.base or "" },
		{ cwd = cwd, timeout_ms = 120000 },
		function(r, cx)
			tern.kv.set(PENDING_KEY, nil)
			if cx == nil then
				return
			end
			if r.status ~= 0 then
				cx:toast("error", "Could not create the task's worktree", trim(r.stderr))
				return
			end
			-- The base actually used; "HEAD" is recorded as none, so the
			-- dashboard compares with the main checkout's branch.
			local used = trim(r.stdout)
			task.base = if used ~= "" and used ~= "HEAD" then used else nil
			open_task_session(cx, task)
		end
	)
end

-- After a load: finishes a task whose worktree was being created when the
-- plugin reloaded. git locks a new worktree ("initializing") until its
-- checkout is done, so this waits for it to be listed unlocked.
local function resume_pending_task()
	local pending: any = tern.kv.get(PENDING_KEY)
	if pending == nil then
		return
	end
	local task: Task = pending.task
	local age = os.time() - pending.since
	if age > PENDING_MAX_S then
		tern.kv.set(PENDING_KEY, nil)
		return
	end
	tern.process.run(
		{ "git", "worktree", "list", "--porcelain" },
		{ cwd = task.main, timeout_ms = 10000 },
		function(r, cx)
			if cx == nil or tern.kv.get(PENDING_KEY) == nil then
				return
			end
			-- Porcelain: a "worktree <path>" line starts each worktree's
			-- lines, "locked [reason]" among them while it's locked.
			local listed, locked, current = false, false, nil
			for _, line in string.split(r.stdout, "\n") do
				local path = string.match(line, "^worktree (.+)$")
				if path ~= nil then
					current = path
					listed = listed or path == task.path
				elseif current == task.path and string.match(line, "^locked") then
					locked = true
				end
			end
			if listed and not locked then
				tern.kv.set(PENDING_KEY, nil)
				-- The base the script resolved is lost with its output; a
				-- requested base is the same, and none compares with HEAD.
				open_task_session(cx, task)
			elseif not listed and age > PENDING_MISSING_S then
				tern.kv.set(PENDING_KEY, nil)
				cx:toast("error", "Could not create the task's worktree", task.path)
			else
				tern.timer(1000, function()
					resume_pending_task()
				end)
			end
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
				local base = repo_settings(main).base
				cx3:toast("info", "Starting task " .. name .. "…", branch .. " from " .. base_label(base))
				start_task(cwd, {
					name = name,
					branch = branch,
					path = task_path(main, branch),
					main = main,
					base = repo_settings(main).base,
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
-- Settings screen

local SETTINGS_TITLE = "Task settings"

local function settings_pane(cx: WindowCx): number?
	for _, c in cx.canvas:list() do
		if c.owner == tern.plugin.id and c.title == SETTINGS_TITLE then
			return c.pane
		end
	end
	return nil
end

local function settings_view(main: string): Node
	local base = repo_settings(main).base
	local actions: { Node } = { button("Change…", "base_change=" .. main, "primary") }
	if base then
		table.insert(actions, button("Use the default branch", "base_reset=" .. main))
	end
	local root = global_settings().worktree_root
	local root_actions: { Node } = { button("Change…", "root_change", "primary") }
	if root then
		table.insert(root_actions, button("Use the default (" .. DEFAULT_WORKTREE_ROOT .. ")", "root_reset"))
	end
	return ui.col({
		ui.rule({ ui.span("All repositories", "muted") }),
		ui.card({ ui.span("Worktree folder", "strong") }, {
			ui.text({ ui.span(root or DEFAULT_WORKTREE_ROOT, "code strong") }),
			ui.text({
				ui.span(
					"New tasks' worktrees go in <folder>/<repository>/<branch>. Existing tasks stay where they are.",
					"muted"
				),
			}),
			ui.el("div", { class = "tk-actions" }, root_actions),
		}),
		ui.rule({ ui.span("This repository", "muted") }),
		ui.kv({ { "repository", ui.path(main) } }),
		ui.card({ ui.span("Base branch for new tasks", "strong") }, {
			ui.text({
				if base == nil
					then ui.span("The repository's default branch", "strong")
					elseif base == "HEAD" then ui.span("The focused pane's current branch", "strong")
					else ui.span(base, "code strong"),
			}),
			ui.text({
				ui.span(
					"New tasks branch from here. A remote branch (origin/…) is fetched first, so a task starts from its latest commit.",
					"muted"
				),
			}),
			ui.el("div", { class = "tk-actions" }, actions),
		}),
	})
end

local function render_settings(cx: WindowCx)
	local pane = settings_pane(cx)
	local main: string? = tern.kv.get("settings_main")
	if pane ~= nil and main ~= nil then
		cx.canvas:set(pane, { view = settings_view(main) })
	end
end

local function open_settings(cx: WindowCx, main: string)
	tern.kv.set("settings_main", main)
	local pane = settings_pane(cx)
	if pane ~= nil then
		render_settings(cx)
		pcall(function()
			cx.layout:focus(pane :: number)
		end)
		return
	end
	local opened, err = cx.canvas:open({
		title = SETTINGS_TITLE,
		about = "Settings for the Tasks plugin, per repository. Change… picks the branch new tasks start from.",
		view = settings_view(main),
	})
	if opened == nil then
		cx:toast("error", "Could not open task settings", err)
	end
end

-- Local and remote branches, most recently committed first.
local function choose_base(cx: WindowCx, main: string)
	tern.process.run(
		{ "git", "for-each-ref", "--sort=-committerdate", "--count=300", "--format=%(refname)", "refs/heads", "refs/remotes" },
		{ cwd = main, timeout_ms = 10000 },
		function(r, cx2)
			if cx2 == nil then
				return
			end
			if r.status ~= 0 then
				cx2:toast("error", "Could not list branches", trim(r.stderr))
				return
			end
			local current = repo_settings(main).base
			local items: { PickItem } = {
				{ label = "The repository's default branch", detail = "default", group = "Default", ref = false, current = current == nil },
				{ label = "The focused pane's current branch", group = "Default", ref = "HEAD", current = current == "HEAD" },
			}
			for _, full in string.split(trim(r.stdout), "\n") do
				local ref, group
				if string.sub(full, 1, 11) == "refs/heads/" then
					ref, group = string.sub(full, 12), "Local branches"
				elseif string.sub(full, 1, 13) == "refs/remotes/" and string.sub(full, -5) ~= "/HEAD" then
					ref, group = string.sub(full, 14), "Remote branches"
				end
				if ref then
					table.insert(items, { label = ref, group = group, ref = ref, current = ref == current })
				end
			end
			-- Default first, then remote branches (the usual base), then local;
			-- by position within a group, as table.sort isn't stable.
			local order = { Default = 1, ["Remote branches"] = 2, ["Local branches"] = 3 }
			local position = {}
			for i, item in items do
				position[item] = i
			end
			table.sort(items, function(a, b)
				local ga, gb = order[a.group] or 9, order[b.group] or 9
				if ga ~= gb then
					return ga < gb
				end
				return position[a] < position[b]
			end)
			cx2:pick({ items = items, placeholder = "Base branch for new tasks", action = "use" }):next(function(item, _err, cx3)
				if cx3 == nil or item == nil then
					return
				end
				local ref: string? = if item.ref then item.ref else nil
				set_base(main, ref)
				render_settings(cx3)
				cx3:toast("success", "New tasks branch from " .. base_label(ref))
			end)
		end
	)
end

-- Finds the repository holding cwd and opens its settings.
local function settings_from(cx: WindowCx, cwd: string)
	local started = pcall(
		tern.process.run,
		{ "git", "rev-parse", "--path-format=absolute", "--git-common-dir" },
		{ cwd = cwd, timeout_ms = 5000 },
		function(r, cx2)
			if cx2 == nil then
				return
			end
			if r.status ~= 0 then
				cx2:toast("error", "Task settings need a pane inside a git repository", cwd)
				return
			end
			open_settings(cx2, (string.gsub(trim(r.stdout), "/%.git$", "")))
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
		local id = cx.sessions:current().id
		local task = read_task(id)
		if task ~= nil then
			delete_task(cx, id, task)
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
		set_dashboard_repo(cx)
		local pane = dashboard_pane(cx, true)
		if pane ~= nil then
			pcall(function()
				cx.layout:focus(pane :: number)
			end)
		else
			open_dashboard_tab(cx, true)
		end
		refresh_tasks(cx)
		start_refresh_loop()
	end,
})

tern.command({
	id = "task_settings",
	title = "Task settings",
	group = "Tasks",
	run = function(cx)
		local cwd = window_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("error", "Task settings need a pane inside a git repository")
			return
		end
		settings_from(cx, cwd)
	end,
})

local function task_action(act: string, value: string?, cx: WindowCx): boolean
	local id = tonumber(value or "")
	if act == "refresh" then
		refresh_tasks(cx)
	elseif act == "new" then
		local cwd: string? = window_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("info", "Start the first task with New task from a pane inside the repository")
		else
			new_task_from(cx, cwd)
		end
	elseif act == "settings" then
		local cwd: string? = window_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("info", "Run Task settings from a pane inside the repository")
		else
			settings_from(cx, cwd)
		end
	elseif act == "base_change" and value then
		choose_base(cx, value)
	elseif act == "root_change" then
		cx:prompt({
			value = worktree_root(),
			placeholder = "Folder for task worktrees",
			action = "save",
		}):next(function(answer, _err, cx2)
			if cx2 == nil or answer == nil then
				return
			end
			local root = string.gsub(trim(answer), "(.)/+$", "%1")
			if root == "" then
				return
			end
			if string.sub(root, 1, 1) ~= "/" and string.sub(root, 1, 1) ~= "~" then
				cx2:toast("error", "Use an absolute path or one starting with ~", root)
				return
			end
			set_worktree_root(if root == DEFAULT_WORKTREE_ROOT then nil else root)
			render_settings(cx2)
			cx2:toast("success", "New tasks' worktrees go in " .. root)
		end)
	elseif act == "root_reset" then
		set_worktree_root(nil)
		render_settings(cx)
		cx:toast("success", "New tasks' worktrees go in " .. DEFAULT_WORKTREE_ROOT)
	elseif act == "base_reset" and value then
		set_base(value, nil)
		render_settings(cx)
		cx:toast("success", "New tasks branch from " .. base_label(nil))
	elseif act == "open" and id ~= nil then
		cx.sessions:switch(id)
	elseif act == "delete" and id ~= nil then
		local task = read_task(id)
		if task ~= nil then
			delete_task(cx, id, task)
		end
	else
		return false
	end
	return true
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx)
	return ev.owner == tern.plugin.id and task_action(ev.act, ev.value, cx)
end)

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #DASHBOARD_LINK_PREFIX) ~= DASHBOARD_LINK_PREFIX or link.pane == nil then
		return nil
	end
	local pane = cx.session:pane(link.pane)
	if pane == nil or pane.block ~= DASHBOARD_KIND then
		return nil
	end
	local act, value = string.match(string.sub(link.url, #DASHBOARD_LINK_PREFIX + 1), "^([a-z]+)/(%d*)$")
	if act ~= nil and task_action(act, value, cx) then
		return { handled = true }
	end
	return nil
end)

-- Let Tern handle confirmation and locks; clean up only after it closes.
tern.override("close_session", function(cx)
	local session = cx.sessions:current()
	if session.tabs == 0 and closing[session.id] == nil then
		-- Tern may close an empty session after its last pane exits. Forget
		-- ownership without removing files, including for the final session.
		tern.kv.set(kv_key(session.id), nil)
		stats[session.id], prs[session.id] = nil, nil
	elseif read_task(session.id) ~= nil and not session.locked and session.tabs > 0 then
		local intent: Closing = { at = os.time(), remove = true }
		closing[session.id] = intent
		await_close(session.id, intent)
	end
	return false
end)

---------------------------------------------------------------------------
-- On load

-- Bind cmd+shift+n to New task once, through Tern's settings API: Tern
-- rewrites settings.json from its own copy, so hand edits to the file while
-- it runs get lost. The kv flag keeps a later rebinding of yours in place.
local NEW_TASK_CHORD = "cmd+shift+n"
local NEW_TASK_ACTION = "plugin." .. tern.plugin.id .. ".new_task"

-- Adopt a single legacy task in place. Shared sessions keep their running
-- panes: each legacy task is moved atomically into a new session. Migrate
-- one per tick to stay within the UI handler budget.
local function migrate_tab_tasks(cx: WindowCx)
	for _, session in cx.session:sessions() do
		for _, tab in session.tabs do
			local key = "tab:" .. tostring(tab)
			local task: Task? = tern.kv.get(key)
			if task ~= nil then
				task.name = task.name or task.branch
				if #session.tabs == 1 and read_task(session.id) == nil then
					tern.kv.set(kv_key(session.id), task)
					cx.sessions:rename(session.id, task.name)
				else
					local blocks = {}
					for _, pane in cx.session:panes() do
						if pane.tab == tab then
							table.insert(blocks, pane.pane)
						end
					end
					if #blocks == 0 then
						return
					end
					local focused = cx.session:focused()
					local previous = cx.sessions:current().id
					cx.sessions:switch(session.id) -- create on the task's host
					local target = cx.sessions:create({ name = task.name, cwd = task.path })
					local moved, err = cx.layout:arrange({
						session = target.id,
						tabs = { { name = task.name, blocks = blocks } },
						rest = "keep",
					})
					pcall(function()
						cx.sessions:switch(previous)
						if focused ~= nil then
							cx.layout:focus(focused)
						end
					end)
					if moved == nil then
						cx:toast("error", "Could not migrate task " .. task.name, err)
						return -- retain the old record and every running pane
					end
					tern.kv.set(kv_key(target.id), task)
				end
				tern.kv.set(key, nil)
				tern.timer(0, function(cx2)
					if cx2 ~= nil then
						migrate_tab_tasks(cx2)
					end
				end)
				return
			end
		end
	end
end

tern.timer(0, function(cx)
	if cx == nil then
		return
	end
	if not tern.kv.get("new_task_bound") then
		cx.settings:bind(NEW_TASK_CHORD, NEW_TASK_ACTION)
		tern.kv.set("new_task_bound", true)
		cx:toast("info", "⌘⇧N now starts a new task")
	end
	migrate_tab_tasks(cx)
	migrate_dashboard_canvas(cx)
	resume_pending_task()
	-- Keep session names and dashboard blocks up to date. A timer starts the
	-- work; the process callbacks send snapshots to the block renderer.
	-- The first refresh waits out window startup, when the UI thread is
	-- busy enough for a callback to overrun its budget.
	tern.timer(STARTUP_REFRESH_DELAY_MS, function(cx2)
		if cx2 == nil then
			return
		end
		refresh_tasks(cx2, true, false)
		start_refresh_loop()
	end)
end)
