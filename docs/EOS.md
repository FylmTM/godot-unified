# EOS setup (online play)

Internet play uses Epic Online Services: anonymous device-ID login (players need no Epic account), lobbies joined by
a short code, and P2P sockets that fall back to Epic's relays. This is the one-time setup on each developer machine
that builds or runs online play. Without it everything else works: games build and play single player and LAN.

The SDK is Epic's, under the EOS Developer Agreement, so it is never in the repo, fetched by `uni`, or in CI. CI has
no SDK and no EOS credentials: its tests skip the two that need the real SDK, and its release packages are single
player and LAN only (`uni release --no-eos`). Online-capable packages come from `uni release` on a machine set up as
below.

1. **Product.** At <https://dev.epicgames.com/portal>, create a product (e.g. "unified survivor").
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
   secret are on the client you created. Dev builds read them at run time (`uni run`, `uni editor` and `uni tool`
   pass `.env` on); `uni release` compiles them into the game's library and checks they are there.
