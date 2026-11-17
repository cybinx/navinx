# Navinx

Navinx is a free iPhone music player for your own Navidrome or Subsonic server. This app was completely built by AI but architected by a human. It supplies no music and has no accounts of its own: you sign in to your server with the login you already have there, and Navinx plays what is on it.

This repository holds the app's source and its website.

- **Website:** https://cybinx.github.io/navinx/ (the [privacy policy](https://cybinx.github.io/navinx/privacy/) and [support](https://cybinx.github.io/navinx/support/))
- **Problems and questions:** open an issue in this repository's [Issues](https://github.com/cybinx/navinx/issues). Please don't post passwords or server addresses there: issues are public.
- **Privacy questions, or anything private:** email [gitcybinx@gmail.com](mailto:gitcybinx@gmail.com).

## What you need

- A Mac with **Xcode 27.2** or later (iOS SDK 27.2, Swift 6).
- An iPhone or a simulator on **iOS 27**. Navinx supports nothing older.
- To use it, a Navidrome server, or another server that speaks the Subsonic API, and a login on it.

There are no third-party packages: everything is Apple's frameworks and the local packages below.

## Building

1. Open `Navinx.xcodeproj` and choose the **Navinx** scheme.
2. For a simulator, just Run.
3. For your own iPhone, sign it as your own: in each target's **Signing & Capabilities**, choose your **Team** (the project names its owner's), and change the bundle IDs (`com.cybinx.navinx.app` and `….widgets`, `….tests`, `….uitests`) to your own. The app and its widgets share an **App Group**, `group.com.cybinx.navinx.shared`: make one of your own and put its name in `Config/Navinx.entitlements`, `Config/NavinxWidgets.entitlements` and `appGroup` in `Packages/SharedKit/Sources/SharedKit/WidgetSnapshot.swift`.

From the command line, a build for the simulator with no signing:

```sh
xcodebuild build -project Navinx.xcodeproj -scheme Navinx -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

## What's where

- `Navinx/`: the app (SwiftUI), by screen: `Home/`, `Library/`, `Search/`, `Player/`, `Settings/`, `Auth/` and `Accounts/` (signing in and saved servers), `Hub/` (a server's own tab), `Common/`.
- `NavinxWidgets/`: the widgets and Control Center controls.
- `Packages/`: the logic, in local Swift packages:
  - `SubsonicKit`: the Subsonic and OpenSubsonic client, its models and its login;
  - `PlaybackKit`: the player, the queue, the audio engine and the lock screen;
  - `Lyrics`: the server's lyrics and timed lines;
  - `HubKit`: a server's own tab (below);
  - `DeviceIdentity`: device approval (below);
  - `SharedKit`: what the app and its widgets share.
- `Config/`: the Info.plist keys and entitlements of the app and the widgets.
- `NavinxTests/` and `NavinxUITests/`: the app's tests; each package has its own under `Packages/<name>/Tests/`.
- The rest of the root (`index.md`, `privacy/`, `support/`, `addons/`, `devices/`, `_config.yml`) is the website, served by GitHub Pages.

## Tests

The **Navinx** scheme's tests (Swift Testing) cover the app and every package, and run offline: the server's answers are JSON fixtures, and the network is stubbed.

```sh
xcodebuild test -project Navinx.xcodeproj -scheme Navinx \
  -destination 'platform=iOS Simulator,name=<an iPhone simulator on iOS 27>'
```

A few tests talk to a real server and are skipped unless you give them a login. Each reads a JSON file kept **outside the repository**, `{"url": "https://…", "username": "…", "password": "…"}`, whose path it takes from an environment variable starting `TEST_RUNNER_` (Xcode passes it to the tests without the prefix): `TEST_RUNNER_SUBSONICKIT_LIVE` and `TEST_RUNNER_PLAYBACKKIT_LIVE` only read, while `TEST_RUNNER_SUBSONICKIT_QUEUE_WRITES` and `TEST_RUNNER_PLAYBACKKIT_WRITES` change that account's play queue, plays and favourites (and put them back where they can). Each test's file says what it needs. Use a test account of your own, never a login you care about.

The UI tests (`NavinxUITests`, their own scheme) sign in and walk the app against a real server with `TEST_RUNNER_NAVINX_LIVE` set to such a file. They reset the app's saved logins on that simulator, and some of them expect albums and songs of the server they were written against, so treat them as examples to adapt.

## Server extras

Navinx works with any Navidrome or Subsonic server as it is. A server's owner can also run small services of their own beside it, and Navinx will use them:

- **[Server add-ons](https://cybinx.github.io/navinx/addons/):** a tab of the server's own, made of screens the server sends, for the accounts it chooses. The page is the format, with a complete example add-on.
- **[Device approval](https://cybinx.github.io/navinx/devices/):** letting in only the iPhones the owner has approved, with a certificate each, issued by the owner's own add-on and checked by their reverse proxy.

What any such service does is up to whoever runs it; Navinx only draws the screens it sends and presents the certificate it was given.

## Credits

Navinx is a SwiftUI rewrite of [Musly](https://github.com/dddevid/Musly), the open-source Flutter app by dddevid. It was written from scratch, holds none of Musly's code, and is released with its author's permission. Thank you, dddevid.

The app's icons are drawn from the treble clef of **Bravura**, Steinberg's music font, under the SIL Open Font License 1.1 ([THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)).

## Licence

MIT: see [LICENSE](LICENSE).
