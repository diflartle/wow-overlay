# M+ Chat Blocker Overlay

An OBS overlay for World of Warcraft Mythic+ that sits over your chat box and shows the current key, timer, party, and boss pulls instead. A PowerShell script reads your combat log and feeds the overlay. No addons and no API keys are needed.

## What it shows

- **Key level and dungeon**, with a live timer that turns green when timed and red when over time.
- **Party**, with names in class colors, a role icon, and spec.
- **Bosses**, with pull and kill times (into the key), fight length, and a wipe count. A boss you're currently fighting is highlighted and its timer ticks live.
- **Between keys**, a summary of your last key, or a custom title such as "Farming crests with Ulk".

## Files

Keep these together in one folder:

| File              | What it is                                     |
| ----------------- | ---------------------------------------------- |
| `wow-overlay.ps1` | Reads the combat log and writes `data.js`      |
| `overlay.html`    | The overlay you add to OBS                     |
| `data.js`         | Created by the script. Don't edit it           |
| `title.txt`       | Created when you set a title. Edit it any time |

## Setup

**1. Turn on combat logging in WoW.**
Turn on **Advanced Combat Logging** under Options > System > Network. Then type `/combatlog` in chat at the start of each session, or use an addon that turns logging on automatically in dungeons.

**2. Start the script.**

```powershell
powershell -ExecutionPolicy Bypass -File .\wow-overlay.ps1
```

If WoW isn't installed in the default location, point the script at your Logs folder:

```powershell
.\wow-overlay.ps1 -LogDir 'D:\Games\World of Warcraft\_retail_\Logs'
```

Leave the window open while you play. It prints what it sees: keys starting, bosses pulled, and so on.

**3. Add the overlay to OBS.**
Add a **Browser** source, check **Local file**, and pick `overlay.html`. Size and position the source to cover your chat. The text resizes itself to fit. A tall box stacks the party above the bosses, and a wide box puts them side by side.

## Custom title

Show your own text in place of "Between keys" when you're not in a key.

At launch:

```powershell
.\wow-overlay.ps1 -Title 'Farming crests with Ulk'
```

While the script is running, edit `title.txt`, save it, and the overlay updates within about a second. You can also set it from another PowerShell window:

```powershell
Set-Content .\title.txt 'Pushing Ara-Kara with Ulk'
```

To go back to "Between keys", empty or delete `title.txt`. The title is kept between sessions.

## Options

| Parameter              | Default                                                  | What it does                                                                               |
| ---------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `-LogDir`              | `C:\Program Files (x86)\World of Warcraft\_retail_\Logs` | Your WoW Logs folder                                                                       |
| `-Title`               | (none)                                                   | Title to show between keys                                                                 |
| `-FinishedHoldSeconds` | `30`                                                     | How long the final time stays up after a key before switching to "Between keys"            |
| `-CatchUpMB`           | `20`                                                     | How much of the existing log to read at startup, so a key already in progress is picked up |
| `-OutFile`             | `data.js` next to the script                             | Where to write data. Must stay next to `overlay.html`                                      |
| `-Demo`                | off                                                      | Cycles through fake data so you can position and style the overlay without WoW running     |

## Customizing the look

Open `overlay.html` in a text editor. The colors are at the top under `:root`. To make the panel see-through, lower the last number in `--panel` (for example, `rgba(14, 18, 26, 0.8)`).

## Troubleshooting

- **"running scripts is disabled"**: launch with `powershell -ExecutionPolicy Bypass -File .\wow-overlay.ps1` as shown above.
- **"No combat log … yet"**: you haven't typed `/combatlog` this session, or `-LogDir` points at the wrong folder.
- **Overlay stuck or blank**: make sure the script is running and that `overlay.html` and `data.js` are in the same folder. Right-click the source in OBS and choose **Refresh**.
- **Party missing or incomplete**: the full roster is filled in when the key starts or a boss is pulled.
