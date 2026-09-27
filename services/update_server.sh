#!/bin/bash

SERVER_NAME="tournament_server"
SERVER_PATH="/home/luanti/tournament_server"

git -C ~/luanti/games/capturetheflag/ pull -r
git -C ~/luanti/games/capturetheflag/ submodule sync --recursive
git -C ~/luanti/games/capturetheflag/ submodule update --init --recursive
git -C ~/luanti/games/capturetheflag/ pull -r --recurse-submodules

if [ -d "$SERVER_PATH/world/worldmods/" ]; then
		cd $SERVER_PATH/world/worldmods/

		for folder in */ ; do
				if [ -d "./$folder.git" ]; then
						git config --global --add safe.directory "$SERVER_PATH/world/worldmods/$folder"

						git -C "./$folder" pull -r

						if [ -f "./$folder.gitmodules" ]; then
								git -C "./$folder" submodule sync --recursive
								git -C "./$folder" submodule update --init --recursive
								git -C "./$folder" pull -r --recurse-submodules
						fi
				fi
		done
fi
