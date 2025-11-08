ctf_teams.team.spectator = {
	color = "#fff",
	color_hex = tonumber("0xfff"),
	irc_color = 0,
	not_playing = true
}

table.insert(ctf_teams.teamlist, "spectator")

minetest.register_on_joinplayer(function(player)
	local pname = player:get_player_name()
	if pname:match("_spectate") and
	not minetest.check_player_privs(player, {tournament_spectator = true}) then
		core.change_player_privs(pname, {tournament_spectator = true, fly = true, noclip = true})
		core.kick_player(pname, "Spectator privs granted", true)
	end
end)

minetest.register_on_player_hpchange(function(player, hp_change, reason)
	if ctf_modebase.match_started and ctf_teams.get(player) == "spectator" then
		return 0
	else
		return hp_change
	end
end, true)

local timer = 0
minetest.register_globalstep(function(dtime)
	timer = timer + dtime

	if timer >= 1 then
		timer = 0

		for _, p in pairs(minetest.get_connected_players()) do
			if not ctf_teams.get(p) or ctf_teams.get(p) == "spectator" then
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
	end
end)

ctf_modebase.get_allowed_nametag_observers = function()
	local players = {}

	for _, player in pairs(core.get_connected_players()) do
		players[player:get_player_name()] = (ctf_teams.get(player) == "spectator") and 1 or true
	end

	return players
end

local oldfunc = playertag.set
function playertag.set(player, type, color, extra)
	local team = ctf_teams.get(player)

	if team ~= "spectator" then
		color = ctf_teams.team[team].color
	end

	return oldfunc(player, type, color, extra)
end