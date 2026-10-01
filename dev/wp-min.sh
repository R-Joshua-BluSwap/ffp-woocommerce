#!/bin/sh
# wp-cli against the MINIMUM stack (WP 5.4 / PHP 7.4 / WC 4.3): ./wp-min.sh plugin list
cd "$(dirname "$0")" && exec docker compose -p ffpmin -f docker-compose.min.yml --profile cli run --rm -T wpcli "$@"
