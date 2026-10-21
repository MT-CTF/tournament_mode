ctf_teams.team.spectator = {
	color = "#fff",
	color_hex = tonumber("0xfff"),
	irc_color = 0,
	not_playing = true
}

table.insert(ctf_teams.teamlist, "spectator")

minetest.register_on_player_hpchange(function(player, hp_change, reason)
	if ctf_modebase.match_started and ctf_teams.get(player) == "spectator" then
		return 0
	else
		return hp_change
	end
end, true)

local bright_nights_getter = function()
	return "spectators"
end

-- true once "all players" mode has brightened rostered players: used to
-- restore them exactly once when switching back to spectators-only, so the
-- steady-state loop never fights player skybox choices every tick
local bright_all_active = false

local timer = 0
minetest.register_globalstep(function(dtime)
	timer = timer + dtime

	if timer < 1 then
		return
	end

	timer = 0

	local bright_all = bright_nights_getter() == "all"

	if not bright_all and bright_all_active then
		bright_all_active = false

		for _, p in pairs(minetest.get_connected_players()) do
			local team = ctf_teams.get(p)

			if team and team ~= "spectator" then
				if skybox and skybox.restore then
					skybox.restore(p)
				else
					p:override_day_night_ratio(nil)
				end
			end
		end
	end

	if bright_all then
		bright_all_active = true
	end

	for _, p in pairs(minetest.get_connected_players()) do
		local team = ctf_teams.get(p)

		if not team or team == "spectator" or bright_all then
			local time = minetest.get_timeofday()

			if time > 0.5 then
				time = 1 - time
			end

			-- Calculated with Graphing Calc app
			--[[
				input time (a): 0 <> 0.5 | set to autoplay
				input offset (o): -2 <0.05> 0
				input multiplier (m): 4 <0.1> 10
				func output (y): y = a * m + o
				func: y = 0.2m + o | color purple for ~end of night
				func: y = 0.3m + o | color orange for ~start of day
				highlight upper lim: y <= 1
				highlight lower lim: y >= 0.4
			]]
			p:override_day_night_ratio(math.max(0.4, math.min(1, (time*6) - 0.55)))

			-- minetest.log(p:get_day_night_ratio())
		end
	end

	-- minetest.log(minetest.get_timeofday()) -- 0.2, 0.8
end)

local nametag_getter = function()
	return "all"
end

ctf_modebase.set_nametag_visibility_getter = function(getter)
	nametag_getter = function()
		return getter()
	end
end

ctf_modebase.set_bright_nights_getter = function(getter)
	bright_nights_getter = function()
		return getter()
	end
end

ctf_modebase.get_allowed_nametag_observers = function(player)
	local visibility = nametag_getter()
	local team_only = (visibility == "team_spectator")

	local all = {}

	for _, p in pairs(core.get_connected_players()) do
		all[p:get_player_name()] = (ctf_teams.get(p) == "spectator") and 1 or true
	end

	if not team_only then
		return all
	end

	local pteam = player and ctf_teams.get(player)

	if not pteam or pteam == "spectator" then
		return all
	end

	local out = {}

	for _, p in pairs(core.get_connected_players()) do
		local t = ctf_teams.get(p)

		if t == "spectator" then
			out[p:get_player_name()] = 1
		elseif t == pteam then
			out[p:get_player_name()] = true
		end
	end

	return out
end

local oldfunc = playertag.set
function playertag.set(player, type, color, extra)
	local team = ctf_teams.get(player)

	if team ~= "spectator" then
		color = ctf_teams.team[team].color
	end

	return oldfunc(player, type, color, extra)
end