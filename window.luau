--!strict
-- Tasks: a task is a session with its own git worktree.
--
-- New task (palette, cmd+shift+n): asks for a task name, creates a worktree
-- on a new branch named after it (from the focused pane's HEAD) beside the
-- main checkout, and opens a session named after the task running only the
-- default agent (Tern's New agent block) in the worktree.
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
-- Task dashboard: a kanban canvas of the open tasks, in columns by pull
-- request (In progress: none yet, Draft, In review, Done: merged or closed),
-- each card with its git state, PR checks and review, and Open / Delete
-- buttons. It refreshes itself while open: git every 15 s, GitHub (gh)
-- every minute.
--
-- Window handlers run on the UI thread under a 50 ms budget, and one overrun
-- disables the handler until the plugins reload. So handlers only read
-- window state and start processes; git and the name prompt run in
-- callbacks.

local ui = tern.ui

tern.css(
	"board",
	[[
.tk-board { display: flex; gap: 12px; align-items: flex-start; overflow-x: auto; }
.tk-column { flex: 1 1 0; min-width: 260px; display: flex; flex-direction: column; gap: 8px; }
.tk-toolbar { display: flex; gap: 8px; }
.tk-actions { display: flex; gap: 6px; }
/* ui.el buttons come unstyled (class sf-el); give them button chrome. */
button.tk-btn {
	padding: 3px 12px;
	border: 1px solid var(--l2);
	border-radius: 6px;
	background: var(--l1);
	color: var(--t1);
	cursor: pointer;
}
button.tk-btn:hover { background: var(--l2); }
button.tk-btn.primary { background: var(--accent); border-color: var(--accent); color: var(--page); }
button.tk-btn.danger { color: var(--bad); }
button.tk-btn.danger:hover { border-color: var(--bad); }
]]
)

-- How long to wait for a close to finish, e.g. while Tern asks to confirm
-- ending a running program.
local CLOSE_POLL_MS = 500
local CLOSE_POLL_TRIES = 240

local DASHBOARD_TITLE = "Tasks"
local DASHBOARD_REFRESH_MS = 15000
-- Start the default agent in a new task's session.
local OPEN_AGENT = true
-- Pull requests every 4th refresh (once a minute), as GitHub rate-limits.
local PR_REFRESH_EVERY = 4

-- base: the ref the branch was created from (nil: the starting pane's HEAD).
type Task = { name: string, branch: string, path: string, main: string, base: string? }
type OpenTask = { id: number, task: Task, current: boolean }
-- Git state of a task's worktree, as the dashboard shows it.
type Stats = { changes: number, ahead: number, last: string } | { missing: true }

-- The task branch's pull request, from gh. checks: "pass" | "fail" |
-- "pending" | "none"; review: GitHub's reviewDecision, "" when there is none.
type Pr = {
	number: string,
	state: string,
	draft: boolean,
	url: string,
	review: string,
	checks: string,
}

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
-- Settings, per repository (keyed by the main checkout's path)

type RepoSettings = {
	-- Ref new tasks branch from, e.g. "origin/cycle-86"; nil: the focused
	-- pane's current branch.
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

-- variant: "primary" or "danger" (see the board CSS).
local function button(text: string, act: string, variant: string?): Node
	local class = if variant then "tk-btn " .. variant else "tk-btn"
	return ui.el("button", { class = class, text = text, actions = { click = act } })
end

-- Kanban columns, left to right. A task's column comes from its PR.
local COLUMNS = {
	{ id = "progress", title = "In progress" },
	{ id = "draft", title = "Draft" },
	{ id = "review", title = "In review" },
	{ id = "done", title = "Done" },
}

local function column_of(id: number): string
	local pr = prs[id]
	if not pr then
		return "progress" -- no PR yet (or not fetched yet)
	elseif pr.state == "MERGED" or pr.state == "CLOSED" then
		return "done"
	elseif pr.draft then
		return "draft"
	end
	return "review"
end

local CHECK_BADGES = {
	pass = { "checks pass", "success" },
	fail = { "checks fail", "error" },
	pending = { "checks running", "pending" },
}
local REVIEW_BADGES = {
	APPROVED = { "approved", "success" },
	CHANGES_REQUESTED = { "changes requested", "error" },
	REVIEW_REQUIRED = { "review required", "muted" },
}

local function pr_line(id: number): Node?
	local pr = prs[id]
	if pr == nil then
		return ui.text({ ui.span("PR: checking…", "muted") })
	elseif pr == false then
		return ui.text({ ui.span("No pull request", "muted") })
	end
	local p = pr :: Pr
	local parts: { Node } = {
		ui.text({ ui.link("#" .. p.number, p.url, "strong") }),
		ui.badge(string.lower(p.state), if p.state == "MERGED" then "accent" elseif p.state == "CLOSED" then "muted" else "info"),
	}
	local check = CHECK_BADGES[p.checks]
	if check and p.state == "OPEN" then
		table.insert(parts, ui.badge(check[1], check[2]))
	end
	local review = REVIEW_BADGES[p.review]
	if review and p.state == "OPEN" then
		table.insert(parts, ui.badge(review[1], review[2]))
	end
	return ui.row(parts)
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
	local body: { Node } = {}
	local pr = pr_line(t.id)
	if pr then
		table.insert(body, pr)
	end
	table.insert(body, ui.row(badges))
	table.insert(
		body,
		ui.kv({
			{ "branch", ui.span(t.task.branch, "code") },
			{ "worktree", ui.path(t.task.path) },
			{ "last commit", last },
		})
	)
	table.insert(
		body,
		ui.el("div", { class = "tk-actions" }, {
			button("Open", "open=" .. tostring(t.id)),
			button("Delete", "delete=" .. tostring(t.id), "danger"),
		})
	)
	return ui.card({ ui.span(t.task.name, "strong") }, body)
end

local function board_view(tasks: { OpenTask }): Node
	local by_column: { [string]: { OpenTask } } = {}
	for _, c in COLUMNS do
		by_column[c.id] = {}
	end
	for _, t in tasks do
		table.insert(by_column[column_of(t.id)], t)
	end

	local columns: { Node } = {}
	for _, c in COLUMNS do
		local cards: { Node } = {
			ui.text({ ui.span(c.title, "strong"), ui.span("  " .. #by_column[c.id], "muted num") }),
		}
		for _, t in by_column[c.id] do
			table.insert(cards, task_card(t))
		end
		table.insert(columns, ui.el("div", { class = "tk-column" }, cards))
	end

	local children: { Node } = {
		ui.el("div", { class = "tk-toolbar" }, {
			button("+ New task", "new", "primary"),
			button("↻ Refresh", "refresh"),
			button("⚙ Settings", "settings"),
		}),
	}
	if #tasks == 0 then
		table.insert(children, ui.md("No open tasks. **New task** starts one."))
	end
	table.insert(children, ui.el("div", { class = "tk-board" }, columns))
	return ui.col(children)
end

local function dashboard_view(cx: WindowCx): Node
	return board_view(open_tasks(cx))
end

-- What the board shows, as a string: an unchanged board isn't redrawn.
-- Building and sending the view is the costly part of a refresh, and a
-- handler that runs past its 50 ms budget is disabled until reload.
local function board_signature(tasks: { OpenTask }): string
	local parts = {}
	for _, t in tasks do
		local st: any = stats[t.id]
		local pr: any = prs[t.id]
		table.insert(
			parts,
			table.concat({
				tostring(t.id),
				t.task.name,
				tostring(t.current),
				if st == nil then "?" elseif st.missing then "missing" else st.changes .. "," .. st.ahead .. "," .. st.last,
				if pr == nil then "?" elseif pr == false then "none" else table.concat({ pr.number, pr.state, tostring(pr.draft), pr.review, pr.checks }, ","),
			}, "|")
		)
	end
	return table.concat(parts, "\n")
end

local drawn_signature: string? = nil

local function render_dashboard(cx: WindowCx, force: boolean?)
	local pane = dashboard_pane(cx)
	if pane == nil then
		return
	end
	local tasks = open_tasks(cx)
	local signature = board_signature(tasks)
	if not force and signature == drawn_signature then
		return
	end
	drawn_signature = signature
	cx.canvas:set(pane, { view = board_view(tasks) })
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
	end)
end

-- with_prs: also ask GitHub, which is slower and rate-limited, so the
-- refresh loop does it only every few ticks. redraw: false leaves drawing
-- to the process callbacks (the refresh loop's timer only starts work).
local function refresh_dashboard(cx: WindowCx, with_prs: boolean?, redraw: boolean?)
	if dashboard_pane(cx) == nil then
		return
	end
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
			if cx == nil or dashboard_pane(cx) == nil then
				refresh_loop_running = false
				return
			end
			ticks += 1
			refresh_dashboard(cx, ticks % PR_REFRESH_EVERY == 0, false)
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

-- Creates the branch and worktree. From a remote-tracking base (origin/…),
-- fetches that branch first so the task starts from its latest commit, and
-- leaves the new branch without an upstream so a push goes to its own name.
local WORKTREE_ADD_SCRIPT = [[
branch=$1 path=$2 base=$3
if [ -z "$base" ]; then
	exec git worktree add --no-track -b "$branch" "$path"
fi
full=$(git rev-parse --symbolic-full-name "$base" 2>/dev/null)
case "$full" in
refs/remotes/*)
	rest=${full#refs/remotes/}
	git fetch --quiet "${rest%%/*}" "${rest#*/}" || echo "could not fetch $base; using the local copy" >&2
	;;
esac
exec git worktree add --no-track -b "$branch" "$path" "$base"
]]

local function start_task(cwd: string, task: Task)
	tern.process.run(
		{ "sh", "-c", WORKTREE_ADD_SCRIPT, "sh", task.branch, task.path, task.base or "" },
		{ cwd = cwd, timeout_ms = 120000 },
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
			if OPEN_AGENT then
				-- Tern's own New agent block: the default agent, in the focused
				-- pane's directory (the new session's first pane, in the
				-- worktree). Then close that shell so the session holds only
				-- the agent; with agent placement set to replace an idle shell
				-- it is already gone. Last, so little runs after the heaviest
				-- step.
				local shell = cx.session:focused()
				cx:command("new_agent_block")
				if shell ~= nil and cx.session:focused() ~= shell then
					pcall(function()
						cx.layout:close(shell :: number)
					end)
				end
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
				cx3:toast("info", "Starting task " .. name .. "…", if base then branch .. " from " .. base else branch)
				start_task(cwd, {
					name = name,
					branch = branch,
					-- Beside the main checkout whichever worktree the task was
					-- started from; fix/login becomes the suffix fix-login.
					path = main .. "-" .. string.gsub(branch, "/", "-"),
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
		table.insert(actions, button("Use the focused pane's branch", "base_reset=" .. main))
	end
	return ui.col({
		ui.kv({ { "repository", ui.path(main) } }),
		ui.card({ ui.span("Base branch for new tasks", "strong") }, {
			ui.text({
				if base then ui.span(base, "code strong") else ui.span("The focused pane's current branch", "strong"),
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
				{ label = "The focused pane's current branch", detail = "default", group = "Default", ref = false, current = current == nil },
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
			table.sort(items, function(a, b)
				-- Default first, then remote branches (the usual base), then local.
				local order = { Default = 1, ["Remote branches"] = 2, ["Local branches"] = 3 }
				return (order[a.group] or 9) < (order[b.group] or 9)
			end)
			cx2:pick({ items = items, placeholder = "Base branch for new tasks", action = "use" }):next(function(item, _err, cx3)
				if cx3 == nil or item == nil then
					return
				end
				local ref: string? = if item.ref then item.ref else nil
				set_base(main, ref)
				render_settings(cx3)
				cx3:toast("success", "New tasks branch from " .. (ref or "the focused pane's current branch"))
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

tern.command({
	id = "task_settings",
	title = "Task settings",
	group = "Tasks",
	run = function(cx)
		local cwd = focused_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("error", "Task settings need a pane inside a git repository")
			return
		end
		settings_from(cx, cwd)
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
	elseif ev.act == "settings" then
		local main: string? = tern.kv.get("last_main")
		if main == nil then
			cx:toast("info", "Run Task settings from a pane inside the repository")
		else
			open_settings(cx, main)
		end
	elseif ev.act == "base_change" and ev.value then
		choose_base(cx, ev.value :: string)
	elseif ev.act == "base_reset" and ev.value then
		set_base(ev.value :: string, nil)
		render_settings(cx)
		cx:toast("success", "New tasks branch from the focused pane's current branch")
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
		refresh_dashboard(cx, true, false) -- a timer: start the work, draw from its callbacks
		start_refresh_loop()
	end
end)
