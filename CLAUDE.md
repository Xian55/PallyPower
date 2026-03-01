## PallyPower WoW Addon

Paladin blessing management addon for **vanilla WoW 1.12** (Interface 11200) with **TurtleWoW** support. Written in **Lua 5.0**.

Coordinates blessing assignments across multiple Paladins in a raid, tracks buff status per class, and provides one-click Greater/regular blessing casting.

### Target Environment
- WoW 1.12.x vanilla API — uses `getglobal()`, `CastSpell()`, `SpellCanTargetUnit()`, `SendAddonMessage()`, classic event names (`UNIT_AURA`, not `UNIT_SPELLCAST_SENT`)
- TurtleWoW compatible (Shaman class support included for cross-faction raids)
- Max player level: 60
- No `C_Timer`, no `_G` shorthand, no `#` length operator (use `table.getn()`)
- No `continue` keyword in Lua 5.0 — use `repeat...until true` inside loops
- No external library dependencies (pure vanilla APIs)

### Project Structure
```
PallyPower/
  PallyPower.toc              TOC manifest (Interface 11200)
  PallyPower.xml              UI frame definitions + script load order
  PallyPower.lua              Core logic (~1088 lines)
  localization.lua            Strings & translations (EN/DE/FR in one file)
  Bindings.xml                Key binding declarations (Toggle, Report)
  PallyPower-ResizeGrip.tga   UI texture for frame resizing
  Icons/                      Class & pet icon textures (.tga/.png)
```

Load order (from `PallyPower.xml`): `localization.lua` → `PallyPower.lua` → `whichblessing.lua` (dead reference — file does not exist)

Note: The TOC also lists `PallyPower.lua` before `PallyPower.xml`, so PallyPower.lua is effectively loaded twice by the client. This is harmless since it only defines globals and functions.

### Saved Variables (per-character)
- `PallyPower_Assignments` — Blessing assignments per Paladin per class (`[playerName][classID] = blessingID`)
- `FiveMinuteBlessingOn` — Toggle between 5-min regular blessings and 15-min Greater blessings
- `PP_PerUser` — User preferences (scale, feedback, smart buffs)

### Code Conventions
- **Indentation:** 4 spaces
- **Public API functions:** `PallyPower_PascalCase` prefix (e.g., `PallyPower_OnLoad`, `PallyPower_ScanSpells`, `PallyPower_UpdateUI`)
- **Local helpers:** `PascalCase` without prefix (e.g., `RebuildRoster`, `ScanOneUnit`, `PruneCurrentBuffs`)
- **Debug helper:** `PP_Debug(str)` — prints to chat when `PP_DebugEnabled` is set
- **Constants:** `ALL_CAPS` (e.g., `PP_PREFIX`, `BINDING_HEADER_PALLYPOWER_HEADER`)
- **State tables:** `PascalCase` (e.g., `RosterUnits`, `UnitClassID`, `CurrentBuffs`, `AllPallys`, `RosterSet`)
- **Blessing IDs:** Numeric 0–5 (Wisdom, Might, Salvation, Light, Kings, Sanctuary); -1 = unassigned
- **Class IDs:** Numeric 0–9 (Warrior, Rogue, Priest, Druid, Paladin, Hunter, Mage, Warlock, Shaman, Pet)

### Architecture: Event-Driven Updates
Events trigger incremental scans instead of periodic polling:
- `UNIT_AURA` → `ScanOneUnit(unit)` → sets `uiDirty = true`
- `OnUpdate` debounces using `PP_PerUser.scanfreq` (default 1s), then calls `PallyPower_UpdateUI()`
- Roster rebuilt on `RAID_ROSTER_UPDATE` / `PARTY_MEMBERS_CHANGED` / `UNIT_PET`
- `BAG_UPDATE` → `PallyPower_ScanInventory()` (Symbol of Kings count)
- `SPELLS_CHANGED` / `PLAYER_ENTERING_WORLD` → `PallyPower_ScanSpells()` (re-scan spellbook)

### Key State Tables
- `RosterUnits` — (local) array of active unit IDs (`"player"`, `"party1"`, `"raid5"`, `"raidpet5"`, etc.)
- `UnitClassID` — (local) map: unit → classID (0–9); pets always use 9
- `RosterSet` — (local) set: unit → `true` for O(1) membership checks
- `CurrentBuffs[classID][unit]` — buff state per unit; each entry has `name`, `visible`, `_mask` (6-char 0/1 string), and `[0]`–`[5]` (boolean per blessing)
- `AllPallys[playerName]` — per-paladin spell info: `[blessingID] = {rank, talent, id, name}`, plus `["symbols"]` count
- `LastCast[buffID..classID]` — countdown timers for blessing duration display
- `BlessingIcon[0..5]` / `BuffIcon[0..5]` — icon texture paths, swapped between 5-min and 15-min modes

### Messaging Protocol
- Addon channel prefix: `"PLPWR"` (`PP_PREFIX`)
- Functions: `PallyPower_SendMessage(msg)` / `PallyPower_ParseMessage(sender, msg)`
- Sends via `"RAID"` if in raid, `"PARTY"` otherwise
- Message types:
  - `REQ` — request all Paladins to broadcast their info
  - `SELF <ranks>@<assignments>` — broadcast own spell ranks + assignments
  - `ASSIGN <name> <classID> <blessingID>` — set one assignment (leader/self only)
  - `MASSIGN <name> <blessingID>` — set all classes to one blessing (shift-click)
  - `SYMCOUNT <count>` — broadcast Symbol of Kings count
  - `CLEAR` — clear all assignments (leader-only broadcast)

### Casting Flow
`PallyPowerBuffButton_OnClick` handles buff bar button clicks:
1. Temporarily disables auto-self-cast (`SetCVar("autoSelfCast", "0")`)
2. Calls `CastSpell(spellID, BOOKTYPE_SPELL)` from `AllPallys` data
3. Iterates `CurrentBuffs[classID]` to find a valid target via `SpellCanTargetUnit(unit)`
4. Falls back to self-cast if no target found
5. Restores auto-self-cast after a 1-second timeout in `OnUpdate`

### Slash Commands
- `/pp` or `/pallypower` — toggle main assignment UI frame
- `/pp report` — print assignments to raid/party chat
- `/pp debug` — toggle debug mode (`PP_DebugEnabled`)

### Localization
Single file `localization.lua` with English as default, German (`deDE`) and French (`frFR`) overrides via `GetLocale()` checks. Key globals:
- `PallyPower_BlessingID[0..5]` — blessing names
- `PallyPower_ClassID[0..9]` — class names
- `PallyPower_BlessingSpellSearch` / `PallyPower_RankSearch` — patterns for spellbook scanning
- `PallyPower_Symbol` — reagent name for inventory scanning

### Performance Best Practices
- Avoid creating tables in hot paths (`OnUpdate`, event handlers) — reuse existing tables
- Use `table_wipe(t)` (local helper that nils all keys) instead of re-allocating tables
- Place early-exit guards before allocations
- Debounce UI updates — set `uiDirty = true` and let `OnUpdate` batch the refresh
- Use `RosterSet` for O(1) unit membership checks instead of scanning arrays
- Use `table.getn()` not `#` (Lua 5.0)
- Lua 5.0 has no `continue` — use `repeat...until true` inside loops:
```lua
for i = 1, n do repeat
    if not condition then break end  -- acts as "continue"
    -- main logic here
until true end
```
