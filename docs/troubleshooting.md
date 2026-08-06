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
networkextension store rather than the TCC database, and the command fails
(verified again on 27.0 build 26A5388g — exit 70, "Failed to reset LocalNetwork
approval status").

The failure is silent and looks nothing like a permission problem. The bar is
reachable, the switch in Settings is **on**, and the app still cannot connect,
because that switch belongs to the *previous* binary. Confirm it from the log
rather than guessing:

```sh
/usr/bin/log show --last 10m --style compact --process <pid> \
  | grep -E "Local network prohibited|status 200"
```

A denial reads `unsatisfied (Local network prohibited)` followed by
`NSURLError -1009`, and the `proc:` field carries the executable UUID the
system is judging (`dwarfdump --uuid` on the installed binary to compare).

### Re-prompting without a rebuild

Installing to a **fresh path in /Applications** forces the prompt. No rebuild is
needed — a plain `cp -R` of the same binary is enough, which is worth knowing
because rebuilding to chase this wastes a lot of time:

```sh
cp -R "/Applications/Busy Control Centre.app" "/Applications/BusyBar Fresh.app"
open -a "/Applications/BusyBar Fresh.app"      # grant the prompt when it appears
osascript -e 'tell application "Busy Control Centre" to quit'
rm -rf "/Applications/Busy Control Centre.app"
mv "/Applications/BusyBar Fresh.app" "/Applications/Busy Control Centre.app"
```

The grant survives that final move, so the app keeps its proper name and its
`UserDefaults` (host, access key, widget and carousel settings) — changing the
bundle id would lose all of them.

Observed 2026-08-06: both copies shared the identical executable UUID, yet the
one at the original path was denied while the one at the new path prompted and
was granted. So the bug is not that a new UUID needs a new grant — it is that a
new UUID at a path with a stale record is denied *without ever prompting*, and a
new path is what forces the system to ask.

Once a good grant exists for that path, plain `cp -R` overwrites keep working:
later the same day, rebuilding and overwriting in place connected immediately
with no prompt and no denial. Only two installs that day needed the dance, and
both followed a change to the entitlements. So try the overwrite first and reach
for the fresh path only when the log actually shows `Local network prohibited`.

## The Mail widget says it cannot reach Mail (-600)

`unread count of inbox` fails with -600 "Application isn't running" while Mail
is running and `NSRunningApplication` can see it. The log names the real cause:

```
appleeventsd: Sandboxed application with pid N attempted to lookup
App:"Mail"/"Mail"/"com.apple.mail" ... but was denied due to sandboxing.
```

The sandbox blocks the Apple event **target lookup**, not the send, so
`com.apple.security.automation.apple-events` alone is not enough — the target
must also be listed in `com.apple.security.temporary-exception.apple-events`.
Both are in `project.yml`. Targeting by bundle id
(`tell application id "com.apple.mail"`) does *not* work around it; that was
tried and still returned -600.

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
