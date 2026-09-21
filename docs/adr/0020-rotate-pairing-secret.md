# Laptop revocation rotates the pairing secret

> Status: accepted

The Relay has one pairing secret for every device. Laptop-side revocation is
**Rotate pairing secret**: the secret is replaced, the QR changes, and every
phone must pair again. The action lives in the desktop shell behind a
confirmation that says so.

**Forget this phone** and a per-phone roster were rejected. There is no device
list to edit. The phone-side action remains **Forget this laptop**, which only
deletes that phone's saved pairing.
