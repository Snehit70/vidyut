# Formatted text rides as an alternative

> Status: accepted

Text copied from a browser or an editor usually carries its formatting as
`text/html` next to the plain `text/plain`. The laptop used to send only the
plain text, so bold, links and lists were lost on the phone even in apps that
paste them.

## The frame

A text frame may now carry one alternative:

```
{v: 1, type: "text", mime: "text/plain", origin, ts, nonce, payload,
 alt: {mime: "text/html", nonce, payload}}   // payload = AES-256-GCM ciphertext || tag
```

The alternative is sealed with the same pairing key as the frame, under its
own random nonce, with this associated data:

```
{"v":1,"kind":"alt","mime":"text/html","nonce":<alt nonce>,"frameNonce":<frame nonce>}
```

Naming the frame's nonce ties the alternative to that frame, so it cannot be
lifted onto another one. The frame's own encryption is untouched, so the plain
text decrypts exactly as before.

## Who does what

- The laptop reads `text/html` only when the selection is text and lists it,
  and only up to 512 KiB. A failed or larger read sends the plain text alone.
  The alternative counts towards the payload size limit.
- The phone writes both with `ClipData.newHtmlText`. Apps that paste
  formatting take the HTML and the rest take the text. If the alternative
  does not open, the phone logs it and writes the plain text.
- History, the receipt and the "tap to copy" path stay plain text.
- Only `text/html` is defined. The Relay rejects a frame with any other
  alternative, and the phone ignores one it does not know.

## Consequences

- A phone from before this change ignores `alt` and writes the plain text.
- An older Relay passes frames through unchanged, so this needs only the
  laptop that reads the clipboard and the phone that writes it.
- Phone to laptop stays plain text for now. The phone's senders read plain
  text only. Adding it needs no wire change, since the Relay already accepts
  the frame shape, but the laptop would also have to write the HTML.

## Considered options

- A separate `html` payload type. Every receiver would need to understand it
  before anyone could send it, and an older phone would drop the copy
  entirely instead of falling back to the text.
- Encrypting `{text, html}` together as one payload. The plain text would no
  longer be the payload, which breaks every receiver from before this change.
