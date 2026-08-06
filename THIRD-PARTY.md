# Third-party notices

Six widgets in this app are Swift ports of Python apps from the
[BUSY Bar Apps gallery](https://maxswinkels.github.io/busybar-apps/), an
unofficial gallery run by Max Swinkels. Both upstreams are MIT licensed, which
requires their copyright and permission notices to travel with substantial
portions of the work — reproduced in full below.

The `application_name` each widget registers with the device is the upstream
app's slug (`clock`, `nyan-cat`, `iss-alert`, `audio-visualizer`,
`flightradar`, `claude-limits`), so the lineage is visible on the wire too.

Each app's author was taken from that app's own gallery page, not from the index,
and each app's licence confirmed against its repository:

| Widget here | Upstream app | Author | Licence |
|---|---|---|---|
| **Clock** | [clock](https://github.com/maxswinkels/busybar-apps/tree/main/apps/clock) | Max Swinkels ([@maxswinkels](https://github.com/maxswinkels)) | MIT |
| **Nyan Cat** | [nyan-cat](https://github.com/maxswinkels/busybar-apps/tree/main/apps/nyan-cat) | Max Swinkels ([@maxswinkels](https://github.com/maxswinkels)) | MIT |
| **ISS Alert** | [iss-alert](https://github.com/maxswinkels/busybar-apps/tree/main/apps/iss-alert) | Max Swinkels ([@maxswinkels](https://github.com/maxswinkels)) | MIT |
| **Music** | [audio-visualizer](https://github.com/maxswinkels/busybar-apps/tree/main/apps/audio-visualizer) | Max Swinkels ([@maxswinkels](https://github.com/maxswinkels)) | MIT |
| **Flightradar** | [flightradar](https://github.com/maxswinkels/busybar-apps/tree/main/apps/flightradar) | Max Swinkels ([@maxswinkels](https://github.com/maxswinkels)) | MIT |
| **Claude Limits** | [busybar-limits](https://github.com/rbhbokka/busybar-limits) | Kiryl ([@rbhbokka](https://github.com/rbhbokka)) | MIT |

The five gallery apps live in `maxswinkels/busybar-apps`, whose MIT notice names
"BUSY Bar Apps contributors" as the copyright holder rather than Max Swinkels
personally — so both the app author and that notice are recorded here. Claude
Limits lives in its own repository with its own notice.

The ports are rewrites rather than copies — Swift `MiniApp`s against the same
`/api/display/draw` endpoint — but they follow the upstream behaviour, layout
and data sources closely enough that these notices belong here.

---

## maxswinkels/busybar-apps

Covers the Clock, Nyan Cat, ISS Alert, Music and Flightradar widgets.

```
MIT License

Copyright (c) 2026 BUSY Bar Apps contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## rbhbokka/busybar-limits

Covers the Claude Limits widget.

```
MIT License

Copyright (c) 2026 Kiryl (rbhbokka)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Not from the gallery

For completeness, the widgets that are not ports: pISS Stream (idea from
[pISSStream](https://github.com/Jaennaet/pISSStream), telemetry from NASA),
Stocks, Weather, YouTube, Mail, Status, Timer, Pomodoro and On Call.

Banner artwork is covered separately in
[Resources/Themes/ATTRIBUTION.md](Resources/Themes/ATTRIBUTION.md) — it is
CC-BY-SA-4.0, not MIT.
