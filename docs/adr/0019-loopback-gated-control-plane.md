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
