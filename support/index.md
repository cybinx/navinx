---
title: Support
---

# Support

## Signing in

Navinx plays the music on a Navidrome server, or another server that speaks the Subsonic API. To sign in you need three things from that server:

- its **address**, starting with `http://` or `https://`;
- your **user name**;
- your **password**.

Navinx has no accounts of its own, so it can't create an account or reset a password. If you've forgotten yours, ask whoever runs the server. For an older Subsonic server, try switching on **Legacy Authentication** on the sign-in screen.

## When signing in fails

The sign-in screen says what went wrong. The usual messages and what to try:

- **"Cannot connect to server. Check the URL and your internet connection."** Check the address for typing mistakes, that your iPhone is online, and that the server is running.
- **"Connection timed out."** The server took too long to answer. Check your network, then try again.
- **"Invalid username or password."** Check both and try again. Only the server's owner can reset a password.
- **"Server not found. Check your URL path."** If your server lives under a path, include it in the address, for example `https://example.com/navidrome`.
- **"URL must start with http:// or https://"**. Add one of them to the start of the address.
- **"Could not make a secure connection. Check whether the server uses https."** The address starts with `https://` but the server may only speak plain `http://`. Ask its owner which one it uses.
- **"Insecure HTTP"** (a note under the address). The address starts with `http://` and isn't a home-network address, so your password and your music aren't encrypted on the way. It's a warning only and Navinx still connects, but an `https://` address is recommended.
- **"SSL certificate error. Check the server's certificate."** Navinx only accepts certificates your iPhone itself trusts. One it doesn't trust, for example an expired or self-signed certificate, is refused, and Navinx has no setting to accept it anyway: the server's owner needs to fix the certificate.
- **"Access denied (HTTP 403)."** Something in front of the server, such as a proxy or firewall, refused the request. Ask the server's owner.

## "This server approves each device"

Some servers only let in devices their owner has approved. If yours does, Navinx asks for the code from your invite and a name for your iPhone. As the screen says, it then sends your server, for approval, that name, your iPhone's model and iOS version, the app's version and an ID made for this installation, together with the code, the public half of a key made on your iPhone and, if the server asks for it, Apple's proof that the app is genuine (the [Privacy Policy]({{ '/privacy/' | relative_url }}), "Device approval", has the full list). It then shows four words: read them to the server's owner, and the screen moves on when they approve. If your invite has expired, ask the owner for a new one.

## An extra tab, or none

**"I see an extra tab."** It comes from your server: its owner runs an add-on that gives some accounts a tab of their own, and decides what it shows. Questions about it go to whoever runs your server.

**"Someone else sees a tab I don't."** The server's owner chooses which accounts get it. Ask them.

## Lyrics

Navinx shows the lyrics your server has. When it has none for a song, the lyrics page asks once, "Look for lyrics online?", whether to look them up on the public service LRCLIB (lrclib.net); only the artist and song title are sent. Once you say yes, Navinx asks LRCLIB about each song your server has no lyrics for, while Now Playing is open and when you download it. You can change your answer at any time in **Settings → Playback → "Fetch lyrics from LRCLIB"**.

## Downloads and storage

Songs, albums and playlists can be downloaded from their menus to play offline. **Settings → Storage** shows how much space the cache and the downloads use, clears the cache, deletes all downloads, and has **Smart Downloads**, which downloads your favorite songs and albums on Wi-Fi and keeps downloaded playlists up to date.

## Removing a saved server

In **Settings → Servers**, tap **Manage**, then the **⋯** button beside the server, then **Remove**. Its saved login and its downloads are removed with it. Removing the server you're signed in to only takes it off the saved list, so sign out first (**Settings → Servers → Sign Out**), then tap **×** beside it under "Saved Profiles" on the sign-in screen.

## Contact

For bugs and questions, open an issue at [https://github.com/cybinx/navinx/issues](https://github.com/cybinx/navinx/issues). Please don't post passwords or server addresses there: issues are public.

For privacy questions, or anything you'd rather not post in public, email [gitcybinx@gmail.com](mailto:gitcybinx@gmail.com).

See also the [Privacy Policy]({{ '/privacy/' | relative_url }}).
