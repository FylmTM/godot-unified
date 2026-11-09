# EOS setup (online play)

Internet play uses Epic Online Services: anonymous device-ID login (players need no Epic account), lobbies joined by
a short code, and P2P sockets that fall back to Epic's relays. This is the one-time setup the developer does; the
game and CI read the results.

1. **Product.** At <https://dev.epicgames.com/portal>, create a product (e.g. "unified survivor").
2. **Client.** Product Settings → Clients:
   - add a **client policy** that allows **Connect**, **P2P** and **Lobbies** (the "Peer2Peer" preset, or a custom
     policy with those three);
   - add a **client** that uses that policy.
3. **SDK.** Download the latest **EOS C SDK** zip (not the Unity/Unreal one) and unzip it to `~/tools/eos-sdk`.
4. **Local IDs**, outside the repo, in `~/.config/unified/eos.ini`:
   ```ini
   [eos]
   product_id=...
   sandbox_id=...
   deployment_id=...
   client_id=...
   client_secret=...
   ```
   The product, sandbox (the Dev sandbox) and deployment IDs are on the product's settings pages; the client ID and
   secret are on the client you created.
5. **CI secrets** (for tagged game builds). Run each and paste the value when prompted:
   ```
   gh secret set EOS_PRODUCT_ID -R FylmTM/unified
   gh secret set EOS_SANDBOX_ID -R FylmTM/unified
   gh secret set EOS_DEPLOYMENT_ID -R FylmTM/unified
   gh secret set EOS_CLIENT_ID -R FylmTM/unified
   gh secret set EOS_CLIENT_SECRET -R FylmTM/unified
   ```

Client credentials ship inside game builds (that's how EOS game clients work), so they aren't true secrets, but they
stay out of the repo. CI gets the SDK from an asset on a draft GitHub release of this repo (`tools/eos.py`, fetched by
`.github/workflows/eos-sdk.yml`, the only job with a write token), checked against a pinned SHA-256. The client
policy should allow only what a game client needs (Connect, P2P, Lobbies), since the client ID and secret ship in
every build.
