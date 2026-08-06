# Troubleshooting

## The app cannot reach the bar

The status line reads `cannot reach 10.0.4.20: The Internet connection appears
to be offline` even though the bar answers in a browser. That error is how macOS
reports a **Local Network privacy denial**, not a networking fault.

Check **System Settings → Privacy & Security → Local Network** for the app and
switch it on. The decision is cached per process, so quit and relaunch the app
afterwards — a running app will not notice the change.

### The permission binds to the binary, not the app name

Local Network privacy keys off the main executable's UUID
([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)).
Every rebuild produces a new UUID, so replacing an installed app in place voids
its grant, and the entry left in Settings belongs to the old binary. Installing
the new build under a different name presents a fresh identity and gets a fresh
prompt.

`tccutil reset LocalNetwork <bundle-id>` does not help: this state lives in the
networkextension store rather than the TCC database, and the command fails.

### No prompt ever appears (macOS 26/27 betas)

On the Tahoe and later betas a corrupt permission store can stop *any* app from
registering: no prompt, no entry in Settings, all local traffic denied. It
affects terminals and GUI apps alike. The fix is to delete the cached files from
Recovery, since they are protected by SIP:

1. Shut down. On Apple Silicon hold the Power button until "Loading startup
   options" appears, then choose **Options → Continue**.
2. **Disk Utility** → mount your **Data** volume → quit.
3. **Utilities → Terminal**:
   ```sh
   rm /Volumes/Data/Library/Preferences/com.apple.networkextension.*.plist
   ```
4. Restart.

The Local Network list will be empty afterwards; apps re-prompt as they ask.
VPN and network-filter configurations may need re-approving.

### Terminals that can never be granted

An app only gets a prompt if it declares `NSLocalNetworkUsageDescription`.
Warp and Terminal.app do not, so scripts run from them cannot reach the bar at
all. iTerm2 does declare it — run `python/*.py` from there.

## Widgets show "display busy (409)"

Something with a higher priority owns the screen: a focus session (priority 90),
or another widget. This is normal and self-correcting — widgets keep drawing and
reappear once the session ends.

## The Music widget says "press play/pause once in Music to sync"

It listens for `com.apple.Music.playerInfo` notifications, which need no
permission but only fire on a change. Press play or pause once and it syncs.
