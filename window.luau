--!strict
-- Tasks: a task is a tab with its own git worktree.
--
-- New task (palette, cmd+shift+n): asks for a task name, creates a worktree
-- on a new branch named after it (from the base branch setting, else the
-- repository's default branch) under the worktree folder setting (default
-- ~/tern/worktrees), and opens a tab in the current session named after the
-- task, running the default agent in the worktree.
--
--   task name:      Fix login redirect
--   branch:         fix-login-redirect
--   worktree:       ~/tern/worktrees/resvu-platform-agent/fix-login-redirect
--   tab:            Fix login redirect
--
-- Delete task: the current tab's task, or one picked from the open tasks.
-- Refuses while the worktree has uncommitted or untracked changes;
-- otherwise closes the tab (with Tern's usual confirmation) and then
-- removes the worktree and branch.
--
-- Close tab on a task's tab (or Close session on a session holding task
-- tabs): once it has closed, removes the worktree and deletes the branch.
-- git refuses both when they would lose work (uncommitted changes, unmerged
-- commits); the worktree or branch is then kept and a toast says why. A task
-- tab that closes any other way (its last pane exited, say) keeps both.
--
-- Tab names: each task's tab is named "<task> · <status>", e.g.
-- "Fix login · #3413 ✓ · ±2" (PR, checks, uncommitted files), kept up to
-- date in the background.
--
-- Task dashboard: a kanban canvas of the open tasks in the current
-- repository, in columns by pull request (In progress: none yet, Draft, In
-- review, Done: merged or closed), each card with its git state, PR checks
-- and review, and Open / Delete buttons. Task state refreshes in the
-- background: git every 15 s, GitHub (gh) every minute.
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

-- How long after Close tab or Delete task a task's tab closing still counts
-- as asked for, e.g. while Tern asks to confirm ending a running program.
local CLOSE_INTENT_S = 120

local DASHBOARD_TITLE = "Tasks"
local DASHBOARD_REFRESH_MS = 15000
-- Start the default agent in a new task's tab.
local OPEN_AGENT = true
-- Append each task's status to its tab name ("Fix login · #3413 ✓ · ±2").
local STATUS_IN_TAB_NAMES = true
-- Pull requests every 4th refresh (once a minute), as GitHub rate-limits.
local PR_REFRESH_EVERY = 4

-- base: the ref the branch was created from (nil: the starting pane's HEAD).
type Task = { name: string, branch: string, path: string, main: string, base: string? }
-- id: the task's tab; session: the session holding it.
type OpenTask = { id: number, session: number, task: Task, current: boolean }
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

local function kv_key(tab_id: number): string
	return "tab:" .. tostring(tab_id)
end

local function read_task(tab_id: number): Task?
	local task: Task? = tern.kv.get(kv_key(tab_id))
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
	local here = current_tab(cx)
	local found = {}
	for _, s in cx.session:sessions() do
		for _, tab in s.tabs do
			local task = read_task(tab)
			if task ~= nil then
				table.insert(found, { id = tab, session = s.id, task = task, current = s.current and tab == here })
			end
		end
	end
	return found
end

-- Shows a tab, switching to its session first.
local function show_tab(cx: WindowCx, tab: number)
	for _, s in cx.session:sessions() do
		if table.find(s.tabs, tab) ~= nil then
			if not s.current then
				cx.sessions:switch(s.id)
			end
			local layout = cx.session:layout(tab)
			if layout ~= nil then
				cx.layout:focus(layout.focus)
			end
			return
		end
	end
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

-- The focused pane's directory, or else the first pane in this session with
-- one: canvas panes such as the dashboard have no directory.
local function window_cwd(cx: WindowCx): string?
	local cwd = focused_cwd(cx)
	if cwd ~= nil then
		return cwd
	end
	for _, pane in cx.session:panes() do
		if pane.cwd ~= "" then
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

-- The main checkout whose tasks the board shows, set when the dashboard is
-- opened from a pane's directory; nil shows every task. In the kv store, as
-- the board outlives reloads.
local DASHBOARD_MAIN_KEY = "dashboard_main"

local function board_tasks(cx: WindowCx): { OpenTask }
	local main: string? = tern.kv.get(DASHBOARD_MAIN_KEY)
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
	local main: string? = tern.kv.get(DASHBOARD_MAIN_KEY)
	if main ~= nil then
		table.insert(children, ui.kv({ { "repository", ui.path(main) } }))
	end
	if #tasks == 0 then
		table.insert(children, ui.md("No open tasks. **New task** starts one."))
	end
	table.insert(children, ui.el("div", { class = "tk-board" }, columns))
	return ui.col(children)
end

local function dashboard_view(cx: WindowCx): Node
	return board_view(board_tasks(cx))
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
	local tasks = board_tasks(cx)
	local signature = (tern.kv.get(DASHBOARD_MAIN_KEY) or "") .. "\n" .. board_signature(tasks)
	if not force and signature == drawn_signature then
		return
	end
	drawn_signature = signature
	cx.canvas:set(pane, { view = board_view(tasks) })
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

-- Points the board at the repository holding the current session's
-- directory: a known task's at once, then git's answer.
local function set_dashboard_repo(cx: WindowCx)
	local cwd = window_cwd(cx)
	if cwd == nil then
		return -- no directory to go by: keep showing what the board shows
	end
	local guess = known_main(cx, cwd)
	if guess ~= nil then
		tern.kv.set(DASHBOARD_MAIN_KEY, guess)
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
			tern.kv.set(DASHBOARD_MAIN_KEY, main)
			render_dashboard(cx2)
		end
	)
end

---------------------------------------------------------------------------
-- Status in tab names

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

-- Renames each task's tab to "<task name><status suffix>", only when that
-- changes it. The part before the first separator is the task's name, so
-- renaming a tab by hand renames its task.
local function apply_tab_names(cx: WindowCx)
	if not STATUS_IN_TAB_NAMES then
		return
	end
	for _, tab in cx.session:tabs() do
		local task = read_task(tab.id)
		-- Wait for both answers, so a reload doesn't strip the suffix and
		-- put it back a moment later.
		if task ~= nil and stats[tab.id] ~= nil and prs[tab.id] ~= nil then
			local name = tab.name or ""
			local base = string.match(name, "^(.-)" .. NAME_SEPARATOR) or name
			if base ~= "" and base ~= task.name then
				task.name = base
				tern.kv.set(kv_key(tab.id), task)
			end
			local wanted = task.name .. status_suffix(tab.id)
			if name ~= wanted then
				cx.layout:name_tab(tab.id, wanted)
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
		apply_tab_names(cx2)
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
		apply_tab_names(cx2)
	end)
end

-- Refreshes every task's git and PR state, for the dashboard and the
-- tab names. with_prs: also ask GitHub, which is slower and
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

-- Task tabs being closed on purpose (Close tab, Close session, Delete
-- task), until their tab_closed. at: os.time() of the request; remove:
-- whether to remove the worktree; return_to: the pane to show again (Delete
-- task from the dashboard switches away to close the task's tab).
type Closing = { at: number, remove: boolean, return_to: number? }
local closing: { [number]: Closing } = {}

local function tab_closed(cx: WindowCx, tab: number)
	local task = read_task(tab)
	if task == nil then
		return
	end
	tern.kv.set(kv_key(tab), nil)
	stats[tab] = nil
	prs[tab] = nil
	local asked = closing[tab]
	closing[tab] = nil
	if asked ~= nil and os.time() - asked.at <= CLOSE_INTENT_S then
		if asked.return_to ~= nil then
			local back = cx.session:tab_of(asked.return_to :: number)
			if back ~= nil then
				pcall(show_tab, cx, back)
			end
		end
		if asked.remove then
			remove_worktree(task)
			return
		end
	end
	-- Closed some other way (its last pane exited, say): keep the worktree
	-- and branch, and forget the task.
	refresh_tasks(cx)
end

-- Tern's own Close tab on the task's tab, with its confirmation; the
-- tab_closed hook does the rest.
local function close_task_tab(cx: WindowCx, tab: number, remove: boolean)
	local focused = cx.session:focused()
	closing[tab] = {
		at = os.time(),
		remove = remove,
		return_to = if focused ~= nil and cx.session:tab_of(focused) ~= tab then focused else nil,
	}
	show_tab(cx, tab)
	cx:command("close_tab")
end

local function delete_task(cx: WindowCx, tab: number, task: Task)
	if not tern.fs.exists(task.path) then
		-- Worktree already removed by hand: just close the tab.
		close_task_tab(cx, tab, false)
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
			close_task_tab(cx2, tab, true)
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

-- Opens the tab for a task whose worktree is ready, in the current session,
-- with the default agent in the worktree as its only pane.
local function open_task_tab(cx: WindowCx, task: Task)
	local tab = cx.layout:tab({ name = task.name, cwd = task.path })
	if tab == nil then
		cx:toast("error", "Could not open a tab for " .. task.name, task.path)
		return
	end
	if OPEN_AGENT then
		-- The agent takes the place of the new tab's lone shell; Tern does
		-- the replacing, as closing the shell from here would close the tab.
		-- Failing that, Tern's own New agent block beside the shell.
		local started = pcall(function()
			cx.agents:start({ prompt = "", cwd = task.path, how = "replace_if_alone" })
		end)
		if not started then
			cx:command("new_agent_block")
		end
	end
	local id = tab :: number
	cx.layout:name_tab(id, task.name)
	tern.kv.set(kv_key(id), task)
	tern.kv.set("last_main", task.main)
	cx:toast("success", "Task started: " .. task.name, task.path)
	refresh_tasks(cx)
end

-- The task whose worktree is being created, kept until its tab opens: a
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
			open_task_tab(cx, task)
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
				open_task_tab(cx, task)
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
		local tab = current_tab(cx)
		local task = if tab ~= nil then read_task(tab) else nil
		if tab ~= nil and task ~= nil then
			delete_task(cx, tab, task)
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
		local pane = dashboard_pane(cx)
		if pane ~= nil then
			pcall(function()
				cx.layout:focus(pane :: number)
			end)
		else
			local opened, err = cx.canvas:open({
				title = DASHBOARD_TITLE,
				about = "Open tasks in this repository (a tab with its own git worktree each). Open switches to a task's tab; Delete closes it and removes its worktree and branch.",
				view = dashboard_view(cx),
				how = "tab",
			})
			if opened == nil then
				cx:toast("error", "Could not open the task dashboard", err)
				return
			end
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

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx)
	if ev.owner ~= tern.plugin.id then
		return false
	end
	local id = tonumber(ev.value or "")
	if ev.act == "refresh" then
		refresh_tasks(cx)
	elseif ev.act == "new" then
		local cwd: string? = window_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("info", "Start the first task with New task from a pane inside the repository")
		else
			new_task_from(cx, cwd)
		end
	elseif ev.act == "settings" then
		local cwd: string? = window_cwd(cx) or tern.kv.get("last_main")
		if cwd == nil then
			cx:toast("info", "Run Task settings from a pane inside the repository")
		else
			settings_from(cx, cwd)
		end
	elseif ev.act == "base_change" and ev.value then
		choose_base(cx, ev.value :: string)
	elseif ev.act == "root_change" then
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
	elseif ev.act == "root_reset" then
		set_worktree_root(nil)
		render_settings(cx)
		cx:toast("success", "New tasks' worktrees go in " .. DEFAULT_WORKTREE_ROOT)
	elseif ev.act == "base_reset" and ev.value then
		set_base(ev.value :: string, nil)
		render_settings(cx)
		cx:toast("success", "New tasks branch from " .. base_label(nil))
	elseif ev.act == "open" and id ~= nil then
		show_tab(cx, id)
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

-- Close tab and Close session on task tabs remove their worktrees once the
-- tabs close; Tern's own commands run, confirmation included.
tern.override("close_tab", function(cx)
	local tab = current_tab(cx)
	if tab ~= nil and read_task(tab) ~= nil then
		closing[tab] = { at = os.time(), remove = true }
	end
	return false
end)

tern.override("close_session", function(cx)
	for _, s in cx.session:sessions() do
		if s.current and not s.locked then
			for _, tab in s.tabs do
				if read_task(tab) ~= nil then
					closing[tab] = { at = os.time(), remove = true }
				end
			end
		end
	end
	return false
end)

tern.on("tab_closed", function(ev: TabEvent, cx: WindowCx)
	tab_closed(cx, ev.tab)
end)

---------------------------------------------------------------------------
-- On load

-- Bind cmd+shift+n to New task once, through Tern's settings API: Tern
-- rewrites settings.json from its own copy, so hand edits to the file while
-- it runs get lost. The kv flag keeps a later rebinding of yours in place.
local NEW_TASK_CHORD = "cmd+shift+n"
local NEW_TASK_ACTION = "plugin." .. tern.plugin.id .. ".new_task"

-- Tasks used to be sessions, recorded under "session:<id>". Each moves to
-- its session's first tab, which then cleans up the worktree on Close tab.
local function migrate_session_tasks(cx: WindowCx)
	for _, s in cx.session:sessions() do
		local key = "session:" .. tostring(s.id)
		local task = tern.kv.get(key)
		if task ~= nil then
			local tab = s.tabs[1]
			if tab ~= nil and read_task(tab) == nil then
				tern.kv.set(kv_key(tab), task)
			end
			tern.kv.set(key, nil)
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
	migrate_session_tasks(cx)
	-- Keeps the tab names (and a dashboard left open, as canvases outlive
	-- reloads) up to date. A timer: start the work, draw from its callbacks.
	refresh_tasks(cx, true, false)
	start_refresh_loop()
	resume_pending_task()
end)
