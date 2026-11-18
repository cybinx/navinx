---
title: Privacy Policy
---

# Privacy Policy

*Last updated: 18 November 2026*

Navinx is a music player for your own Navidrome or Subsonic server. It's built to keep your data between you and your server.

## What Navinx collects

**Nothing.** Navinx has no accounts of its own, no analytics, no advertising and no tracking. The developer doesn't receive any of your data, with one exception that follows from how Navinx works: it sends your data to the server you sign in to, so on a server the developer runs (the demo server used for Apple's review, or the developer's own) the developer, as that server's owner, receives what any server's owner receives (below, "Your music server").

## Your music

Navinx doesn't supply, sell or host any music. It plays what is on the server you connect it to, and nothing else. You are responsible for having the right to every recording on that server: music you bought, ripped from discs you own, made yourself, or that is freely licensed. **Navinx is not meant for music that was obtained illegally and must not be used with it.** The developer has no view of, and no control over, what is on anyone else's server.

## Your music server

Navinx connects to the server addresses you enter. It sends your server what it needs to work: your login, what you browse and search, what you play (so your server can count plays), and any changes you make, such as favorites, ratings and playlists. All of that lives on your server, under the control of whoever runs it.

Navinx also asks the same address for a few things only an add-on on that server can answer (below): a sign-in for the add-on, whether the server approves devices (on an `https` address), and the levels for Now Playing's equalizer, for the song playing and the next few. These carry your login as a token made from your password, never the password itself. A server without an add-on refuses them, and nothing more is sent.

**Pictures.** Covers, artist pictures and the pictures in your server's tab (below) are loaded from the address your server gives for each. Usually that is your server itself, but a server may give any `http` or `https` address, on another host. Navinx then loads the picture straight from that address, so that host sees your iPhone's IP address and which picture was asked for (unencrypted, if the address is `http`). Pictures may be kept in Navinx's picture cache on your iPhone.

**An extra tab from your server.** If your server's owner runs an add-on for Navinx, your account may see an extra tab with the screens it sends. The tab is open-ended: its owner decides what it offers and is responsible for it, and Navinx only draws it. What you type and tap there, and, while your account has the tab, what you type in Search, goes to your server, at the same address, with your login (a token made from your password, never the password itself). Navinx doesn't send it anywhere else.

**Proof that the app is genuine (App Attest).** Only if your server's add-on asks for it, Navinx proves to that server that it is the real app on a real iPhone, using Apple's App Attest. The iPhone makes a key that never leaves it and asks Apple to certify that key. This happens when you sign in to the add-on and the server asks for a new key: the first time, again if the server no longer knows the key your iPhone holds or didn't keep a new one, and again if your iPhone reports that its key is no longer valid (for example after a restore onto another iPhone). If your server also approves devices and asks for it there, one more key is certified each time you send a request for approval. Each time, Apple receives the public half of the new key and a one-way fingerprint of what it is for (the server's one-time challenge and your user name; at device approval, the invite's code, your user name and the device's public key), which can't be turned back into any of them; and, as with any Apple service, Apple knows the request comes from Navinx on an Apple device. Your server receives Apple's certificate each time, and then a signature made on the iPhone each time you sign in to the add-on. Nothing of your account, your server or your music goes to Apple. If your server doesn't ask, App Attest is never used.

**Resume Across Devices.** So that another phone can pick up where you stopped, Navinx saves your queue and your place in the song on your server. You can switch this off in Settings → Playback.

**Device approval.** Some servers only let in devices their owner has approved. If yours asks, Navinx sends that server, with your request:

- the code from your invite;
- a name for the device (you can edit it);
- your iPhone's model (an identifier such as `iPhone18,1`) and its iOS version;
- the app's version;
- an ID made for this installation of Navinx (random, made once, and not taken from the iPhone);
- a certificate request, which carries the public half of a key made on your iPhone (the private half never leaves it);
- if the server asks for it, Apple's App Attest certificate (above).

These go to the server for its owner to approve. The server answers with a certificate that Navinx then shows to that server, at that address, only. Later, when the certificate is due for renewal, Navinx sends that server a new certificate request for the same key.

## Stored on your iPhone

Navinx keeps these on your iPhone:

- your saved servers (address, user name, name) and your settings, including your answer about LRCLIB (below);
- the servers' passwords, in the iOS Keychain;
- if a server approves devices: the device's key and certificate (Keychain) and the state of its request;
- if a server's add-on uses App Attest: the ID of the key iOS holds for it (Keychain);
- the ID made for this installation (sent only with a device approval request);
- the play queue and your place in the song, and plays not yet sent to your server;
- a copy of your library's list of albums, artists and playlists, cached pictures, and the equalizer's levels;
- music you download for offline listening, with its covers and its lyrics;
- your listening history, used for Listening History, recommendations and your year in review, all worked out on the phone;
- the names of your albums, artists and playlists in the iPhone's own search (Spotlight) and for Siri;
- for Navinx's widgets: the song playing, your recently played albums and your playlists' names, with their covers.

**Backups.** Downloads are kept out of iCloud and computer backups. The copy of your library, the cached pictures and the equalizer's levels are a cache, which iOS doesn't back up. The Keychain entries (passwords, the device's key and certificate, the App Attest key's ID) are kept to this iPhone: iOS doesn't move them to another iPhone, from a backup or otherwise. The rest (your saved servers and settings, the queue, your listening history, the installation's ID and the widgets' copy) goes into your iPhone's backups like any app's data.

## Signing out and removing a server

**Signing out** (Settings → Servers → Sign Out) first asks: "Sign out of this server? Its downloads and the app's cached data are removed from this iPhone. The server stays in your saved list." It removes from this iPhone that server's downloads (with their covers and lyrics), the picture cache, the copy of every server's library, the play queue, the server's albums, artists and playlists in Spotlight, the widgets' copy and the ID of that server's App Attest key. It keeps your saved servers and their passwords, so you can sign in again with one tap, your listening history and your settings; for a saved server, the device's approval stays too.

**Removing a saved server** (Settings → Servers → Manage) deletes its saved password, its copy of the library, its downloads, the ID of its App Attest key, and its device key and certificate. Removing the server you're signed in to only takes it off the saved list: the rest goes when you sign out, so sign out first.

**Settings → Storage** clears the cache and deletes all downloads; **Settings → Appearance → Clear Listening History** deletes the listening history.

## How long data is kept, and deleting it

The developer holds nothing about you, so there is nothing for the developer to keep or delete (other than as the owner of a server the developer runs, above: ask by email, below). What is on your iPhone stays until you remove it as above, or until you delete the app, which removes the rest. (iOS may keep Keychain entries after an app is deleted, so remove your servers first if you want the passwords gone too.) What is on your server (your account, your plays, favorites, ratings and playlists, the saved queue, and anything sent with device approval or to its tab) is kept and deleted by that server's owner: ask them.

## Lyrics

Navinx can look up lyrics your server doesn't have on the public lyrics service LRCLIB (lrclib.net). This is off until you say yes: the first time the lyrics page shows a song your server has no lyrics for, Navinx asks once whether to look them up online, and remembers your answer. Until you say yes, nothing is sent to LRCLIB. Once you do, Navinx asks LRCLIB about every song your server has no lyrics for, in two cases: each song that plays while Now Playing is open (on any of its pages, not only the lyrics), and each song you download. An answer is remembered for as long as Navinx runs, so the same song isn't asked about twice meanwhile.

Navinx sends LRCLIB the **artist name and song title**, and names itself as Navinx; nothing about you or your server. Like any web service, LRCLIB also sees your iPhone's IP address. How LRCLIB handles that is up to LRCLIB. You can change your answer at any time in Settings → Playback → "Fetch lyrics from LRCLIB".

**Translation.** Lyrics are translated on your iPhone by Apple's own translation. The lyrics aren't sent anywhere. If a language isn't on your iPhone yet, iOS offers to download it from Apple.

## Donations

If the project ever takes donations, the payment will be handled entirely by a third-party service, under its own privacy policy. Navinx itself never handles payments.

## Children

Navinx doesn't knowingly collect any information from anyone, including children under 13.

## Changes

If this policy changes, the new version will be posted here with a new date.

## Contact

For privacy questions, or anything you'd rather not post in public, email [gitcybinx@gmail.com](mailto:gitcybinx@gmail.com).

For bugs and other questions, you can also open an issue at [https://github.com/cybinx/navinx/issues](https://github.com/cybinx/navinx/issues). Please don't post passwords or server addresses there: issues are public.
