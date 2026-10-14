MANAGE FALLEN ITEMS - a spell mod for RuneScape: Dragonwilds (UE4SS Lua mod)

What it does
  Adds the spell "Manage Fallen Items" (15 Fire + 15 Law runes). Every character has it unlocked, and it
  goes into the first empty spell-wheel slot the first time. Casting it opens the game's chest window
  beside your backpack, holding every item lying on the ground in the loaded part of the world: one cell
  per kind of item, most plentiful first, labelled with the total on the ground (1.5K = 1,500, 20M =
  20 million). It scrolls when there are more kinds than fit. It works like any chest:
    Hover          - the item's usual tooltip.
    Drag / Split   - moves up to one stack (the cell holds one stack at a time and refills from the ground).
    Ctrl+click     - Transfer: takes ALL of that item, filling as many slots as needed (gear fills the
                     hotbar too, as with any chest), until there is no more room.
    Hold X         - Destroy: destroys all of that item on the ground (quest items are never destroyed).
    R (Take All)   - takes everything that fits, one item after another, until the backpack is full.
  Like any chest, Transfer and Take All can leave you encumbered; set StopAtCarryWeight = true in
  config.txt to stop before that instead.
  Masterwork-upgraded gear is not listed; pick it up by hand so the upgrades survive. Items cannot be put
  into this chest. Close it like any chest. It updates live while open.

Install
  Needs RE-UE4SS (experimental build for UE 5.6) installed in RSDragonwilds\Binaries\Win64.
  Copy the ManageFallenItems folder into RSDragonwilds\Binaries\Win64\ue4ss\Mods\ (it contains
  enabled.txt, so UE4SS loads it). Settings are in config.txt.

Multiplayer
  Everyone in the session needs the same version of the mod, including a dedicated server. The chest
  opens for whoever casts the spell, host or not. Ground items belong to the host, so for anyone else
  the host's copy of the mod builds their chest and sends it to their game; everything works as above.
  The count on a cell is the total their game can see, which is the fallen items fairly near them.

Uninstalling (important)
  A character that has this spell will not load without the mod: the game rejects saves that mention a
  spell it does not know ("Corrupted Save File"). That is true for any mod that adds a spell. The world
  save is not affected. A dedicated uninstall option is not included; back up your character saves
  (%LOCALAPPDATA%\RSDragonwilds\Saved\SaveCharacters) before trying the mod on a character you care about.
