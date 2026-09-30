# A link payload is written to the clipboard and opened

> Status: accepted

Vidyut adds a third payload type, `link`, alongside `image` and `text`. A link
is a single web address. When one arrives at the Relay, the laptop does both
things the user wants: it writes the address to the clipboard exactly as it
would for text, and it opens the address in a browser. The clipboard half is
not a fallback. It is what makes the tab disposable, because closing the tab
does not lose the address.

The mime stays `text/plain`, so pasting a link still yields plain text. The
difference is the behaviour the payload triggers, not what the clipboard holds.

## The phone decides, the Relay obeys

The phone runs the detection and tags the payload. The Relay does not
re-derive it. Two reasons:

- The phone has to know the answer anyway, to label its own action. It cannot
  show "Open in browser" without having decided the text is a URL.
- If both sides guessed independently they could disagree, and a disagreement
  here is visible and confusing: the phone says it is opening a link, and the
  laptop pastes a line of text instead.

The Relay still re-checks the string before spawning anything, because it is
the side actually handing the string to a process. That check is deliberately
stricter than the phone's. The phone's leniency decides whether a tab should
appear, and a false positive there costs a browser tab. The Relay's check is
the last gate before a process argument, so it accepts only an explicit `http`
or `https` URL, with no whitespace and no control characters. A payload tagged
`link` whose text is not an openable URL is still written to the clipboard;
only the launch is skipped.

## Detection is offline and lenient

Nothing is probed. Verifying a URL over the network would add latency to every
copy and hand the address to a third party, for little gain: if the format
reads as a URL, opening it either works or the browser shows its own error
page.

Leniency is deliberate, because the costs are asymmetric. A false positive
costs one browser tab. A false negative means the feature does nothing for the
thing it exists for. So `hello.world` counts as a URL, since it is one. What
keeps ordinary text out is a small number of structural rules: no whitespace
anywhere in the string, no control characters, a length ceiling, `http` or
`https` as the only accepted schemes, and a host that is either `localhost`, a
dotted name with an alphabetic last label, or an IP literal. That is enough to
reject prose, version strings, and anything that is not an address, without a
public-suffix list.

## Opening is delegated, not reimplemented

The Relay hands the URL to `xdg-open`. That is the whole strategy, and it is
the point rather than a shortcut. `xdg-open` routes to whatever the session
registered as its default handler, and every mainstream browser, when handed a
URL, reuses an already-running instance and opens a tab in it, in whichever
profile it was last using. So "open a tab in the browser that is already open,
in the right profile" is answered by the browser.

The alternative was considered and rejected: enumerating running browsers and
choosing a window or a profile. On Wayland there is no window introspection to
lean on, so it would mean shelling out to compositor-specific tools, and it
would duplicate the browser's own session restore badly and untestably. If a
link lands on an unwelcome profile, the fix is a better default handler, not a
smarter guess inside the Relay.

The launch is fire-and-forget, for the same reason the clipboard write is not
awaited on the pool path: a browser that takes seconds to surface must not hold
the phone's acknowledgement. It runs through the same bounded process runner as
`wl-copy`, so a hung launch cannot stall the Relay.

## Considered options

- Have the Relay infer URL-ness from text, with no new payload type. Cheaper
  wire-wise, but it re-runs detection the phone already did, and any text that
  happens to parse as a URL opens a browser.
- Publish the URL as text and send a separate control message to open the tab.
  Additive, and it leaves the pool's types alone, but the two can fail
  independently. A closed tab with nothing in the clipboard, or a payload with
  no tab, are both half-states that read as bugs.
- Add a preference to disable link opening. Not built. There is no settings
  surface on the laptop to hang it on, only `relay.json`, and the plain-text
  clipboard half means a user who never wants tabs opened can still publish the
  address as ordinary text.
