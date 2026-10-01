#!/bin/bash
# Compatibility/regression API suite. Usage: ./e2e-api.sh <site-url> <wp-cli script> <sql script>
#   ./e2e-api.sh http://localhost:8080 ./wp.sh ./sql.sh          (modern stack)
#   ./e2e-api.sh http://localhost:8074 ./wp-min.sh ./sql-min.sh  (WP 5.4 / WC 4.3 / PHP 7.4)
# Needs the mock API (node mock-api.js) on :9090, the plugin active + configured (token "testkey"),
# products "Blue Shirt" (simple) and "Tee" (variable with sizes S/M), classic [woocommerce_cart] cart page.
cd "$(dirname "$0")"
U=$1; W=$2; SQLX=$3; H="$U/wp-json/fastflowpe"; T=$(mktemp -d); PASS=0; FAIL=0
ok(){ if [ "$1" = "0" ]; then PASS=$((PASS+1)); echo "PASS $2"; else FAIL=$((FAIL+1)); echo "FAIL $2"; fi; }
has(){ echo "$1" | grep -q "$2"; ok $? "$3"; }
wp(){ $W "$@" 2>&1 | grep -v -E '^ Container|called incorrectly|Deprecated|sendmail'; }
count(){ wp eval 'echo count(wc_get_orders(array("limit"=>-1,"return"=>"ids")));' | tail -1; }
S=1; sqlv(){ $SQLX "$1" | tail -1; }
jget(){ python3 -c "import sys,json
try:
  print(json.load(sys.stdin)['$1'])
except Exception:
  print('')"; }
rl(){ $SQLX "DELETE FROM wp_options WHERE option_name LIKE '%fastflowpe_rl_%'" >/dev/null; }
mock(){ curl -s -X POST "localhost:9090/_mock/$1" >/dev/null; }

setup(){
wp plugin activate fastflowpe-checkout >/dev/null
wp eval 'update_option("fastflowpe_settings", array_merge(array("db_version"=>"1","show_buy_now"=>true), (array) get_option("fastflowpe_settings", array()), array("enabled"=>true,"merchant_token"=>"testkey","api_base_url"=>"http://host.docker.internal:9090","request_timeout"=>20)), false); update_option("woocommerce_currency","INR"); update_option("woocommerce_default_country","IN:MH"); update_option("woocommerce_coming_soon","no"); if (!get_option("woocommerce_cart_page_id") || !get_post(get_option("woocommerce_cart_page_id"))) { WC_Install::create_pages(); } wp_update_post(array("ID"=>(int) get_option("woocommerce_cart_page_id"),"post_content"=>"[woocommerce_cart]"));' >/dev/null

}
# idempotent: plugin active + configured against the mock API, classic cart page, currency INR
setup

SIMPLE=$(wp eval 'echo get_page_by_title("Blue Shirt",OBJECT,"product")->ID;' | tail -1)
VARIABLE=$(wp eval 'echo get_page_by_title("Tee",OBJECT,"product")->ID;' | tail -1)
VS=$(wp eval '$p=wc_get_product('$VARIABLE'); foreach($p->get_children() as $c){ if(wc_get_product($c)->get_attributes()["size"]=="S") echo $c; }' | tail -1)
VM=$(wp eval '$p=wc_get_product('$VARIABLE'); foreach($p->get_children() as $c){ if(wc_get_product($c)->get_attributes()["size"]=="M") echo $c; }' | tail -1)
wp eval 'foreach (array('"$SIMPLE"','"$VS"','"$VM"') as $i) { wc_update_product_stock( wc_get_product( $i ), 100 ); }' >/dev/null 2>&1
echo "products: simple=$SIMPLE variable=$VARIABLE S=$VS M=$VM"

has "$(curl -s $H/health)" '"status":"ok"' "health endpoint"
curl -s -L -c $T/cj -b $T/cj "$U/?p=$SIMPLE" -o $T/p.html
has "$(cat $T/p.html)" 'fastflowpe-buy-now' "Buy Now button rendered on product page"
N=$(grep -o '"nonce":"[a-z0-9]*"' $T/p.html | head -1 | cut -d'"' -f4)
post(){ curl -s -b $T/cj -c $T/cj -H "Origin: $U" -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d "$1"; }

has "$(post '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"quantity":0}}')" 'Invalid quantity' "reject quantity 0"
has "$(post '{"mode":"buy_now","buy_now":{"product_id":'$VARIABLE',"quantity":1}}')" 'choose product options' "reject variable w/o variation"
has "$(post '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"variation_id":'$VM',"quantity":1}}')" 'Invalid product variation' "reject wrong variation parent"
has "$(post '{"mode":"cart"}')" 'empty cart' "reject empty cart"
has "$(curl -s -H 'Origin: http://evil.example' -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d '{"mode":"cart"}')" 'fastflowpe_forbidden' "reject cross-site start"

# --- prepaid buy-now, forged price ignored, concurrency
R=$(post '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"quantity":2,"price":1}}'); ID=$(echo "$R" | jget id)
has "$R" 'external_app=true' "start returns hosted link with external_app"
SLUG=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID'")
has "$(curl -s localhost:9090/_mock/orders)" '"order_amount":1499' "server-side price used (1499, not forged 1)"
has "$(curl -s "$H/checkout/status?id=$ID")" '"status":"pending"' "status pending before payment"
B=$(count); mock "pay/$SLUG?mode=prepaid&billing=1549&state=Maharashtra"
for i in 1 2 3 4 5 6; do curl -s "$H/checkout/status?id=$ID" > $T/c$i.json & done; wait
A=$(count); [ "$((A-B))" = "1" ]; ok $? "6 concurrent polls created exactly 1 order (before=$B after=$A)"
curl -s "$H/checkout/status?id=$ID" >/dev/null; [ "$(count)" = "$A" ]; ok $? "repeat poll creates no duplicate"
OID=$(sqlv "SELECT wc_order_id FROM wp_checkout_sessions WHERE public_id='$ID'")
INFO=$(wp eval '$o=wc_get_order('$OID'); echo $o->get_status()."|".$o->get_total()."|".$o->get_billing_state()."|".$o->get_billing_country()."|".$o->get_billing_phone()."|".$o->get_created_via()."|".$o->get_meta("_fp_checkout_slug")."|".$o->get_meta("_fp_utr")."|".$o->get_billing_address_2();' | tail -1)
[ "$INFO" = "processing|1549.00|MH|IN|9876543210|fastflowpe|$SLUG|UTR$SLUG|Indiranagar" ]; ok $? "order fields (status/total/state/country/phone/meta): $INFO"
has "$(sqlv "SELECT paid_at IS NULL FROM wp_checkout_sessions WHERE public_id='$ID'")" '^0$' "paid_at set for prepaid"

# --- COD lower billing
rl
R=$(post '{"mode":"buy_now","buy_now":{"product_id":'$VARIABLE',"variation_id":'$VM',"quantity":1,"attributes":{"attribute_size":"M"}}}'); ID2=$(echo "$R" | jget id)
SLUG2=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID2'")
S0=$(wp eval 'echo wc_get_product('$VM')->get_stock_quantity();' | tail -1)
mock "fail?on=1"; has "$(curl -s "$H/checkout/status?id=$ID2")" '"status":"pending"' "API down: stays pending"; mock "fail?on=0"
mock "pay/$SLUG2?mode=cod&billing=350&state=Tamilnadu&country=IN"; curl -s "$H/checkout/status?id=$ID2" >/dev/null
OID2=$(sqlv "SELECT wc_order_id FROM wp_checkout_sessions WHERE public_id='$ID2'")
INFO=$(wp eval '$o=wc_get_order('$OID2'); echo $o->get_status()."|".$o->get_total()."|".$o->get_billing_state()."|".($o->get_date_paid()?"paid":"unpaid")."|".wc_get_product('$VM')->get_stock_quantity();' | tail -1)
[ "$INFO" = "on-hold|350.00|TN|unpaid|$((S0-1))" ]; ok $? "COD: on-hold, reconciled to 350, TN, not paid, stock reduced: $INFO"
has "$(sqlv "SELECT paid_at IS NULL FROM wp_checkout_sessions WHERE public_id='$ID2'")" '^1$' "COD paid_at NULL"

# --- cart mode + coupon-free cart, cookie-bound clearing
CJ=$T/cart; touch $CJ
curl -s -c $CJ -b $CJ -o /dev/null "$U/?add-to-cart=$SIMPLE&quantity=2"
curl -s -c $CJ -b $CJ -L "$U/cart/" -o $T/cart.html
has "$(cat $T/cart.html)" 'fastflowpe-checkout-button' "cart page button rendered"
N=$(grep -o '"nonce":"[a-z0-9]*"' $T/cart.html | head -1 | cut -d'"' -f4)
R=$(curl -s -c $CJ -b $CJ -H "Origin: $U" -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d '{"mode":"cart"}'); ID3=$(echo "$R" | jget id)
SLUG3=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID3'")
mock "pay/$SLUG3?mode=prepaid&billing=1499"
has "$(curl -s "$H/checkout/status?id=$ID3")" '"status":"success"' "cart checkout success (no cart cookie, like cron)"
has "$(curl -s -c $CJ -b $CJ -L "$U/cart/" | grep -c 'fastflowpe-checkout-button')" '^1$' "cart untouched by cookie-less poll"
curl -s -c $CJ -b $CJ "$H/checkout/status?id=$ID3" >/dev/null
has "$(curl -s -c $CJ -b $CJ -L "$U/cart/")" 'currently empty' "cart cleared by shopper's status call"

# --- coupon-applied cart (10% off, server-side discount)
rl
wp eval 'if (!wc_get_coupon_id_by_code("SAVE10")) { $c=new WC_Coupon(); $c->set_code("SAVE10"); $c->set_discount_type("percent"); $c->set_amount(10); $c->save(); }' >/dev/null
CJ2=$T/cart2; touch $CJ2
curl -s -c $CJ2 -b $CJ2 -o /dev/null "$U/?add-to-cart=$SIMPLE&quantity=2"
curl -s -c $CJ2 -b $CJ2 -L "$U/cart/" -o $T/cart2.html
CN=$(grep -o 'name="woocommerce-cart-nonce" value="[a-z0-9]*"' $T/cart2.html | head -1 | cut -d'"' -f4)
curl -s -c $CJ2 -b $CJ2 -o /dev/null -L -X POST "$U/cart/" --data-urlencode "coupon_code=SAVE10" --data-urlencode "apply_coupon=Apply coupon" --data-urlencode "woocommerce-cart-nonce=$CN" --data-urlencode "_wp_http_referer=/cart/"
R=$(curl -s -c $CJ2 -b $CJ2 -H "Origin: $U" -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d '{"mode":"cart"}'); ID5=$(echo "$R" | jget id)
SLUG5=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID5'")
has "$(curl -s localhost:9090/_mock/orders)" '"order_amount":1349.1' "coupon: order_amount is discounted total (1349.1)"
has "$(curl -s localhost:9090/_mock/orders)" '"discount_amount":149.9' "coupon: discount_amount sent per line"
mock "pay/$SLUG5?mode=prepaid&billing=1349.1"; curl -s "$H/checkout/status?id=$ID5" >/dev/null
OID5=$(sqlv "SELECT wc_order_id FROM wp_checkout_sessions WHERE public_id='$ID5'")
INFO=$(wp eval '$o=wc_get_order('$OID5'); echo $o->get_status()."|".$o->get_total();' | tail -1)
[ "$INFO" = "processing|1349.10" ]; ok $? "coupon cart order total = 1349.10: $INFO"

# --- logged-in customer (nonce required so core keeps the user)
rl
wp eval 'if (!get_user_by("login","shopper")) wp_create_user("shopper","pw123","shopper@example.com"); $u=get_user_by("login","shopper"); $u->set_role("customer");' >/dev/null
UC=$T/user; touch $UC
curl -s -c $UC -b $UC -o /dev/null -d "log=shopper&pwd=pw123&wp-submit=Log+In&testcookie=1" -H "Cookie: wordpress_test_cookie=WP%20Cookie%20check" "$U/wp-login.php"
curl -s -c $UC -b $UC -L "$U/?p=$SIMPLE" -o $T/up.html
UN=$(grep -o '"nonce":"[a-z0-9]*"' $T/up.html | head -1 | cut -d'"' -f4)
R=$(curl -s -c $UC -b $UC -H "X-WP-Nonce: $UN" -H "Origin: $U" -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"quantity":1}}'); ID6=$(echo "$R" | jget id)
SLUG6=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID6'")
mock "pay/$SLUG6?mode=prepaid&billing=749.5"; curl -s "$H/checkout/status?id=$ID6" >/dev/null
OID6=$(sqlv "SELECT wc_order_id FROM wp_checkout_sessions WHERE public_id='$ID6'")
UID_=$(wp eval 'echo get_user_by("login","shopper")->ID;' | tail -1)
INFO=$(wp eval '$o=wc_get_order('$OID6'); $c=new WC_Customer($o->get_customer_id()); echo $o->get_customer_id()."|".$c->get_billing_city();' | tail -1)
[ "$INFO" = "$UID_|Pune" ]; ok $? "logged-in order linked to customer, profile synced: $INFO"
has "$(curl -s -c $UC -b $UC -H "X-WP-Nonce: bad" -H "Origin: $U" -H 'Content-Type: application/json' -X POST "$H/checkout/start" -d '{"mode":"cart"}')" 'rest_cookie_invalid_nonce' "logged-in user with bad nonce rejected"

# --- mini cart widget on a page that is NOT product/cart/shop (only where the theme has widget areas)
SB=$(wp sidebar list --format=ids 2>/dev/null | tr ' ' '\n' | grep -v -E 'wp_inactive|orphaned' | head -1)
if [ -n "$SB" ]; then
  wp widget delete $(wp widget list $SB --format=ids 2>/dev/null) >/dev/null 2>&1
  wp widget add woocommerce_widget_cart $SB --title=MiniCart >/dev/null 2>&1
  MC=$T/mini; touch $MC
  curl -s -c $MC -b $MC -o /dev/null "$U/?add-to-cart=$SIMPLE"
  curl -s -c $MC -b $MC -L "$U/" -o $T/home.html
  has "$(cat $T/home.html)" 'fastflowpe-checkout/assets/js/storefront.js' "storefront.js loaded on the home page (mini cart present)"
  wp widget delete $(wp widget list $SB --format=ids 2>/dev/null) >/dev/null 2>&1
  curl -s -L "$U/" -o $T/home2.html
  [ "$(grep -c 'fastflowpe-checkout/assets/js/storefront.js' $T/home2.html)" = "0" ]; ok $? "home page without a mini cart does not load storefront.js"
else
  echo "SKIP mini cart widget test (theme has no widget area; covered by tests/run.php)"
fi

# --- Action Scheduler poll
rl
R=$(post '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"quantity":1}}'); ID4=$(echo "$R" | jget id)
SLUG4=$(sqlv "SELECT checkout_slug FROM wp_checkout_sessions WHERE public_id='$ID4'")
has "$(wp eval 'echo count(as_get_scheduled_actions(array("hook"=>"fastflowpe_poll_session","status"=>"pending")));' | tail -1)" '^[1-9]' "poll action scheduled"
has "$(wp eval 'echo false!==as_next_scheduled_action("fastflowpe_sweep_sessions", array(), "fastflowpe")?"yes":"no";' | tail -1)" 'yes' "recurring sweep scheduled"
mock "pay/$SLUG4?mode=prepaid&billing=749.5"; sleep 32; wp action-scheduler run --force >/dev/null
has "$(sqlv "SELECT status FROM wp_checkout_sessions WHERE public_id='$ID4'")" 'success' "Action Scheduler poll created the order"

# --- sweep: stale, expire, stuck
rl
for i in 1 2 3; do post '{"mode":"buy_now","buy_now":{"product_id":'$SIMPLE',"quantity":1}}' >/dev/null; done
IDS=($($SQLX "SELECT id FROM wp_checkout_sessions ORDER BY id DESC LIMIT 3" | tail -3))
$SQLX "UPDATE wp_checkout_sessions SET created_at=UTC_TIMESTAMP()-INTERVAL 25 HOUR WHERE id=${IDS[0]}; UPDATE wp_checkout_sessions SET status='processing', updated_at=UTC_TIMESTAMP()-INTERVAL 20 MINUTE WHERE id=${IDS[1]}" >/dev/null
wp eval 'do_action("fastflowpe_sweep_sessions");' >/dev/null
[ "$(sqlv "SELECT status FROM wp_checkout_sessions WHERE id=${IDS[0]}")" = "expired" ]; ok $? "sweep expires 24h-old unpaid session"
[ "$(sqlv "SELECT status FROM wp_checkout_sessions WHERE id=${IDS[1]}")" = "pending" ]; ok $? "sweep releases stuck processing"

# --- admin ajax + settings (login)
A=$T/admin; touch $A
curl -s -c $A -b $A -o /dev/null -d "log=admin&pwd=admin&wp-submit=Log+In&testcookie=1" -H "Cookie: wordpress_test_cookie=WP%20Cookie%20check" "$U/wp-login.php"
curl -s -c $A -b $A "$U/wp-admin/admin.php?page=wc-settings&tab=fastflowpe" -o $T/set.html
[ "$(grep -c testkey $T/set.html)" = "0" ]; ok $? "token not rendered in settings HTML"
has "$(cat $T/set.html)" 'Configured' "settings shows Configured"
AN=$(grep -o 'FastFlowPeAdmin = {[^;]*' $T/set.html | grep -o '"nonce":"[a-z0-9]*"' | cut -d'"' -f4)
has "$(curl -s -c $A -b $A -X POST "$U/wp-admin/admin-ajax.php" -d "action=fastflowpe_test_connection&nonce=$AN")" '"success":true' "test connection (valid token)"
has "$(curl -s -c $A -b $A -X POST "$U/wp-admin/admin-ajax.php" -d "action=fastflowpe_test_connection")" 'Security check failed' "ajax rejects missing nonce"
has "$(curl -s -c $A -b $A -X POST "$U/wp-admin/admin-ajax.php" -d "action=fastflowpe_check_status&nonce=$AN&id=${IDS[2]}")" '"success":true' "manual check status"
WN=$(grep -o 'name="_wpnonce" value="[a-z0-9]*"' $T/set.html | head -1 | cut -d'"' -f4)
curl -s -c $A -b $A -o /dev/null -X POST "$U/wp-admin/admin.php?page=wc-settings&tab=fastflowpe" --data-urlencode "_wpnonce=$WN" --data-urlencode "save=1" --data-urlencode "fastflowpe[enabled]=1" --data-urlencode "fastflowpe[request_timeout]=999" --data-urlencode "fastflowpe[api_base_url]=ftp://x"
has "$(wp option get fastflowpe_settings --format=json | tail -1)" '"request_timeout":60' "settings save clamps timeout"
has "$(wp option get fastflowpe_settings --format=json | tail -1)" '"merchant_token":"testkey"' "blank token keeps saved token"

# --- lifecycle
wp plugin deactivate fastflowpe-checkout >/dev/null
ok 0 "deactivate"
wp eval 'update_option("fastflowpe_settings", array_merge((array) get_option("fastflowpe_settings", array()), array("delete_data_on_uninstall"=>true)), false);' >/dev/null
wp eval 'define("WP_UNINSTALL_PLUGIN","x"); include WP_PLUGIN_DIR."/fastflowpe-checkout/uninstall.php";' >/dev/null
[ -z "$($SQLX "SHOW TABLES LIKE 'wp_checkout_sessions'" | tail -1)" ]; ok $? "uninstall drops table"
wp plugin activate fastflowpe-checkout >/dev/null
has "$($SQLX "SHOW TABLES LIKE 'wp_checkout_sessions'" | tail -1)" 'wp_checkout_sessions' "re-activation recreates table"

setup   # leave the site configured for the browser suite
echo "== $PASS passed, $FAIL failed =="; [ $FAIL = 0 ]
