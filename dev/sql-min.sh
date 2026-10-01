#!/bin/sh
# SQL against the MINIMUM stack DB
cd "$(dirname "$0")" && exec docker compose -p ffpmin -f docker-compose.min.yml exec -T db mysql -uwp -pwp wp -e "$1" 2>&1 | grep -v 'Using a password'
