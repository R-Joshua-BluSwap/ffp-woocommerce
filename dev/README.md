# Test bench

Two stacks, both mount `../fastflowpe-checkout`:

| Stack | Compose | Ports | Helpers |
|---|---|---|---|
| Modern (WP latest, WC latest, PHP 8.2, MySQL 8; HPOS toggle with `./wp.sh wc hpos enable/disable`) | `docker-compose.yml` | 8080 | `wp.sh`, `sql.sh` |
| Minimum (WP 5.4, WC 4.3.0, PHP 7.4, MariaDB 10.4) | `docker-compose.min.yml` (`-p ffpmin`) | 8074 | `wp-min.sh`, `sql-min.sh` |

Mock FastFlowPe API: `node mock-api.js` (port 9090, key `testkey`).

Set up the minimum stack once:

    docker compose -p ffpmin -f docker-compose.min.yml up -d
    ./wp-min.sh core install --url=http://localhost:8074 --title=Min --admin_user=admin --admin_password=admin --admin_email=a@b.co --skip-email
    ./wp-min.sh plugin install https://downloads.wordpress.org/plugin/woocommerce.4.3.0.zip --activate
    # then create a simple product "Blue Shirt" and a variable product "Tee" (sizes S/M) - see git history / e2e-api.sh

Suites (run both, plus HPOS on/off on the modern stack):

    ./e2e-api.sh http://localhost:8074 ./wp-min.sh ./sql-min.sh
    ./e2e-api.sh http://localhost:8080 ./wp.sh ./sql.sh
    BASE=http://localhost:8074 SIMPLE=5 VARIABLE=6 node e2e-storefront.js   # needs puppeteer-core + Chrome
    ./lint-php74.sh                                                          # PHP 7.4 syntax lint

Note: run the API suite with bash (`./e2e-api.sh`), it resets the plugin (uninstall/reactivate) and re-configures it at the end.

Regression suite (runs inside WordPress; disposable dev site only):

    ./wp-min.sh eval-file wp-content/plugins/fastflowpe-checkout/tests/run.php
    ./wp.sh     eval-file wp-content/plugins/fastflowpe-checkout/tests/run.php

Both compose files set `WP_ENVIRONMENT_TYPE=local` so the plain-http mock API is accepted by the API URL policy.
