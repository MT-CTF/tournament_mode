-- Tournament teamform: lobby UI plus the roster/map state it manages.
-- Loaded with ctf_core.include_files; init.lua then calls setup() with
-- the functions this file needs but doesn't own (match control, privs,
-- player meta, HUD) and uses the returned interface for the rest.

local is_manager
local is_spectate_allowed
local set_spectate_allowed
local is_match_started
local is_match_starting
local try_start_match
local hud

local function setup(deps)
	is_manager = deps.is_manager
	is_spectate_allowed = deps.is_spectate_allowed
	set_spectate_allowed = deps.set_spectate_allowed
	is_match_started = deps.is_match_started
	is_match_starting = deps.is_match_starting
	try_start_match = deps.try_start_match
	hud = deps.hud
end
local readied = {}
local locked = {}
local teams_locked = false
-- statbar positions hidden from spectators, restored if they play a later match
local spectator_statbars = {}
-- pre-spectator snapshots (properties, armor, hud flags) taken before we
-- hide a player: restores never guess CTF/player_api/engine defaults
local spectator_props = {}
local pending_map = "two_hills"
local pending_mode = "classes"
local swap_colors = false
local auto_capture_minutes = 15
local nametag_visibility = "all"


--[[

   _______                     ______
  |__   __|                   |  ____|
     | | ___  __ _ _ __ ___   | |__ ___  _ __ _ __ ___
     | |/ _ \/ _` | '_ ` _ \  |  __/ _ \| '__| '_ ` _ \
     | |  __/ (_| | | | | | | | | | (_) | |  | | | | | |
     |_|\___|\__,_|_| |_| |_| |_|  \___/|_|  |_| |_| |_|

]]

local TEAM = {"Team 1", "Team 2"}

local storage = core.get_mod_storage()

local function save_carryover()
	storage:set_string("locked", core.serialize(locked))
	storage:set_string("team_names", core.serialize(TEAM))
	storage:set_string("pending_map", pending_map or "")
	storage:set_string("pending_mode", pending_mode or "")
	storage:set_string("swap_colors", swap_colors and "true" or "")
	storage:set_string("auto_capture_minutes", tostring(auto_capture_minutes))
	storage:set_string("nametag_visibility", nametag_visibility)
end

local function load_carryover()
	local data = core.deserialize(storage:get_string("locked"))

	if type(data) == "table" then
		for pname, tnum in pairs(data) do
			if type(pname) == "string" and (tnum == 1 or tnum == 2) then
				locked[pname] = tnum
			end
		end
	end

	data = core.deserialize(storage:get_string("team_names"))

	if type(data) == "table" then
		for i = 1, 2 do
			local name = data[i]

			if type(name) == "string" then
				-- same scrub as live renames: stored names with
				-- formspec metachars would break the next boot's render
				name = name:trim():sub(1, 20):gsub("[^%w _%-]", "_"):trim()

				if name ~= "" then
					TEAM[i] = name
				end
			end
		end
	end

	local map = storage:get_string("pending_map")

	if type(map) == "string" and map ~= "" then
		pending_map = map
	end

	local mode = storage:get_string("pending_mode")

	if type(mode) == "string" and mode ~= "" then
		pending_mode = mode
	end

	swap_colors = storage:get_string("swap_colors") == "true"

	local acm = tonumber(storage:get_string("auto_capture_minutes"))

	if acm then
		acm = math.floor(acm)
	end

	if acm and acm >= 1 and acm <= 60 then
		auto_capture_minutes = acm
	end

	local nv = storage:get_string("nametag_visibility")
	if nv == "all" or nv == "team_spectator" then
		nametag_visibility = nv
	end
end

load_carryover()

-- display list: offline players stay rostered (a rejoin restores their
-- team) and show greyed until they're back online. The whole roster
-- sorts together, online and offline intermixed.
local function get_team_players(teamnum)
	local out = {}

	for pname, tnum in pairs(locked) do
		if tnum == teamnum then
			out[#out + 1] = pname
		end
	end

	table.sort(out)
	return out
end

local function get_unassigned_players()
	local out = {}

	for _, player in ipairs(core.get_connected_players()) do
		local pname = player:get_player_name()

		if not locked[pname] then
			table.insert(out, pname)
		end
	end

	table.sort(out)
	return out
end

-- whole roster, online or not: the start gate waits for offline
-- members too, so the "readied/total" HUD must include them
local function locked_count()
	local n = 0

	for _ in pairs(locked) do
		n = n + 1
	end

	return n
end

local function count_playable_teams(map)
	if not map or not map.teams then
		return 0
	end

	local n = 0

	for _, def in pairs(map.teams) do
		if not def.not_playing then
			n = n + 1
		end
	end

	return n
end

local function get_mode_options()
	local out = {}

	for _, name in ipairs(ctf_modebase.modelist) do
		if ctf_modebase.modes[name] then
			table.insert(out, name)
		end
	end

	table.sort(out)
	return out
end

local function get_pending_mode()
	if ctf_modebase.modes[pending_mode] then
		return pending_mode
	end

	if ctf_modebase.modes["classes"] then
		return "classes"
	end

	local opts = get_mode_options()

	if #opts > 0 then
		return opts[1]
	end

	return "classes"
end

local function map_supports_mode(map, mode)
	return not map.game_modes or table.indexof(map.game_modes, mode) ~= -1
end

local function map_is_playable(dirname, mode)
	mode = mode or get_pending_mode()
	local idx = dirname and ctf_modebase.map_catalog.map_dirnames[dirname]

	if not idx then
		return false
	end

	local map = ctf_modebase.map_catalog.maps[idx]

	if count_playable_teams(map) ~= 2 then
		return false
	end

	return map_supports_mode(map, mode)
end

local function get_map_options(mode)
	mode = mode or get_pending_mode()
	local out = {}

	for _, map in ipairs(ctf_modebase.map_catalog.maps) do
		if count_playable_teams(map) == 2 and map_supports_mode(map, mode) then
			table.insert(out, {name = map.name, dirname = map.dirname})
		end
	end

	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

local function get_pending_map()
	if map_is_playable(pending_map) then
		return pending_map
	end

	if map_is_playable("two_hills") then
		return "two_hills"
	end

	local opts = get_map_options()

	if #opts > 0 then
		return opts[1].dirname
	end

	return "two_hills"
end

local function get_pending_colors()
	local idx = ctf_modebase.map_catalog.map_dirnames[get_pending_map()]

	if not idx then
		return nil
	end

	local map = ctf_modebase.map_catalog.maps[idx]

	if not map or not map.teams then
		return nil
	end

	local out = {}

	for color, def in pairs(map.teams) do
		if not def.not_playing then
			table.insert(out, color)
		end
	end

	table.sort(out)

	if swap_colors then
		local rev = {}

		for i = #out, 1, -1 do
			rev[#rev + 1] = out[i]
		end

		out = rev
	end

	return out
end

local function color_readied(players)
	local out = {}

	for _, p in pairs(players) do
		if not core.get_player_by_name(p) then
			table.insert(out, "#888888" .. p)
		elseif table.indexof(readied, p) ~= -1 then
			table.insert(out, "#00FF00" .. p)
		else
			table.insert(out, p)
		end
	end

	return table.concat(out, ",")
end

local function color_unassigned(players)
	local out = {}

	for _, p in pairs(players) do
		if is_manager(p) then
			table.insert(out, "#FFD700" .. p)
		elseif is_spectate_allowed(p) then
			table.insert(out, "#00FF00" .. p)
		else
			table.insert(out, p)
		end
	end

	return table.concat(out, ",")
end

local function team_display_color(colorname)
	local team = colorname and ctf_teams.team[colorname]

	if not team or not team.color then
		return nil
	end

	return colorname == "blue" and "#5A8CFF" or team.color
end

local function colored_label(name, colorname)
	local color = team_display_color(colorname)

	if color then
		return "<style color=\"" .. color .. "\">" .. core.hypertext_escape(name) .. "</style>"
	end

	return core.hypertext_escape(name)
end

local function update_readied_hud()
	for _, p in pairs(core.get_connected_players()) do
		if hud:exists(p, "readied_players") then
			hud:change(p, "readied_players", {
				text = string.format("Readied Players: %d/%d", #readied, locked_count())
			})
		end
	end
end

local showform
local form_shown = {}
local editing_team = {}
local adding_open = {}
local manager_tab = {}
-- managers actively typing a new auto-capture value: same reshow
-- protection as the roster typing flags, but scoped to actual
-- editing so plain Settings viewers still get live updates
local editing_timer = {}
-- spectator list picks, tracked by player name so list shifts can't
-- misassign. The rendered highlight is forced to the stored name's row.
local selected_spectator = {}
-- last-rendered team rosters per viewer. A double-click carries only a
-- row index, so it is resolved against the render the clicker actually
-- saw and re-validated before removing anyone.
local rendered_rosters = {}

local field_epoch = {[1] = 0, [2] = 0}

-- Add-field element names carry an epoch so Clear can wipe a still-open
-- field: a new name rebuilds the element empty client-side.
local function add_field(teamnum)
	return "team" .. teamnum .. "_add_" .. field_epoch[teamnum]
end

local function reshow_form(except)
	for p in pairs(form_shown) do
		-- never clobber a manager's form while they're typing
		-- (roster add/name fields, or the Settings timer field):
		-- their own submit/cancel refreshes them instead
		if (not except or p ~= except) and not adding_open[p] and not editing_team[p]
				and not editing_timer[p] then
			local player = core.get_player_by_name(p)

			if player then
				showform(player)
			end
		end
	end
end

showform = function(player)
	if not hud:exists(player, "readied_players") then
		hud:add(player, "readied_players", {
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.5},
			offset = {x = 0, y = -64},
			alignment = {x = "center", y = "up"},
			text = string.format("Readied Players: %d/%d", #readied, locked_count()),
			color = 0xFFFFFF,
		})
	end

	if not hud:exists(player, "showform_explanation") then
		local text, color = "Use /teamform to view the teams.", 0xFFFFFF

		if not is_spectate_allowed(player:get_player_name()) then
			text = "Use /teamform to see the teams. Wait for an admin to assign you, then ready up."
			color = 0xFF0000
		end

		hud:add(player, "showform_explanation", {
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.5},
			offset = {x = 0, y = -32},
			alignment = {x = "center", y = "up"},
			text = text,
			color = color,
		})
	end

	local playername = player:get_player_name()
	local manager = is_manager(playername)
	local spectator_approved = is_spectate_allowed(playername)

	form_shown[playername] = true
	ctf_gui.show_formspec(player, "tournament_mode:choose_team",
		function(context)
			local starting = is_match_starting()
			-- while starting everyone sees the plain player form:
			-- no manager controls, no ready/unready buttons
			local view_manager = manager and not starting
			-- a rostered manager readies exactly like a player, and a
			-- rostered player is a player even if approved as spectator:
			-- the exemption only applies to unassigned non-managers
			local spectator_exempt = spectator_approved and not manager and
				not locked[playername]
			local rostered_active = locked[playername] and not spectator_exempt and not starting
			local readied_idx = table.indexof(readied, playername)
			local show_ready = rostered_active and readied_idx == -1
			local show_unready = rostered_active and readied_idx ~= -1
			local waiting = not locked[playername] and not spectator_approved and not manager
			local show_bottom = show_ready or show_unready or waiting or manager or starting
			-- locked teams block every roster/map mutation: tooltips must
			-- describe the block, not the unlocked action
			local function tip(normal)
				return teams_locked and "Teams are locked - unlock them to make changes" or normal
			end
			local w = 15
			local h = (view_manager and 10.5 or 8.7) + (show_bottom and (view_manager and 0.9 or 1.3) or 0)
			local col_w = w / 3 - 0.2
			local col2_x = w / 3
			local col3_x = (w / 3) * 2
			local bottom_y = 8.8 + (view_manager and 1.7 or 0)

			local team1_players = get_team_players(1)
			local team2_players = get_team_players(2)
			rendered_rosters[playername] = {team1_players, team2_players}
			local unassigned_players = get_unassigned_players()
			local mode_options = get_mode_options()
			local pending_mode_idx = 1

			for i, name in ipairs(mode_options) do
				if name == get_pending_mode() then
					pending_mode_idx = i
					break
				end
			end

			local map_options = get_map_options()
			local pending_idx = 1

			for i, opt in ipairs(map_options) do
				if opt.dirname == get_pending_map() then
					pending_idx = i
					break
				end
			end

			local map_title = map_options[pending_idx]
				and map_options[pending_idx].name
				or get_pending_map()
			local mode_name = mode_options[pending_mode_idx]
				and HumanReadable(mode_options[pending_mode_idx])
				or get_pending_mode()
			map_title = map_title .. " - " .. mode_name

			-- force the highlight to the stored pick's row (a nonzero
			-- index overrides the client's preserved one); 0 preserves.
			local selected_idx = 0
			local pick = selected_spectator[playername]

			if pick then
				selected_idx = table.indexof(unassigned_players, pick) or 0
			end

			local current_tab = manager_tab[playername] or "1"
			local is_settings_tab = view_manager and current_tab == "2"
			local tab_idx = is_settings_tab and "2" or "1"

			if is_settings_tab then
				local sw, sh = 15, 7.2
				local mode_items = {}

				for _, name in ipairs(mode_options) do
					table.insert(mode_items, HumanReadable(name))
				end

				local nv_idx = nametag_visibility == "all" and 1 or 2
				local s_out = {
					{"size[%d,%f]", sw, sh},
					"formspec_version[4]",
					{"background[-0.1,-0.1;%f,%f;%s]", sw + 0.2, sh + 0.5,
						get_pending_map() .. "_screenshot.png^[opacity:25]"},
					{"tabheader[0,0;teamform_tabs;Main,Settings;%s;true;false]", tab_idx},
					{"label[0.3,0.5;Match Settings]"},
					{"dropdown[0.3,1.1;3.5;mode_select;%s;%d;true]", mode_items, pending_mode_idx},
					{"tooltip[mode_select;Tournament game mode]"},
				}

				if editing_timer[playername] then
					table.insert(s_out,
						{"field[0.6,2.8;3,0.5;auto_capture_minutes;Auto-Capture Timer (minutes);%d]", auto_capture_minutes})
					table.insert(s_out,
						{"tooltip[auto_capture_minutes;Minutes until sudden death activates (1-60)]"})
					table.insert(s_out, {"button[3.3,2.5;1.5,0.5;save_auto_capture;Save]"})
					table.insert(s_out, {"tooltip[save_auto_capture;Save the auto-capture timer]"})
					table.insert(s_out, {"button[5.0,2.5;1.5,0.5;cancel_auto_capture;Cancel]"})
					table.insert(s_out, {"tooltip[cancel_auto_capture;Close without changing the timer]"})
					table.insert(s_out, "field_close_on_enter[auto_capture_minutes;false]")
				else
					table.insert(s_out, {"label[0.3,2.5;Auto-Capture Timer: %d minute%s]",
						auto_capture_minutes, auto_capture_minutes == 1 and "" or "s"})
					table.insert(s_out, {"button[3.3,2.5;1.5,0.5;edit_auto_capture;Change]"})
					table.insert(s_out, {"tooltip[edit_auto_capture;Change the auto-capture timer (1-60 minutes)]"})
				end

				table.insert(s_out, {"label[0.3,3.2;Nametag Visibility]"})
				table.insert(s_out, {"dropdown[0.3,3.7;4.5;nametag_visibility;%s;%d;true]",
					{"All Players", "Team & Spectators Only"}, nv_idx})
				table.insert(s_out, {"tooltip[nametag_visibility;Who can see player nametags]"})

				return ctf_gui.list_to_formspec_str(s_out)
			end

			local out = {
				{"size[%d,%f]", w, (manager and (h - 0.3) or (h - 0.4))},
				"formspec_version[4]",
				{"background[-0.1,-0.1;%f,%f;%s]", w+0.2, h + 0.1,
					get_pending_map() .. "_screenshot.png^[opacity:" .. (view_manager and 25 or 40) .. "]"},
			}

			if view_manager then
				table.insert(out, {"tabheader[0,0;teamform_tabs;Main,Settings;%s;true;false]", tab_idx})
				table.insert(out, {"hypertext[2.1,0;5.6,1;map_title;<big>%s</big>]",
					core.hypertext_escape(map_title)})
			else
				table.insert(out, {"hypertext[0,0;14.8,1;map_title;<center><big>%s</big></center>]",
					core.hypertext_escape(map_title)})
			end

			table.insert(out, {"label[%f,1;Spectators (unassigned)]", col3_x})
			table.insert(out, {"box[0,1.8;%f,6.5;#00000080]", col_w})
			table.insert(out, {"box[%f,1.8;%f,6.5;#00000080]", col2_x, col_w})
			table.insert(out, {"box[%f,1.8;%f,6.5;#00000080]", col3_x, col_w})
			table.insert(out, {"textlist[0,1.8;%f,6.5;team1;" .. color_readied(team1_players) .. ";0;true]", col_w})
			table.insert(out, {"textlist[%f,1.8;%f,6.5;team2;" .. color_readied(team2_players) .. ";0;true]", col2_x, col_w})
			table.insert(out, {"textlist[%f,1.8;%f,6.5;spectators;" .. color_unassigned(unassigned_players) ..
				";%d;true]", col3_x, col_w, selected_idx})

			-- Unassigned players may close the form and reopen it with
			-- /teamform. Only close-locked rostered players need Leave Game.
			if not manager and not spectator_approved and table.indexof(readied, playername) == -1 and
					not starting and locked[playername] then
				table.insert(out, "allow_close[false]")
				table.insert(out, "style[leave_game;bgcolor=#CC0000;textcolor=#FFFFFF]")
				table.insert(out, {"button[%f,%f;3,0.9;leave_game;Leave Game]", w - 3.1, bottom_y - 0.1})
				table.insert(out, {"tooltip[leave_game;Disconnect from the server]"})
			end

			if view_manager then
				local items = {}

				for _, opt in ipairs(map_options) do
					table.insert(items, opt.name)
				end

				local mode_items = {}

				for _, name in ipairs(mode_options) do
					table.insert(mode_items, HumanReadable(name))
				end

				table.insert(out, {"dropdown[%f,0;%f;mode_select;%s;%d;true]", 7.9, 3.3,
					mode_items, pending_mode_idx})
				table.insert(out, {"tooltip[mode_select;Tournament game mode]"})
				table.insert(out, {"dropdown[%f,0;%f;map_select;%s;%d;true]", 11.4, 3.4,
					items, pending_idx})
				table.insert(out, {"tooltip[map_select;Maps supporting the selected mode]"})
				table.insert(out, {"button[0,0;1.9,0.8;swap_colors;Swap Teams]"})
				table.insert(out, {"tooltip[swap_colors;%s]",
					tip("Swap which in-game color each team is assigned")})
			end

			local pending_colors = get_pending_colors()
			local color1 = pending_colors and pending_colors[1]
			local color2 = pending_colors and pending_colors[2]

			if view_manager and editing_team[playername] == 1 then
				table.insert(out, {"field[0.3,1.31;%f,0.5;team1_name;;%s]", col_w - 1.3, TEAM[1]})
				table.insert(out, {"button[%f,1.1;1.3,0.3;save_team1;Save]", col_w - 1.3})
			else
				table.insert(out, {"hypertext[0.4,1;%f,0.7;team1_label;%s]", col_w - 0.4,
					colored_label(TEAM[1] or "1", color1)})

				if view_manager then
					table.insert(out, {"button[%f,1.1;1,0.3;edit_team1;Edit]", col_w - 1})
				end
			end

			if view_manager and editing_team[playername] == 2 then
				table.insert(out, {"field[%f,1.31;%f,0.5;team2_name;;%s]", col2_x + 0.3, col_w - 1.3, TEAM[2]})
				table.insert(out, {"button[%f,1.1;1.3,0.3;save_team2;Save]", col2_x + col_w - 1.3})
			else
				table.insert(out, {"hypertext[%f,1;%f,0.7;team2_label;%s]", col2_x + 0.4, col_w - 0.4,
					colored_label(TEAM[2] or "2", color2)})

				if view_manager then
					table.insert(out, {"button[%f,1.1;1,0.3;edit_team2;Edit]", col2_x + col_w - 1})
				end
			end

			if view_manager then
				if adding_open[playername] == 1 then
					-- set_focus must precede the field; force re-applies on
					-- refresh (same formname) so typing can start at once
					table.insert(out, {"set_focus[%s;true]", add_field(1)})
					table.insert(out, {"field[0.3,8.8;4.1,1;%s;;]", add_field(1)})
					table.insert(out, {"image_button[4.1,8.52;0.9,0.9;clear.png;cancel_add1;]"})
					table.insert(out, {"tooltip[cancel_add1;Close without adding]"})
					table.insert(out, {"tooltip[%s;Comma-separated usernames. " ..
						"Prefix [Team Name\\]: to name the team.]", add_field(1)})
					table.insert(out, {"button[0.3,9.4;2.6,0.9;open_add1;Submit]"})
					table.insert(out, {"button[3.0,9.4;1.7,0.9;clear_team1;Clear]"})
					table.insert(out, {"tooltip[open_add1;%s]",
						tip("Add these players to team 1")})
				else
					table.insert(out, {"button[0.3,8.52;2.6,0.9;open_add1;Add players]"})
					table.insert(out, {"button[3.0,8.52;1.7,0.9;clear_team1;Clear]"})
					table.insert(out, {"tooltip[open_add1;Add players to team 1]"})
				end

				if adding_open[playername] == 2 then
					-- set_focus must precede the field; force re-applies on
					-- refresh (same formname) so typing can start at once
					table.insert(out, {"set_focus[%s;true]", add_field(2)})
					table.insert(out, {"field[%f,8.8;4.1,1;%s;;]", col2_x + 0.3, add_field(2)})
					table.insert(out, {"image_button[%f,8.52;0.9,0.9;clear.png;cancel_add2;]",
						col2_x + 4.1})
					table.insert(out, {"tooltip[cancel_add2;Close without adding]"})
					table.insert(out, {"tooltip[%s;Comma-separated usernames. " ..
						"Prefix [Team Name\\]: to name the team.]", add_field(2)})
					table.insert(out, {"button[%f,9.4;2.6,0.9;open_add2;Submit]", col2_x + 0.3})
					table.insert(out, {"button[%f,9.4;1.7,0.9;clear_team2;Clear]", col2_x + 3.0})
					table.insert(out, {"tooltip[open_add2;%s]",
						tip("Add these players to team 2")})
				else
					table.insert(out, {"button[%f,8.52;2.6,0.9;open_add2;Add players]", col2_x + 0.3})
					table.insert(out, {"button[%f,8.52;1.7,0.9;clear_team2;Clear]", col2_x + 3.0})
					table.insert(out, {"tooltip[open_add2;Add players to team 2]"})
				end

				table.insert(out, {"field_close_on_enter[%s;false]", add_field(1)})
				table.insert(out, {"field_close_on_enter[%s;false]", add_field(2)})
				table.insert(out, {"field_close_on_enter[team1_name;false]"})
				table.insert(out, {"field_close_on_enter[team2_name;false]"})
				table.insert(out, {"tooltip[clear_team1;%s]",
					tip("Remove everyone from team 1 and reset its name")})
				table.insert(out, {"tooltip[clear_team2;%s]",
					tip("Remove everyone from team 2 and reset its name")})
				table.insert(out, {"tooltip[team1;%s]",
					tip("Double-click a member to remove them from the team")})
				table.insert(out, {"tooltip[team2;%s]",
					tip("Double-click a member to remove them from the team")})
				local tcolor1 = team_display_color(color1)
				local tcolor2 = team_display_color(color2)

				if tcolor1 then
					table.insert(out, {"style[assign_spectator1;textcolor=%s]", tcolor1})
				end

				if tcolor2 then
					table.insert(out, {"style[assign_spectator2;textcolor=%s]", tcolor2})
				end

				table.insert(out, {"button[%f,8.52;2.5,0.9;assign_spectator1;%s]", col3_x, TEAM[1] or "1"})
				table.insert(out, {"button[%f,8.52;2.5,0.9;assign_spectator2;%s]", col3_x + 2.5, TEAM[2] or "2"})
				table.insert(out, {"tooltip[assign_spectator1;%s]",
					tip("Assign the selected spectator to " .. (TEAM[1] or "1"))})
				table.insert(out, {"tooltip[assign_spectator2;%s]",
					tip("Assign the selected spectator to " .. (TEAM[2] or "2"))})
			-- select and the double-click spectator mark work while locked;
			-- only assigning to a team is blocked
			local spectator_tip = "Single-click to select, then assign " ..
				"with a team button below. Double-click to toggle the allowed-spectator mark."

			if teams_locked then
				spectator_tip = "Teams are locked - unlock them to assign spectators to a team. " ..
					"Double-click still toggles the allowed-spectator mark."
			end

			table.insert(out, {"tooltip[spectators;%s]", spectator_tip})
			end

		local lock_label = teams_locked and "Unlock Teams" or "Lock Teams"
		local lock_tip = teams_locked and "Unlock the rosters so managers can change them again"
			or "Lock in both rosters (no changes until unlocked)"

		if show_ready then
			table.insert(out, "style[ready;font=bold]")
			table.insert(out, {
				"label[0,%f;You're in team %s]",
				bottom_y + 0.05,
				TEAM[locked[playername]] or locked[playername],
			})

			if view_manager then
				table.insert(out, {
					"button[%f,%f;3,0.9;ready;Ready]",
					(w / 2) - 3.2,
					bottom_y - 0.1,
				})
				table.insert(out, {
					"button[%f,%f;3,0.9;toggle_lock;%s]",
					(w / 2) + 0.2,
					bottom_y - 0.1,
					lock_label,
				})
				table.insert(out, {"tooltip[toggle_lock;%s]", lock_tip})
			else
				table.insert(out, {
					"button[%f,%f;3,0.9;ready;Ready]",
					(w / 2) - (3 / 2),
					bottom_y - 0.1,
				})
			end
		elseif show_unready then
			table.insert(out, {
				"label[0,%f;You are now able to close this formspec]",
				bottom_y + 0.05,
			})
			table.insert(out, "style[unready;font=bold]")

			if view_manager then
				table.insert(out, {
					"button[%f,%f;3,0.9;unready;Unready]",
					(w / 2) - 3.2,
					bottom_y - 0.1,
				})
				table.insert(out, {
					"button[%f,%f;3,0.9;toggle_lock;%s]",
					(w / 2) + 0.2,
					bottom_y - 0.1,
					lock_label,
				})
				table.insert(out, {"tooltip[toggle_lock;%s]", lock_tip})
			else
				table.insert(out, {
					"button[%f,%f;3,0.9;unready;Unready]",
					(w / 2) - (3 / 2),
					bottom_y - 0.1,
				})
			end
		elseif view_manager then
			-- locking is a manager duty, not a player one: any manager
			-- can lock, rostered or not. Locked rosters are required
			-- before readied teams can start a match.
			table.insert(out, {
				"button[%f,%f;3,0.9;toggle_lock;%s]",
				(w / 2) - (3 / 2),
				bottom_y - 0.1,
				lock_label,
			})
			table.insert(out, {"tooltip[toggle_lock;%s]", lock_tip})
		elseif starting then
			table.insert(out, {
				"label[0,%f;Match starting...]",
				bottom_y - 0.1,
			})
		elseif waiting then
				table.insert(out, {
					"label[0,%f;Waiting for an admin to assign teams.]",
					bottom_y - 0.1,
				})
			end

			if view_manager then
				table.insert(out, {"image_button[%f,%f;0.9,0.9;refresh.png;refresh;]", w - 0.9, bottom_y - 0.2})
				table.insert(out, {"tooltip[refresh;Refresh the form]"})
			end

			return ctf_gui.list_to_formspec_str(out)
		end
	, {
		player = player,
		_on_formspec_input = function(pname, context, fields)
			-- the match is starting: lobby controls are frozen, just
			-- flip the submitter to the starting view
			if is_match_starting() then
				return "refresh"
			end

			if fields.try_quit then
				core.chat_send_player(pname, locked[pname] and
					"[tournament] Please ready up in /teamform first" or
					"[tournament] Please wait for an admin to assign you a team")

				return
			end

			local admin = is_manager(pname)

			local function unready(name)
				local idx = table.indexof(readied, name)

				if idx ~= -1 then
					table.remove(readied, idx)
				end

			-- hud:exists stays true for offline players with stored HUDs
			-- while hud:change asserts online: unready() runs for offline
			-- names too (Clear, team moves), so check presence first
			if core.get_player_by_name(name) and hud:exists(name, "showform_explanation") then
				hud:change(name, "showform_explanation", {
					text = "Use /teamform to see the teams. Your team changed, please ready up again.",
					color = 0xFF0000,
				})
			end

				update_readied_hud()

				-- readied players closed their form, so reshow_form() would
				-- skip them: pop it open so they see the change immediately
			if not is_match_started() then
				local target = core.get_player_by_name(name)

				if target and not adding_open[name] and not editing_team[name] then
					showform(target)
				end
			end
			end

		local function sanitize_team_name(raw)
			local name = (raw or ""):trim():sub(1, 20)
			return name:gsub("[^%w _%-]", "_"):trim()
		end

		local function parse_add_input(raw)
			local text = (raw or ""):trim()
			local teamname
			local bracket, rest = text:match("^%[(.-)%]%s*:%s*(.*)$")

			if bracket then
				teamname = sanitize_team_name(bracket)
				text = rest or ""
			end

			local names = {}

			for part in text:gmatch("[^,]+") do
				local name = part:trim()

				if name ~= "" then
					table.insert(names, name)
				end
			end

			return teamname, names
		end

		local function assign_one(name, teamnum)
			if name == "" or not name:match("^[a-zA-Z0-9-_]+$") or #name > 20 then
				return false
			end

			if locked[name] == teamnum then
				return true
			end

			if locked[name] then
				unready(name)
			end

			locked[name] = teamnum

			if core.get_player_by_name(name) then
				set_spectate_allowed(name, false)
			end

			return true
		end

		local function assign_names(raw, teamnum)
			if teams_locked then
				adding_open[pname] = nil
				core.chat_send_player(pname, "[tournament] Teams are locked - unlock them to make changes")
				reshow_form()
				return "refresh"
			end

			local teamname, names = parse_add_input(raw)

			if teamname and teamname ~= "" then
				TEAM[teamnum] = teamname
			end

			local bad = {}
			local added = {}
			local changed = false
			local before = get_unassigned_players()

			for _, name in ipairs(names) do
				local was = locked[name]
				local ok = assign_one(name, teamnum)

				if ok and was ~= teamnum then
					changed = true
					table.insert(added, name)
				elseif not ok then
					table.insert(bad, name)
				end
			end

			if #added > 0 then
				core.chat_send_player(pname, "[tournament] Added to \"" ..
					(TEAM[teamnum] or teamnum) .. "\": " .. table.concat(added, ", "))
			end

			if #bad > 0 then
				core.chat_send_player(pname,
					"[tournament] Invalid username(s): " .. table.concat(bad, ", "))
			end

			adding_open[pname] = nil

			-- keep track of the selection after moves: a pick that left
			-- the list sticks to the new occupant of its old row
			if changed then
				local pick = selected_spectator[pname]
				local after = get_unassigned_players()

				if pick and not table.indexof(after, pick) then
					local idx = table.indexof(before, pick) or 1
					selected_spectator[pname] = after[math.min(idx, #after)]
				end
			end

			reshow_form()
			update_readied_hud()
			return "refresh"
		end

		local function rename_team(teamnum, rawname)
			if teams_locked then
				editing_team[pname] = nil
				core.chat_send_player(pname, "[tournament] Teams are locked - unlock them to make changes")
				reshow_form()
				return "refresh"
			end

			local name = (rawname or ""):trim()

				if name == "" or #name > 20 or not name:match("^[a-zA-Z0-9-_ ]+$") then
					core.chat_send_player(pname,
						"[tournament] Invalid team name (letters, numbers, spaces, - and _ only, max 20 chars)")
					return "refresh"
				end

				TEAM[teamnum] = name
				editing_team[pname] = nil
				core.chat_send_player(pname,
					"[tournament] Team " .. teamnum .. " renamed to \"" .. name .. "\"")
				reshow_form()
				return "refresh"
			end

		local function modifications_allowed()
			if teams_locked then
				core.chat_send_player(pname, "[tournament] Teams are locked - unlock them to make changes")
				return false
			end

			return true
		end

		local function clear_team(teamnum)
			if not modifications_allowed() then
				return "refresh"
			end

			-- collect first: deleting keys during pairs() traversal
			-- is undefined in Lua 5.1 and can skip entries, leaving
			-- ghosts. Iterate the raw roster so offline ghosts are
			-- cleared too.
			local todel = {}

			for name, tnum in pairs(locked) do
				if tnum == teamnum then
					todel[#todel + 1] = name
				end
			end

			for _, name in ipairs(todel) do
				locked[name] = nil
				unready(name)
			end

			TEAM[teamnum] = "Team " .. teamnum
			field_epoch[teamnum] = field_epoch[teamnum] + 1
			reshow_form()
			return "refresh"
		end

		-- Read a typed add-field value even if our render is a stale epoch
		-- (another manager's Clear bumped it while this form was suppressed
		-- for typing). Typed text is self-describing, so unlike stored list
		-- indices it can never hit the wrong player.
		local function add_field_value(teamnum)
			local cur = fields[add_field(teamnum)]

			if cur ~= nil then
				return cur
			end

			for k, v in pairs(fields) do
				if type(k) == "string" and k:match("^team" .. teamnum .. "_add_") then
					return v
				end
			end

			return nil
		end

		if admin then
			if fields.refresh then
				return "refresh"
			end

			if fields.teamform_tabs then
				if fields.teamform_tabs == "1" or fields.teamform_tabs == "2" then
					manager_tab[pname] = fields.teamform_tabs

					if fields.teamform_tabs == "1" then
						editing_timer[pname] = nil
					end
				end
				return "refresh"
			end

			if fields.edit_auto_capture then
				editing_timer[pname] = true
				return "refresh"
			end

			if fields.cancel_auto_capture then
				editing_timer[pname] = nil
				return "refresh"
			end

		-- NOTE: the dropdowns submit their current value with every
		-- click, so only treat an actual change as an action. Otherwise
		-- the lock guard below would swallow every manager submission
		-- (ready, assign, ...) while teams are locked.
		if fields.mode_select then
			local idx = tonumber(fields.mode_select) or
				tonumber((fields.mode_select or ""):match(":(%d+)$"))
			local opts = get_mode_options()

			if idx and opts[idx] and opts[idx] ~= pending_mode then
				if not modifications_allowed() then
					return "refresh"
				end

				pending_mode = opts[idx]

				if not map_is_playable(pending_map, pending_mode) then
					local mopts = get_map_options(pending_mode)

					if #mopts > 0 then
						pending_map = mopts[1].dirname
					end
				end

				reshow_form()
				return "refresh"
			end
		end

		if fields.map_select then
				local idx = tonumber(fields.map_select) or
					tonumber((fields.map_select or ""):match(":(%d+)$"))
				local opts = get_map_options()

				if idx and opts[idx] and opts[idx].dirname ~= pending_map then
					if not modifications_allowed() then
						return "refresh"
					end

					pending_map = opts[idx].dirname
					reshow_form()
					return "refresh"
				end
			end

			if fields.swap_colors then
				if not modifications_allowed() then
					return "refresh"
				end

				swap_colors = not swap_colors
					reshow_form()
					return "refresh"
				end

			if fields.save_auto_capture or fields.key_enter_field == "auto_capture_minutes" then
				local val = tonumber(fields.auto_capture_minutes)

				if val then
					val = math.floor(val)
				end

				if val and val >= 1 and val <= 60 then
					if val ~= auto_capture_minutes then
						if not modifications_allowed() then
							return "refresh"
						end

						auto_capture_minutes = val
						save_carryover()
						core.chat_send_player(pname,
							"[tournament] Auto-capture timer set to " .. val ..
							" minute" .. (val == 1 and "" or "s"))
						reshow_form()
					end

					editing_timer[pname] = nil
					return "refresh"
				else
					core.chat_send_player(pname, "[tournament] Invalid value (1-60)")
					return "refresh"
				end
			end

			if fields.nametag_visibility then
				local idx = tonumber(fields.nametag_visibility) or
					tonumber((fields.nametag_visibility or ""):match(":(%d+)$"))
				local new_nv

				if idx == 1 then
					new_nv = "all"
				elseif idx == 2 then
					new_nv = "team_spectator"
				end

				if new_nv and new_nv ~= nametag_visibility then
					if not modifications_allowed() then
						return "refresh"
					end

					nametag_visibility = new_nv
					save_carryover()

					if ctf_modebase.update_playertags then
						ctf_modebase.update_playertags()
					end

					core.chat_send_player(pname, "[tournament] Nametag visibility set to " ..
						(nametag_visibility == "all" and "All Players" or "Team & Spectators Only"))
					reshow_form()
					return "refresh"
				end
			end

			if fields.edit_team1 then
				if not modifications_allowed() then
					return "refresh"
				end

				editing_team[pname] = (editing_team[pname] == 1) and nil or 1
				return "refresh"
			end

			if fields.edit_team2 then
				if not modifications_allowed() then
					return "refresh"
				end

				editing_team[pname] = (editing_team[pname] == 2) and nil or 2
				return "refresh"
			end

				if fields.save_team1 or fields.key_enter_field == "team1_name" then
					return rename_team(1, fields.team1_name)
				end

				if fields.save_team2 or fields.key_enter_field == "team2_name" then
					return rename_team(2, fields.team2_name)
				end

			if fields.open_add1 then
				if adding_open[pname] == 1 then
					return assign_names(add_field_value(1), 1)
				end

				adding_open[pname] = 1
				return "refresh"
			end

			if fields.open_add2 then
				if adding_open[pname] == 2 then
					return assign_names(add_field_value(2), 2)
				end

				adding_open[pname] = 2
				return "refresh"
			end

			if fields.cancel_add1 or fields.cancel_add2 then
				adding_open[pname] = nil
				return "refresh"
			end

			local key_field = fields.key_enter_field
			local team = key_field and tonumber(key_field:match("^team([12])_add_") or "") or nil
			local value = team and fields[key_field]

			if team and value and value:trim() ~= "" then
				return assign_names(value, team)
			end

			for _, spec in ipairs({{key = "team1", team = 1}, {key = "team2", team = 2}}) do
				local raw = fields[spec.key]

					if raw then
						local evt = core.explode_textlist_event(raw)

						if evt and evt.type == "DCL" and evt.index and evt.index >= 1 then
							-- resolve against this manager's own last render:
							-- another manager's edit may have shifted the
							-- list since. Only remove the clicked player if
							-- they're still on that team.
							local seen = rendered_rosters[pname]
							local name = seen and seen[spec.team] and
								seen[spec.team][math.floor(evt.index)]

							if name and locked[name] == spec.team then
								if not modifications_allowed() then
									return "refresh"
								end

								locked[name] = nil
								selected_spectator[pname] = name
								unready(name)
								reshow_form()
								return "refresh"
							elseif name then
								core.chat_send_player(pname,
									"[tournament] That list changed, please try again")
								return "refresh"
							end
						end
					end
				end

			if fields.clear_team1 then
				return clear_team(1)
			end

			if fields.clear_team2 then
				return clear_team(2)
			end

			-- NOTE: picks are tracked by player name (never by row index),
			-- so list shifts can't misassign. The form forces the
			-- highlight to the stored name's row on every render.
			if fields.spectators then
				local evt = core.explode_textlist_event(fields.spectators)

				if evt and evt.index and evt.index >= 1 and
						(evt.type == "CHG" or evt.type == "DCL") then
					local list = get_unassigned_players()
					local name = list[math.min(math.floor(evt.index), #list)]

					if name then
						selected_spectator[pname] = name

						if evt.type == "DCL" then
							set_spectate_allowed(name, not is_spectate_allowed(name))
							reshow_form()
							return "refresh"
						end
					end
				end
			end

			if fields.assign_spectator1 or fields.assign_spectator2 then
				if not modifications_allowed() then
					return "refresh"
				end

				local teamnum = fields.assign_spectator1 and 1 or 2
				local pick = selected_spectator[pname]
				local name = pick and table.indexof(get_unassigned_players(), pick) and pick

				if name then
					return assign_names(name, teamnum)
				end

				selected_spectator[pname] = nil
				core.chat_send_player(pname,
					"[tournament] Single-click a spectator in the list first")
				return "refresh"
			end

			-- inside `if admin`: any manager may (un)lock, rostered or not
			if fields.toggle_lock then
				if teams_locked then
					teams_locked = false
					core.chat_send_all("[tournament] Teams unlocked by " .. pname)
					reshow_form()
					return "refresh"
				end

			-- rosters, not presence: locking with offline members is
			-- fine, the start gate still waits until everyone added
			-- is online and readied. Any filled 1v1 may lock; only an
			-- empty team blocks, unless the other team has a manager
			-- (test/debug matches).
			local rosters = {get_team_players(1), get_team_players(2)}

			for teamnum = 1, 2 do
				if #rosters[teamnum] < 1 then
					local other_has_manager = false

					for _, member in ipairs(rosters[3 - teamnum]) do
						if is_manager(member) then
							other_has_manager = true
							break
						end
					end

					if not other_has_manager then
						core.chat_send_player(pname,
							"[tournament] Each team needs at least one player to lock")
						return "refresh"
					end
				end
			end

			teams_locked = true
				core.chat_send_all("[tournament] Teams locked in by " .. pname .. " - ready up to start!")
				reshow_form()

				if try_start_match(false) then
					return
				end

				return "refresh"
			end
		end

			if fields.leave_game and not is_manager(pname) and
				not is_spectate_allowed(pname) and
				table.indexof(readied, pname) == -1 then
			core.kick_player(pname, "You left the tournament lobby")
			return
		end

		if fields.unready and locked[pname] and table.indexof(readied, pname) ~= -1 then
				-- rostered means playing (managers and approved
				-- spectators included): no exemption check, the outer
				-- locked[pname] already guarantees it
				unready(pname)
				reshow_form(pname)
				return "refresh"
			elseif fields.ready and locked[pname] and table.indexof(readied, pname) == -1 then
				-- rostered means playing (managers and approved
				-- spectators included): no exemption check, the outer
				-- locked[pname] already guarantees it
			table.insert(readied, pname)

			if teams_locked and try_start_match(false) then
				return
			end

			reshow_form()

			local num = locked[pname]

				if hud:exists(pname, "showform_explanation") then
					hud:change(pname, "showform_explanation", {
						text = "Use /teamform to see the teams. You're ready in team \"" .. (TEAM[num] or num) .. "\"",
						color = 0xFFFFFF,
					})
				end

				update_readied_hud()
				return "refresh"
		elseif fields.quit then
			form_shown[pname] = nil
			editing_team[pname] = nil
			adding_open[pname] = nil
			manager_tab[pname] = nil
			editing_timer[pname] = nil
			selected_spectator[pname] = nil
			rendered_rosters[pname] = nil

			if not locked[pname] and not is_spectate_allowed(pname) then
				core.chat_send_player(pname,
					"[NOTICE] An admin can assign you to a team, " ..
					"otherwise you will spectate when the match starts"
				)
			end
			end
		end,
	})
end

local function all_locked_readied()
	local n1, n2 = 0, 0

	for pname, tnum in pairs(locked) do
		-- everyone added must be online and readied: approval meta is
		-- only readable while online, and being rostered means playing
		-- (a short-handed team starts via /force_start instead)
		if not core.get_player_by_name(pname) or table.indexof(readied, pname) == -1 then
			return false
		end

		if tnum == 1 then
			n1 = n1 + 1
		elseif tnum == 2 then
			n2 = n2 + 1
		end
	end

	return n1 >= 1 and n2 >= 1
end

-- membership entry points used by init.lua's event registrations
local function player_joined(player)
	local pname = player:get_player_name()

	if is_manager(pname) then
		core.chat_send_player(pname, "Not checking your team, as you're a manager")
	elseif is_spectate_allowed(pname) then
		core.chat_send_player(pname, "Not checking your team, as you're a spectator")
	end

	-- being rostered means you're playing: drop a stale spectator
	-- approval (e.g. approved, logged off, then assigned to a team
	-- while offline). Safe here, the player is online.
	if locked[pname] and is_spectate_allowed(pname) then
		set_spectate_allowed(pname, false)
	end

	if not is_match_started() then
		player = core.get_player_by_name(pname)

		if player then
			showform(player)
			-- everyone else needs the new arrival in their lists
			-- (skips managers mid-typing via reshow_form's guard)
			reshow_form(pname)
		end

		core.chat_send_player(pname, "You can run " .. core.colorize("cyan", "/teamform") ..
				" to see the teams in this tournament, and their players")
	end
end

local function player_left(player)
	local pname = player:get_player_name()
	local idx = table.indexof(readied, pname)

	if idx ~= -1 then
		table.remove(readied, idx)
		update_readied_hud()
	end

	form_shown[pname] = nil
	editing_team[pname] = nil
	adding_open[pname] = nil
	manager_tab[pname] = nil
	editing_timer[pname] = nil
	selected_spectator[pname] = nil
	rendered_rosters[pname] = nil
	spectator_statbars[pname] = nil
	spectator_props[pname] = nil
	reshow_form()
end

local function close_all_forms()
	for pname in pairs(form_shown) do
		core.close_formspec(pname, "tournament_mode:choose_team")
	end

	form_shown = {}
end

return {
	setup = setup,
	locked = locked,
	readied = readied,
	TEAM = TEAM,
	-- shared with init's on_allocplayer, which snapshots/restores these
	spectator_statbars = spectator_statbars,
	spectator_props = spectator_props,
	teams_locked = function()
		return teams_locked
	end,
	swap_colors = function()
		return swap_colors
	end,
	get_auto_capture_minutes = function()
		return auto_capture_minutes
	end,
	get_nametag_visibility = function()
		return nametag_visibility
	end,
	all_locked_readied = all_locked_readied,
	update_readied_hud = update_readied_hud,
	get_pending_map = get_pending_map,
	get_pending_mode = get_pending_mode,
	save_carryover = save_carryover,
	showform = showform,
	reshow_form = reshow_form,
	close_all_forms = close_all_forms,
	player_joined = player_joined,
	player_left = player_left,
}
