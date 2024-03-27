local rankings = ctf_rankings.init()
local hud = mhud.init()
local recent_rankings = ctf_modebase.recent_rankings(rankings)
local features = ctf_modebase.features(rankings, recent_rankings)

local classes = ctf_core.include_files(
	"paxel.lua",
	"classes.lua",
	"spectators.lua"
)

local TEAM_SIZE = 0.5

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

minetest.register_entity("tournament_mode:freezeplayer", {
	is_visible = true,
	visual = "wielditem",
	wield_item = "default:glass",
	visual_size = vector.new(1, 2, 1),
	physical = false,
	makes_footstep_sound = false,
	backface_culling = false,
	static_save = false,
	pointable = false,
	glow = 5,
	on_punch = function() return true end,
})

local match_started = false
local confirmed = {}

local function showform(player)
	local playername = player:get_player_name()

	ctf_gui.show_formspec(player, "tournament_mode:choose_team",
		function(context)
			local show_confirm = table.indexof(confirmed, playername) == -1 and ctf_teams.get(playername) ~= "spectator"
			local w, h = 10, (show_confirm and 10 or 9)
			local px, py = 0.2, 0.2

			local team1 = ctf_teams.current_team_list[1]
			local team2 = ctf_teams.current_team_list[2]
			local team1_players = {}
			local team2_players = {}

			for p in pairs(ctf_teams.online_players[team1].players) do
				table.insert(team1_players, p)
			end
			for p in pairs(ctf_teams.online_players[team2].players) do
				table.insert(team2_players, p)
			end

			local out = {
				{"size[%d,%d]", w, h},
				"formspec_version[4]",
				{"label[0 ,0;Team 1 (%s)]",      minetest.colorize(ctf_teams.team[team1].color, HumanReadable(team1))},
				{"label[%f,0;Team 2 (%s)]", w/2, minetest.colorize(ctf_teams.team[team2].color, HumanReadable(team2))},
				{"textlist[0 ,0.5;%f,7;team1;%s]",
					w/2 - px,
					table.concat(team1_players, ",")
				},
				{"textlist[%f,0.5;%f,7;team2;%s]",
					w/2,
					w/2 - px,
					table.concat(team2_players, ",")
				},
				{"style[select_team1;bgcolor=%s]", ctf_teams.team[team1].color},
				{"style[select_team2;bgcolor=%s]", ctf_teams.team[team2].color},
				{"button[0, %f;2.4,1;select_team1;Select Team]", 7.5 + py},
				{"button[%f,%f;2.4,1;select_team2;Select Team]", w/2, 7.5 + py},
			}

			if show_confirm then
				table.insert(out, "style[confirm;font=bold]")
				table.insert(out, {"button_exit[%f,%f;3,1;confirm;Confirm Team]", (w/2) - (3/2), 9 + py})
			end

			return ctf_gui.list_to_formspec_str(out)
		end
	, {
		player = player,
		_on_formspec_input = function(pname, context, fields)
			if fields.select_team1 then
				ctf_teams.remove_online_player(pname)
				ctf_teams.set(pname, ctf_teams.current_team_list[1], true)

				return "refresh"
			elseif fields.select_team2 then
				ctf_teams.remove_online_player(pname)
				ctf_teams.set(pname, ctf_teams.current_team_list[2], true)

				return "refresh"
			elseif fields.confirm and table.indexof(confirmed, pname) == -1 then
				table.insert(confirmed, pname)

				hud:change(pname, "showform_explanation", {
					text = "Use /teamform to join a team. You've confirmed being in team " .. ctf_teams.get(pname)
				})
			end
			-- select_team1 = "Select Team"
			-- team1 = "CHG:1"
		end,
	})

	if not hud:exists(player, "showform_explanation") then
		hud:add(player, "showform_explanation", {
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.5},
			offset = {x = 0, y = -32},
			alignment = {x = "center", y = "up"},
			text = "Use /teamform to join a team. You haven't confirmed what team you're in.",
			color = 0xFFFFFF,
		})
	end
end

minetest.register_chatcommand("teamform", {
	description = "Show the team choosing formspec",
	func = function(name)
		local player = minetest.get_player_by_name(name)

		if player and not match_started then
			local idx = table.indexof(confirmed, name)

			if idx ~= -1 then
				table.remove(confirmed, idx)
			end

			hud:change(name, "showform_explanation", {
				text = "Use /teamform to join a team. You haven't confirmed what team you're in."
			})

			showform(player)
		end
	end
})

minetest.register_on_leaveplayer(function(player)
	local idx = table.indexof(confirmed, player:get_player_name())

	if idx ~= -1 then
		table.remove(confirmed, idx)
	end
end)

-- TODO: Need to prevent access to the server to all but those with a 'manager' priv granted to admins by default
-- Use on_prejoinplayer

local timer = 0
minetest.register_globalstep(function(dtime)
	if match_started then return end
	if #minetest.get_connected_players() < TEAM_SIZE * 2 then return end

	timer = timer + dtime

	if timer >= 2 then
		timer = 0

		if #confirmed >= TEAM_SIZE * 2 then
			match_started = true

			hud:clear_all()

			for _, tdef in pairs(ctf_teams.online_players) do
				for name in pairs(tdef.players) do
					local player = minetest.get_player_by_name(name)

					if player then
						minetest.change_player_privs(name, {
							interact = true,
							fly = false, noclip = false,
						})

						if player.observers then -- Need to account for the pre-5.9 alternative if set up
							player:set_observers(nil)
						end

						features.tp_player_near_flag(player)
					end
				end
			end

			ctf_modebase.build_timer.start(100)
		end
	end
end)

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

		["grenades:frag" ]  = {rarity = 0.1, max_stacks = 1},
		["grenades:smoke"]  = {rarity = 0.2, max_stacks = 2},
		["grenades:poison"] = {rarity = 0.1, max_stacks = 2},
	},
	crafts = {
		"ctf_ranged:ammo", "default:axe_mese", "default:axe_diamond", "default:shovel_mese", "default:shovel_diamond",
		"ctf_map:damage_cobble", "ctf_map:spike", "ctf_map:reinforced_cobble 2",
	},
	physics = {sneak_glitch = true, new_move = false},
	blacklisted_nodes = {"default:apple"},
	team_chest_items = {
		"default:cobble 99", "default:wood 99", "ctf_map:damage_cobble 24", "ctf_map:reinforced_cobble 24",
		"default:torch 30", "ctf_teams:door_steel 2",
	},
	rankings = rankings,
	recent_rankings = recent_rankings,
	summary_ranks = {
		_sort = "score",
		"score",
		"flag_captures", "flag_attempts",
		"kills", "kill_assists", "bounty_kills",
		"deaths",
		"hp_healed"
	},
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

		match_started = false
		confirmed = {}

		classes.reset_class_cooldowns()
	end,
	on_match_end = function(...)
		features.on_match_end(...)

		minetest.request_shutdown("Thanks for playing", false)
	end,
	allocate_teams = function(map_teams, dont_allocate_players, ...)
		local teams = table.copy(map_teams)
		teams["spectator"] = {}

		local out = ctf_teams.allocate_teams(teams, true, ...)

		table.remove(ctf_teams.current_team_list, table.indexof(ctf_teams.current_team_list, "spectator"))
		table.insert(ctf_teams.current_team_list, "spectator")

		local players = minetest.get_connected_players()
		table.shuffle(players)
		for _, player in ipairs(players) do
			ctf_teams.allocate_player(player)
		end

		return out
	end,
	team_allocator = function(player)
		if not match_started then
			local pname = PlayerName(player)
			minetest.after(0, function()
				player = minetest.get_player_by_name(pname)

				if player then
					showform(player)
				end
			end)

			return "spectator"
		end
	end,
	on_allocplayer = function(player, new_team)
		if new_team then
			classes.update(player)
			features.on_allocplayer(player, new_team)

			if new_team == "spectator" then
				minetest.change_player_privs(player:get_player_name(), {
					interact = false,
					fly = true, noclip = true,
				})

				if player.observers then -- Need to set up a pre-5.9 alternative
					player:set_observers({[player:get_player_name()] = false})
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
	on_flag_take = features.on_flag_take,
	on_flag_drop = features.on_flag_drop,
	on_flag_capture = features.on_flag_capture,
	on_flag_rightclick = function(clicker)
		classes.show_class_formspec(clicker)
	end,
	get_chest_access = features.get_chest_access,
	on_punchplayer = features.on_punchplayer,
	can_punchplayer = features.can_punchplayer,
	on_healplayer = features.on_healplayer,
	calculate_knockback = function(player, hitter, time_from_last_punch, tool_capabilities, dir, distance, damage)
		if features.can_punchplayer(player, hitter) then
			return 2 * (tool_capabilities.damage_groups.knockback or 1) * math.min(1, time_from_last_punch or 0)
		else
			return 0
		end
	end,
})
