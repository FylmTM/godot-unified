## Playing

- **Move:** WASD or arrow keys, gamepad left stick. **Dash:** Space / pad A.
- **Level up:** pick an upgrade with 1 / 2 / 3 (pad X / Y / B).
- **Menu:** Esc. **Dev UI:** F1 (included in every test build for now).
- **Single player** puts you in the arena. Everyone spawns inside the circle; the match starts when any player
  walks out of it.

## Playing with a friend (online)

1. The host picks **Host online** in the main menu and gets a 6-character lobby code (**Copy** puts it on the
   clipboard); send it to your friend.
2. The friend picks **Join with code**, types the code and presses **Join**. macOS and Windows can play together.
3. Connections go through Epic Online Services relays; no ports to open. If joining fails, check the code and try
   again. If it keeps failing, send us the log: `~/Library/Application Support/Godot/app_userdata/Survivor/logs/`
   on macOS, `%APPDATA%\Godot\app_userdata\Survivor\logs\` on Windows.
4. First time online: macOS asks once per new build to let Survivor use a keychain item (the anonymous device ID):
   click **Always Allow**. **Deny** is safe too (online play then fails with a message; nothing else changes).
   Windows may show a Firewall prompt: click **Allow access**.
