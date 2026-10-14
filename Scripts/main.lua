-- Manage Fallen Items - RuneScape: Dragonwilds
--
-- Adds the utility spell "Manage Fallen Items" (15 Fire + 15 Law runes by default). Casting it opens the
-- game's chest window beside your backpack, holding every item lying on the ground in the loaded world:
-- one cell per kind of item, labelled with the total on the ground. Take, drag, split, Transfer, Destroy
-- and Take All work as on any chest (see "Chest window" below). The chest refreshes while open: right
-- away when a new item hits the ground, and every RefreshSeconds for everything else.
--
-- How the spell exists:
--   * It is a UtilitySpellData built at startup as a copy of the game's Personal Chest spell (same
--     montage, icon and cast flow), with the Personal Chest effect removed and the cost changed.
--   * It is registered in UtilitySpellDataSubsystem under a permanent persistence ID BEFORE any save
--     loads. The game loads saves in strict mode: a save naming a spell it does not know fails to load
--     ("Corrupted Save File"). With the mod installed the ID is known, so saves load normally.
--     UNINSTALLING: a character that had this spell will not load without the mod (the same rule every
--     content mod in this game lives under). See README.txt for how to remove it from a character first.
--   * The network ID is appended after the game's own spells, so host and clients agree on it when both
--     run the mod.
--   * The cast is recognised by the game's own cast broadcast (PlayerMagicComponent
--     Multicast_SendPayloadForSpellCasting) carrying our network ID; the panel opens once the runes are paid.
--
-- Ground items are AWorldItem actors. The game pools them: a "destroyed" stack stays in memory with a
-- stack size of 0, parked at the world origin, so the scan skips anything with stack size 0.
-- Collect: AddItemByData (capped by GetSpaceAvailableForItemByData) with the ground item's durability, then
-- RemoveFromStack for a partial pickup or K2_DestroyActor for a whole one. Every add is measured.
-- Masterwork-upgraded gear is left on the ground (its upgrades cannot be recreated); pick it up by hand.
-- Only the host can change ground items. A client's chest sends each action to the host's copy of the
-- mod, which carries it out on that client's backpack (see "Clients" below).
--
-- Crash rules learned on this game (do not break them):
--   * never call RuntimeSpawnedWorldItem:HandleInteraction or SetLifeSpan on a world item;
--   * never build soft object references from Lua (MakeSoftObjectPath & co. crash), never read them;
--   * never call functions that return a const TArray reference (SkillPerkComponent:GetPerksForSkill);
--   * LoadAsset does not work on this UE4SS build; icons are used only if already loaded.

local TAG = "[ManageFallenItems] "
local function log(msg) print(TAG .. tostring(msg) .. "\n") end

local SPELL_NAME = "USD_ManageFallenItems"
local SPELL_PID = "MFI-ManageFallenItems-v1"
local SPELL_INTERNAL = "spell_managefallenitems"
local TEMPLATE = "/Game/Gameplay/UtilityMagic/PerkSpells/AccessPersonalChest/USD_AccessPersonalChest.USD_AccessPersonalChest"
local FIRE_RUNE = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Fire.ITEM_Rune_Fire"
local LAW_RUNE = "/Game/Gameplay/Items/Resources/Magic/ITEM_Rune_Law.ITEM_Rune_Law"

local cfg = {
    FireRunes = 15,
    LawRunes = 15,
    CooldownSeconds = 2,
    AddToSpellWheel = true,     -- put the spell in the first empty wheel slot when it is first unlocked
    RefreshSeconds = 1.0,       -- how often the open chest re-reads the ground
    ProtectQuestItems = true,   -- destroying never destroys quest / key items
    VisibleRows = 5,            -- rows of cells shown before the chest scrolls (8 cells per row)
    StopAtCarryWeight = false,  -- Transfer / Take All stop before you would become encumbered (chests do not)
    OpenKey = "none",           -- optional hotkey that opens the chest without casting, e.g. "CTRL+G"
    DevCommandFile = false,     -- development only: run Mods/ManageFallenItems/cmd.lua when it changes
}

local function modRoot()
    local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
    return src:match("^(.*)[/\\]Scripts[/\\]")
end

local function loadConfig()
    local root = modRoot()
    if not root then return end
    local f = io.open(root .. "\\config.txt", "r")
    if not f then return end
    for raw in f:lines() do
        local line = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^([%w_]+)%s*=%s*(.+)$")
            if k and v and cfg[k] ~= nil then
                v = v:gsub("%s*#.*$", "")
                if type(cfg[k]) == "boolean" then cfg[k] = (v:lower() == "true" or v == "1")
                elseif type(cfg[k]) == "number" then cfg[k] = tonumber(v) or cfg[k]
                else cfg[k] = v end
            elseif k then
                log("unknown config key ignored: " .. k)
            end
        end
    end
    f:close()
end
loadConfig()
cfg.FireRunes = math.max(1, math.floor(cfg.FireRunes))
cfg.LawRunes = math.max(1, math.floor(cfg.LawRunes))
cfg.RefreshSeconds = math.max(0.25, cfg.RefreshSeconds)
cfg.VisibleRows = math.max(1, math.floor(cfg.VisibleRows))

-- Helpers ------------------------------------------------------------------------------------------
local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end

local function fullName(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and tostring(n) or nil
end

local function objPath(o)
    return (fullName(o) or ""):match("^%S+ (.+)$") or ""
end

local function isDefault(o)
    local ok, n = pcall(function() return o:GetFName():ToString() end)
    return not ok or tostring(n):find("^Default__") ~= nil
end

local function firstLive(className)
    local ok, all = pcall(FindAllOf, className)
    if not ok or not all then return nil end
    for _, o in ipairs(all) do
        if valid(o) and not isDefault(o) then return o end
    end
    return nil
end

local function commas(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Spell ---------------------------------------------------------------------------------------------
local SPELL = { obj = nil, netId = nil, sub = nil, nextTry = 0, warned = false }

local function configureSpell(s)
    s.SpellDisplayName = FText("Manage Fallen Items")
    s.SpecialRequirementsText = FText("")
    s.PersistenceID = SPELL_PID
    s.InternalName = SPELL_INTERNAL
    s.CooldownDuration = cfg.CooldownSeconds
    s.OwningPerk = nil
    s.bNeedsUnlocking = true
    s.bSoftDeleted = false
    local fire, law = StaticFindObject(FIRE_RUNE), StaticFindObject(LAW_RUNE)
    if not (valid(fire) and valid(law)) then error("rune item data not loaded yet") end
    local keep = {}
    for i = 1, s.Modules.Modules:GetArrayNum() do
        local m = s.Modules.Modules[i].Module
        local cls = m:GetClass():GetFName():ToString()
        if cls == "SpellModule_CostItems" then
            m.ItemsCostInfo[1].ItemData = fire
            m.ItemsCostInfo[1].Count = cfg.FireRunes
            m.ItemsCostInfo[2].ItemData = law
            m.ItemsCostInfo[2].Count = cfg.LawRunes
        end
        -- The Personal Chest spell's GameplayEffect module is what opens the chest. Everything else
        -- (montage, cast, cost) is the game's own and stays.
        if cls ~= "SpellModule_GameplayEffect" then keep[#keep + 1] = { Module = m } end
    end
    s.Modules.Modules = keep
end

-- Builds and registers the spell once per game launch. Runs from the main menu onwards, so the ID is
-- known before any save is loaded.
local function ensureSpell()
    if SPELL.obj and valid(SPELL.obj) and SPELL.netId then return true end
    if os.clock() < SPELL.nextTry then return false end
    SPELL.nextTry = os.clock() + 2
    local sub = firstLive("UtilitySpellDataSubsystem")
    local tmpl = StaticFindObject(TEMPLATE)
    if not (valid(sub) and valid(tmpl)) then return false end
    local ok, err = pcall(function()
        local s = StaticFindObject(objPath(tmpl):gsub("%.[^%.]+$", "") .. "." .. SPELL_NAME)
        if not valid(s) then
            local cls = StaticFindObject("/Script/Dominion.UtilitySpellData")
            -- RF_Public | RF_Standalone: never garbage collected while the game runs.
            s = StaticConstructObject(cls, tmpl:GetOuter(), FName(SPELL_NAME), 0x3, 0, false, false, tmpl)
        end
        if not valid(s) then error("could not create the spell object") end
        configureSpell(s)
        if not sub.DataToNetIdMap:Contains(s) then
            local n = sub.NetIdToData:GetArrayNum()
            sub.NetIdToData[n + 1] = s
            sub.DataToNetIdMap:Add(s, { NetId = n })
        end
        if not sub.PersistenceIDToDataMap:Contains(SPELL_PID) then sub.PersistenceIDToDataMap:Add(SPELL_PID, s) end
        if not sub.InternalNameToDataMap:Contains(SPELL_INTERNAL) then sub.InternalNameToDataMap:Add(SPELL_INTERNAL, s) end
        local id = sub.DataToNetIdMap:Find(s)
        local netId = nil
        pcall(function() netId = id:get().NetId end)
        if netId == nil then pcall(function() netId = id.NetId end) end
        SPELL.obj, SPELL.sub, SPELL.netId = s, sub, netId
    end)
    if not ok then
        if not SPELL.warned then SPELL.warned = true; log("spell not ready yet: " .. tostring(err)) end
        return false
    end
    log(string.format("spell registered (net id %s, cost %d fire + %d law)", tostring(SPELL.netId), cfg.FireRunes, cfg.LawRunes))
    return true
end

-- Player -------------------------------------------------------------------------------------------
local P = { pc = nil, pcName = nil, readyAt = 0, setupDone = false, nextScan = 0,
            sawLocked = false, granted = {}, nextGrant = 0 }

local function localPC()
    if P.pc and valid(P.pc) then return P.pc end
    P.pc = nil
    if os.clock() < P.nextScan then return nil end
    P.nextScan = os.clock() + 2
    local ok, all = pcall(FindAllOf, "DominionPlayerController")
    if not ok or not all then return nil end
    for _, pc in ipairs(all) do
        if valid(pc) and not isDefault(pc) then
            local okL, isLocal = pcall(function() return pc:IsLocalController() end)
            local okP, pawn = pcall(function() return pc.Pawn end)
            if okL and isLocal and okP and valid(pawn) then
                P.pc = pc
                return pc
            end
        end
    end
    return nil
end

local function pawnOf(pc)
    local p = nil
    pcall(function() p = pc.Pawn end)
    return valid(p) and p or nil
end

local function isHost(pc)
    local ok, h = pcall(function() return pc:HasAuthority() end)
    return ok and h == true
end

local function spellUnlocked(prog)
    local unlocked = false
    pcall(function() unlocked = prog:IsSpellUnlocked(SPELL.obj) end)
    return unlocked == true
end

-- Unlocking is server-authoritative, so only a copy with authority calls UnlockSpells; it does so for
-- every connected player (a dedicated server has no local player). Returns unlocked, newlyUnlocked.
local function unlockFor(pc)
    local prog = nil
    pcall(function() prog = pc.BP_Components_Progress end)
    if not valid(prog) then return false, false end
    if spellUnlocked(prog) then return true, false end
    if not isHost(pc) then return false, false end
    pcall(function() prog:UnlockSpells({ SPELL.obj }) end)
    if not spellUnlocked(prog) then return false, false end
    return true, true
end

local function grantAll()
    if os.clock() < P.nextGrant then return end
    P.nextGrant = os.clock() + 3
    local ok, all = pcall(FindAllOf, "DominionPlayerController")
    if not ok or not all then return end
    for _, pc in ipairs(all) do
        if valid(pc) and not isDefault(pc) and isHost(pc) and valid(pawnOf(pc)) then
            local name = fullName(pc)
            if name and not P.granted[name] then
                local unlocked, new = unlockFor(pc)
                if unlocked then
                    P.granted[name] = true
                    if new then log("spell unlocked for " .. name) end
                end
            end
        end
    end
end

-- Once per character. The game puts a newly unlocked spell on the wheel by itself, a moment later;
-- tidyWheel runs after that and only fills in if the game did not. A client waits for the unlock to
-- arrive from the host and treats it as new if it was seen locked first.
local function setupCharacter(pc)
    local unlocked, new = unlockFor(pc)
    if not unlocked then
        local prog = nil
        pcall(function() prog = pc.BP_Components_Progress end)
        if valid(prog) then P.sawLocked = true end
        return false
    end
    if new or P.sawLocked then
        log("spell unlocked for this character")
        P.justUnlocked = true
    end
    P.sawLocked = false
    return true
end

-- Keeps exactly one copy of the spell on the wheel. UObject wrappers from UE4SS are not comparable
-- with ==, so slots are compared by full name.
local function tidyWheel(pc)
    local sc = nil
    pcall(function() sc = pc.SpellcastingComponent end)
    if not valid(sc) then return end
    local mine = fullName(SPELL.obj)
    local slots, n = nil, 0
    pcall(function() slots = sc.SelectedSpells; n = slots:GetArrayNum() end)
    local found, firstEmpty = {}, nil
    for i = 1, n do
        local cur = nil
        pcall(function() cur = slots[i] end)
        if valid(cur) then
            if fullName(cur) == mine then found[#found + 1] = i end
        elseif not firstEmpty then
            firstEmpty = i
        end
    end
    for k = 2, #found do
        pcall(function() sc:Server_UpdateSpellData(nil, found[k] - 1) end)
        log("removed duplicate from wheel slot " .. found[k])
    end
    if #found == 0 and P.justUnlocked and cfg.AddToSpellWheel then
        if firstEmpty then
            pcall(function() sc:Server_UpdateSpellData(SPELL.obj, firstEmpty - 1) end)
            log("spell placed in wheel slot " .. firstEmpty)
        else
            log("spell wheel is full; assign Manage Fallen Items from the spellbook")
        end
    end
    P.justUnlocked = false
end

-- Inventory ----------------------------------------------------------------------------------------
-- The backpack is one inventory in fixed sections (hotbar, main backpack, rune pouch, quiver, quest).
-- Collected items are added the way the game adds them (AddItemByData), so each lands in the section
-- a chest transfer would put it in.
local function bagOf(pc)
    local b = nil
    pcall(function() b = pc.BP_Components_Inventory end)
    return valid(b) and b or nil
end

local function readSlot(inv, i)
    local it = nil
    local ok = pcall(function() it = inv:GetItemFromSlot(i) end)
    if not ok then return false, nil, 0 end
    if not valid(it) then return true, nil, 0 end
    local d, n = nil, 0
    pcall(function() d = it.ItemData end)
    pcall(function() n = inv:GetNumItemsInSlot(i) end)
    if valid(d) and type(n) == "number" and n > 0 then return true, d, n end
    return true, nil, 0
end

local function wouldBeEncumbered(pawn, extra)
    local comp = nil
    pcall(function() comp = pawn:GetPlayerEncumbranceComponent() end)
    if not valid(comp) then return nil end
    local ok, v = pcall(function() return comp:IsOrWillBecomeEncumbered(extra) end)
    if not ok or type(v) ~= "boolean" then return nil end
    return v
end

-- The most of `amount` you can carry without becoming encumbered (binary search), nil if unreadable.
local function carryable(pawn, data, amount)
    local w = 0
    pcall(function() w = tonumber(data:GetRawWeight()) or 0 end)
    if w <= 0 then return amount end
    local top = wouldBeEncumbered(pawn, w * amount)
    if top == nil then return nil end
    if top == false then return amount end
    local lo, hi = 0, amount
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local enc = wouldBeEncumbered(pawn, w * mid)
        if enc == nil then return nil end
        if enc then hi = mid - 1 else lo = mid end
    end
    return lo
end

-- Ground -------------------------------------------------------------------------------------------
local function stackSize(w)
    local n = 0
    pcall(function() n = w:GetStackSize() end)
    return type(n) == "number" and n or 0
end

local function maxStack(data)
    local cap = 1
    pcall(function() cap = data.MaxStackSize end)
    if type(cap) ~= "number" or cap < 1 then cap = 1 end
    return cap
end

-- Takes n items off a ground stack: the whole actor goes when nothing would be left.
local function takeFromStack(actor, n)
    if n >= stackSize(actor) then
        pcall(function() actor:K2_DestroyActor() end)
    else
        pcall(function() actor:RemoveFromStack(n) end)
    end
end

local function isQuestItem(data)
    local p = objPath(data):lower()
    return p:find("/key/", 1, true) ~= nil or p:find("item_quest", 1, true) ~= nil or p:find("/quest/", 1, true) ~= nil
end

local function durabilityPct(w)
    local pct = 1.0
    pcall(function()
        local it = w.MagneticComponentGrantItem.SpawnedItem
        local mx = it:GetMaxDurability()
        if type(mx) == "number" and mx > 0 then pct = math.max(0, math.min(1, it.Durability / mx)) end
    end)
    return pct
end

local function masterworked(w)
    local n = 0
    pcall(function() n = w.MagneticComponentGrantItem.SpawnedItem.NumMasterworkUpgradesApplied end)
    return type(n) == "number" and n > 0
end

-- groups: list of { key, data, name, total, stacks = { {actor, n, dist} } }, sorted by total desc.
-- Masterwork-upgraded gear is not listed: its upgrades cannot be recreated, so it is picked up by hand.
local function scanGround(pawn)
    local ok, all = pcall(FindAllOf, "WorldItem")
    local byKey, groups = {}, {}
    if not ok or not all then return groups end
    for _, w in ipairs(all) do
        if valid(w) and not isDefault(w) then
            local n = stackSize(w)
            local flying = false
            pcall(function()
                local mc = w.MagneticComponentGrantItem
                flying = valid(mc) and valid(mc.Target)
            end)
            local manip = false
            pcall(function() manip = w:IsBeingManipulated() == true end)
            local d = nil
            pcall(function() d = w.ItemData end)
            if n > 0 and not flying and not manip and valid(d) and not masterworked(w) then
                local key = fullName(d)
                local g = byKey[key]
                if not g then
                    local name = "?"
                    pcall(function() name = d.Name:ToString() end)
                    g = { key = key, data = d, name = name, total = 0, stacks = {}, nearest = math.huge }
                    byKey[key] = g
                    groups[#groups + 1] = g
                end
                local dist = math.huge
                if pawn then pcall(function() dist = pawn:GetDistanceTo(w) / 100 end) end
                g.total = g.total + n
                g.stacks[#g.stacks + 1] = { actor = w, n = n, dist = dist }
                if dist < g.nearest then g.nearest = dist end
            end
        end
    end
    table.sort(groups, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.name < b.name
    end)
    for _, g in ipairs(groups) do table.sort(g.stacks, function(a, b) return a.dist < b.dist end) end
    return groups
end

-- keys: set of item keys to act on, or nil for everything.
local function onlyKeys(groups, keys)
    if not keys then return groups end
    local out = {}
    for _, g in ipairs(groups) do if keys[g.key] then out[#out + 1] = g end end
    return out
end

-- Collect everything that fits in the backpack (and the carry weight, with StopAtCarryWeight).
-- Returns a plain-words summary.
local function collectAll(pc, keys)
    local pawn, inv = pawnOf(pc), bagOf(pc)
    if not (pawn and inv) then return "Could not read your backpack." end
    local groups = onlyKeys(scanGround(pawn), keys)
    if #groups == 0 then return "Nothing to collect." end
    local moved, kinds, left = 0, 0, 0
    local heavy, full = false, false
    local function held(data)
        local n = 0
        pcall(function() n = inv:GetNumItemsByData(data) end)
        return type(n) == "number" and n or 0
    end
    for _, g in ipairs(groups) do
        local gotAny = false
        for _, st in ipairs(g.stacks) do
            local guard = 0
            while guard < 16 do
                guard = guard + 1
                local n = stackSize(st.actor)
                if n <= 0 then break end
                local can = n
                if cfg.StopAtCarryWeight then can = carryable(pawn, g.data, n) or n end
                if can <= 0 then heavy = true; break end
                local space = 0
                pcall(function() space = inv:GetSpaceAvailableForItemByData(g.data) end)
                if type(space) ~= "number" or space <= 0 then full = true; break end
                local before = held(g.data)
                local pct = durabilityPct(st.actor)
                pcall(function() inv:AddItemByData(g.data, math.min(n, can, space), pct, {}) end)
                local got = held(g.data) - before
                if got <= 0 then full = true; break end
                takeFromStack(st.actor, got)
                moved = moved + got
                gotAny = true
            end
        end
        if gotAny then kinds = kinds + 1 end
    end
    for _, g in ipairs(onlyKeys(scanGround(pawn), keys)) do left = left + g.total end
    local msg = (moved > 0) and ("Collected " .. commas(moved) .. " items (" .. kinds .. (kinds == 1 and " kind)." or " kinds).")) or "Collected nothing."
    local why = {}
    if heavy then why[#why + 1] = "carry weight limit reached" end
    if full then why[#why + 1] = "backpack full" end
    if #why > 0 then msg = msg .. " Stopped: " .. table.concat(why, ", ") .. "." end
    if left > 0 then msg = msg .. " " .. commas(left) .. " still on the ground." end
    log(msg)
    return msg
end

local function destroyAll(pc, keys)
    local groups = onlyKeys(scanGround(pawnOf(pc)), keys)
    local gone, kept = 0, 0
    for _, g in ipairs(groups) do
        if cfg.ProtectQuestItems and isQuestItem(g.data) then
            kept = kept + g.total
        else
            for _, st in ipairs(g.stacks) do
                local n = stackSize(st.actor)
                if n > 0 then
                    pcall(function() st.actor:K2_DestroyActor() end)
                    if stackSize(st.actor) <= 0 then gone = gone + n end
                end
            end
        end
    end
    local msg = "Destroyed " .. commas(gone) .. " items."
    if kept > 0 then msg = msg .. " Kept " .. commas(kept) .. " quest items." end
    log(msg)
    return msg
end

-- Chest window ---------------------------------------------------------------------------------------
-- The list is the game's own chest window (the one every storage chest opens beside your backpack),
-- shown for a virtual chest: an InventoryComponent added to your character holding one stack of each
-- kind of fallen item, in the order of how much of it there is. The game handles tooltips, drag, split,
-- Ctrl+click Transfer, hold-X Destroy and Take All on it as for any chest. Players cannot put items in
-- (bAllowAdds is off), so it only ever holds what the mod put there.
--
-- Those actions run in native code with no hookable call, so the mod watches the chest instead:
-- whatever leaves a cell is taken off the ground stacks, and the cell is topped back up from what is
-- still lying there. What left is told apart afterwards:
--   * it reached your inventory: a move. Dragging or splitting moves at most the one stack in the cell.
--     With Ctrl held (Transfer), Take All pressed, or several kinds leaving at once (Take All), the
--     rest of that item (or of everything, one item after the other) is collected too, until the
--     backpack is full. Like any chest this can leave you encumbered (StopAtCarryWeight stops before);
--   * it did not, with X held: a destroy. The rest of that item on the ground is destroyed too (quest
--     items excepted when ProtectQuestItems is on);
--   * it did not, without X: it was dropped, so the game has put it back on the ground already.
-- The cell shows the total on the ground (1.5K, 20M), not the stack inside it.
local COLS, ROW_PITCH = 8, 69
local SCROLL_STYLE = "/Game/UI/InGameMenus/TopNavScreens/Journal/WBP_JournalListEntryNavWidget.WBP_JournalListEntryNavWidget_C:WidgetTree.BiomeScrollBox"
local XF = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }
local KEY_CTRL_L, KEY_CTRL_R, KEY_X, KEY_R = "LeftControl", "RightControl", "X", "R"

local CHEST = {
    open = false, pc = nil, api = nil, comp = nil, compName = nil, slots = 0,
    keyAt = {}, slotKey = {}, placed = {}, rep = {}, byKey = {}, bag = {}, total = 0,
    nextScan = 0, dirty = false, ctrlAt = -10, xAt = -10, takeAllAt = -10,
    wrap = nil, panel = nil, pending = nil, painted = {},
    client = false, forceClient = false, clickReq = false, takeAllReq = false, xCell = nil, xStart = 0, xSent = false,
}
local DESTROY_HOLD = 1.0
local paintCounts

local function compact(n)
    local function fmt(v, suffix)
        if v < 10 then
            local s = string.format("%.1f", math.floor(v * 10) / 10):gsub("%.0$", "")
            return s .. suffix
        end
        return tostring(math.floor(v)) .. suffix
    end
    if n >= 1e9 then return fmt(n / 1e9, "B") end
    if n >= 1e6 then return fmt(n / 1e6, "M") end
    if n >= 1e3 then return fmt(n / 1e3, "K") end
    return tostring(math.floor(n))
end

local function className(w)
    local ok, n = pcall(function() return w:GetClass():GetFName():ToString() end)
    return ok and n or ""
end

-- The live copy of a game widget (class templates share the class but are not under /Engine/Transient).
local function liveWidget(cls)
    local ok, all = pcall(FindAllOf, cls)
    if not ok or not all then return nil end
    for _, w in ipairs(all) do
        if valid(w) and (fullName(w) or ""):find("/Engine/Transient", 1, true) then return w end
    end
    return nil
end

local function keyDown(pc, name)
    local ok, d = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(name) }) end)
    return ok and d == true
end

-- Scrolling: the chest grid grows with its slot count, so it is put in a scroll box as tall as
-- VisibleRows rows (a 40-slot chest at the default 5). Undone on close: the same window serves every chest.
local function wrapScroll()
    if CHEST.wrap then return end
    local body = liveWidget("WBP_WorldActorInventory_InventoryBody_C")
    if not body then return end
    local vb = body:GetParent()
    if not valid(vb) or className(vb) ~= "VerticalBox" then return end
    local tree = body:GetOuter()
    local kids = {}
    for i = 0, vb:GetChildrenCount() - 1 do
        local c = vb:GetChildAt(i)
        local s = c.Slot
        kids[#kids + 1] = {
            w = c,
            size = { Value = s.Size.Value, SizeRule = s.Size.SizeRule },
            pad = { Left = s.Padding.Left, Top = s.Padding.Top, Right = s.Padding.Right, Bottom = s.Padding.Bottom },
            h = s.HorizontalAlignment, v = s.VerticalAlignment,
        }
    end
    if #kids == 0 or fullName(kids[1].w) ~= fullName(body) then return end
    local box = StaticConstructObject(StaticFindObject("/Script/UMG.SizeBox"), tree)
    local scroll = StaticConstructObject(StaticFindObject("/Script/UMG.ScrollBox"), tree)
    local style = StaticFindObject(SCROLL_STYLE)
    if valid(style) then
        pcall(function() scroll.WidgetBarStyle = style.WidgetBarStyle end)
        pcall(function() scroll.WidgetStyle = style.WidgetStyle end)
        pcall(function() scroll:SetScrollbarThickness({ X = style.ScrollbarThickness.X, Y = style.ScrollbarThickness.Y }) end)
        pcall(function()
            local p = style.ScrollbarPadding
            scroll:SetScrollbarPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
        end)
    end
    box:SetHeightOverride(cfg.VisibleRows * ROW_PITCH + 10)
    box:AddChild(scroll)
    local function place(list, first)
        vb:ClearChildren()
        for i, k in ipairs(list) do
            local s = vb:AddChildToVerticalBox(i == 1 and first or k.w)
            s:SetSize(k.size); s:SetPadding(k.pad); s:SetHorizontalAlignment(k.h); s:SetVerticalAlignment(k.v)
        end
    end
    vb:ClearChildren()
    scroll:AddChild(body)
    place(kids, box)
    CHEST.wrap = { vb = vb, body = body, scroll = scroll, kids = kids, place = place }
end

local function unwrapScroll()
    local w = CHEST.wrap
    CHEST.wrap = nil
    if not w or not (valid(w.vb) and valid(w.body)) then return end
    pcall(function() w.scroll:RemoveChild(w.body) end)
    pcall(function() w.place(w.kids, w.body) end)
end

-- On a client the pawn belongs to the host, which ignores items added to a component on it, so the
-- chest goes on an actor spawned on this machine only (it has authority here and is never replicated).
local function chestOwner(pawn)
    if not CHEST.client then return pawn end
    local a = nil
    pcall(function()
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        a = gs:BeginDeferredActorSpawnFromClass(pawn, StaticFindObject("/Script/Engine.Actor"), XF, 1, nil, 0)
        if valid(a) then gs:FinishSpawningActor(a, XF, 0) end
    end)
    return valid(a) and a or nil
end

local function newChest(pawn, slots)
    local owner = chestOwner(pawn)
    if not owner then return nil end
    local c = owner:AddComponentByClass(StaticFindObject("/Script/Dominion.InventoryComponent"), true, XF, true)
    if not valid(c) then return nil end
    c.MaxSlotCount = slots
    c.bSupportsSortAndFillStacks = false
    owner:FinishAddComponent(c, true, XF)
    c.bAllowAdds = false
    return c
end

local function destroyChest(c)
    if not valid(c) then return end
    local owner = nil
    pcall(function() owner = c:GetOwner() end)
    pcall(function() c:K2_DestroyComponent(c) end)
    if valid(owner) and className(owner) == "Actor" then pcall(function() owner:K2_DestroyActor() end) end
end

local function emptyChest(c)
    if not valid(c) then return end
    local n = 0
    pcall(function() n = c.MaxSlotCount end)
    for i = 0, n - 1 do
        local k = 0
        pcall(function() k = c:GetNumItemsInSlot(i) end)
        if type(k) == "number" and k > 0 then pcall(function() c:RemoveFromSlot(i, k, nil) end) end
    end
end

local function slotsFor(nKinds)
    local visible = cfg.VisibleRows * COLS
    if nKinds <= visible then return visible end
    return (math.ceil(nKinds / COLS) + 1) * COLS
end

-- Each kind keeps its cell while it is on the ground; new kinds take the first free cell.
local function layout(groups)
    for k, i in pairs(CHEST.keyAt) do
        if not CHEST.byKey[k] then CHEST.keyAt[k] = nil; CHEST.slotKey[i] = nil; CHEST.rep[i] = nil end
    end
    for _, g in ipairs(groups) do
        if not CHEST.keyAt[g.key] then
            local i = 0
            while CHEST.slotKey[i] ~= nil do i = i + 1 end
            if i >= CHEST.slots then return false end
            CHEST.keyAt[g.key], CHEST.slotKey[i] = i, g.key
        end
    end
    return true
end

-- Puts the right stack in cell i: up to one full stack of its kind, or for gear (stack size 1) the
-- nearest piece with its own durability, kept the same piece while it stays on the ground.
local function syncSlot(i)
    local comp = CHEST.comp
    local key = CHEST.slotKey[i]
    local g = key and CHEST.byKey[key]
    local want, pct, repName = 0, 1.0, nil
    if g then
        local cap = maxStack(g.data)
        want = math.min(g.total, cap)
        if cap == 1 then
            local r = g.stacks[1].actor
            pct, repName = durabilityPct(r), fullName(r)
        end
    end
    local _, d, n = readSlot(comp, i)
    local ours = d ~= nil and key ~= nil and fullName(d) == key
    local extra = ours and n - (CHEST.placed[i] or 0) or 0
    if d and (not ours or extra > 0) then
        -- Items the mod did not put here (the game let them in) go on the ground at your feet, where
        -- they become fallen items like any other. Never deleted.
        -- On a client the host never accepted the move, so the item is still in the backpack there.
        local amount = ours and extra or 0
        if CHEST.client then
            pcall(function() comp:RemoveFromSlot(i, ours and extra or n, nil) end)
        else
            pcall(function()
                local l = pawnOf(CHEST.pc):K2_GetActorLocation()
                local xf = { Rotation = XF.Rotation, Translation = { X = l.X, Y = l.Y, Z = l.Z }, Scale3D = XF.Scale3D }
                comp:DropItem(i, xf, CHEST.pc, 0, { X = 0, Y = 0, Z = 0 }, amount, false)
            end)
        end
        local _, d1, n1 = readSlot(comp, i)
        local left = ours and (n1 - (CHEST.placed[i] or 0)) or (d1 and n1 or 0)
        if left > 0 then log("could not move an item you put in the chest back out"); CHEST.placed[i] = n1; return end
        n = ours and n1 or 0
        CHEST.dirty = true
    end
    if ours and CHEST.rep[i] ~= repName then
        pcall(function() comp:RemoveFromSlot(i, n, nil) end)
        n = 0
    end
    if want > n and g then
        pcall(function() comp:AddItemByDataToSlot(g.data, i, want - n, pct, {}) end)
    elseif want < n then
        pcall(function() comp:RemoveFromSlot(i, n - want, nil) end)
    end
    local _, d2, n2 = readSlot(comp, i)
    CHEST.placed[i] = (d2 and key and fullName(d2) == key) and n2 or 0
    CHEST.rep[i] = repName
end

local function snapshotBag()
    local bag = bagOf(CHEST.pc)
    CHEST.bag = {}
    if not bag then return end
    for key, g in pairs(CHEST.byKey) do
        local n = 0
        pcall(function() n = bag:GetNumItemsByData(g.data) end)
        CHEST.bag[key] = type(n) == "number" and n or 0
    end
end

local function chestTotal()
    local n = 0
    pcall(function() n = CHEST.comp:GetNumItems() end)
    return type(n) == "number" and n or 0
end

local function closeChest(fromGame)
    if CHEST.open and not fromGame and valid(CHEST.api) then
        pcall(function() CHEST.api:CloseCurrentInventory() end)
    end
    if valid(CHEST.comp) then
        pcall(function() CHEST.comp.bAllowAdds = true end)
        emptyChest(CHEST.comp)
    end
    pcall(paintCounts, true)
    unwrapScroll()
    destroyChest(CHEST.comp)
    CHEST.painted = {}
    CHEST.open, CHEST.comp, CHEST.compName, CHEST.api = false, nil, nil, nil
    CHEST.keyAt, CHEST.slotKey, CHEST.placed, CHEST.rep, CHEST.byKey, CHEST.bag = {}, {}, {}, {}, {}, {}
end

local refreshChest

-- Opens (or re-opens at a bigger size) the game's chest window on a fresh virtual chest.
local function showChest(groups)
    local pawn = pawnOf(CHEST.pc)
    if not (pawn and valid(CHEST.api)) then return false end
    local old = CHEST.comp
    local comp = newChest(pawn, slotsFor(#groups))
    if not comp then log("could not create the chest"); return false end
    CHEST.comp, CHEST.compName, CHEST.slots = comp, fullName(comp), slotsFor(#groups)
    CHEST.slotKey, CHEST.placed, CHEST.rep = {}, {}, {}
    for k, i in pairs(CHEST.keyAt) do CHEST.slotKey[i] = k end
    if valid(old) then
        unwrapScroll()
        pcall(function() CHEST.api:CloseCurrentInventory() end)
        pcall(function() old.bAllowAdds = true end)
        emptyChest(old)
        destroyChest(old)
    end
    refreshChest(groups)
    pcall(function() CHEST.api:ToggleInventory(comp) end)
    CHEST.open = true
    pcall(wrapScroll)
    return true
end

-- Re-reads the ground and brings every cell in line with it.
refreshChest = function(groups)
    groups = groups or scanGround(pawnOf(CHEST.pc))
    local byKey = {}
    for _, g in ipairs(groups) do byKey[g.key] = g end
    CHEST.byKey = byKey
    for key, i in pairs(CHEST.keyAt) do
        local g, rn = byKey[key], CHEST.rep[i]
        if g and rn then
            for j, st in ipairs(g.stacks) do
                if j > 1 and fullName(st.actor) == rn then table.insert(g.stacks, 1, table.remove(g.stacks, j)); break end
            end
        end
    end
    if not layout(groups) then
        if CHEST.open then showChest(groups) end
        return
    end
    pcall(function() CHEST.comp.bAllowAdds = true end)
    for i = 0, CHEST.slots - 1 do syncSlot(i) end
    pcall(function() CHEST.comp.bAllowAdds = false end)
    CHEST.total = chestTotal()
    snapshotBag()
end

-- Something left the chest: work out what happened and do the same to the ground.
local function settleChest()
    local placedBy, present = {}, {}
    for i, key in pairs(CHEST.slotKey) do placedBy[key] = (placedBy[key] or 0) + (CHEST.placed[i] or 0) end
    for i = 0, CHEST.slots - 1 do
        local _, d, n = readSlot(CHEST.comp, i)
        if d then
            local k = fullName(d)
            present[k] = (present[k] or 0) + n
        end
    end
    local gone, kinds = {}, 0
    for key, p in pairs(placedBy) do
        local c = p - (present[key] or 0)
        if c > 0 and CHEST.byKey[key] then gone[key] = c; kinds = kinds + 1 end
    end
    if kinds == 0 then CHEST.total = chestTotal(); return end

    local now = os.clock()
    local pc = CHEST.pc
    local bag = bagOf(pc)
    local takeAll = kinds > 1 or now - CHEST.takeAllAt < 1.0
    local transfer = now - CHEST.ctrlAt < 1.0
    local destroying = now - CHEST.xAt < 1.0
    local collectKeys, destroyKeys = {}, {}
    for key, c in pairs(gone) do
        local g = CHEST.byKey[key]
        local have = 0
        if bag then pcall(function() have = bag:GetNumItemsByData(g.data) end) end
        have = have or 0
        local moved = have > (CHEST.bag[key] or 0)
        local protected = cfg.ProtectQuestItems and isQuestItem(g.data)
        -- Transfer / Take All: the game moved one stack per cell. That stack goes back (it is still on
        -- the ground until settled here) and collectAll takes the items in order, stack after stack,
        -- so when space runs out it is the later items that stay behind. Gear keeps the game's move:
        -- taking a piece back by item type could take one of your own instead.
        local returned = 0
        if moved and (takeAll or transfer) and maxStack(g.data) > 1 and bag then
            pcall(function() bag:RemoveItemByData(g.data, c) end)
            local after = have
            pcall(function() after = bag:GetNumItemsByData(g.data) end)
            returned = math.max(0, math.min(c, have - (after or have)))
        end
        if (moved or not destroying or not protected) and returned < c then
            local left = c - returned
            for _, st in ipairs(g.stacks) do
                if left <= 0 then break end
                local n = stackSize(st.actor)
                local d = nil
                pcall(function() d = st.actor.ItemData end)
                -- Ground actors are pooled: a stack seen at the last scan may hold something else now.
                if n > 0 and fullName(d) == key then
                    local take = math.min(n, left)
                    takeFromStack(st.actor, take)
                    left = left - take
                end
            end
        end
        if moved then
            if takeAll or transfer then collectKeys[key] = true end
        elseif destroying and not protected then
            destroyKeys[key] = true
        end
    end
    if next(collectKeys) then pcall(collectAll, pc, takeAll and nil or collectKeys) end
    if next(destroyKeys) then pcall(destroyAll, pc, destroyKeys) end
    refreshChest()
end

-- Count labels: the game writes the stack size in each cell; the mod writes the ground total over it.
-- The game does not rewrite a label when a cell empties or holds gear (no label), so a label the mod
-- wrote is put back to the game's own when no longer needed, and all of them on close (every chest
-- shares these cells). reset = put every label back.
paintCounts = function(reset)
    local body = CHEST.wrap and CHEST.wrap.body or liveWidget("WBP_WorldActorInventory_InventoryBody_C")
    if not valid(body) then return end
    local cells = nil
    pcall(function() cells = body.InventorySlots end)
    if not cells then return end
    local want = {}
    if not reset then
        for i, key in pairs(CHEST.slotKey) do
            local g = CHEST.byKey[key]
            if g and g.total > 1 then want[i] = compact(g.total) end
        end
    end
    for i, s in pairs(want) do
        pcall(function()
            local tb = cells[i + 1].StackSizeText
            if tb:GetText():ToString() ~= s then tb:SetText(FText(s)) end
            if tb:GetVisibility() ~= 3 then tb:SetVisibility(3) end
        end)
        CHEST.painted[i] = true
    end
    for i in pairs(CHEST.painted) do
        if not want[i] then
            local d, n = nil, 0
            if valid(CHEST.comp) then _, d, n = readSlot(CHEST.comp, i) end
            pcall(function()
                local tb = cells[i + 1].StackSizeText
                if d and maxStack(d) > 1 then
                    tb:SetText(FText(tostring(n)))
                    tb:SetVisibility(3)
                else
                    tb:SetText(FText(""))
                    tb:SetVisibility(1)
                end
            end)
            CHEST.painted[i] = nil
        end
    end
end

-- The game sizes an item tooltip once, when it appears. When a drag is released over a cell, the
-- cell's tooltip gets its controls back but keeps the shorter drag-time size, so a tooltip whose
-- content changes height is shown again.
local function fixTooltip()
    local body = CHEST.wrap and CHEST.wrap.body
    local cells = nil
    if valid(body) then pcall(function() cells = body.InventorySlots end) end
    if cells then
        for i in pairs(CHEST.slotKey) do
            local cell, on, h = nil, false, nil
            pcall(function() cell = cells[i + 1]; on = cell.bIsTooltipSpawned and cell.bIsMousedOver end)
            if on then
                pcall(function() h = cell.CurrentSlotTooltip:GetDesiredSize().Y end)
                if not h or h <= 1 then return end
                if CHEST.ttCell == i and CHEST.ttH and math.abs(h - CHEST.ttH) > 1 then
                    pcall(function() cell:DespawnTooltip(); cell:SpawnTooltip() end)
                    CHEST.ttCell, CHEST.ttH = i, nil
                else
                    CHEST.ttCell, CHEST.ttH = i, h
                end
                return
            end
        end
    end
    CHEST.ttCell, CHEST.ttH = nil, nil
end

-- Clients ---------------------------------------------------------------------------------------------
-- Ground items belong to the host, so on a client the game refuses every move out of the chest. A client
-- reads the input instead (Ctrl+click or hold X on the cell under the mouse, R) and asks the host's copy
-- of the mod to do it, through the game's own pickup request: Server_RequestInteraction naming a ground
-- item's collision box but no interaction component. A real pickup always names its component, and the
-- game ignores a request without one, so only the mod acts on it. The two flags carry the action.
local REQUEST_FLAGS = { transfer = { false, false }, destroy = { true, false }, takeAll = { false, true } }

local function hoveredCell()
    local body = CHEST.wrap and CHEST.wrap.body
    local cells = nil
    if valid(body) then pcall(function() cells = body.InventorySlots end) end
    if not cells then return nil end
    for i in pairs(CHEST.slotKey) do
        local on = false
        pcall(function() on = cells[i + 1].bIsMousedOver end)
        if on then return i end
    end
    return nil
end

local function interactionManager(pawn)
    local m = nil
    pcall(function() m = pawn.BP_Components_InteractionManager end)
    return valid(m) and m or nil
end

-- key: the item kind, or nil (Take All) for any.
local function sendRequest(action, key)
    local mgr = interactionManager(pawnOf(CHEST.pc))
    if not mgr then log("could not reach the host"); return end
    local col = nil
    for k, g in pairs(CHEST.byKey) do
        if key == nil or k == key then
            for _, st in ipairs(g.stacks) do
                local c, d = nil, nil
                pcall(function() c = st.actor.InteractionCollision; d = st.actor.ItemData end)
                if valid(c) and stackSize(st.actor) > 0 and fullName(d) == k then col = c; break end
            end
        end
        if col then break end
    end
    if not col then return end
    local f = REQUEST_FLAGS[action]
    pcall(function() mgr:Server_RequestInteraction(nil, col, f[1], f[2]) end)
    CHEST.nextScan = os.clock() + 0.3
end

local function clientInput()
    local pc, now = CHEST.pc, os.clock()
    if CHEST.clickReq then
        CHEST.clickReq = false
        local i = hoveredCell()
        if i and CHEST.slotKey[i] then sendRequest("transfer", CHEST.slotKey[i]) end
    end
    if CHEST.takeAllReq then
        CHEST.takeAllReq = false
        sendRequest("takeAll", nil)
    end
    if keyDown(pc, KEY_X) then
        local i = hoveredCell()
        if i ~= CHEST.xCell then CHEST.xCell, CHEST.xStart, CHEST.xSent = i, now, false end
        if i and not CHEST.xSent and now - CHEST.xStart >= DESTROY_HOLD and CHEST.slotKey[i] then
            CHEST.xSent = true
            sendRequest("destroy", CHEST.slotKey[i])
        end
    else
        CHEST.xCell = nil
    end
end

-- Host side: requests from any player (the host's own forced-client tests included) are queued here and
-- carried out in the main tick, on that player's backpack.
local HOST = { queue = {} }

pcall(RegisterHook, "/Script/Dominion.PlayerInteractionManager:Server_RequestInteraction", function(self, ic, col, sec, rel)
    local comp = nil
    pcall(function() comp = ic:get() end)
    if valid(comp) then return end
    local mgr, c, pawn, item = nil, nil, nil, nil
    pcall(function() mgr = self:get() end)
    pcall(function() c = col:get() end)
    if not (valid(mgr) and valid(c)) then return end
    pcall(function() pawn = mgr:GetOwner() end)
    pcall(function() item = c:GetOwner() end)
    local auth = false
    pcall(function() auth = pawn:HasAuthority() end)
    if not (auth and valid(item)) then return end
    local s, r = false, false
    pcall(function() s = sec:get() end)
    pcall(function() r = rel:get() end)
    local action = nil
    for name, f in pairs(REQUEST_FLAGS) do if f[1] == s and f[2] == r then action = name end end
    local key = nil
    pcall(function() key = fullName(item.ItemData) end)
    if action and key then HOST.queue[#HOST.queue + 1] = { pawn = pawn, action = action, key = key } end
end)

local function serveRequests()
    local q = HOST.queue
    if #q == 0 then return end
    HOST.queue = {}
    for _, r in ipairs(q) do
        local pc = nil
        pcall(function() pc = r.pawn.Controller end)
        if valid(pc) then
            if r.action == "transfer" then pcall(collectAll, pc, { [r.key] = true })
            elseif r.action == "takeAll" then pcall(collectAll, pc, nil)
            elseif r.action == "destroy" then pcall(destroyAll, pc, { [r.key] = true }) end
        end
    end
    CHEST.dirty = true
end

local function openChest()
    if CHEST.open then return end
    local pc = localPC()
    if not valid(pc) then return end
    local api = firstLive("WorldActorInventoryUIAPI")
    if not valid(api) then log("chest window not available yet"); return end
    CHEST.client = CHEST.forceClient or not isHost(pc)
    CHEST.clickReq, CHEST.takeAllReq, CHEST.xCell = false, false, nil
    CHEST.pc, CHEST.api = pc, api
    CHEST.keyAt, CHEST.byKey = {}, {}
    local groups = scanGround(pawnOf(pc))
    if not showChest(groups) then closeChest(true); return end
    CHEST.nextScan = os.clock() + cfg.RefreshSeconds
end

-- Runs every tick while the chest is open.
local function chestTick()
    if not (valid(CHEST.comp) and valid(CHEST.api) and valid(CHEST.pc)) then closeChest(true); return end
    local shown, visible = nil, false
    pcall(function() shown = fullName(CHEST.api.InventoryComponent) end)
    if not valid(CHEST.panel) then CHEST.panel = liveWidget("WBP_WorldActorInventory_MainPanel_C") end
    pcall(function() visible = CHEST.panel:IsVisible() end)
    if shown ~= CHEST.compName or not visible then closeChest(true); return end

    local pc, now = CHEST.pc, os.clock()
    if keyDown(pc, KEY_CTRL_L) or keyDown(pc, KEY_CTRL_R) then CHEST.ctrlAt = now end
    if keyDown(pc, KEY_X) then CHEST.xAt = now end
    if keyDown(pc, KEY_R) then CHEST.takeAllAt = now end

    if chestTotal() ~= CHEST.total then
        if CHEST.client then refreshChest() else settleChest() end
        CHEST.nextScan = now + cfg.RefreshSeconds
    elseif CHEST.dirty or now >= CHEST.nextScan then
        CHEST.dirty = false
        CHEST.nextScan = now + cfg.RefreshSeconds
        refreshChest()
    end
    paintCounts()
    fixTooltip()
end

-- Runs every frame while the chest is open. A transfer empties the cell; refilling it on the very next
-- frame keeps its icon from visibly blinking out.
local function chestFastTick()
    if not (CHEST.open and valid(CHEST.comp) and valid(CHEST.pc)) then return end
    if CHEST.client then
        clientInput()
        if chestTotal() ~= CHEST.total then refreshChest(); paintCounts() end
        return
    end
    if chestTotal() == CHEST.total then return end
    local pc, now = CHEST.pc, os.clock()
    if keyDown(pc, KEY_CTRL_L) or keyDown(pc, KEY_CTRL_R) then CHEST.ctrlAt = now end
    if keyDown(pc, KEY_X) then CHEST.xAt = now end
    if keyDown(pc, KEY_R) then CHEST.takeAllAt = now end
    settleChest()
    paintCounts()
    CHEST.nextScan = now + cfg.RefreshSeconds
end

-- Cast detection ------------------------------------------------------------------------------------
local CAST = { at = nil, fire = 0, law = 0 }

local function runeCounts(pc)
    local inv = bagOf(pc)
    local f, l = 0, 0
    if inv then
        pcall(function() f = inv:GetNumItemsByData(StaticFindObject(FIRE_RUNE)) end)
        pcall(function() l = inv:GetNumItemsByData(StaticFindObject(LAW_RUNE)) end)
    end
    return f or 0, l or 0
end

pcall(RegisterHook, "/Script/Dominion.PlayerMagicComponent:Multicast_SendPayloadForSpellCasting", function(self, netIdParam)
    if not SPELL.netId then return end
    local id = nil
    pcall(function() id = netIdParam:get().NetId end)
    if id ~= SPELL.netId then return end
    local pc = P.pc
    if not valid(pc) then return end
    local mine = false
    pcall(function() mine = self:get():GetOwner() == pc.Pawn end)
    if not mine then
        pcall(function() mine = fullName(self:get():GetOwner()) == fullName(pc.Pawn) end)
    end
    if not mine then return end
    CAST.at = os.clock()
    CAST.fire, CAST.law = runeCounts(pc)
end)

-- New ground items mark the open chest dirty, so drops show up at once.
pcall(NotifyOnNewObject, "/Script/Dominion.WorldItem", function() CHEST.dirty = true end)

-- Take All and Transfer are also caught as they happen, so a quick tap between ticks is not missed.
pcall(RegisterKeyBind, Key.R, function()
    CHEST.takeAllAt = os.clock()
    if CHEST.open and CHEST.client then CHEST.takeAllReq = true end
end)
pcall(RegisterKeyBind, Key.LEFT_MOUSE_BUTTON, { ModifierKey.CONTROL }, function()
    CHEST.ctrlAt = os.clock()
    if CHEST.open and CHEST.client then CHEST.clickReq = true end
end)

local function bindOpenKey()
    local k = tostring(cfg.OpenKey or ""):upper()
    if k == "" or k == "NONE" then return end
    local mods, key = {}, nil
    for part in k:gmatch("[^%+%s]+") do
        if part == "CTRL" or part == "CONTROL" then mods[#mods + 1] = ModifierKey.CONTROL
        elseif part == "ALT" then mods[#mods + 1] = ModifierKey.ALT
        elseif part == "SHIFT" then mods[#mods + 1] = ModifierKey.SHIFT
        else key = Key[part] end
    end
    if not key then log("OpenKey not understood: " .. k); return end
    local fn = function() CHEST.pending = CHEST.open and "close" or "open" end
    if #mods > 0 then pcall(RegisterKeyBind, key, mods, fn) else pcall(RegisterKeyBind, key, fn) end
    log("OpenKey bound: " .. k)
end
bindOpenKey()

pcall(RegisterConsoleCommandHandler, "mfi", function()
    CHEST.pending = "open"
    return true
end)

-- Dev command file ----------------------------------------------------------------------------------
local DEV = { last = nil, nextCheck = 0 }
local function devPoll()
    if not cfg.DevCommandFile or os.clock() < DEV.nextCheck then return end
    DEV.nextCheck = os.clock() + 1
    local root = modRoot()
    local f = root and io.open(root .. "\\cmd.lua", "rb")
    if not f then return end
    local src = f:read("*a"); f:close()
    if src == DEV.last then return end
    DEV.last = src
    local buf = {}
    local env = setmetatable({
        MFI = { cfg = cfg, SPELL = SPELL, P = P, CHEST = CHEST, CAST = CAST, scanGround = scanGround, collectAll = collectAll,
                destroyAll = destroyAll, openChest = openChest, closeChest = closeChest, refreshChest = refreshChest,
                compact = compact, setupCharacter = setupCharacter, localPC = localPC, isQuestItem = isQuestItem },
        P = function(...)
            local t = {}
            for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
            buf[#buf + 1] = table.concat(t, " ")
        end,
    }, { __index = _G })
    local chunk, err = load(src, "cmd", "t", env)
    if not chunk then buf[#buf + 1] = "COMPILE ERROR: " .. tostring(err)
    else
        local ok, e = xpcall(chunk, debug.traceback)
        if not ok then buf[#buf + 1] = "RUNTIME ERROR: " .. tostring(e) end
    end
    buf[#buf + 1] = "--DONE " .. os.date("%H:%M:%S")
    local o = io.open(root .. "\\out.txt", "wb")
    if o then o:write(table.concat(buf, "\n")); o:close() end
end

-- Main tick (game thread) ---------------------------------------------------------------------------
local tickErrors = 0
local function tick()
    pcall(devPoll)
    if not ensureSpell() then return end
    serveRequests()
    pcall(grantAll)

    local pc = localPC()
    if not valid(pc) then
        if CHEST.open then closeChest(true) end
        P.setupDone, P.pcName = false, nil
        return
    end
    local name = fullName(pc)
    if name ~= P.pcName then
        P.pcName, P.setupDone, P.readyAt, P.sawLocked = name, false, os.clock() + 3, false
        if CHEST.open then closeChest(true) end
    end
    if not P.setupDone and os.clock() >= P.readyAt then
        local ok, done = pcall(setupCharacter, pc)
        if ok and done then P.setupDone, P.wheelAt = true, os.clock() + 3 else P.readyAt = os.clock() + 2 end
    end
    if P.wheelAt and os.clock() >= P.wheelAt then
        P.wheelAt = nil
        pcall(tidyWheel, pc)
    end

    -- A cast of our spell: open once the runes have been paid (or give up if the cast was cancelled).
    if CAST.at then
        local f, l = runeCounts(pc)
        if f < CAST.fire or l < CAST.law then
            CAST.at = nil
            if not CHEST.open then CHEST.pending = "open" end
        elseif os.clock() - CAST.at > 6 then
            CAST.at = nil
        end
    end

    local action = CHEST.pending
    CHEST.pending = nil
    if action == "open" then
        openChest()
    elseif action == "close" and CHEST.open then
        closeChest(false)
    end

    if CHEST.open then chestTick() end
end

local function mainTick()
    local ok, err = pcall(tick)
    if not ok then
        tickErrors = tickErrors + 1
        if tickErrors <= 5 then log("tick error: " .. tostring(err)) end
    end
end

local okLoop = pcall(LoopInGameThreadWithDelay, 100, mainTick)
if okLoop then
    pcall(LoopInGameThreadWithDelay, 1, function()
        local ok, err = pcall(chestFastTick)
        if not ok then
            tickErrors = tickErrors + 1
            if tickErrors <= 5 then log("fast tick error: " .. tostring(err)) end
        end
    end)
else
    local queued, queuedAt = false, 0
    LoopAsync(100, function()
        if queued and os.clock() - queuedAt > 5 then queued = false end
        if queued then return false end
        queued, queuedAt = true, os.clock()
        local sent = pcall(ExecuteInGameThread, function() queued = false; mainTick() end)
        if not sent then queued = false end
        return false
    end)
end
log("loaded (" .. (okLoop and "game-thread loop" or "async loop") .. ")")
