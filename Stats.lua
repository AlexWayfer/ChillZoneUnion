local _, U = ...

local classic = {
    { "WARRIOR", "Воин", 0.78, 0.61, 0.43 },
    { "PALADIN", "Паладин", 0.96, 0.55, 0.73 },
    { "HUNTER", "Охотник", 0.67, 0.83, 0.45 },
    { "ROGUE", "Разбойник", 1, 0.96, 0.41 },
    { "PRIEST", "Жрец", 1, 1, 1 },
    { "SHAMAN", "Шаман", 0, 0.44, 0.87 },
    { "MAGE", "Маг", 0.25, 0.78, 0.92 },
    { "WARLOCK", "Чернокнижник", 0.53, 0.53, 0.93 },
    { "DRUID", "Друид", 1, 0.49, 0.04 },
}
local defaults = {}
for _, entry in ipairs(classic) do defaults[entry[1]] = entry end

local function ClassRow(token, guilds)
    local definition = defaults[token]
    local label = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
    if type(label) ~= "string" or label == "" then
        label = definition and definition[2] or token == "UNKNOWN" and "Неизвестно" or token
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    local function Component(key, index)
        local value = color and color[key]
        return type(value) == "number" and value or definition and definition[index] or 0.65
    end
    local row = { class = token, label = label,
        color = { r = Component("r", 3), g = Component("g", 4), b = Component("b", 5) },
        knownTotal = 0, knownOnline = 0, guilds = {} }
    for guild = 1, 2 do
        row.guilds[guild] = { total = guilds[guild].known and 0 or nil, online = guilds[guild].fresh and 0 or nil }
    end
    return row
end

-- Counts describe characters, including offline characters, independently of UI filters.
-- Missing rosters and stale online flags remain unknown rather than becoming zero.
function U.ClassStatistics()
    local result = { rows = {}, guilds = {}, knownTotal = 0, knownOnline = 0, complete = true, onlineComplete = true }
    local sourceRows = {}
    for guild = 1, 2 do
        local cache = U.db and U.db.rosters and U.db.rosters[guild]
        local own = guild == U.guild
        local rows
        if own then rows = U.own else rows = cache and cache.rows end
        local known = type(rows) == "table" and (not own or rows[U.me] ~= nil)
        local fresh = known and U.RosterFresh and U.RosterFresh(guild) == true or false
        local state = U.RosterState and U.RosterState(guild) or {}
        result.guilds[guild] = { name = U.GUILDS[guild], known = known, fresh = fresh,
            age = state.age, at = state.at, status = state.status,
            total = known and 0 or nil, online = fresh and 0 or nil }
        sourceRows[guild] = known and rows or {}
        if not known then result.complete = false end
        if not fresh then result.onlineComplete = false end
    end

    local byClass, extra = {}, {}
    for _, definition in ipairs(classic) do
        local row = ClassRow(definition[1], result.guilds)
        byClass[row.class] = row
        result.rows[#result.rows + 1] = row
    end
    for guild = 1, 2 do
        local metadata, seen = result.guilds[guild], {}
        for key, member in pairs(sourceRows[guild]) do
            if type(member) == "table" then
                local name = U.Name(member.name) or U.Name(key) or tostring(key)
                name = U.Fold(name)
                if not seen[name] then
                    seen[name] = true
                    local token = type(member.class) == "string" and U.Trim(member.class) or ""
                    if token == "" then token = "UNKNOWN" end
                    local row = byClass[token]
                    if not row then
                        row = ClassRow(token, result.guilds); byClass[token] = row; extra[#extra + 1] = token
                    end
                    row.guilds[guild].total = row.guilds[guild].total + 1
                    row.knownTotal = row.knownTotal + 1
                    metadata.total = metadata.total + 1
                    result.knownTotal = result.knownTotal + 1
                    if metadata.fresh and member.online == true then
                        row.guilds[guild].online = row.guilds[guild].online + 1
                        row.knownOnline = row.knownOnline + 1
                        metadata.online = metadata.online + 1
                        result.knownOnline = result.knownOnline + 1
                    end
                end
            end
        end
    end
    table.sort(extra)
    for _, token in ipairs(extra) do result.rows[#result.rows + 1] = byClass[token] end
    for _, row in ipairs(result.rows) do
        row.total = result.complete and row.knownTotal or nil
        row.online = result.onlineComplete and row.knownOnline or nil
    end
    result.total = result.complete and result.knownTotal or nil
    result.online = result.onlineComplete and result.knownOnline or nil
    return result
end
