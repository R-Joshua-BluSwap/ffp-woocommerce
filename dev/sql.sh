#!/bin/sh
# Run SQL against the test bench DB: ./sql.sh "SELECT ..."
cd "$(dirname "$0")" && exec docker compose exec -T db mysql -uwp -pwp wp -e "$1" 2>&1 | grep -v 'Using a password'
