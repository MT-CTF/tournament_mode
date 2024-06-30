ctf_teams.team.spectator = {
	color = "#fff",
	color_hex = tonumber("0xfff"),
	irc_color = 0,
	not_playing = true
}

table.insert(ctf_teams.teamlist, "spectator")

minetest.register_on_player_hpchange(function(player, hp_change, reason)
	if ctf_teams.get(player) == "spectator" then
		return 0
	else
		return hp_change
	end
end, true)