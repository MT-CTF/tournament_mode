#!/bin/bash

REPORT_DISCORD=false
WEBHOOK_URL=""

LOG_PATH="/home/luanti/tournament_server/logs"

SERVER_NAME="tournament_server"
SERVER_PATH="/home/luanti/tournament_server"

json_escape() {
		python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

if [ -f "$LOG_PATH/debug.txt" ]; then
		if [[ $REPORT_DISCORD ]]; then
				ERROR=$(tail -n100 $LOG_PATH/debug.txt | fgrep --before-context=10 ERROR | tail -c $((1989 - ${#SERVER_NAME})) )

				if [ ${#ERROR} -le 0 ]; then
						ERROR="**Server \`$SERVER_NAME\` Restarting...**"
						# message_chat "**Server \`$SERVER_NAME\` Restarting...**"
				else
						ERROR="**$SERVER_NAME**:\`\`\`$ERROR\`\`\`"
						# message_chat "**Server \`$SERVER_NAME\` Restarting (Errors Reported)**"
				fi

				ERROR=$(echo "$ERROR" | json_escape)

				curl -X POST $WEBHOOK_URL -H "Content-Type: application/json" -d "{\"content\": $ERROR}" &
		fi

		touch $LOG_PATH/debug_$(date +"%d-%m-%Y").txt
		cat $LOG_PATH/debug.txt >> $LOG_PATH/debug_$(date +"%d-%m-%Y").txt
		printf "\n\n\n\n\n\n" >> $LOG_PATH/debug_$(date +"%d-%m-%Y").txt
		echo "" > $LOG_PATH/debug.txt

		find $LOG_PATH/* -mtime +30 -delete &
fi

wait

$SERVER_PATH/update_server.sh

# sqlite3 $SERVER_PATH/world/players.sqlite "DELETE FROM player_inventories; DELETE FROM player_inventory_items;"
# sqlite3 $SERVER_PATH/world/players.sqlite "DELETE FROM player_metadata WHERE metadata = 'skybox:skybox';"
# sqlite3 $SERVER_PATH/world/players.sqlite "UPDATE player SET pitch = 0, yaw = 0, posX = 0, posY = 0, posZ = 0; VACUUM;"

/home/luanti/luanti/bin/luantiserver --gameid capturetheflag --world $SERVER_PATH/world/ --config $SERVER_PATH/luanti.conf --logfile $LOG_PATH/debug.txt &
# Comment out the line above and uncomment the one below if you want to get backtraces at $SERVER_PATH/gdb.txt
#cd $SERVER_PATH && gdb -batch -ex "set logging on" -ex "run" -ex "bt" --args /home/luanti/luanti/bin/luantiserver --gameid capturetheflag --world $SERVER_PATH/world/ --config $SERVER_PATH/luanti.conf --logfile $LOG_PATH/debug.txt

wait
