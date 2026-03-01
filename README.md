# PallyPower for TurtleWoW
- Download the zip file and rename to PallyPower

## Slash Commands

| Command | Description |
|---|---|
| `/pp` or `/pallypower` | Toggle the main assignment UI frame |
| `/pp report` | Print blessing assignments to raid/party chat |
| `/pp lock` | Toggle frame position locking (persists across reloads) |
| `/pp debug` | Toggle debug output to chat |

---

## v1.8.0

**Performance:**
- Event-driven scanning replaces periodic full-raid polling (uses UNIT_AURA per-unit)
- Debounced UI refreshes to reduce frame stutter
- Reusable internal tables to reduce memory churn

**Buff casting:**
- Smart casting now skips players who already have the blessing — cycles through units that actually need it

**Raid coordination / messaging:**
- Raid leader assignments no longer get overwritten by incoming SELF broadcasts
- Paladins auto-sync on login/reload/zone-in (no manual `/pp refresh` needed)
- REQ message throttle prevents addon chat floods in large raids

**TurtleWoW:**
- Auto-detects TurtleWoW realms, adjusts blessing durations (10min regular / 30min greater)

**UI/QoL:**
- Frame opacity setting
- Chat feedback toggle for cast notifications
- `/pp lock` to toggle frame position locking (persists across reloads)

---

## Previous changes

- Added an option to swap between Five minute blessings and Greater Blessings.
- Added a "hack" to make it show up while questing solo
- Updated Pally Power with Shaman class in the buff table

- Added Hunter Pet Support
- Added autoSelfCast Support

- Fixed icons, 5min/15min blessing icons and detection
- Fixed Refresh and Clear
- Added Refresh and Clear feedback

- Minor fixes to accomodate Turtle WoW patch 1.17.2