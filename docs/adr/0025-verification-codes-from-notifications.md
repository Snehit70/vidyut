# Verification codes come from notifications

> Status: accepted

Logging in on the laptop often means a one-time code that lands on the phone.
Copying it by hand defeats the point of a shared clipboard, and Android does
not let Vidyut read the phone clipboard in the background anyway. The code is
already in a notification, so Vidyut reads it there.

## How it works

- A `NotificationListenerService` (`CodeNotificationListener`) runs once the
  user grants notification access in system settings. Vidyut cannot grant it
  itself.
- The listener skips Vidyut's own notifications, group summaries, and anything
  whose title and text hold no digit. Only what remains crosses into Dart, and
  only while the foreground service is subscribed.
- The service subscribes while **Verification codes** is on and access is
  granted, and reconciles that on every sync, like the auto-send watcher.
- A code needs an English keyword nearby ("code", "OTP", "verify", "sign in"
  and similar). Times, dates, decimals, percentages, amounts and labelled
  numbers ("Ref", "order #", "A/c") are not codes. When several numbers
  qualify, the one nearest a keyword wins.
- The same code is sent once per two minutes, since it often shows up twice.
- The code goes out as a plain text payload through the share-sheet publish
  path, so the laptop treats it like any other text.
- The phone's clipboard pause holds codes, the same as screenshots.

## Privacy

- Off by default, and inert without notification access.
- The notification text is never stored. The code is never written to the
  debug log or Activity; the log names only the app it came from, and Activity
  records "verification code".
- The code is encrypted like every payload and stays on the LAN.

## Consequences

- Non-English notifications are not recognised. Adding a language means adding
  its keywords.
- A number next to a keyword that is not a code ("Use code 4521 at checkout")
  can be sent. It lands on the laptop clipboard only, which the next copy
  replaces.
- Notification access lets Android deliver every notification to the
  listener. The digit filter keeps most of them in native code, but the grant
  itself is broad, and the screen says what it is for.

## Considered options

- Reading SMS (`RECEIVE_SMS`). Misses codes that arrive as app notifications
  rather than texts, and asks for a broader permission over messages.
- The SMS Retriever / User Consent APIs. They need Google Play services and
  either a hash in the sender's message or a consent prompt per code.
