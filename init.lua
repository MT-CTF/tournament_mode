local rankings = ctf_rankings.init()
local hud = mhud.init()
local recent_rankings = ctf_modebase.recent_rankings(rankings)
local features = ctf_modebase.features(rankings, recent_rankings)

local classes = ctf_core.include_files(
	"classes.lua",
	"paxel.lua",
	"spectators.lua"
)

local TEAM_SIZE = 3 --players each
local CONFIRMED_PLAYER_TARGET = TEAM_SIZE * 2

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
local confirmed = {}
local locked = {}

minetest.register_can_bypass_userlimit(function(name, ip)
	if not MATCH_STARTED or minetest.check_player_privs(name, {tournament_manager   = true}) or
	minetest.check_player_privs(name, {tournament_spectator = true}) then
		return true end
end)

--[[

   _______                     ______
  |__   __|                   |  ____|
     | | ___  __ _ _ __ ___   | |__ ___  _ __ _ __ ___
     | |/ _ \/ _` | '_ ` _ \  |  __/ _ \| '__| '_ ` _ \
     | |  __/ (_| | | | | | | | | | (_) | |  | | | | | |
     |_|\___|\__,_|_| |_| |_| |_|  \___/|_|  |_| |_| |_|

]]

local TEAM = {"1", "2"}
local TEAM_ID = {false, false}

local TEAM_LEADER = {}

local function no_spectator()
	local out = {}

	for t, def in pairs(ctf_map.current_map.teams) do
		if not def.not_playing then
			table.insert(out, t)
		end
	end

	return out
end

local function teamcolor_to_teamnum(x)
	return table.indexof(no_spectator(), x)
end

local function teamnum_to_teamcolor(x)
	return no_spectator()[x]
end

local function has_team_leader(teamnum)
	return true
end

local function color_confirmed(players)
	local out = ""

	for _, p in pairs(players) do
		if table.indexof(confirmed, p) ~= -1 then
			out = out .. "#00FF00" .. p .. ","
		else
			out = out .. p .. ","
		end
	end

	return out
end

local showform
local form_shown = {}

local function reshow_form(except)
	for p in pairs(form_shown) do
		if not except or p ~= except then
			showform(minetest.get_player_by_name(p))
		end
	end
end

local selected_team = {}
showform = function(player)
	if not hud:exists(player, "confirmed_players") then
		hud:add(player, "confirmed_players", {
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.5},
			offset = {x = 0, y = -64},
			alignment = {x = "center", y = "up"},
			text = string.format("Confirmed Players: %d/%d", #confirmed, CONFIRMED_PLAYER_TARGET),
			color = 0xFFFFFF,
		})
	end

	if not hud:exists(player, "showform_explanation") then
		hud:add(player, "showform_explanation", {
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.5},
			offset = {x = 0, y = -32},
			alignment = {x = "center", y = "up"},
			text = "Use /teamform to join a team. You haven't confirmed what team you're in.",
			color = 0xFF0000,
		})
	end

	if minetest.check_player_privs(player, {tournament_spectator = true}) then return end

	local playername = player:get_player_name()

	if locked[playername] then
		selected_team[playername] = locked[playername]
	end

	if not selected_team[playername] then
		selected_team[playername] = "spectator"
	end

	form_shown[playername] = true
	ctf_gui.show_formspec(player, "tournament_mode:choose_team",
		function(context)
			local show_confirm = table.indexof(confirmed, playername) == -1 and selected_team[playername] ~= "spectator"
			local w, h = 10, (locked[playername] and 0 or 1) + (show_confirm and 10 or 9)
			local px, py = 0.2, 0.2

			local team1_players = {}
			local team2_players = {}


			for p, tnum in pairs(selected_team) do
				if tnum == 1 then
					table.insert(team1_players, p)
				elseif tnum == 2 then
					table.insert(team2_players, p)
				end
			end

			local out = {
				{"size[%d,%d]", w, h},
				"formspec_version[4]",
				{"label[0 ,0;Team %s]",      TEAM[1] or "1"},
				{"label[%f,0;Team %s]", w/2, TEAM[2] or "2"},
				{"textlist[0 ,0.5;%f,7;team1;" .. color_confirmed(team1_players) .. "]",
					w/2 - px,
				},
				{"textlist[%f,0.5;%f,7;team2;" .. color_confirmed(team2_players) .. "]",
					w/2,
					w/2 - px,
				},
			}

			if not locked[playername] then
				table.insert(out, {"button[0, %f;2.4,1;select_team1;Select Team]", 7.5 + py})
				table.insert(out, {"button[%f,%f;2.4,1;select_team2;Select Team]", w/2, 7.5 + py})
			end

			if show_confirm then
				if has_team_leader(selected_team[playername]) then
					table.insert(out, "style[confirm;font=bold]")
					table.insert(out, {
						"button_exit[%f,%f;3,1;confirm;%s]",
						(w/2) - (3/2),
						9 + py,
						locked[playername] and "Confirm Ready" or "Confirm Team"
					})
				else
					table.insert(out, "style[confirm_disabled;font=bold;textcolor=grey]")
					table.insert(out, {
						"button[%f,%f;6,1;confirm_disabled;Confirm Team (Waiting for team leader...)]",
						(w/2) - (6/2), 9 + py
					})
				end
			end

			return ctf_gui.list_to_formspec_str(out)
		end
	, {
		player = player,
		_on_formspec_input = function(pname, context, fields)
			if minetest.check_player_privs(pname, {tournament_spectator = true}) then return end

			if fields.select_team1 and not locked[pname] then
				selected_team[pname] = 1

				reshow_form(pname)

				local idx = table.indexof(confirmed, pname)
				if idx ~= -1 then
					table.remove(confirmed, idx)

					if hud:exists(pname, "showform_explanation") then
						hud:change(pname, "showform_explanation", {
							text = "Use /teamform to join a team. You haven't confirmed what team you're in.",
							color = 0xFF0000,
						})
					end

					for _, p in pairs(minetest.get_connected_players()) do
						if hud:exists(p, "confirmed_players") then
							hud:change(p, "confirmed_players", {
								text = string.format("Confirmed Players: %d/%d", #confirmed, CONFIRMED_PLAYER_TARGET)
							})
						end
					end
				end

				return "refresh"
			elseif fields.select_team2 and not locked[pname] then
				selected_team[pname] = 2

				reshow_form(pname)

				local idx = table.indexof(confirmed, pname)
				if idx ~= -1 then
					table.remove(confirmed, idx)

					if hud:exists(pname, "showform_explanation") then
						hud:change(pname, "showform_explanation", {
							text = "Use /teamform to join a team. You haven't confirmed what team you're in.",
							color = 0xFF0000,
						})
					end

					for _, p in pairs(minetest.get_connected_players()) do
						if hud:exists(p, "confirmed_players") then
							hud:change(p, "confirmed_players", {
								text = string.format("Confirmed Players: %d/%d", #confirmed, CONFIRMED_PLAYER_TARGET)
							})
						end
					end
				end

				return "refresh"
			elseif fields.confirm and table.indexof(confirmed, pname) == -1 and
					has_team_leader(selected_team[pname]) then
				table.insert(confirmed, pname)

				form_shown[pname] = nil

				reshow_form(pname)

				local num = selected_team[pname]
				if hud:exists(pname, "showform_explanation") then
					hud:change(pname, "showform_explanation", {
						text = "Use /teamform to see the teams. You've confirmed being in team \"" .. (TEAM[num] or num) .. "\"",
						color = 0xFFFFFF,
					})
				end

				for _, p in pairs(minetest.get_connected_players()) do
					if hud:exists(p, "confirmed_players") then
						hud:change(p, "confirmed_players", {
							text = string.format("Confirmed Players: %d/%d", #confirmed, CONFIRMED_PLAYER_TARGET)
						})
					end
				end
			else
				if fields.quit then
					form_shown[pname] = nil

					-- note: legit spectators can't reach this point in the code
					if selected_team[pname] == "spectator" then
						minetest.chat_send_player(pname,
							"[NOTICE] Unless you are made an official spectator or join a team you will be kicked when the match starts"
						)
					end
				end
			end

			-- select_team1 = "Select Team"
			-- team1 = "CHG:1"
		end,
	})
end

minetest.register_chatcommand("teamform", {
	description = "Show the team choosing formspec",
	func = function(name)
		local player = minetest.get_player_by_name(name)

		if player and not MATCH_STARTED then
			showform(player)
		end
	end
})

minetest.register_on_leaveplayer(function(player)
	local idx = table.indexof(confirmed, player:get_player_name())

	if idx ~= -1 then
		table.remove(confirmed, idx)
	end

	form_shown[player:get_player_name()] = nil
	reshow_form()
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

local tracked_players = {}
local allow_rejoin = {}

minetest.register_privilege("tournament_manager", {
	description = "Tournament Manager",
	give_to_admin = false,
})

minetest.register_privilege("tournament_spectator", {
	description = "Tournament Spectator",
	give_to_admin = false,
})

minetest.register_chatcommand("report_dq", {
	description = "Tell the game a player can't make it",
	privs = {},
	func = function(name, params)
		local player = minetest.get_player_by_name(name)

		if player and ((locked[name] and (TEAM_LEADER[1] == locked[name] or TEAM_LEADER[2] == locked[name])) or
			minetest.check_player_privs(name, {tournament_manager = true}))
		then
			CONFIRMED_PLAYER_TARGET = CONFIRMED_PLAYER_TARGET - 1

			for _, p in pairs(minetest.get_connected_players()) do
				if hud:exists(p, "confirmed_players") then
					hud:change(p, "confirmed_players", {
						text = string.format("Confirmed Players: %d/%d", #confirmed, CONFIRMED_PLAYER_TARGET)
					})
				end
			end

			return true, "Player dq reported successfully"
		else
			return false, "You need to be a team leader/tournament manager to run this command"
		end
	end
})

local start_new_match = ctf_modebase.start_new_match
ctf_modebase.start_new_match = function()
end

local promohud = mhud.init()

minetest.register_on_joinplayer(function(player)
	if minetest.check_player_privs(player, {tournament_spectator = true}) then
		local promo = player:get_meta():get_string("spectator_promo")

		if promo == "" then promo = "Set this text with /promo" end

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

minetest.register_chatcommand("promo", {
	description = "Display a line of text in the bottom right of your screen",
	privs = {tournament_spectator = true},
	params = "<text|20char limit>",
	func = function(name, params)
		local player = minetest.get_player_by_name(name)

		if player and minetest.check_player_privs(player, {tournament_spectator = true}) then
			player:get_meta():set_string("spectator_promo", params:sub(1, 20))

			if promohud:exists(player, "spectator_promo") then
				promohud:change(player, "spectator_promo", {
					text = params:sub(1, 20)
				})
			else
				promohud:add(player, "spectator_promo", {
					hud_elem_type = "text",
					position = {x = 1, y = 1},
					alignment = {x = "left", y = "up"},
					offset = {x = -24, y = -12},
					color = 0xFFFFFF,
					text_scale = 1,
					text = params:sub(1, 20)
				})
			end

			return true, "Promo set"
		else
			return false, "You must be online/a spectator to run this command!"
		end
	end
})

local function on_new_tracked(pname)
end

minetest.register_on_prejoinplayer(function(name)
	if MATCH_STARTED then
		if minetest.check_player_privs(name, {tournament_manager   = true}) or
		   minetest.check_player_privs(name, {tournament_spectator = true}) or
		   allow_rejoin[name]
		then
			return
		end

		return "Game has started. Only spectators/tournament managers can join"
	end
end)

minetest.register_on_joinplayer(function(player)
	local pname = player:get_player_name()

	if allow_rejoin[pname] then
		allow_rejoin[pname] = nil
	end

	if minetest.check_player_privs(player, {tournament_manager   = true}) or
	   minetest.check_player_privs(player, {tournament_spectator = true})
	then
		minetest.chat_send_player(pname, "Not checking your team, as you're a manager/spectator")
	else
		table.insert(tracked_players, player:get_player_name())
		on_new_tracked(player:get_player_name())
	end

	if not MATCH_STARTED then
		player = minetest.get_player_by_name(pname)

		if player then
			showform(player)
		end
	end
end)

minetest.register_on_leaveplayer(function(player)
	local name = player:get_player_name()

	if MATCH_STARTED then
		allow_rejoin[name] = true
	end

	local idx = table.indexof(tracked_players, name)

	if idx >= 1 then
		table.remove(tracked_players, idx)
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

local http, TOURNAMENT_URL

local FOR_MATCH

local API_KEY = minetest.settings:get("tournament_mode_api_key")
local TOURNAMENT_ID = minetest.settings:get("tournament_mode_tournament_id")
local STATION_ID = minetest.settings:get("tournament_mode_station_id") or 1

if API_KEY and TOURNAMENT_ID then
	assert(STATION_ID, "Please set tournament_mode_station_id")

	TOURNAMENT_URL = "https://api.challonge.com/v1/tournaments/" .. TOURNAMENT_ID

	http = minetest.request_http_api()
	assert(http, "Please add tournament_mode to secure.http_mods")

	http.fetch({
		url = TOURNAMENT_URL .. "/matches.json?state=open&api_key="..API_KEY,
		timeout = 10,
		method = "GET",
	}, function(checktournament)
		assert(checktournament.succeeded)

		-- minetest.log(dump(checktournament))

		checktournament = minetest.parse_json(checktournament.data, {})

		local function parse_team_members(json_entry)
			local players = {}
			local smallest = math.huge
			local leader = 1

			for id, v in pairs(json_entry.participant.custom_field_response) do
				if type(v) == "string" then
					if tonumber(id) < smallest then
						smallest = tonumber(id)
						leader = #players+1
					end

					table.insert(players, v)
				end
			end

			leader = table.remove(players, leader)

			return leader, players
		end

		local cmd_timer = os.time()
		minetest.register_chatcommand("tournament_teams", {
			description = "List the current teams",
			func = function(name, params)
				if os.time() - cmd_timer <= 5 then
					return false, "This command is being run too fast!"
				else
					cmd_timer = os.time()
				end

				http.fetch({
					url = TOURNAMENT_URL .. "/participants.json?api_key="..API_KEY,
					timeout = 5,
					method = "GET",
				}, function(player_res)
					if FOR_MATCH and TEAM_LEADER[1] and TEAM_LEADER[2] then
						minetest.log("action", dump(FOR_MATCH) .. " " .. dump(TEAM_LEADER))
						return
					end

					if not player_res.succeeded then
						minetest.log("error", "Issue with /tournament_teams")
						minetest.log("action", dump(player_res))
						return
					end

					player_res = minetest.parse_json(player_res.data, {})

					local out = "List of teams in tournament:\n"

					for _, entry in ipairs(player_res) do
						local leader, players = parse_team_members(entry)

						out = out .. string.format(
							"    Team %s (Leader: %s)\n        Members: %s\n",
							minetest.colorize("cyan", entry.participant.display_name),
							leader,
							table.concat(players, ", ")
						)
					end

					minetest.chat_send_player(name, out:sub(1, -2))
				end)

				return true
			end,
		})

		if #checktournament > 0 then
			minetest.log("action", "Tournament Started")
			TEAM = {false, false}

			has_team_leader = function(teamnum)
				if TEAM_LEADER[teamnum] then
					return TEAM_LEADER[teamnum]
				else
					return false
				end
			end

			on_new_tracked = function(pname)
				if not minetest.get_player_by_name(pname) then
					return
				end

				http.fetch({
					url = TOURNAMENT_URL .. "/matches.json?state=open&api_key="..API_KEY,
					timeout = 10,
					method = "GET",
				}, function(matches_res)
					assert(matches_res.succeeded)

					-- minetest.log(dump(matches_res))

					matches_res = minetest.parse_json(matches_res.data, {})

					if #matches_res > 0 then
						local found = {}
						for matchidx, entry in pairs(matches_res) do
							for team, id in pairs({entry.match.player1_id, entry.match.player2_id}) do
								team = tonumber(team)

								http.fetch({
									url = TOURNAMENT_URL .. "/participants/" .. id .. ".json?api_key="..API_KEY,
									timeout = 10,
									method = "GET",
								}, function(player_res)
									if FOR_MATCH and found[pname] then
										-- minetest.log("action", dump(FOR_MATCH) .. " " .. dump(pname))
										return
									end

									assert(player_res.succeeded)

									-- minetest.log(dump(player_res))

									player_res = minetest.parse_json(player_res.data, {})

									local leader, players = parse_team_members(player_res)

									if (not FOR_MATCH or FOR_MATCH == entry.match.id) then
										if leader == pname or table.indexof(players, pname) ~= -1 then
											TEAM[team] = player_res.participant.display_name
											TEAM_ID[team] = player_res.participant.id

											if leader == pname then
												TEAM_LEADER[team] = pname
												minetest.chat_send_all("Found team leader for team "..team.." ("..TEAM[team].."): "..pname)
											else
												minetest.chat_send_all("Found team member for team "..team.." ("..TEAM[team].."): "..pname)
											end

											locked[pname] = tonumber(team)
											FOR_MATCH = entry.match.id

											if TEAM[team] == "" then
												TEAM[team] = false
											else
												reshow_form()
											end
										end
									end
								end)
							end
						end
					end
				end)
			end
		end
	end)
end

local function report_win(teamnum)
	local winning_team = TEAM_ID[teamnum]

	if winning_team then
		minetest.after(10, function()
			http.fetch({
				url = TOURNAMENT_URL .. "/matches/"..FOR_MATCH..".json",
				timeout = 10,
				method = "PUT",
				extra_headers = {"Content-Type: application/json"},
				data = "{\"api_key\": \"" .. API_KEY .. "\", \"match\": {\"winner_id\": " .. winning_team ..
						", \"scores_csv\": \"" .. ((teamnum == 1) and "1-0" or "0-1") .. "\"}}",
			}, function(res)
				assert(res.succeeded, "Match ID was incorrect")
			end)
		end)
	else
		minetest.log("error", "The winning team wasn't connected with a Challonge ID. " ..
				"Send a screenshot of this to an admin. [" .. dump(TEAM[teamnum]) .. "]")
	end

	minetest.request_shutdown("Thanks for playing", false, 21)
end

minetest.register_chatcommand("surrender", {
	description = "Give the other team the win",
	func = function(name)
		local tnum = locked[name]

		if tnum and TEAM_LEADER[tnum] == name then
			report_win(tnum)

			return true, "You have surrendered to the other team"
		else
			return false, "You need to be a team leader to run this command"
		end
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

		classes.reset_class_cooldowns()

		if http and FOR_MATCH then
			http.fetch({
				url = TOURNAMENT_URL .. "/matches/"..FOR_MATCH.."/mark_as_underway.json",
				timeout = 10,
				method = "POST",
				data = {api_key = API_KEY},
			}, function(res)
				assert(res.succeeded, "Match ID was incorrect")
			end)
		end

		hud:clear_all()

		ctf_modebase.build_timer.start(60 * 3)
		MATCH_STARTED = true
	end,
	on_match_end = function(...)
		features.on_match_end(...)
	end,
	allocate_teams = function(map_teams, dont_allocate_players, ...)
		local teams = table.copy(map_teams)
		teams["spectator"] = {}

		local out = ctf_teams.allocate_teams(teams, true, ...)

		local players = minetest.get_connected_players()
		table.shuffle(players)
		for _, player in ipairs(players) do
			ctf_teams.allocate_player(player)
		end

		return out
	end,
	team_allocator = function(player)
		local pname = PlayerName(player)

		if locked[pname] then
			return teamnum_to_teamcolor(locked[pname])
		end

		if selected_team[pname] == "spectator" or minetest.check_player_privs(player, {tournament_spectator = true}) then
			return "spectator"
		else
			return teamnum_to_teamcolor(selected_team[pname])
		end
	end,
	on_allocplayer = function(player, new_team)
		if new_team then
			classes.update(player)
			features.on_allocplayer(player, new_team)

			if new_team == "spectator" then
				if table.indexof(confirmed, player:get_player_name()) == -1 then
					if not minetest.check_player_privs(player, {tournament_spectator = true}) then
						minetest.kick_player(player:get_player_name(), "Only official spectators are allowed when a match is started. "..
								"You aren't confirmed in a team")
					end
				end

				minetest.change_player_privs(player:get_player_name(), {
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

				for id, def in pairs(player:hud_get_all()) do
					if def.type == "statbar" then
						player:hud_change(id, "position", {x = -10, y = -10})
					end
				end

				hud:add(player, "match_info", {
					hud_elem_type = "text",
					position = {x = 0.5, y = 0},
					alignment = {x = "center", y = "down"},
					color = 0xFFFFFF,
					text_scale = 3,
					text = minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(1)].color, TEAM[1]) ..
							" vs " ..
							minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(2)].color, TEAM[2])
				})

				if player.set_observers then
					player:set_observers({[player:get_player_name()] = true})
				end

				player:set_pos(vector.add(ctf_map.current_map.pos1, vector.divide(ctf_map.current_map.size, 2)))
			else
				local name = player:get_player_name()

				minetest.change_player_privs(name, {
					interact = true,
					shout = true,
					canafk = true,
					fly = false, noclip = false, fast = false,
				})
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

		for _, p in pairs(minetest.get_connected_players()) do
			if ctf_teams.get(p) ~= "spectator" then
				if not hud:exists(p, "attempt_info") then
					hud:add(p, "attempt_info", {
						hud_elem_type = "text",
						position = {x = 0.5, y = 1},
						offset = {x = 0, y = -112},
						alignment = {x = "center", y = "up"},
						color = 0xFFFFFF,
						text = minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(1)].color, TEAM[1]) ..
							string.format(" (%d) vs (%d) ",
								recent_rankings.teams()[teamnum_to_teamcolor(1)].flag_attempts or 0,
								recent_rankings.teams()[teamnum_to_teamcolor(2)].flag_attempts or 0
							) ..
							minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(2)].color, TEAM[2])
					})
				else
					hud:change(p, "attempt_info", {
						text = minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(1)].color, TEAM[1]) ..
							string.format(" (%d) vs (%d) ",
								recent_rankings.teams()[teamnum_to_teamcolor(1)].flag_attempts or 0,
								recent_rankings.teams()[teamnum_to_teamcolor(2)].flag_attempts or 0
							) ..
							minetest.colorize(ctf_teams.team[teamnum_to_teamcolor(2)].color, TEAM[2])
					})
				end
			end
		end

		if QUEUE_MATCH_END then
			features.on_flag_capture(player, {teamname})
			minetest.after(5, report_win, teamcolor_to_teamnum(ctf_teams.get(player)))
		end

		return out
	end,
	on_flag_drop = features.on_flag_drop,
	on_flag_capture = function(capturer, teams, ...)
		local teamnum = teamcolor_to_teamnum(ctf_teams.get(capturer))

		minetest.after(5, report_win, teamnum)

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
minetest.register_globalstep(function(dtime)
	if MATCH_STARTED then return end
	if #tracked_players < CONFIRMED_PLAYER_TARGET then return end

	timer = timer + dtime

	if timer >= 1 then
		timer = 0

		if TEAM[1] and TEAM[2] and #confirmed >= CONFIRMED_PLAYER_TARGET then
			-- trim extra players out, prioritize players locked in by Challonge
			if #confirmed > CONFIRMED_PLAYER_TARGET then
				local confirmed_only = {{}, {}}
				local locked_p = {{}, {}}

				for idx, p in ipairs(confirmed) do
					if not locked_p[p] then
						table.insert(confirmed_only[selected_team[p]], p)
					else
						table.insert(locked_p[selected_team[p]], p)
					end
				end

				for _, tm in pairs({1, 2}) do
					for i = #confirmed_only[tm] + #locked_p[tm], TEAM_SIZE+1, -1 do
						local p = table.remove(confirmed, table.indexof(confirmed, confirmed_only[tm][1]))
						table.remove(confirmed_only[tm], 1)

						minetest.kick_player(p, "Kicked due to your team having too many teammates")
					end
				end
			end

			minetest.after(25 * 60, function()
				minetest.chat_send_all("\n" ..
					minetest.colorize("green", "[ANNOUNCEMENT]") ..
					" In 5 minutes the match will end, and the team with the most attempts will win\n\n"
				)

				minetest.after(5 * 60, function()
					local players = recent_rankings.players()
					local teams = recent_rankings.teams()
					local attempts_1 = teams[teamnum_to_teamcolor(1)].flag_attempts or 0
					local attempts_2 = teams[teamnum_to_teamcolor(2)].flag_attempts or 0

					if attempts_1 == attempts_2 then
						QUEUE_MATCH_END = true
						minetest.chat_send_all("\n" ..
							minetest.colorize("green", "[ANNOUNCEMENT]") ..
							" The next team to grab a flag will win\n\n"
						)
					elseif attempts_1 > attempts_2 then
						local best, best_count = false, -1

						for player, scores in pairs(players) do
							scores.flag_attempts = scores.flag_attempts or 0

							if scores._team == teamnum_to_teamcolor(1) and scores.flag_attempts > best_count then
								best = player
								best_count = scores.flag_attempts
							end
						end

						if best then
							features.on_flag_capture(PlayerObj(best), {teamnum_to_teamcolor(2)})
						end

						report_win(attempts_1)
					else
						local best, best_count

						for player, scores in pairs(players) do
							scores.flag_attempts = scores.flag_attempts or 0

							if scores._team == teamnum_to_teamcolor(2) and scores.flag_attempts > best_count then
								best = player
								best_count = scores.flag_attempts
							end
						end

						if best then
							features.on_flag_capture(PlayerObj(best), {teamnum_to_teamcolor(1)})
						end

						report_win(attempts_2)
					end
				end)
			end)

			start_new_match()
		end
	end
end)