-- LootTracker currency set
-- Classic, TBC, and WotLK dungeon/raid/PvP currencies that we want
-- to bucket under a separate "Currencies" tab instead of mixing into
-- boss loot. Edit by hand if your server adds custom emblems / marks.

LootTracker_Currencies = {
    -- Classic PvP Marks of Honor
    [17326] = 1, -- Alterac Valley Mark of Honor
    [20558] = 1, -- Warsong Gulch Mark of Honor
    [20559] = 1, -- Arathi Basin Mark of Honor

    -- TBC PvP
    [29024] = 1, -- Eye of the Storm Mark of Honor

    -- TBC dungeon / raid / world
    [29434] = 1, -- Badge of Justice
    [28558] = 1, -- Spirit Shard (Auchindoun)
    [32569] = 1, -- Apexis Shard (Ogri'la dailies)

    -- WotLK dungeon / raid emblems
    [40752] = 1, -- Emblem of Heroism
    [40753] = 1, -- Emblem of Valor
    [45624] = 1, -- Emblem of Conquest
    [47241] = 1, -- Emblem of Triumph
    [49426] = 1, -- Emblem of Frost

    -- WotLK PvE tokens
    [43228] = 1, -- Stone Keeper's Shard
    [47557] = 1, -- Trophy of the Crusade
    [50260] = 1, -- Mark of Sanctification (heroic ICC equivalent)
    [44990] = 1, -- Champion's Seal (Argent Tournament)

    -- WotLK PvP marks
    [43589] = 1, -- Wintergrasp Mark of Honor
    [47395] = 1, -- Isle of Conquest Mark of Honor
}
