# EOS setup (online play)

Internet play uses Epic Online Services: anonymous device-ID login (players need no Epic account), lobbies joined by
a short code, and P2P sockets that fall back to Epic's relays. This is the one-time setup on each developer machine
that builds or runs online play. Without it everything else works: games build and play single player and LAN.

The SDK is Epic's, under the EOS Developer Agreement, so it is never in the repo, fetched by `uni`, or in CI. CI has
no SDK and no EOS credentials: its tests skip those that need the real SDK, and a library release's game exports
are checked single player and LAN only (`uni release --no-eos`). Online-capable packages come from `uni release` on a
machine set up as below.

1. **Product.** At <https://dev.epicgames.com/portal>, create a product (e.g. "unified survivor"). One product per
   repo: the example games in this repo share one (their lobbies are kept apart by game name and build); a game you ship
   lives in its own repo (`uni init`) with its own `.env`, so its own product.
2. **Client.** Product Settings → Clients:
   - add a **custom client policy** with only **Lobbies** enabled (all its actions). The client ID and secret ship
     inside every online build, so anyone can call EOS as this client: allow nothing the game doesn't use. Connect
     (the anonymous device-ID login) and P2P aren't policy features. Not the "Peer2Peer" preset: it also enables
     Achievements, Leaderboards, Metrics, Notifications, Player Data Storage, Player Reports, Progression Snapshot,
     Sanctions, Sessions, Stats, Title Storage and Voice;
   - add a **client** that uses that policy.
3. **SDK.** Download the **EOS C SDK** zip (not the Unity/Unreal one) of the version `pins.cfg` `[eos_sdk]` pins,
   unzip it anywhere outside the repo and point `UNIFIED_EOS_SDK` at it. `uni setup` shows whether it is found and
   the right version; a game's build copies this platform's library next to the game's.
4. **IDs.** In the project's `.env` (git-ignored, next to `uni`):
   ```
   UNIFIED_EOS_SDK=/path/to/EOS-SDK-1.19.2.1
   UNIFIED_EOS_PRODUCT_ID=...
   UNIFIED_EOS_SANDBOX_ID=...
   UNIFIED_EOS_DEPLOYMENT_ID=...
   UNIFIED_EOS_CLIENT_ID=...
   UNIFIED_EOS_CLIENT_SECRET=...
   ```
   The product, sandbox (the Dev sandbox) and deployment IDs are on the product's settings pages; the client ID and
   secret are on the client you created. Every game build compiles them into the game's library (`uni build` and
   `uni release` pass them as `-define`s; `uni release` checks they are there), and the environment is the
   fallback (`uni run`, `uni editor` and `uni tool` pass `.env` on).

**Logs.** `UNIFIED_EOS_LOG=info` (or more verbose) makes the SDK print its boot line with the product, sandbox,
deployment and client IDs (not the secret): don't paste those logs anywhere public. The default level is Warning.

**Test identities.** A machine's EOS identity is a device ID kept per OS user (macOS: in the login keychain). The
test tools replace it: `uni coop`'s joiner makes a fresh one (`UNIFIED_EOS_FRESH_DEVICE=1`, so two processes on one
machine are two players), and the headless `eos-host` / `eos-client` delete theirs at exit. So after a test the
machine plays as a new anonymous player, and two EOS tests run at once on one machine can delete each other's
identity: run one at a time. Nothing is stored per player across sessions, so this costs nothing yet.

## Testing over real EOS

- **One machine, two processes**, the game's headless binary (survivor's opts into EOS lobbies):
  `survivor eos-host --ticks 1920 --code-file F` and `UNIFIED_EOS_FRESH_DEVICE=1 survivor eos-client --code C --ticks
  1920` (`UNIFIED_EOS_RELAYS=force` to go through Epic's relays). The fresh device gives the second process its own
  Product User ID. A pass: both play to the end with 0 desyncs, direct and relayed. `uni coop survivor` does the
  same with the game (`--rejoin`: a clean leave and rejoin; `--crash`: the joiner kills itself and rejoins).
- **Crossplay (macOS ↔ Windows over the internet)**, by hand on two machines: a Mac hosts with the game itself,
  `godot --headless --path examples/survivor -- --host-online --scripted --ticks 15360 --quit-at-end`; Windows joins
  with the release headless binary, `.out/release/survivor.exe eos-client --code XXXXXX --ticks 15360` (the lobby's
  build must be the binary's, else it says which version the host runs), or with the exported game from a release zip.
  Joining after the host started is a late join with a snapshot. A run passes when every common verified checksum
  of the two sides' result lines matches. The headless `eos-host --wait-s N` hosts too where the binary owns the
  keychain entry (not on a Mac where Godot.app made the device ID). Each side labels the path (Direct, Relayed) from
  its own P2P notification, so the two can disagree when EOS switches routes: the round trip is the better signal.
