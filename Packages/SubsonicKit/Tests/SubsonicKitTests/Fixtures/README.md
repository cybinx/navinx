# SubsonicKit fixtures

## Recorded (this folder)

Recorded **read-only** on 2026-11-05 (C1) from the user's Navidrome (0.64.2, OpenSubsonic) as
the non-admin Navidrome user `api`, one GET each, JSON (`f=json`). Before saving, every response
was scrubbed: the server address became `<navidrome-host>`, Navidrome's signed image paths
(`/share/img/<signed token>`) became `/share/img/<token>`, and each was checked to hold no
password, token, salt or IP address. The request URLs (with `u`, `t`, `s`) were never saved.

The library had three artists then (most of it sits on the NFS share that was stale), so these
are small. `*_empty` files are real empty answers: Navidrome sends `"starred2": {}` with no list.
`ping_wrong_password` is the real answer to a wrong login (HTTP 200, `status: failed`, code 40);
`getPlaylist_notFound` is code 70.

To re-record: the recording script lives outside the repo (it reads the login from `SERVERS.md`
at run time); see `docs/log/C01.md`.

Two more were recorded the same way on 2026-11-13 (C35), read-only as `api`, scrubbed the same
way: `getArtistInfo2_similar.json` (Childish Gambino, whose six similar artists are in the
library; Navidrome leaves `similarArtist` out when none is) and `getSong.json` (a 16-bit FLAC,
with OpenSubsonic's `samplingRate`, `bitDepth` and `channelCount`).

## Hand-written (`Handwritten/`)

Not recorded: the `api` user has no playlists, favourites or lyrics, and recording is
read-only. They copy the recorded shape and reuse a few real IDs.

- `getPlaylists.json`, `getPlaylist.json`: two playlists; one with two entries (one starred).
- `getStarred2.json`: one artist, album and song.
- `getLyricsBySongId.json`: OpenSubsonic structured lyrics, one synced set (with an offset) and
  one unsynced.
- `getArtists_combined.json`: combined names ("Alpha & Beta"), an `artists` list, a duplicate
  by case ("beta", with no ID), a blank name, and an index entry with one object instead of a
  list.
- `getPlayQueue.json`, `getPlayQueue_empty.json` (C36): the saved play queue in the shape of
  Navidrome's source (`responses.PlayQueue`), three songs copied from `getRandomSongs.json`; with
  nothing saved, Navidrome still sends a `playQueue` with a zero `changed` and no `entry`. The shape
  of the first was confirmed by one live save and read back as `api` (`LivePlayQueueTests`).
- `getAlbumList2_single.json`: another server sending one object instead of a list, with
  numbers as strings and a numeric ID.
