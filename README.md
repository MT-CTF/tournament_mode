# tournament_mode

Tournament mode for CTF, code taken from from CTF's [classes mode](https://github.com/MT-CTF/capturetheflag/tree/master/mods/ctf/ctf_modes/ctf_mode_classes) and modified by LoneWolfHT

This mod should only be used on server dedicated to running tournament matches. It's possible for players to end up without interact privs if you disable the mod.

For community tournaments the tournament id needs to be prefixed with the subdomain of your community. Which you can find at `https://challonge.com/communities/<your community>/community_settings/edit`
The format for the id is `<subdomain>-<tournament id>`, or just `<tournament id>` if it's a user-hosted tournament

Custom fields setup should look like this, in order:
- `Team Leader Username (Text, required)`
- `Team Member Username (Text, required)`
- `Team Member Username (Text, required)`

You can set up stations for each server you have and have them automatically assigned too