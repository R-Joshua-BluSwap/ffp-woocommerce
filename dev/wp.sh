#!/bin/sh
# Run wp-cli inside the compose test bench: ./wp.sh plugin list
cd "$(dirname "$0")" && exec docker compose --profile cli run --rm -T wpcli "$@"
