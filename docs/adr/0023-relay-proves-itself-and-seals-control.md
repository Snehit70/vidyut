# Relay proves itself and seals control messages

> Status: accepted

Until now only the phone proved anything. The Relay's `hello` carried a
challenge, the phone answered with an HMAC over it, and the Relay said
`auth_ok`. Anything on the WiFi that could answer on the laptop's address
could say `auth_ok` too. Payload frames were safe, since they are encrypted
end to end under the pairing secret (ADR 0003), but every other message
travelled as plain JSON: health, telemetry, acks and the whole transfer
control channel. An impostor could feed the phone fake telemetry and fake
transfer offers, and someone on the path could read or edit any of them.

## Handshake

The phone's `auth` adds `clientChallenge`, base64 of 24 random bytes, and
lists `sealed_control` in `features`. A Relay that understands it answers:

```
auth_ok {
  relayProof: base64 HMAC-SHA256(secret,
    "vidyut-relay-proof-v1:{challenge}:{clientChallenge}:{features}:{deviceId}"),
  features: ["sealed_control"]        // what this session agreed to
}
```

`{features}` is the agreed list joined with `,`. The challenges are base64
and the feature names come from a fixed set, so none contains `:`, and
`deviceId` goes last so its own colons cannot shift a field. The proof covers
the agreed features, so stripping `sealed_control` from either side's message
breaks it.

Both sides then derive a session key:

```
key = HMAC-SHA256(secret, "vidyut-session-v1:{challenge}:{clientChallenge}:{deviceId}")
```

Both challenges are fresh every connection, so no two sessions share a key.

## Sealed messages

After `auth_ok`, every message in both directions travels as

```
{v: 1, kind: "sealed", nonce, payload}   // payload = AES-256-GCM ciphertext || tag
```

except `publish` and `payload`, which already carry their own encryption.
Sealing them again would cost a second pass over up to 25 MiB for no gain in
secrecy.

The nonce is the direction byte (0 Relay→phone, 1 phone→Relay), three zero
bytes, then a 64-bit big-endian message counter. Each side expects exactly the
next counter from its peer, so a dropped, replayed, reordered or reflected
message fails to open. Nothing can resynchronise the counters, so a failure
ends the session: the Relay closes with 1008 `seal_failed` (or `seal_required`
for a plain control message on a sealed session) and logs
`sealed_message_rejected`; the phone reports `seal_failed`, goes offline and
reconnects. A plain control message reaching the phone on a sealed session is
dropped.

`src/shared/session-seal.ts` and `app/lib/src/shared/session_seal.dart` are
the two implementations. `tests/fixtures/crypto-fixtures.json` keeps them
byte-for-byte equal.

## Downgrade pin

An older Relay sends no `relayProof`, and the phone must keep working with
it. Without anything else, an attacker could pose as an older Relay. So the
pairing remembers what it has seen. The first time a laptop proves itself,
the phone stores `vidyut.pairing.relayVerified`, and from then on that pairing
refuses, with `relay_unverified`, a Relay that:

- sends no proof,
- sends a wrong proof, or
- proves itself but did not agree to seal (this phone always asks, and a
  Relay that proves itself always agrees, so that means the ask was altered).

A wrong proof is refused even before the pin exists. The pin is trust on
first use: a pairing that has never met a proving laptop cannot tell an
older Relay from an impostor. Pairing again, or forgetting the laptop, clears
it. The phone only writes the pin if the stored secret still matches the
session's, so a re-pair is never pinned on the old laptop's word.

## Consequences

- Rolling the laptop back to a Relay from before this change, after the phone
  has met a newer one, leaves the phone refusing it with `relay_unverified`.
  Pair again to recover.
- `publish` and `payload` frames are still not tied to the session. Someone
  on the path cannot read or forge them, but could resend an old one, and
  `sentAt` travels outside the encryption, so the pool's stale check does not
  stop it. The worst a resend does is bring back clipboard content that was
  current once. Binding frames to the session would mean sealing them, which
  is the cost rejected below.
- The HTTP data plane for file bytes keeps its own auth and encryption and is
  not affected.
- A phone from before this change sends no `clientChallenge`. The Relay
  answers it the old way, with no proof and no sealing.

## Considered options

- TLS on the Relay port. The phone would need a pinned self-signed
  certificate from the QR code, and the laptop shell and CLI would need it
  too. That means more moving parts than an HMAC over the secret both sides
  already hold.
- Sealing every message, payloads included. This costs a second AES pass over
  large frames, which are already encrypted.
- Proof without a pin. This is simpler, but an attacker defeats it by
  claiming to be an older Relay.
