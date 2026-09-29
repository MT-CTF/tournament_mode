local RANKLIST = {
	_sort = "score",
	"score",
	"flag_captures", "flag_attempts",
	"kills", "kill_assists", "bounty_kills",
	"deaths",
	"hp_healed"
}

local rankings = ctf_rankings:init(RANKLIST)
local hud = mhud.init()
local recent_rankings = ctf_modebase.recent_rankings(rankings)
local features = ctf_modebase.features(rankings, recent_rankings)

local classes = ctf_core.include_files(
	"classes.lua",
	"paxel.lua",
	"spectators.lua"
)

-- team sizes are fully dynamic: the locked rosters define the match

local old_bounty_reward_func = ctf_modebase.bounties.bounty_reward_func
local old_get_next_bounty = ctf_modebase.bounties.get_next_bounty
local old_get_skin = ctf_cosmetics.get_skin
local custom_item_levels = table.copy(features.initial_stuff_item_levels)

local function prioritize_medic_paxel(tooltype)
	return function(item)
		local iname = item:get_name()

		if iname == "tournament_mode:support_paxel" then
			return
				features.initial_stuff_item_levels[tooltype](
					ItemStack(string.format("default:%s_steel", tooltype))
				) + 0.1,
				true
		else
			return features.initial_stuff_item_levels[tooltype](item)
		end
	end
end

custom_item_levels.pick   = prioritize_medic_paxel("pick"  )
custom_item_levels.axe    = prioritize_medic_paxel("axe"   )
custom_item_levels.shovel = prioritize_medic_paxel("shovel")

local MATCH_STARTED = false
local QUEUE_MATCH_END = false
-- set once a match is won: no new match may start afterwards, the
-- server is shutting down for a restart and this just guards the wait
local MATCH_OVER = false
-- declared up here so the teamform setup closure below captures this
-- same upvalue (it reads it only when rendering/handling, after load)
local STARTING = false


--[[

   _______                     ______
  |__   __|                   |  ____|
     | | ___  __ _ _ __ ___   | |__ ___  _ __ _ __ ___
     | |/ _ \/ _` | '_ ` _ \  |  __/ _ \| '__| '_ ` _ \
     | |  __/ (_| | | | | | | | | | (_) | |  | | | | | |
     |_|\___|\__,_|_| |_| |_| |_|  \___/|_|  |_| |_| |_|

]]

local SPECTATE_META_KEY = "tournament_mode:spectate_allowed"

local function is_manager(pname)
	return core.check_player_privs(pname, {tournament_manager = true})
end

local function is_spectate_allowed(pname)
	return ctf_core.meta_get_string(pname, SPECTATE_META_KEY) == "true"
end

-- player meta can't be read before join, so approvals are mirrored in
-- mod storage for the connection-time gates (prejoin/userlimit).
-- the mirror is only ever written here, alongside the meta itself.
local storage = core.get_mod_storage()
local spectator_approved = {}
do
	local data = core.deserialize(storage:get_string("spectators"))

	if type(data) == "table" then
		for _, name in ipairs(data) do
			if type(name) == "string" then
				spectator_approved[name] = true
			end
		end
	end
end

local function save_spectators()
	local out = {}

	for name in pairs(spectator_approved) do
		table.insert(out, name)
	end

	storage:set_string("spectators", core.serialize(out))
end

local function set_spectate_allowed(pname, allowed)
	ctf_core.meta_set_string(pname, SPECTATE_META_KEY, allowed and "true" or "", true)

	if allowed then
		spectator_approved[pname] = true
	else
		spectator_approved[pname] = nil
	end

	save_spectators()
end

local function no_spectator()
	local out = {}

	for t, def in pairs(ctf_map.current_map.teams) do
		if not def.not_playing then
			table.insert(out, t)
		end
	end

	table.sort(out)
	return out
end

local teamform -- loaded below; entry denial and match control live here

local function teamcolor_to_teamnum(x)
	local teams = no_spectator()
	local idx = table.indexof(teams, x)

	if idx and teamform.swap_colors() then
		idx = #teams - idx + 1
	end

	return idx
end

local function teamnum_to_teamcolor(x)
	local teams = no_spectator()

	if teamform.swap_colors() then
		x = #teams - x + 1
	end

	return teams[x]
end

local try_start_match -- assigned in the match-start section below

teamform = ctf_core.include_files("teamform.lua")

teamform.setup({
	is_manager = is_manager,
	is_spectate_allowed = is_spectate_allowed,
	set_spectate_allowed = set_spectate_allowed,
	is_match_started = function() return MATCH_STARTED end,
	is_match_starting = function() return STARTING end,
	try_start_match = function(force) return try_start_match(force) end,
	hud = hud,
})

local locked = teamform.locked
local readied = teamform.readied
local TEAM = teamform.TEAM
local spectator_statbars = teamform.spectator_statbars
local spectator_props = teamform.spectator_props

core.after(0, function()
	ctf_modebase.map_on_next_match = teamform.get_pending_map()
	ctf_modebase.mode_on_next_match = "tournament"
end)

core.register_chatcommand("teamform", {
	description = "Show the team choosing formspec",
	func = function(name)
		local player = core.get_player_by_name(name)

		if player and not MATCH_STARTED and not MATCH_OVER then
			teamform.showform(player)
		end
	end
})

core.register_on_leaveplayer(function(player)
	teamform.player_left(player)
end)

--[[

   _____  _                         _______             _    _
  |  __ \| |                       |__   __|           | |  (_)
  | |__) | | __ _ _   _  ___ _ __     | |_ __ __ _  ___| | ___ _ __   __ _
  |  ___/| |/ _` | | | |/ _ \ '__|    | | '__/ _` |/ __| |/ / | '_ \ / _` |
  | |    | | (_| | |_| |  __/ |       | | | | (_| | (__|   <| | | | | (_| |
  |_|    |_|\__,_|\__, |\___|_|       |_|_|  \__,_|\___|_|\_\_|_| |_|\__, |
                   __/ |                                              __/ |
                  |___/                                              |___/

]]

local allow_rejoin = {}

local MATCH_ID = 0

core.register_privilege("tournament_manager", {
	description = "Tournament Manager",
	give_to_admin = false,
})

local start_new_match = ctf_modebase.start_new_match
ctf_modebase.start_new_match = function()
end

local promohud = mhud.init()

core.register_on_joinplayer(function(player)
	local pname = player:get_player_name()

	-- the meta is the source of truth: re-sync the prejoin mirror in
	-- case it was ever edited outside set_spectate_allowed
	if is_spectate_allowed(pname) then
		spectator_approved[pname] = true
		save_spectators()
	elseif spectator_approved[pname] then
		spectator_approved[pname] = nil
		save_spectators()
	end

	-- accounts made for spectating approve themselves on first join.
	-- no kick needed: unlike privs, meta applies immediately
	if pname:match("_spectate") and not is_spectate_allowed(pname) then
		set_spectate_allowed(pname, true)
		core.change_player_privs(pname, {fly = true, noclip = true})
		core.chat_send_player(pname, "Spectator access approved")
	end

	local promo = player:get_meta():get_string("spectator_promo")

	if promo ~= "" then
		promohud:add(player, "spectator_promo", {
			hud_elem_type = "text",
			position = {x = 1, y = 1},
			alignment = {x = "left", y = "up"},
			offset = {x = -24, y = -12},
			color = 0xFFFFFF,
			text_scale = 2,
			text = promo
		})
	end
end)

core.register_chatcommand("promo", {
	description = "Display a line of text in the bottom right of your screen",
	params = "<text|20char limit>",
	func = function(name, params)
		local player = core.get_player_by_name(name)

		if not player then
			return false, "You must be online to run this command!"
		end

		local text = params:sub(1, 20)
		player:get_meta():set_string("spectator_promo", text)

		if promohud:exists(player, "spectator_promo") then
			promohud:change(player, "spectator_promo", {text = text})
		else
			promohud:add(player, "spectator_promo", {
				hud_elem_type = "text",
				position = {x = 1, y = 1},
				alignment = {x = "left", y = "up"},
				offset = {x = -24, y = -12},
				color = 0xFFFFFF,
				text_scale = 1,
				text = text
			})
		end

		return true, "Promo set"
	end
})

core.register_on_prejoinplayer(function(name)
	-- once a match starts the server is closed: only managers, approved
	-- spectators, rostered players and same-match rejoiners get back in.
	-- everyone else waits for the next teamform. Also stays closed in
	-- the post-win restart window (MATCH_STARTED is already false there)
	-- and while the next match is loading.
	if not (MATCH_STARTED or MATCH_OVER or STARTING) then
		return
	end

	-- rejoin passes are scoped to the match the player left: a stale
	-- pass must not admit them into a later match under a roster
	-- that no longer exists
	if core.check_player_privs(name, {tournament_manager = true}) or
		spectator_approved[name] or
		locked[name] or
		allow_rejoin[name] == MATCH_ID then
		return
	end

	return "Match in progress. Please wait until it's done"
end)

core.register_can_bypass_userlimit(function(name, ip)
	if (not MATCH_STARTED and not MATCH_OVER and not STARTING) or
		core.check_player_privs(name, {tournament_manager = true}) or
		spectator_approved[name] or
		locked[name] or
		allow_rejoin[name] == MATCH_ID then
		return true
	end
end)

core.register_on_joinplayer(function(player)
	teamform.player_joined(player)
end)

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()

	-- rejoin passes are only for players who may come back mid-match.
	-- unapproved spectators kicked at match start must stay out: the
	-- modstorage mirror is used because player meta can't be read once
	-- they're offline
	if MATCH_STARTED and (locked[name] or spectator_approved[name] or is_manager(name)) then
		allow_rejoin[name] = MATCH_ID
	end
end)

--[[

    _____ _           _ _                          _____       _                       _   _
   / ____| |         | | |                        |_   _|     | |                     | | (_)
  | |    | |__   __ _| | | ___  _ __   __ _  ___    | |  _ __ | |_ ___  __ _ _ __ __ _| |_ _  ___  _ __
  | |    | '_ \ / _` | | |/ _ \| '_ \ / _` |/ _ \   | | | '_ \| __/ _ \/ _` | '__/ _` | __| |/ _ \| '_ \
  | |____| | | | (_| | | | (_) | | | | (_| |  __/  _| |_| | | | ||  __/ (_| | | | (_| | |_| | (_) | | | |
   \_____|_| |_|\__,_|_|_|\___/|_| |_|\__, |\___| |_____|_| |_|\__\___|\__, |_|  \__,_|\__|_|\___/|_| |_|
                                       __/ |                            __/ |
                                      |___/                            |___/

]]

local function report_win(teamnum, match_id)
	-- teamnum derives from allocator lookups that return nil for
	-- unknown colors; TEAM[nil] would error below (and in the delayed
	-- core.after callers, 5s later)
	if match_id ~= MATCH_ID or not MATCH_STARTED or (teamnum ~= 1 and teamnum ~= 2) then
		return
	end

	local winner = TEAM[teamnum] or teamnum
	core.chat_send_all(core.colorize("green", "[TOURNAMENT] ") ..
		"Team \"" .. winner .. "\" wins the match!")
	core.log("action", "[tournament] Team " .. dump(winner) .. " won, restarting for the next match")

	teamform.save_carryover()

	-- fresh process for every match: all lobby/match state starts clean
	-- and rosters, team names, map and color swap come back from
	-- modstorage on boot. Nothing may start a
	-- new match in the meantime (rosters are still locked and readied).
	MATCH_OVER = true
	MATCH_STARTED = false
	core.chat_send_all(core.colorize("cyan", "[TOURNAMENT] Server restarting in 10 seconds"))
	core.request_shutdown("Tournament match over. Restarting for the next match.", true, 10)
end

local function count_readied(teamnum)
	local n = 0

	for _, pname in ipairs(readied) do
		if locked[pname] == teamnum then
			n = n + 1
		end
	end

	return n
end

local function best_online_attempt(players, teamcolor)
	local best, best_count = false, -1

	for player, scores in pairs(players) do
		scores.flag_attempts = scores.flag_attempts or 0

		-- team totals already include leavers' attempts; but the
		-- simulated capture needs a live player object (PlayerObj of
		-- an offline name is nil and would crash on_flag_capture),
		-- so the credit goes to the best attempter still online
		if core.get_player_by_name(player) and scores._team == teamcolor and
				scores.flag_attempts > best_count then
			best, best_count = player, scores.flag_attempts
		end
	end

	return best
end

local function schedule_sudden_death(match_id)
	core.after(15 * 60, function()
		if match_id ~= MATCH_ID or not MATCH_STARTED then
			return
		end

		core.chat_send_all("\n" ..
			core.colorize("green", "[ANNOUNCEMENT]") ..
			" In 5 minutes flag attempts will instantly capture!\n\n"
		)

		core.after(5 * 60, function()
			if match_id ~= MATCH_ID or not MATCH_STARTED then
				return
			end

			local players = recent_rankings.players()
			local teams = recent_rankings.teams()
			local color1, color2 = teamnum_to_teamcolor(1), teamnum_to_teamcolor(2)
			local attempts_1 = (teams[color1] or {}).flag_attempts or 0
			local attempts_2 = (teams[color2] or {}).flag_attempts or 0

			if attempts_1 == attempts_2 then
				QUEUE_MATCH_END = true
				core.chat_send_all("\n" ..
					core.colorize("green", "[ANNOUNCEMENT]") ..
					" The next team to grab a flag will win!\n\n"
				)
			elseif attempts_1 > attempts_2 then
				local best = best_online_attempt(players, color1)

				if best then
					features.on_flag_capture(PlayerObj(best), {color2})
				end

				report_win(1, match_id)
			else
				local best = best_online_attempt(players, color2)

				if best then
					features.on_flag_capture(PlayerObj(best), {color1})
				end

				report_win(2, match_id)
			end
		end)
	end)
end

try_start_match = function(force)
	if MATCH_STARTED or STARTING or MATCH_OVER then
		return false
	end

	if count_readied(1) < 1 or count_readied(2) < 1 then
		return false
	end

	if not force and not teamform.all_locked_readied() then
		return false
	end

	teamform.update_readied_hud()
	MATCH_ID = MATCH_ID + 1
	STARTING = true
	-- everyone with the lobby form open drops to the player starting
	-- view (no ready/unready/manager controls) while the match loads
	teamform.reshow_form()
	core.chat_send_all(core.colorize("cyan", "Match starting on " .. teamform.get_pending_map() .. "!"))
	schedule_sudden_death(MATCH_ID)
	ctf_modebase.map_on_next_match = teamform.get_pending_map()
	start_new_match()
	return true
end

core.register_chatcommand("force_start", {
	description = "Start the match with the currently readied players",
	privs = {tournament_manager = true},
	func = function(name)
		if MATCH_OVER then
			return false, "Match is over, server is restarting"
		end

		if MATCH_STARTED then
			return false, "Match has already started"
		end

		if count_readied(1) < 1 or count_readied(2) < 1 then
			return false, "Each team needs at least one readied player"
		end

		if try_start_match(true) then
			return true, "Match force-started with " .. #readied .. " readied players"
		else
			return false, "Could not start match"
		end
	end
})

core.register_chatcommand("surrender", {
	description = "Surrender a team, giving the other team the win",
	privs = {tournament_manager = true},
	func = function(name, params)
		if not MATCH_STARTED then
			return false, "No match is running"
		end

		local arg = (params or ""):trim():lower()
		local loser

		for i = 1, 2 do
			if TEAM[i] and TEAM[i]:lower() == arg then
				loser = i
				break
			end
		end

		loser = loser or tonumber(arg:match("^([12])$"))

		if not loser then
			return false, "Usage: /surrender <team name> (the losing team)"
		end

		report_win(loser == 1 and 2 or 1, MATCH_ID)

		return true, "Team \"" .. (TEAM[loser] or loser) .. "\" surrendered"
	end
})

--[[

   _______                                                _     __  __           _
  |__   __|                                              | |   |  \/  |         | |
     | | ___  _   _ _ __ _ __   __ _ _ __ ___   ___ _ __ | |_  | \  / | ___   __| | ___
     | |/ _ \| | | | '__| '_ \ / _` | '_ ` _ \ / _ \ '_ \| __| | |\/| |/ _ \ / _` |/ _ \
     | | (_) | |_| | |  | | | | (_| | | | | | |  __/ | | | |_  | |  | | (_) | (_| |  __/
     |_|\___/ \__,_|_|  |_| |_|\__,_|_| |_| |_|\___|_| |_|\__| |_|  |_|\___/ \__,_|\___|

]]

ctf_modebase.register_mode("tournament", {
	rounds = 1,
	build_timer = 0, -- Disables default build timer, we will start it manually after team selection
	exclusive = true, -- Unregister all other modes
	treasures = {
		["default:ladder_wood" ] = {                max_count = 20, rarity = 0.3, max_stacks = 5},
		["default:torch"       ] = {                max_count = 20, rarity = 0.3, max_stacks = 5},

		["ctf_teams:door_steel"] = {rarity = 0.2, max_stacks = 3},

		["default:pick_steel"  ] = {rarity = 0.2, max_stacks = 2},
		["default:shovel_steel"] = {rarity = 0.1, max_stacks = 1},
		["default:axe_steel"   ] = {rarity = 0.1, max_stacks = 1},

		["ctf_ranged:pistol_loaded"        ] = {rarity = 0.2 , max_stacks = 2},
		["ctf_ranged:shotgun_loaded"       ] = {rarity = 0.05                },
		["ctf_ranged:smg_loaded"           ] = {rarity = 0.05                },
		["ctf_ranged:sniper_magnum_loaded" ] = {rarity = 0.05                },

		["ctf_map:unwalkable_dirt"  ] = {min_count = 5, max_count = 26, max_stacks = 1, rarity = 0.1},
		["ctf_map:unwalkable_stone" ] = {min_count = 5, max_count = 26, max_stacks = 1, rarity = 0.1},
		["ctf_map:unwalkable_cobble"] = {min_count = 5, max_count = 26, max_stacks = 1, rarity = 0.1},
		["ctf_map:spike"            ] = {min_count = 1, max_count =  5, max_stacks = 2, rarity = 0.2},
		["ctf_map:damage_cobble"    ] = {min_count = 5, max_count = 20, max_stacks = 2, rarity = 0.2},
		["ctf_map:reinforced_cobble"] = {min_count = 5, max_count = 25, max_stacks = 2, rarity = 0.2},

		["ctf_ranged:ammo"    ] = {min_count = 3, max_count = 10, rarity = 0.1, max_stacks = 2},
		["ctf_healing:medkit" ] = {                               rarity = 0.1, max_stacks = 2},

		["ctf_grenades:frag" ]  = {rarity = 0.1, max_stacks = 1},
		["ctf_grenades:smoke"]  = {rarity = 0.2, max_stacks = 2},
		["ctf_grenades:poison"] = {rarity = 0.1, max_stacks = 2},
	},
	crafts = {
		"ctf_ranged:ammo", "default:axe_mese", "default:axe_diamond", "default:shovel_mese", "default:shovel_diamond",
		"ctf_map:damage_cobble", "ctf_map:spike", "ctf_map:reinforced_cobble 2",
	},
	physics = {sneak_glitch = true, new_move = true},
	blacklisted_nodes = {"default:apple"},
	team_chest_items = {
		"default:cobble 99", "default:wood 99", "ctf_map:damage_cobble 24", "ctf_map:reinforced_cobble 24",
		"default:torch 30", "ctf_teams:door_steel 2",
	},
	rankings = rankings,
	recent_rankings = recent_rankings,
	summary_ranks = RANKLIST,
	is_bound_item = function(_, name)
		if name:match("tournament_mode:") or name:match("ctf_melee:") or name == "ctf_healing:bandage" then
			return true
		end
	end,
	stuff_provider = function(player)
		local initial_stuff = table.copy(classes.get(player).items or {})
		table.insert_all(initial_stuff, {"default:pick_stone", "default:torch 15", "default:stick 5"})
		return initial_stuff
	end,
	initial_stuff_item_levels = custom_item_levels,
	is_restricted_item = classes.is_restricted_item,
	on_mode_start = function()
		ctf_modebase.bounties.bounty_reward_func = ctf_modebase.bounty_algo.kd.bounty_reward_func
		ctf_modebase.bounties.get_next_bounty = ctf_modebase.bounty_algo.kd.get_next_bounty

		ctf_cosmetics.get_skin = function(player)
			if not ctf_teams.get(player) then
				return old_get_skin(player)
			end

			return old_get_skin(player) .. classes.get_skin_overlay(player)
		end
	end,
	on_mode_end = function()
		ctf_modebase.bounties.bounty_reward_func = old_bounty_reward_func
		ctf_modebase.bounties.get_next_bounty = old_get_next_bounty
		ctf_cosmetics.get_skin = old_get_skin

		classes.finish()
	end,
	on_new_match = function()
		features.on_new_match()

		classes.reset_class_cooldowns()

		teamform.close_all_forms()

		hud:clear_all()

		ctf_modebase.build_timer.start(60 * 3)
		MATCH_STARTED = true
		STARTING = false
	end,
	on_match_end = function(...)
		ctf_modebase.map_on_next_match = teamform.get_pending_map()
		ctf_modebase.mode_on_next_match = "tournament"

		features.on_match_end(...)
	end,
	allocate_teams = function(map_teams, dont_allocate_players, ...)
		local teams = table.copy(map_teams)
		teams["spectator"] = {}

		local out = ctf_teams.allocate_teams(teams, true, ...)

		local players = core.get_connected_players()
		table.shuffle(players)
		for _, player in ipairs(players) do
			local pname = player:get_player_name()

			-- unapproved spectators are kicked at match start
			-- instead of watching it
			if not locked[pname] and not is_manager(pname) and
					not is_spectate_allowed(pname) then
				core.kick_player(pname, "Spectator access was not approved - " ..
					"ask a tournament manager, then rejoin for the next match")
			else
				ctf_teams.allocate_player(player)
			end
		end

		return out
	end,
	team_allocator = function(player)
		local pname = PlayerName(player)

		if locked[pname] then
			return teamnum_to_teamcolor(locked[pname])
		end

		-- non-rostered players allocate as spectators; the
		-- allocate_teams loop above kicks the unapproved ones
		return "spectator"
	end,
	on_allocplayer = function(player, new_team)
		if new_team then
			classes.update(player)
			features.on_allocplayer(player, new_team)

		if new_team == "spectator" then
			-- managers and approved spectators watch the match.
			-- unapproved spectators pass through here during the
			-- match-start allocation but are kicked right after by
			-- the allocate_teams loop above
			local pname = player:get_player_name()

			-- snapshot everything below before mutating it. Kept across
			-- consecutive spectates (still hidden then); a relog starts
			-- from fresh engine visuals, so leave clears it again.
			if not spectator_props[pname] then
				local props = player:get_properties()
				local armor = {}
				local hud_flags = {}

				for group, rating in pairs(player:get_armor_groups()) do
					armor[group] = rating
				end

				for flag, value in pairs(player:hud_get_flags()) do
					hud_flags[flag] = value
				end

				spectator_props[pname] = {
					props = {
						is_visible = props.is_visible,
						pointable = props.pointable,
						visual_size = {
							x = props.visual_size.x,
							y = props.visual_size.y,
							z = props.visual_size.z,
						},
						selectionbox = {
							props.selectionbox[1], props.selectionbox[2],
							props.selectionbox[3], props.selectionbox[4],
							props.selectionbox[5], props.selectionbox[6],
						},
					},
					armor = armor,
					hud_flags = hud_flags,
				}
			end

			core.change_player_privs(player:get_player_name(), {
					interact = false,
					shout = false,
					canafk = true,
					fly = true, noclip = true, fast = true,
				})

				player:hud_set_flags({
					hotbar = false,
					healthbar = false,
					crosshair = false,
					wielditem = false,
					breathbar = false,
					minimap = false,
					minimap_radar = false,
					basic_debug = false,
					chat = false,
				})

				player:set_properties({
					is_visible = false,
					pointable = false,
					visual_size  = { x = 0, y = 0, z = 0 }, -- Workaround until we figure out if is_visibe should work for players
					selectionbox = { 0, 0, 0, 0, 0, 0 },
				})

				for _, o in pairs(player:get_children()) do
					if o.set_observers and o:get_pos() then
						o:set_observers({})
					else
						o:set_properties({
							is_visible = false,
							pointable = false,
						})
					end
				end

				player:set_armor_groups({immortal = 1, fall_damage_add_percent = -100})

			spectator_statbars[pname] = spectator_statbars[pname] or {}

			for id, def in pairs(player:hud_get_all()) do
				if def.type == "statbar" then
					spectator_statbars[pname][id] = spectator_statbars[pname][id] or {
						x = def.position.x,
						y = def.position.y,
					}

					player:hud_change(id, "position", {x = -10, y = -10})
				end
			end

				if promohud:exists(player, "match_info") then
					promohud:remove(player, "match_info")
				end

				promohud:add(player, "match_info", {
					hud_elem_type = "text",
					position = {x = 0.5, y = 0},
					alignment = {x = "center", y = "down"},
					color = 0xFFFFFF,
					text_scale = 3,
					text = core.colorize(ctf_teams.team[teamnum_to_teamcolor(1)].color, TEAM[1]) ..
							" vs " ..
							core.colorize(ctf_teams.team[teamnum_to_teamcolor(2)].color, TEAM[2])
				})

				if player.set_observers then
					player:set_observers({[player:get_player_name()] = true})
				end

				player:set_pos(vector.add(ctf_map.current_map.pos1, vector.divide(ctf_map.current_map.size, 2)))
			else
				local name = player:get_player_name()

				core.change_player_privs(name, {
					interact = true,
					shout = true,
					canafk = true,
					fly = false, noclip = false, fast = false,
				})

				-- mirror every spectator mutation above: last match's
				-- spectators are routinely rostered for the next one.
				-- properties/armor/hud come from the pre-hide snapshot,
				-- never hardcoded defaults (CTF owns those values).
				local snap = spectator_props[name]

				if snap then
					player:set_properties(snap.props)
					player:set_armor_groups(snap.armor)
					player:hud_set_flags(snap.hud_flags)
					spectator_props[name] = nil
				end

				if player.set_observers then
					player:set_observers()
				end

				if spectator_statbars[name] then
					local all = player:hud_get_all()

					for id, pos in pairs(spectator_statbars[name]) do
						if all[id] then
							player:hud_change(id, "position", pos)
						end
					end

					spectator_statbars[name] = nil
				end

				if promohud:exists(player, "match_info") then
					promohud:remove(player, "match_info")
				end

				for _, o in pairs(player:get_children()) do
					if o.set_observers and o:get_pos() then
						o:set_observers()
					else
						o:set_properties({
							is_visible = true,
							pointable = true,
						})
					end
				end
			end
		end
	end,
	on_leaveplayer = features.on_leaveplayer,
	on_dieplayer = features.on_dieplayer,
	on_respawnplayer = function(player, ...)
		features.on_respawnplayer(player, ...)

		classes.reset_class_cooldowns(player)
	end,
	can_take_flag = features.can_take_flag,
	on_flag_take = function(player, teamname, ...)
		local out = features.on_flag_take(player, teamname, ...)
		local color1, color2 = teamnum_to_teamcolor(1), teamnum_to_teamcolor(2)
		local team_attempts = recent_rankings.teams()
		local text = core.colorize(ctf_teams.team[color1].color, TEAM[1]) ..
			string.format(" (%d) vs (%d) ",
				(team_attempts[color1] or {}).flag_attempts or 0,
				(team_attempts[color2] or {}).flag_attempts or 0
			) ..
			core.colorize(ctf_teams.team[color2].color, TEAM[2])

		for _, p in pairs(core.get_connected_players()) do
			if ctf_teams.get(p) ~= "spectator" then
				if not hud:exists(p, "attempt_info") then
					hud:add(p, "attempt_info", {
						hud_elem_type = "text",
						position = {x = 0.5, y = 1},
						offset = {x = 0, y = -112},
						alignment = {x = "center", y = "up"},
						color = 0xFFFFFF,
						text = text
					})
				else
					hud:change(p, "attempt_info", {text = text})
				end
			end
		end

		if MATCH_STARTED and QUEUE_MATCH_END then
			features.on_flag_capture(player, {teamname})
			core.after(5, report_win, teamcolor_to_teamnum(ctf_teams.get(player)), MATCH_ID)
		end

		return out
	end,
	on_flag_drop = features.on_flag_drop,
	on_flag_capture = function(capturer, teams, ...)
		if MATCH_STARTED then
			local teamnum = teamcolor_to_teamnum(ctf_teams.get(capturer))

			core.after(5, report_win, teamnum, MATCH_ID)
		end

		return features.on_flag_capture(capturer, teams, ...)
	end,
	on_flag_rightclick = function(clicker)
		classes.show_class_formspec(clicker)
	end,
	get_chest_access = function() return true, true end,
	on_punchplayer = features.on_punchplayer,
	can_punchplayer = features.can_punchplayer,
	on_healplayer = features.on_healplayer,
	calculate_knockback = function(player, hitter, time_from_last_punch, tool_capabilities, dir, distance, damage)
		if features.can_punchplayer(player, hitter) and not tool_capabilities.damage_groups.ranged then
			return 2 * (tool_capabilities.damage_groups.knockback or 1) * math.min(1, time_from_last_punch or 0)
		else
			return 0
		end
	end,
})

--[[

   __  __       _       _        _____ _             _         __  ______           _
  |  \/  |     | |     | |      / ____| |           | |       / / |  ____|         | |
  | \  / | __ _| |_ ___| |__   | (___ | |_ __ _ _ __| |_     / /  | |__   _ __   __| |
  | |\/| |/ _` | __/ __| '_ \   \___ \| __/ _` | '__| __|   / /   |  __| | '_ \ / _` |
  | |  | | (_| | || (__| | | |  ____) | || (_| | |  | |_   / /    | |____| | | | (_| |
  |_|  |_|\__,_|\__\___|_| |_| |_____/ \__\__,_|_|   \__| /_/     |______|_| |_|\__,_|

]]

local timer = 0
core.register_globalstep(function(dtime)
	if MATCH_STARTED or STARTING or MATCH_OVER or not teamform.teams_locked() then
		return
	end

	timer = timer + dtime

	if timer >= 1 then
		timer = 0
		try_start_match(false)
	end
end)
