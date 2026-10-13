--!strict
-- The window owns task operations and refreshes; this block owns the view.
-- Returning a keyed view lets Tern diff props and children into TSP frames.
local Dashboard = require("./dashboard")
type Snapshot = Dashboard.Snapshot

local dashboard: BlockDef<Snapshot> = {
	init = function(cx, args, saved)
		local state: Snapshot
		if saved ~= nil then
			state = saved
		elseif args[1] ~= nil then
			state = tern.json.decode(args[1])
		else
			state = { tasks = tern.json.array({}) }
		end
		local key = Dashboard.repository_key(cx.pane)
		if tern.kv.get(key) == nil then
			tern.kv.set(key, { main = state.main })
		end
		return state
	end,
	view = function(state, _cx)
		return { main = Dashboard.view(state) }
	end,
	key = function(_state, _key, _cx)
		return false
	end,
	event = function(state, ev, cx)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "snapshot" and ev.value ~= nil then
			local snapshot: Snapshot = tern.json.decode(ev.value)
			local key = Dashboard.repository_key(cx.pane)
			if ev.select == true then
				tern.kv.set(key, { main = snapshot.main })
			else
				local selection = tern.kv.get(key)
				if selection ~= nil and selection.main ~= snapshot.main then
					return -- a late refresh from a window with the old filter
				end
			end
			-- A window reload starts with empty caches. Unknown answers must not
			-- remove the status already shown by the persisted block.
			local previous: { [number]: Dashboard.Card } = {}
			for _, card in state.tasks do
				previous[card.id] = card
			end
			for _, card in snapshot.tasks do
				local old = previous[card.id]
				if old ~= nil and old.path == card.path then
					if card.stats == nil then
						card.stats = old.stats
					end
					if card.pr == nil then
						card.pr = old.pr
					end
				end
			end
			state.main, state.tasks = snapshot.main, snapshot.tasks
		elseif ev.act == "refresh" or ev.act == "new" or ev.act == "settings" or ev.act == "open" or ev.act == "delete" then
			-- Host effects route back through the originating window's link
			-- handler, retaining prompts, session focus and deletion confirmation.
			cx:open(tern.plugin.id .. "://dashboard/" .. ev.act .. "/" .. (ev.value or ""))
		end
	end,
	save = function(state)
		return { main = state.main, tasks = tern.json.array(state.tasks) }
	end,
}

tern.block.define("dashboard", dashboard)

tern.on("pane_exited", function(ev)
	tern.kv.set(Dashboard.repository_key(ev.pane), nil)
end)
