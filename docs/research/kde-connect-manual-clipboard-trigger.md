# KDE Connect manual clipboard trigger audit

Audited 2026-07-28 against these upstream revisions:

- KDE Connect Android `master`: [`0150bd323db4da9cd3adb79499c0c6d57ac07be1`](https://invent.kde.org/network/kdeconnect-android/-/commit/0150bd323db4da9cd3adb79499c0c6d57ac07be1), 29 commits after `v1.35.9`. The project currently targets Android 15 / API 35 ([build configuration](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/build.gradle.kts#L37-45)).
- KDE Connect desktop `master`: [`3435f69097534b4c9f077988ec2986e849213be1`](https://github.com/KDE/kdeconnect-kde/commit/3435f69097534b4c9f077988ec2986e849213be1).

## Conclusion

The proposed correction for Vidyut is right: **the notification action should be an activity `PendingIntent` that directly launches the transparent clipboard-reading activity.** KDE Connect does exactly that. It does not deliver the notification tap to its foreground service and then ask that service to call `startActivity()`.

That distinction is material on modern Android. Android explicitly allows an activity started from a `PendingIntent` sent by the system, including a notification tap, while restricting ordinary background activity starts ([Android background-activity-launch rules](https://developer.android.com/guide/components/activities/secure-bal#when-allowed)). Android also describes `PendingIntent.getActivity()` as the direct mechanism for a special notification activity ([notification navigation documentation](https://developer.android.com/develop/ui/views/notifications/navigation#SpecialActivity)). On Android 12+, notification trampolines—notification → service/receiver → activity—are blocked and apps are told to use a direct `PendingIntent` instead ([Android 12 behavior changes](https://developer.android.com/about/versions/12/behavior-changes-12#notification-trampolines)).

Therefore Vidyut's observed four-second timeout is consistent with losing the user-initiated launch path before `ClipboardReadActivity` receives focus. KDE Connect's implementation supports the direct-activity fix; it does **not** support increasing the timeout.

## Exact Android workflow

When at least one paired device is reachable, KDE Connect builds its persistent foreground notification. On Android 10+ without its privileged `READ_LOGS` automatic-sync path, it:

1. creates an intent for `ClipboardFloatingActivity`;
2. wraps that intent with `PendingIntent.getActivity(...)`; and
3. installs that pending intent directly as the notification's “Send Clipboard” action.

The relevant code is [`BackgroundService.kt` lines 157–199](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/BackgroundService.kt#L157-199). The action is omitted when no device is connected and omitted when automatic clipboard sync is available.

`ClipboardFloatingActivity` is transparent and excluded from Recents in the manifest ([manifest lines 202–205](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/AndroidManifest.xml#L202-205)). Its intent starts a new task and clears that task. Once the window gains focus, it reads the clipboard through the shared listener and immediately calls `finish()` ([activity lines 44–73](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardFloatingActivity.java#L44-73)). It does not open KDE Connect's normal UI.

The Quick Settings tile follows the same principle. `TileServiceCompat.startActivityAndCollapse` receives an activity pending-intent wrapper targeting `ClipboardFloatingActivity`; the tile does not call a foreground service which later launches the activity ([`ClipboardTileService.kt` lines 18–34](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardTileService.kt#L18-34)).

After the activity asks `ClipboardListener` to refresh, the listener:

- reads the first clipboard item and coerces it to text;
- detects Android's sensitive-clipboard marker;
- suppresses an event if both content and content type equal the cached values; otherwise
- updates its timestamp/cache and notifies all registered plugin observers.

See [`ClipboardListener.kt` lines 81–100](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardListener.kt#L81-100). Each active device's `ClipboardPlugin` is an observer, so one refresh fans out the same text to all applicable connected devices ([plugin lines 62–80 and 101–109](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardPlugin.kt#L62-109)).

## What KDE Connect does—and does not—handle

| Case | Upstream behavior | Implication for Vidyut |
|---|---|---|
| Background activity launch | Direct system-sent activity `PendingIntent` from the notification. | Adopt this exact boundary. Do not route the tap through the Flutter foreground-service callback before `startActivity()`. |
| Timeouts | There is no focus, read, send, or acknowledgement timeout in the Android manual path. | A short watchdog is useful for Vidyut diagnostics, but it is not the mechanism that makes the launch reliable. Four or five seconds is already far outside the expected local clipboard-read time. |
| No focus / launch failure | No explicit recovery. If focus never arrives, the activity does not read or finish; no error is surfaced. | Vidyut should improve on KDE Connect: retain a watchdog and show retry guidance, but direct launch should prevent the current common failure. |
| Empty or missing clipboard | `primaryClip!!` / first-item access is inside a broad caught exception. No event is sent. | Return a typed `empty` / `unreadable` result. Do not claim success. |
| Empty string | It can be emitted if it differs from the cache; KDE desktop later suppresses locally observed empty text, but a received normal clipboard packet is still written. | Vidyut's current rejection of null/blank text is clearer for a manual “send copied text” action. |
| Duplicate text | The shared listener suppresses identical content+type. A notification tap may therefore show a success toast while sending nothing. | **Do not copy this edge case.** A manual request must send the current text even if it equals Vidyut's cached/previously-sent value. Dedupe belongs only on automatic copy events. |
| Sensitive text | Automatic observer propagation can honor “skip sensitive”; the in-app manual function explicitly bypasses that filter ([plugin lines 136–146](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardPlugin.kt#L136-146)). The floating notification route goes through the observer filter. | Decide explicitly. For an intentional manual tap, sending the selected clipboard text is reasonable, but the result should never reveal clipboard contents in the notification/log. |
| Multiple devices | The listener has one observer per active plugin, so a change fans out. The notification exists if one or more devices are reachable. | Vidyut has one paired laptop, so resolve that target before showing/processing the action and report “laptop offline” without attempting a read if appropriate. |
| Repeated taps / concurrency | No explicit in-flight guard. The notification uses a stable request code; the tile uses a one-shot pending intent. The activity has no special launch mode. | Keep Vidyut's single in-flight guard. Give each request an ID so a late activity result cannot complete a newer request. |
| Feedback | The activity shows a “sent” toast immediately after asking the listener to refresh—without proving that content existed, a packet was emitted, or delivery succeeded ([activity lines 51–60](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardFloatingActivity.java#L51-60)). | Vidyut's notification result should remain tied to its actual publish result/ack, not merely clipboard acquisition. |
| Automatic mode | Android 10+ automatic sync is considered available only with `READ_LOGS` ([plugin lines 179–185](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardPlugin.kt#L179-185)). The log watcher then calls `context.startActivity`; KDE's source comments say granting overlay access is optional but makes this much more reliable ([activity lines 20–38](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardFloatingActivity.java#L20-38)). | Do not confuse the fragile ADB/overlay automatic path with the user-tapped notification path. The latter should not require overlay permission. |
| Listener lifecycle | One process singleton registers Android's primary-clip listener on the main looper. Plugins register/unregister observers in `onCreate`/`onDestroy` ([listener lines 49–70](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardListener.kt#L49-70), [plugin lines 101–109](https://invent.kde.org/network/kdeconnect-android/-/blob/0150bd323db4da9cd3adb79499c0c6d57ac07be1/src/main/java/org/kde/kdeconnect/plugins/clipboard/ClipboardPlugin.kt#L101-109)). | Ensure the foreground-service Flutter engine has registered its result/event channel before the action is exposed, or use an explicit native-to-service command that survives engine recreation. |

## Desktop receive/write behavior

The Android activity launch is independent of the desktop clipboard write. KDE Connect desktop receives a normal `kdeconnect.clipboard` packet and immediately calls `ClipboardListener::setText(content)` ([desktop plugin lines 154–199](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardplugin.cpp#L154-L199)). `setText` updates the listener's cached content and timestamp **before** writing the text into the system clipboard ([desktop listener lines 112–118](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardlistener.cpp#L112-L118)). That cache prevents the clipboard-change signal caused by the remote write from being echoed back: local text changes are ignored when empty or identical to the cached content/type ([desktop listener lines 66–109](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardlistener.cpp#L66-L109)).

Other desktop edge behavior:

- A normal clipboard packet has no timestamp conflict check; it overwrites the local clipboard immediately. Only the connection-sync packet compares timestamps and rejects `0` or older values ([desktop plugin lines 185–198](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardplugin.cpp#L185-L198)).
- The receive path does not send an application-level acknowledgement for a text clipboard write. Any Vidyut “sent” state must therefore rely on Vidyut's relay acknowledgement semantics, not KDE Connect behavior.
- Desktop supports text, URL/file, and image clipboard payloads, including configured file-size limits and file-transfer error checks ([desktop plugin lines 83–139](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardplugin.cpp#L83-L139)). Vidyut's action is correctly named “Send copied text” if it intentionally supports text only.
- Password-manager hints can suppress automatic sharing according to configuration, while remote received text is applied as ordinary text ([desktop plugin lines 49–68](https://github.com/KDE/kdeconnect-kde/blob/3435f69097534b4c9f077988ec2986e849213be1/plugins/clipboard/clipboardplugin.cpp#L49-L68)).

## Recommended Vidyut implementation contract

```text
notification action
  -> system sends activity PendingIntent directly
  -> transparent ClipboardReadActivity gains focus
  -> read first item and coerce to text
  -> return {requestId, text | typed acquisition error} to the running service
  -> service publishes once
  -> notification reports actual publish result
  -> activity finishes immediately
```

Required guards:

1. Use a direct immutable `PendingIntent.getActivity` targeting `ClipboardReadActivity`; no service/receiver trampoline.
2. Mark the request as manual so duplicate text is still sent.
3. Allow only one active request, attach a monotonically unique request ID, and ignore stale/late results.
4. Have the activity finish in all result and exception paths. Add a lifecycle fallback (`onStop`/short local watchdog) so a focus anomaly cannot strand the transparent activity.
5. Distinguish `empty`, `unreadable`, `launch/focus timeout`, `offline`, `publish rejected`, and `ack timeout`.
6. Do not log or preview clipboard content. Only show success after Vidyut's publish path confirms success.
7. Keep the expected happy path under one second. A watchdog around 2 seconds for clipboard acquisition is ample as a failure detector; extending the existing four/five-second timers would only delay feedback.

The final timeout recommendation is an engineering bound, not a KDE Connect constant: upstream uses no timeout at all. The key reliability property evidenced by upstream is the direct activity pending-intent.
