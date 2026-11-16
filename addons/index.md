---
title: Server add-ons
---

# Server add-ons

This page is for people who run their own music server and want to add something of their own to Navinx. If you only listen, you don't need it.

## What it is

A server's owner can run a small service of their own next to their music server, called an add-on here. If it answers Navinx at `/panel` on the server's own address, the accounts it accepts see **one extra tab** in Navinx, made of the screens it sends. Everyone else, and every server without an add-on, sees Navinx's four tabs (Home, New, Library, Search) and nothing else.

The tab is open-ended: an add-on can offer any forms and actions that its server can carry out, such as managing which devices may connect, rescanning the library, showing the server's status, or requesting or adding music to the library. Navinx knows nothing of what an add-on does: it draws the screens and sends the taps back, and the add-on decides what they mean. **What an add-on does is its owner's responsibility**, including having the right to any music it adds to the server; Navinx must not be used with music obtained illegally ([Privacy Policy]({{ '/privacy/' | relative_url }})). The demo server's add-on, for example, shows a device list on sample devices.

So nobody takes the tab for part of Navinx itself, Navinx ends the tab's first screen with its own line, "This tab comes from your server.", and puts a small "From your server" over the add-on's section in Search.

## What an add-on can and can't make Navinx do

An add-on **can**:

- give the tab its title and symbol, and fill it with screens built from **seven parts**: text, field, choice, button, row, progress and image, in sections, on the app's own glass cards;
- answer a tap by replacing the screen, pushing a new one, opening one as a sheet, closing that sheet, or changing nothing, each with an optional short message (a toast);
- ask Navinx to fetch a screen again every few seconds while it is shown;
- show a section of its own in Search, under the results, whenever the account has its tab;
- show pictures from any `http` or `https` address (the phone loads them from that address, and may keep them in Navinx's picture cache).

An add-on **can't**:

- make Navinx send what the person types or taps anywhere but the same server address: every tap and every submit goes to `/panel` there, and nowhere else;
- open a link, download any file to the phone (pictures aside, above), play anything, or run any code or expression: Navinx only draws the seven parts;
- reach outside its tab (and its section in Search), change Navinx's settings, or see anything on the phone beyond what the person types into its fields, the choices they pick, what they type in Search while the account has the tab, and the account's login (below); an add-on that also approves devices ([Device approval]({{ '/devices/' | relative_url }})) is sent what the [Privacy Policy]({{ '/privacy/' | relative_url }}) lists under device approval; like any server, an add-on also sees the phone's IP address and when the app asks for the tab (at launch and sign-in, and each time the app comes back to the front);
- break the app with something new: unknown fields are ignored, an unknown part is skipped, an unknown style takes its default and an unknown colour none, and a screen of any version other than 1 is refused (no tab).

Navinx keeps nothing of the tab on the phone, except that its pictures may stay in the app's caches. It asks again at every launch and sign-in, whenever the app comes back to the front, when the network comes back, and when the address in use changes.

## The format, version 1

All JSON, UTF-8. `<server>` below is the account's address in Navinx, including any path after the host (`https://example.com/navidrome` gives `https://example.com/navidrome/panel`): the main address, or the home-network address when Navinx is using that one. Navinx sends `Accept: application/json`, stores no cookies, caches none of these calls and **never follows a redirect** on them. (Pictures are loaded apart from them, like any picture, and may be kept in Navinx's picture cache.)

### The calls

| Call | When | What Navinx expects |
|---|---|---|
| `GET <server>/panel` | The probe (10-second timeout). | `200` with a screen that has `tab`: the tab shows, third, between New and Library. Any other answer: no tab. No answer at all, `429` or a `5xx`: whatever is shown stays. |
| `GET <server>/panel/s/<id>` | A screen's refresh (30 seconds). | `200` with that screen. A failure keeps the screen as it is. |
| `POST <server>/panel` | A tap or a submit (30 seconds). | `200` with a reply. A failure keeps the screen and shows Navinx's own "Something went wrong." |

**Other calls your add-on will see.** For accounts that sign in with a token (not Legacy Authentication), Navinx also asks every server for a few routes under `/eq` (the `/eq/enroll/…` ones at the account's main address only, never a home-network one): `POST <server>/eq/hello` and, when that answers, `POST <server>/eq/session` (an optional session handshake, below, "Signing in"); `GET <server>/eq/enroll/hello` at sign-in, when the account's main address is `https`, and further `/eq/enroll/…` steps only when the server asks for device approval ([Device approval]({{ '/devices/' | relative_url }})); and `GET <server>/eq/<song id>` for the playing song and the next few (levels for the equaliser in Now Playing). An add-on that serves only `/panel` needs to do nothing about them: let the music server answer them as it answers any path it doesn't know, and Navinx carries on without them.

### A screen

```json
{ "v": 1, "id": "main", "title": "Hello", "tab": { "title": "Hello", "symbol": "hand.wave" },
  "refresh": 5, "sheetHeight": 300, "sections": [ ... ] }
```

| Field | Type | |
|---|---|---|
| `v` | number, required | Must be `1`. Any other value: the screen is refused. |
| `id` | text, required | Sent back with every tap on the screen, and used for its refresh. |
| `title` | text | The navigation title. Empty or absent: none. |
| `tab` | `{ "title", "symbol" }` | The tab's title and an SF Symbol's name; a symbol the phone doesn't have shows a generic one. **Every answer to the app's `GET /panel` must carry it:** one without it removes the tab (Navinx asks at launch, at sign-in and each time it comes back to the front). A root screen that arrives another way (a reply to a tap, or its refresh from `/panel/s/<id>`) may leave it out and keeps the title and symbol; one that carries it changes them. |
| `refresh` | whole seconds | While the screen is shown and Navinx is in front, `GET <server>/panel/s/<id>` every so many seconds, paused while a tap from the screen is on its way. At most 86,400. Absent: never. Pull to refresh on the tab's root fetches it once. |
| `sheetHeight` | points | When the screen is shown as a sheet: its first height (at most 3,000), then medium and large. Absent: medium and large. A sheet's content scrolls when it is taller than the sheet. |
| `sections` | list | Top to bottom. Navinx draws at most 100 sections and 500 parts of one screen; what comes after is left out. An answer longer than 4 MB isn't read at all; a text longer than 10,000 characters is cut; and at most 200 pictures are loaded on one screen (the rest show a placeholder; a picture larger than 25 MB isn't loaded). |

**A section:** `id` (text, required; a repeated one gets a suffix), `title` (a header above it), `button` (a button with a symbol, at the end of the title's line, drawn as its icon), `gap` (points above it, 0 to 200; 16 by default, none above the first in the tab), `card` (`glass`, the default; `plain`, a translucent card; `none`, the parts on the page itself) and `parts` (a list).

**Every part** has `type` (required) and may have `id` (your own name for it; a field's or a choice's is how `sends` names it) and `gap` (points above it in its section, 0 to 200; 8 by default).

| `type` | Fields |
|---|---|
| `text` | `text` (required); `style`: `headline`, `body`, `subhead` (the default), `strong`, `secondary`, `caption`; `tint`: `accent`, `secondary`, `red`, `orange`, `green` (it colours the symbol, or the text when there is no symbol); `symbol` (an SF Symbol before the text); `align`: `leading` (the default) or `center`; `lines` (a line limit, 1 to 100); `label` and `labelWidth` (a label column before the text, 64 points wide by default, at most 400); `button` (at the end of the line). |
| `field` | `id` (required: the text is sent under it); `placeholder`; `label` (for VoiceOver); `value` (the text it starts with); `paste` (`true` adds the system's Paste button under it); `keyboard`: `text` (the default) or `url`; `returnKey`: `go` (the default) or `search`; `submit` (an action posted on return, when the text isn't blank); `clear` (an action posted after the clear button empties it); `button`. |
| `choice` | `id` (required), `options` (required: a list of `{ "id", "label" }`; a repeated id is dropped, and at most 20 are shown), `value` (the option shown as picked), `action` (required: posted as soon as an option is picked, with the option's id under the choice's id), `large` (a larger control), `button`. A segmented control. |
| `button` | `label` (required), `action` (required), `symbol`, `style`: `prominent`, `bordered` (the default), `plain`, `pill`; `needs` (field ids: the button is off while any of them is blank); `enabled` (`false` turns it off); `busy` (`true` shows a spinner and turns it off). Buttons one after another share a line. The same object goes in the `button` of a section, text, field, choice, row or image. |
| `row` | `title` (required), `subtitle`, `lines`, `image` (a picture's `http` or `https` address), `imageSize` (points, at most 400; a row with it has room for a picture), `symbol`, `tint`, `busy` (a spinner), `progress` (0 to 1), `note`, `noteStyle` (`secondary` or `error`), `noteSymbol`, `noteTint`, `button`, `action` (a tap on the row posts it). Rows one after another sit together, like a list. |
| `progress` | `label` (with one: a bar under it; without: a large spinner), `value` (0 to 1; absent: a moving bar). |
| `image` | `url` (`http` or `https`; anything else isn't loaded), `aspect` (width ÷ height, 0.1 to 10; 16/9 by default), `button` (on the picture). |

Numbers outside their range are brought into it; a text where a number belongs is ignored.

### An action, and what Navinx sends on a tap

An action is `{ "id": "hello", "sends": ["name"] }`: its id, and the ids of the fields and choices whose values go with it. On a tap Navinx sends:

```
POST <server>/panel
Content-Type: application/json

{ "screen": "main", "action": "hello", "values": { "name": "Sam" } }
```

`screen` is the id of the screen the tap came from, and every value is text: a field's text as typed (trim it yourself), a choice's picked option id. One tap at a time per screen: its controls wait for the answer.

### The reply

```json
{ "present": "replace", "screen": { "v": 1, "id": "main", ... }, "toast": "Saved." }
```

| `present` | What happens |
|---|---|
| `replace` | `screen` takes the place of the screen the tap came from. Text the person typed stays, unless your `value` for that field changed, or the tap sent that field (then your `value` is shown, so an empty one clears it). |
| `push` | `screen` is pushed onto the tab's own stack, with a back button. |
| `sheet` | `screen` opens as a sheet. |
| `dismiss` | The sheet the tap came from closes; `screen`, if any, replaces the screen under it. |
| `none` | Nothing changes. Also what an unknown value means. |

`toast`, with any of them, is shown as a short message. A reply whose `screen` isn't version 1 counts as a failure.

### Search's section

Whenever the account has the tab (not only while the tab is on screen), when someone has typed at least two characters in Search and stopped for 0.7 seconds, Navinx sends `POST <server>/panel` with `{ "screen": "search", "action": "search", "values": { "q": "<what they typed>" } }`. A reply that replaces the screen with sections shows them in Search, under the results, with Navinx's caption "From your server" over them; an empty `sections` shows nothing. `push` and `sheet` are ignored there. Give that screen the id `search`: taps in the section, and the next query, are posted with the id of the screen your last reply gave. A `refresh` on that screen posts the same search again (`POST /panel`, action `search`, the same `q`); it is never fetched by its id. If your add-on has nothing for Search, answer `{ "present": "replace", "screen": { "v": 1, "id": "search", "title": "", "sections": [] } }`.

## Signing in

**The simplest way, which every add-on can rely on:** every call carries the account's login in one header,

```
X-Subsonic-Login: u=<username>&t=<token>&s=<salt>
```

form-encoded: the Subsonic API's token login, where `t` is the MD5 of the password followed by the salt. The password itself is never sent. Navinx keeps one salt and token for up to 4 minutes. An account signed in with Legacy Authentication (the plain password) sends no login at all, so it never sees a tab.

Before using that header, Navinx first tries a **session handshake** of its own, `POST <server>/eq/hello`. If the answer is anything but `200` (and not `429` or a `5xx`), Navinx sends the header on every call instead, for 10 minutes, then tries the handshake again; on `429` or a `5xx` it sends the header that once. So an add-on that serves only `/panel` needs to do nothing about it: let the music server answer `/eq/hello` as it answers any path it doesn't know. The handshake (a session made once from the login, then every request signed with the session's secret, so the login crosses the network once) is optional and isn't described here.

**What your add-on should do with the header:**

1. Ask the music server whether it accepts the login: `GET <music server>/rest/ping.view?u=…&t=…&s=…&v=1.16.1&c=<your add-on's name>&f=json`, on the music server's own address as your add-on knows it (never an address taken from the request), and accept only `"status": "ok"`. You may keep a login the server accepted for a few minutes, so a screen refreshing every second doesn't cost a check every second.
2. Keep your own list of the usernames that may use the tab, and compare without regard to case.
3. Answer everyone else, and anything you don't serve, with any status other than `200` (and not `429` or a `5xx`, which keep the tab where it is): Navinx then shows no tab.

## Advice

- **Use https:** put the add-on behind the same reverse proxy as your music server, on its address, so the login and everything typed travel encrypted. Let only the proxy reach the add-on (listen on `127.0.0.1`).
- **Never trust a login you haven't checked** with the music server, and never take the music server's address from a request.
- **Limit guesses:** count refused logins for each username and stop asking the music server for a while after a few (the example locks a username for 10 minutes after 5).
- **Keep requests small:** refuse a body over a few kilobytes before reading it.
- **Don't log the login header**, or any request headers.
- **Answer quickly:** Navinx waits 10 seconds for the probe and 30 for anything else, and gives up on an answer that hasn't finished after twice that (20 and 60 seconds). Do slow work in the background and answer with a screen that shows it in progress, with `refresh: 1`.
- **Pictures** are loaded by the phone straight from the address you give, so prefer addresses on your own server.

## A complete example

One screen with a text, a field and a button. A tap on the button (or Return in the field) answers with a toast. It checks every login with the music server, keeps its own list of usernames, limits guesses and refuses large bodies.

```python
"""A tiny add-on for Navinx: one screen with a text, a field and a button that answers with a toast.

    NAVIDROME_URL=http://127.0.0.1:4533 ALLOWED_USERS=alice,bob python3 hello_addon.py

It listens on 127.0.0.1:8790 (PORT). Put it behind your reverse proxy at /panel on your music
server's own address, with https. Python 3.9 or later, standard library only.
"""
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAVIDROME = os.environ.get("NAVIDROME_URL", "http://127.0.0.1:4533").rstrip("/")
ALLOWED = {u.strip().lower() for u in os.environ.get("ALLOWED_USERS", "").split(",") if u.strip()}
PORT = int(os.environ.get("PORT", "8790"))
BODY_LIMIT = 16 * 1024          # Every request the app sends is small.
GOOD_FOR = 300                  # A login the server accepted is trusted again for 5 minutes.
FAILURES, WINDOW = 5, 600       # 5 refused logins for a username within 10 minutes lock it for 10.

lock = threading.Lock()
good = {}                       # (u, t, s) -> until when
failed = {}                     # username -> times of refused logins


def check_login(header):
    """The username, when the music server accepts this login and it is on the list; else None."""
    fields = dict(urllib.parse.parse_qsl(header or ""))
    login = (fields.get("u", ""), fields.get("t", ""), fields.get("s", ""))
    user = login[0].lower()
    if not all(login) or user not in ALLOWED:
        return None
    now = time.time()
    with lock:
        if good.get(login, 0) > now:
            return user
        recent = [t for t in failed.get(user, []) if now - t < WINDOW]
        if len(recent) >= FAILURES:
            return None         # Locked: the server isn't even asked.
    query = urllib.parse.urlencode({"u": login[0], "t": login[1], "s": login[2], "v": "1.16.1",
                                    "c": "hello-addon", "f": "json"})
    try:
        with urllib.request.urlopen(NAVIDROME + "/rest/ping.view?" + query, timeout=10) as answer:
            ok = json.load(answer)["subsonic-response"]["status"] == "ok"
    except Exception:
        return None             # The server didn't answer: refuse, but don't count it.
    with lock:
        if ok:
            good[login] = now + GOOD_FOR
        else:
            failed[user] = recent + [now]
    return user if ok else None


def main_screen(user):
    return {"v": 1, "id": "main", "title": "Hello", "tab": {"title": "Hello", "symbol": "hand.wave"},
            "sections": [{"id": "greeting", "card": "glass", "parts": [
                {"type": "text", "id": "who", "text": "Signed in as %s." % user, "style": "subhead"},
                {"type": "field", "id": "name", "gap": 12, "placeholder": "Your name", "value": "",
                 "keyboard": "text", "returnKey": "go", "submit": {"id": "hello", "sends": ["name"]}},
                {"type": "button", "id": "hello", "gap": 12, "label": "Say hello", "style": "prominent",
                 "action": {"id": "hello", "sends": ["name"]}, "needs": ["name"]}]}]}


class Handler(BaseHTTPRequestHandler):
    def send(self, status, value=None):
        body = json.dumps(value).encode("utf-8") if value is not None else b""
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        user = check_login(self.headers.get("X-Subsonic-Login"))
        if user is None or self.path.split("?")[0] not in ("/panel", "/panel/s/main"):
            return self.send(404)  # Anything but 200 (or 429 and 5xx): no tab.
        self.send(200, main_screen(user))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        user = check_login(self.headers.get("X-Subsonic-Login"))
        if user is None or self.path != "/panel" or not 0 < length <= BODY_LIMIT:
            return self.send(404)
        try:
            request = json.loads(self.rfile.read(length))
            name = str(request["values"].get("name", "")).strip()[:100]
        except (ValueError, KeyError, AttributeError, TypeError):
            return self.send(400)
        if request.get("screen") == "search":   # Nothing to add to Search.
            return self.send(200, {"present": "replace", "screen": {
                "v": 1, "id": "search", "title": "", "sections": []}})
        self.send(200, {"present": "none", "toast": "Hello, %s!" % (name or user)})

    def log_message(self, fmt, *args):
        pass                    # Don't log the requests: their headers carry logins.


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
```

To try it, start it next to your music server, then send `/panel` to it from your reverse proxy. With Caddy, for example, add this line to your music server's site, before the line that sends everything else to the music server:

```
reverse_proxy /panel* 127.0.0.1:8790
```

Then sign in to Navinx as one of `ALLOWED_USERS`, through the proxy's https address: the tab "Hello" appears in third place within a moment.

[Navinx]({{ '/' | relative_url }}) · [Device approval]({{ '/devices/' | relative_url }}) · [Privacy Policy]({{ '/privacy/' | relative_url }}) · [Support]({{ '/support/' | relative_url }})
