# Control plane is loopback-gated on the Relay port

> Status: accepted

Pairing QR, status, rotate pairing secret, and the desktop-shell HTTP/JSON
API are served from the Relay on port 17321, but only to loopback clients.
The Relay still binds `0.0.0.0` for the phone WebSocket. LAN requests to
control routes return 404. The pairing secret must never be fetchable from
another device on the WiFi.

A second loopback-only port and a Unix socket were rejected for the first
ship. Transfers already distinguish loopback on this port; control routes
follow that gate. A Unix socket is the later hardening if Vidyut runs on a
shared machine.

## Amendment: loopback is not the same as local

A loopback peer can still be a web page. DNS rebinding sends a request to
127.0.0.1 carrying the attacker's hostname, and a cross-site `text/plain`
POST reaches the Relay without a CORS preflight. Either one could read the
pairing secret or queue local files for the phone.

Control routes therefore also require:

- `Host` is `127.0.0.1`, `localhost` or `[::1]`, on the Relay's port when a
  port is given.
- `Origin`, when present, is `http://{one of those}:{port}`.
- State-changing requests carry no `Sec-Fetch-Site` other than `same-origin`
  or `none`.
- `/control/v1/transfers/enqueue` takes only `application/json`.

WebSocket handshakes that carry a foreign `Origin` get 403. Browsers always
send `Origin` on a handshake; the phone and the CLI send none. Failing checks
return 403 with a `code`. All of this lives in `src/relay/local-origin.ts`.
