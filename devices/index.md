---
title: Device approval
---

# Device approval

This page is for people who run their own music server and want it to let in only the iPhones they have approved. If you only listen, you don't need it: the [support page]({{ '/support/' | relative_url }}) says what you'll see.

## What it is

A server's owner can put two things in front of their music server: a reverse proxy that asks every connection for a **client certificate** in the TLS handshake (mutual TLS), and an add-on (see [Server add-ons]({{ '/addons/' | relative_url }})) that hands out those certificates to the devices the owner approves. Navinx does its part on its own: when the server says it approves devices, Navinx asks for the code from an invite, makes a key on the iPhone, applies, shows four words to read to the owner, waits, and from then on presents the certificate it is given on every connection to that server.

Navinx knows nothing of how the owner checks a request, sends invites or runs the proxy. This page describes only what the app sends and expects, so that anyone can build the server's side. Every server without it, or that answers these calls as a stock music server answers an unknown path, sees Navinx exactly as before: no screens, no key, no certificate.

**When Navinx takes part at all.** Only for an account that signs in with a token (not Legacy Authentication, which has no token login to send), and only at the account's **main** address, and only when that address is `https`. A plain `http` main address is treated as a server that doesn't approve devices, so no code, key or login is ever sent in clear. The home-network address, if the account has one, is never asked and is never shown a certificate.

## How it goes, start to finish

1. **Signing in.** The person signs in to Navinx as usual. Navinx asks the main address `GET /eq/enroll/hello`. A stock music server answers with its own reply to an unknown path, and nothing more happens.
2. **The invite.** If the answer says the server approves devices and this device isn't approved, Navinx shows the screen "This server approves each device." If an invite waits for this username, it asks for its code ("Enter the code sent to …", with the address the server gives) and a name for the device; with none, it says "Ask the server's owner for an invite." How the code reaches the person is up to the server: Navinx only ever asks for it.
3. **Applying.** Navinx makes a P-256 key on the iPhone (in the Secure Enclave where there is one; its private half never leaves the iPhone) and sends `POST /eq/enroll/request` with the code, a certificate request for that key, the device's name, model, iOS version, the app's version, an ID made for this installation and, if the server asks for it, Apple's App Attest proof.
4. **Waiting.** The server files the request. Navinx shows **four words** worked out from the key's public half and the line "Read these words to the server's owner. This screen moves on when they approve." The server works out the same four words from the request, so the owner can compare them with what the person reads out, in person or on a call, before approving. Meanwhile Navinx asks `GET /eq/enroll/status` now, then every 5 seconds while the screen is shown, and again each time the app comes back to the front. Leaving the screen keeps the request: it is asked about again next time.
5. **Approved.** The status answer carries a certificate for the device's key. Navinx stores it in the Keychain and from then on presents it whenever a TLS connection to the main address asks for a client certificate. The sign-in then finishes (or, if the server let nobody in without one, is tried again).
6. **Renewing.** The certificate comes with a time to renew after. Whenever Navinx connects to the server after that time, it sends `POST /eq/enroll/renew` with a new certificate request for the same key, over a connection that presents the current certificate.
7. **Revoking.** When `hello` says a device that holds a certificate isn't approved, Navinx asks it once more over a new connection that presents the certificate. If the answer is the same, Navinx removes the key, the certificate and the request from the iPhone. At sign-in it then shows the approval screens again; when the saved server had stopped answering, it asks for the password again with "This device is no longer approved for this server." Either way, the device can apply again with a new invite. Navinx asks `hello` at sign-in and when the saved server stops answering, not on every launch, so a revoked device is noticed once the server turns it away.

**`optional` or `required`.** At `optional`, the server still lets in devices without a certificate: the approval screens have **Not Now**, and the sign-in finishes without one. At `required`, they have **Cancel** instead, and the sign-in finishes only once the device is approved. A server that requires certificates may turn away a connection without one however it likes (refusing the handshake, closing the connection, or any error status), except with the music server's "wrong username or password": Navinx takes that as a wrong password, and doesn't ask about devices.

## The calls, version 1

All JSON, UTF-8; base64 is standard, with padding. `<server>` is the account's main address in Navinx, including any path after the host. Every call carries the account's login in `X-Subsonic-Login` (the same header as the add-on's tab: `u=<username>&t=<token>&s=<salt>`, form-encoded; [Server add-ons]({{ '/addons/' | relative_url }}), "Signing in"), and `Accept: application/json`. Navinx stores no cookies, caches none of these calls and **never follows a redirect** on them. It waits 10 seconds for `hello` and 30 for the others.

**How Navinx reads any answer:** `200` with a JSON object is an answer; `429` or a `5xx`, or no answer at all, means "try again later" (nothing changes); any other status means "no" (for `hello`: the server doesn't approve devices). An answer whose `v` isn't `1` is a "no" too.

| Call | When | What Navinx expects |
|---|---|---|
| `GET <server>/eq/enroll/hello` | At sign-in, when the saved server stops answering, after an approval, and from "Check Again" | The server's rule for this account, below |
| `POST <server>/eq/enroll/request` | The person taps Send | The request filed, or why not |
| `GET <server>/eq/enroll/status?request=<id>` | While the waiting screen is shown | Pending, denied or approved |
| `POST <server>/eq/enroll/renew` | After the certificate's renewal time | A new certificate |

### `hello`

```json
{ "v": 1, "devices": "required", "approved": false, "invited": true, "to": "s•••@e•••.com", "attest": "off" }
```

| Field | |
|---|---|
| `devices` | `off`, `optional` or `required`, required. `off` (or a missing or unknown value) means the server doesn't approve devices: Navinx carries on as before. |
| `approved` | `true` when this connection presented a certificate the server issued and hasn't revoked. Navinx asks for nothing more then. |
| `invited` | `true` when an invite waits for this username: Navinx asks for its code. |
| `to` | Shown as "Enter the code sent to …". Mask it: it is shown to whoever signs in. Absent: "Enter the code from your invite." |
| `attest` | `off` (the default), `optional` or `required`: whether to send App Attest's proof with the request (below). |

`hello` must be answered over a connection without a client certificate: a device that has none yet asks it that way.

### `request`

```
POST <server>/eq/enroll/request
Content-Type: application/json

{ "v": 1, "code": "ABCD2345", "csr": "<base64>",
  "device": { "id": "<UUID>", "name": "iPhone", "model": "iPhone18,1", "system": "iOS 27.2", "app": "1.0 (12)" },
  "key": null, "attestation": null }
```

- `code`: what the person typed, upper-cased, with anything but letters and digits left out (`abcd-2345` is sent as `ABCD2345`). Navinx sends only 8 characters.
- `csr`: a PKCS#10 certificate request in DER, for a P-256 key, signed with ECDSA and SHA-256, its subject `CN=navinx`. Write your own subject into the certificate; the request's signature proves the sender holds the key.
- `device`: the name the person typed (it starts as "iPhone"; iOS doesn't give apps the real one), the hardware's model identifier, the iOS version, the app's version and build, and an ID made once for this installation (random, not taken from the iPhone).
- `key` and `attestation`: when `hello`'s `attest` isn't `off` and the iPhone can make one, a new App Attest key's id and its attestation (base64 CBOR), for the client data hash `SHA256("navinx-enroll-v1\n" + code + "\n" + lower-cased username + "\n" + SHA256(the key's SubjectPublicKeyInfo, DER))`. Otherwise `null`: decide yourself whether `required` refuses it. Check an attestation as Apple describes ("Validating apps that connect to your server"), against the App ID of the Navinx build you accept.

The answer:

| Answer | What Navinx does |
|---|---|
| `{ "v": 1, "request": "<id>" }` | Filed: the waiting screen with the four words. |
| `{ "v": 1, "error": "code", "tries": 2 }` | "That code isn't right. 2 tries left." With `tries` at `0`, "This invite has expired. Ask the server's owner for a new one." Without `tries`, Navinx asks `hello` again and shows that line if no invite waits any more. |
| `{ "v": 1, "error": "place" }` | "This invite can't be used on this network." (for an invite that may be used only from some places). |
| Anything else | "The server didn't take this request. Try again.", or the expired line when `hello` says no invite waits any more. |

A request refused for a wrong code keeps the key: the next try sends the same one.

### The four words

`SHA256("navinx-words-v1\n" + the key's SubjectPublicKeyInfo, DER)`: its first four bytes, each an index (0 to 255) into Navinx's list of 256 words, [`Packages/DeviceIdentity/Sources/DeviceIdentity/words.txt`](https://github.com/cybinx/navinx/blob/main/Packages/DeviceIdentity/Sources/DeviceIdentity/words.txt), one word a line. Work them out from the certificate request's public key and show them to whoever approves. The test vectors in [`enroll_vectors.json`](https://github.com/cybinx/navinx/blob/main/Packages/DeviceIdentity/Tests/DeviceIdentityTests/Fixtures/enroll_vectors.json) give a key, its words and the hashes above, to check your side against.

### `status`

```
GET <server>/eq/enroll/status?request=<id>
X-Navinx-Time: 1795132800
X-Navinx-Proof: <base64>
```

`X-Navinx-Proof` is the device key's ECDSA signature (DER, X9.62) over `"navinx-status-v1\n" + id + "\n" + time`, with the time exactly as sent in `X-Navinx-Time` (Unix seconds). Check it with the public key of the request's certificate request, so only the device that applied can fetch the certificate, and refuse a time too far from your clock. Navinx corrects its own clock by the `Date` header of your earlier answers, by at most 5 minutes.

| Answer | What Navinx does |
|---|---|
| `{ "v": 1, "state": "pending" }` | Waits and asks again. |
| `{ "v": 1, "state": "denied" }` | "The server's owner didn't approve this device." The key and the request are removed. |
| `{ "v": 1, "state": "approved", "certificate": "<base64>", "issuer": "<base64>", "renewAfter": 1795737600 }` | Stores the certificate and goes on. |
| A "no" | The request is forgotten, and Navinx starts again from `hello`. |

`certificate` is one X.509 certificate in DER, at most 16 KB, **for the device's own key**: one for another key is not kept, and counts as a request the server didn't take. `issuer`, optional, is the certificate of the authority that signed it (DER, at most 16 KB): Navinx sends it with its own in the TLS handshake. `renewAfter` is the Unix time after which Navinx renews.

### `renew`

```
POST <server>/eq/enroll/renew
Content-Type: application/json

{ "v": 1, "csr": "<base64>" }
```

A new certificate request for the same key, over a connection that presents the current certificate. Answer as `status` does when approved (`certificate`, `issuer`, `renewAfter`). A refusal, no answer, or a certificate for another key leaves the current one in place; Navinx tries again at its next connection.

## The certificate on every connection

Once approved, every connection Navinx makes to the main address's host and port (the music server's API, streaming, covers, downloads, and the add-on's own routes) answers a TLS request for a client certificate with the device's certificate. No other host or port, and not the home-network address, is ever shown it. A connection opened before the certificate was stored doesn't present it, so Navinx drops its open connections whenever the certificate is stored, renewed or removed.

**What your proxy needs to do,** in whichever proxy you use:

- ask for a client certificate in the TLS handshake and verify it against your own authority;
- let the four `/eq/enroll/…` routes through without one (they carry the login, and `hello` must answer a device that has no certificate yet), while making sure whatever answers `hello` and `renew` can tell which certificate, if any, the connection presented;
- at `optional`, let everything else through too; at `required`, refuse everything else without a valid certificate;
- remove any header a client sends that your add-on would trust as coming from the proxy (the client's address, the certificate it presented).

## Advice

- **Every refusal the same:** answer a refused login, an unknown request or a bad proof exactly as your music server answers an unknown path, so the routes tell a stranger nothing.
- **Check the login** with the music server, as [Server add-ons]({{ '/addons/' | relative_url }}) describes, on every call, and limit guesses.
- **Make codes short-lived and single-use,** with few tries, kept only as a salted hash, and sent by a channel the person controls. Read the four words before approving: someone who has a person's password and code can apply too, but not with that person's words.
- **Keep certificates short,** a few days to a few weeks, with `renewAfter` well before their end, so a device that is revoked, or stops renewing, loses access soon.
- **Don't log the login header,** the codes or the proofs.

[Navinx]({{ '/' | relative_url }}) · [Server add-ons]({{ '/addons/' | relative_url }}) · [Privacy Policy]({{ '/privacy/' | relative_url }}) · [Support]({{ '/support/' | relative_url }})
