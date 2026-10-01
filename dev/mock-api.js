// Minimal FastFlowPe hosted-checkout mock for local testing (contract per PLAN.md §4.5 + backend behaviour).
// Control endpoints: POST /_mock/pay/:slug?mode=prepaid|cod|partial&billing=1549&state=Maharashtra&country=India
//                    POST /_mock/fail?on=1|0   (make every API call return 500)
//                    GET  /_mock/orders        (inspect)
const http = require('http');
const KEY = 'testkey';
const orders = {};
let failing = false;

function send(res, code, body) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    const p = url.pathname;
    if (req.method === 'HEAD') { res.writeHead(200); return res.end(); }
    if (p === '/_mock/orders') return send(res, 200, orders);
    if (p === '/_mock/fail') { failing = url.searchParams.get('on') === '1'; return send(res, 200, { failing }); }
    let m;
    if (req.method === 'GET' && p.startsWith('/pay/')) {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      return res.end(`<html><body><h3>Mock hosted checkout ${p}</h3>
<button id="close" onclick="parent.postMessage({type:'FASTFLOW_CHECKOUT_CLOSED'},'*')">close</button>
<script>parent.postMessage({type:'FASTFLOW_CHECKOUT_ANALYTICS_EVENT',provider:'ga4',eventName:'begin_checkout',params:{value:1}},'*')</script></body></html>`);
    }
    if ((m = p.match(/^\/_mock\/pay\/(.+)$/))) {
      const o = orders[m[1]];
      if (!o) return send(res, 404, { message: 'no such order' });
      o.paid = true;
      o.mode = url.searchParams.get('mode') || 'prepaid';
      o.billing = parseFloat(url.searchParams.get('billing') || o.order_amount);
      o.state = url.searchParams.get('state') || 'Maharashtra';
      o.country = url.searchParams.get('country') || 'India';
      return send(res, 200, o);
    }

    if (req.headers['x-hosted-checkout-key'] !== KEY)
      return send(res, 404, { status: 'error', detail: 'Merchant not found. Invalid hosted checkout key.' });
    if (failing) return send(res, 500, { status: 'Error', message: 'Failed to create order' });

    if (req.method === 'POST' && p === '/merchant/hosted-checkout/create-order') {
      const body = JSON.parse(raw || '{}');
      if (!Array.isArray(body.products) || typeof body.order_amount !== 'number')
        return send(res, 422, { detail: [{ msg: 'invalid' }] });
      const slug = 'S' + Math.random().toString(36).slice(2, 10);
      orders[slug] = { slug, ...body, paid: false };
      console.log('create-order', slug, JSON.stringify(body));
      return send(res, 200, { status: 'success', data: { order: { slug, order_reference_id: body.order_reference_id }, checkout_url: 'http://localhost:9090/pay/' + slug } });
    }
    if ((m = p.match(/^\/merchant\/hosted-checkout\/order-status\/(.+)$/))) {
      const o = orders[m[1]];
      if (!o) return send(res, 404, { status: 'error', message: 'Order not found' });
      const txn = o.paid ? {
        transaction_id: 'txn_' + o.slug, utr: o.mode === 'cod' ? null : 'UTR' + o.slug, status: 'SUCCESS',
        payment_mode: o.mode === 'cod' ? 'COD' : 'upi', amount: o.billing,
      } : null;
      return send(res, 200, { status: 'success', data: {
        order: { slug: o.slug, billing_amount: o.billing || o.order_amount, payment_mode: o.paid ? (o.mode === 'cod' ? 'cash-on-delivery' : 'upi') : null,
          customer_details: { customer_name: 'Asha Rao', email: 'asha@example.com', phone_number: '+91 98765 43210' },
          shipping_address: { first_name: 'Asha', last_name: 'Rao', address_line: '12 MG Road', area: 'Indiranagar', city: 'Pune', state: o.state, country: o.country, pincode: '411001', phone_number: '9876543210', email: 'asha@example.com' } },
        transactions: txn, is_partial_cod_applied: o.mode === 'partial' } });
    }
    send(res, 404, { message: 'unknown route' });
  });
}).listen(9090, () => console.log('mock on 9090'));
