--!strict
-- Shared dashboard model and native block view. Keys follow task tab ids,
-- so Tern's block renderer can diff updates without replacing the board.
local ui = tern.ui
local Dashboard = {}

export type Stats = { changes: number, ahead: number, last: string } | { missing: true }
export type Pr = {
	number: string,
	state: string,
	draft: boolean,
	url: string,
	review: string,
	checks: string,
}
export type Card = {
	id: number,
	name: string,
	branch: string,
	path: string,
	current: boolean,
	stats: Stats?,
	pr: (Pr | false)?,
}
export type Snapshot = { main: string?, tasks: { Card } }

function Dashboard.repository_key(pane: number): string
	return "dashboard_repo:" .. tostring(pane)
end

local function keyed(node: Node, key: string): Node
	local props = node.p or {}
	props.key = key
	node.p = props
	return node
end

local function button(text: string, act: string, key: string, variant: string?): Node
	local class = if variant then "tk-btn " .. variant else "tk-btn"
	return keyed(ui.el("button", { class = class, text = text, actions = { click = act } }), key)
end

local COLUMNS = {
	{ id = "progress", title = "In progress" },
	{ id = "draft", title = "Draft" },
	{ id = "review", title = "In review" },
	{ id = "done", title = "Done" },
}
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

local function column_of(card: Card): string
	local pr = card.pr
	if not pr then
		return "progress"
	elseif pr.state == "MERGED" or pr.state == "CLOSED" then
		return "done"
	elseif pr.draft then
		return "draft"
	end
	return "review"
end

local function pr_line(pr: (Pr | false)?): Node?
	if pr == nil then
		return nil
	elseif pr == false then
		return keyed(ui.text({ ui.span("No pull request", "muted") }), "pr")
	end
	local parts: { Node } = {
		keyed(ui.text({ ui.link("#" .. pr.number, pr.url, "strong") }), "number"),
		keyed(ui.badge(string.lower(pr.state), if pr.state == "MERGED" then "accent" elseif pr.state == "CLOSED" then "muted" else "info"), "state"),
	}
	local check = CHECK_BADGES[pr.checks]
	if check and pr.state == "OPEN" then
		table.insert(parts, keyed(ui.badge(check[1], check[2]), "checks"))
	end
	local review = REVIEW_BADGES[pr.review]
	if review and pr.state == "OPEN" then
		table.insert(parts, keyed(ui.badge(review[1], review[2]), "review"))
	end
	return keyed(ui.row(parts), "pr")
end

local function task_card(card: Card): Node
	local s = card.stats
	local badges: { Node } = {}
	if card.current then
		table.insert(badges, keyed(ui.badge("current", "accent"), "current"))
	end
	local last: string? = nil
	if s ~= nil and (s :: any).missing then
		table.insert(badges, keyed(ui.badge("worktree missing", "error"), "git"))
		last = "—"
	elseif s ~= nil then
		local st = s :: { changes: number, ahead: number, last: string }
		if st.changes > 0 then
			table.insert(badges, keyed(ui.badge(st.changes .. " uncommitted", "warning"), "git"))
		else
			table.insert(badges, keyed(ui.badge("clean", "success"), "git"))
		end
		if st.ahead > 0 then
			table.insert(badges, keyed(ui.badge(st.ahead .. (if st.ahead == 1 then " commit" else " commits"), "info"), "ahead"))
		end
		last = st.last
	end
	local body: { Node } = {}
	local pr = pr_line(card.pr)
	if pr then
		table.insert(body, pr)
	end
	if #badges > 0 then
		table.insert(body, keyed(ui.row(badges), "badges"))
	end
	local details = {
		{ "branch", ui.span(card.branch, "code") },
		{ "worktree", ui.path(card.path) },
	}
	if card.pr and card.pr.url ~= "" then
		local url = card.pr.url
		table.insert(details, { "pull request", ui.link((string.gsub(url, "^https?://", "")), url) })
	end
	if last ~= nil then
		table.insert(details, { "last commit", last })
	end
	table.insert(body, keyed(ui.kv(details), "details"))
	table.insert(body, keyed(ui.el("div", { class = "tk-actions" }, {
		button("Open", "open=" .. tostring(card.id), "open", nil),
		button("Delete", "delete=" .. tostring(card.id), "delete", "danger"),
	}), "actions"))
	return keyed(ui.card({ ui.span(card.name, "strong") }, body), "task_" .. tostring(card.id))
end

function Dashboard.view(snapshot: Snapshot): Node
	local by_column: { [string]: { Card } } = {}
	for _, c in COLUMNS do
		by_column[c.id] = {}
	end
	for _, card in snapshot.tasks do
		table.insert(by_column[column_of(card)], card)
	end
	local columns: { Node } = {}
	for _, c in COLUMNS do
		local cards: { Node } = {
			keyed(ui.text({ ui.span(c.title, "strong"), ui.span("  " .. #by_column[c.id], "muted num") }), "heading"),
		}
		for _, card in by_column[c.id] do
			table.insert(cards, task_card(card))
		end
		table.insert(columns, keyed(ui.el("div", { class = "tk-column" }, cards), c.id))
	end
	local children: { Node } = {
		keyed(ui.el("div", { class = "tk-toolbar" }, {
			button("+ New task", "new", "new", "primary"),
			button("↻ Refresh", "refresh", "refresh", nil),
			button("⚙ Settings", "settings", "settings", nil),
		}), "toolbar"),
	}
	if snapshot.main ~= nil then
		table.insert(children, keyed(ui.kv({ { "repository", ui.path(snapshot.main) } }), "repository"))
	end
	if #snapshot.tasks == 0 then
		table.insert(children, keyed(ui.md("No open tasks. **New task** starts one."), "empty"))
	end
	table.insert(children, keyed(ui.el("div", { class = "tk-board" }, columns), "board"))
	return ui.col(children)
end

return Dashboard
