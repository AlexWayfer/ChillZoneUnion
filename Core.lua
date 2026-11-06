local _, U = ...
ChillZoneUnion = U
U.VERSION, U.PREFIX = "0.5.0-beta", "CZUnion2"
U.GUILDS = { "Чиллзон", "Чиллзон Навсегда" }
U.GUILD_LEADERS = { [1] = "Вован Дубан" }
U.UNION_LEADER = "Вован Дубан"
U.events, U.history, U.notices = {}, {}, {}
U.chatByID, U.chatSeen = {}, {}
U.clock = function() return GetTime() end
U.stamp = function() return GetServerTime() end

function U.Public(v)
    return not (issecretvalue and issecretvalue(v))
end
function U.Text(v, limit)
    return U.Public(v) and type(v) == "string" and #v <= (limit or 8192)
end
function U.Trim(s) return (s or ""):match("^%s*(.-)%s*$") end
function U.Name(s)
    if not U.Text(s, 160) then return nil end
    s = U.Trim(s):gsub("%-[^%-]+$", "")
    if s == "" or s:find("[\n\r|%c]") then return nil end
    return s
end
function U.PlayerName()
    local first, second = UnitFullName("player")
    if not U.Text(first, 80) or not U.Public(second) then return nil end
    if second and second ~= "" and second ~= GetRealmName() and second ~= GetNormalizedRealmName() then
        return first .. " " .. second
    end
    return first
end
function U.GuildIndex(guild)
    for i, g in ipairs(U.GUILDS) do if guild == g then return i end end
end
function U.Print(s)
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff73d8c7[Чиллзон]|r " .. tostring(s)) end
end
function U.Notify(s)
    U.notices[#U.notices + 1] = s
    if #U.notices > 100 then table.remove(U.notices, 1) end
    U.Print(s)
    if U.Refresh then U.Refresh() end
end
function U.SafeDisplay(s)
    return (tostring(s or ""):gsub("|", "||"):gsub("[\r\n]", " "))
end
local russianLower = {}
do
    local upper, lower = { "А", "Б", "В", "Г", "Д", "Е", "Ё", "Ж", "З", "И", "Й", "К", "Л", "М", "Н", "О", "П", "Р", "С", "Т", "У", "Ф", "Х", "Ц", "Ч", "Ш", "Щ", "Ъ", "Ы", "Ь", "Э", "Ю", "Я" },
        { "а", "б", "в", "г", "д", "е", "ё", "ж", "з", "и", "й", "к", "л", "м", "н", "о", "п", "р", "с", "т", "у", "ф", "х", "ц", "ч", "ш", "щ", "ъ", "ы", "ь", "э", "ю", "я" }
    for i, letter in ipairs(upper) do russianLower[letter] = lower[i] end
end
function U.Fold(s) return (s:lower():gsub("[\208\209][\128-\191]", russianLower)) end
function U.ChatText(s)
    local links, allowed = {}, { item = true, spell = true, quest = true, enchant = true, achievement = true }
    s = s:gsub("[%z\1-\8\11\12\14-\31]", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("|H(%a+):([^|]-)|h([^|]-)|h", function(kind, payload, title)
        if not allowed[kind] or #payload > 600 or #title > 250 or not payload:match("^[%w:%-]+$") then return title end
        links[#links + 1] = "|H" .. kind .. ":" .. payload .. "|h" .. title .. "|h"
        return "\1" .. #links .. "\2"
    end)
    s = U.SafeDisplay(s)
    return (s:gsub("\1(%d+)\2", function(i) return links[tonumber(i)] or "" end))
end
function U.ChatStatus(id, status)
    local row = id and U.chatByID[id]
    if not row or (status ~= "pending" and status ~= "delivered" and status ~= "local-only") then return false end
    if row.status == "delivered" and status ~= "delivered" then return false end
    if row.status == status then return false end
    row.status = status
    if U.RefreshChat then U.RefreshChat() end
    return true
end
function U.Chat(guild, name, text, native, metadata)
    metadata = type(metadata) == "table" and metadata or {}
    local id = U.Text(metadata.id, 220) and metadata.id ~= "" and metadata.id or nil
    if id and U.chatSeen[id] then
        local existing = U.chatByID[id]
        if existing and (existing.guild ~= guild or existing.name ~= name or existing.text ~= text) then return false, existing, "conflict" end
        if metadata.status then U.ChatStatus(id, metadata.status) end
        return false, U.chatByID[id]
    end
    local at = metadata.at
    if not U.Public(at) or type(at) ~= "number" or at < 0 or at > U.stamp() + 60 then at = U.stamp() end
    local entry = { time = at, guild = guild, name = name, text = text, id = id,
        status = metadata.status or "delivered", native = native == true, replayed = metadata.replayed == true }
    local h, index = U.history, #U.history + 1
    for i = #h, 1, -1 do if h[i].time <= at then break else index = i end end
    table.insert(h, index, entry)
    if id then U.chatByID[id], U.chatSeen[id] = entry, U.clock() end
    if #h > 200 then
        local removed = table.remove(h, 1)
        if removed.id and U.chatByID[removed.id] == removed then U.chatByID[removed.id] = nil end
    end
    if U.DisplayChat then U.DisplayChat(entry, native) end
    if U.RefreshChat then U.RefreshChat(entry) end
    return true, entry
end
function U.ChatRecent(limit, afterTime)
    limit = math.max(1, math.min(100, tonumber(limit) or 100))
    afterTime = tonumber(afterTime) or U.stamp() - 300
    local out = {}
    for i = math.max(1, #U.history - limit + 1), #U.history do
        local row = U.history[i]
        if row.id and row.time >= afterTime then out[#out + 1] = row end
    end
    return out
end
function U.ExpectedLeader(guild)
    local cache = U.db and U.db.rosters[guild]
    local rows = guild == U.guild and U.own or cache and cache.rows
    if rows then for name, row in pairs(rows) do if row.rank == 0 then return name end end end
    return U.GUILD_LEADERS[guild]
end
function U.On(event, fn)
    U.events[event] = U.events[event] or {}
    table.insert(U.events[event], fn)
end
function U.IsMaster()
    return U.guild and U.own and U.own[U.me] and U.own[U.me].rank == 0
end
function U.IsUnionLeader(name, guild)
    name, guild = U.Name(name or U.me), guild or U.guild
    if not name or not U.GUILDS[guild] or U.Fold(name) ~= U.Fold(U.UNION_LEADER) then return false end
    local rows
    if guild == U.guild then rows = U.own
    else
        local cache = U.db and U.db.rosters and U.db.rosters[guild]
        if not cache or type(cache.at) ~= "number" or U.stamp() - cache.at > 600 or cache.at > U.stamp() + 60 then return false end
        rows = cache.rows
    end
    return rows ~= nil and rows[name] ~= nil and rows[name].rank == 0
end
function U.CanInvite()
    if not U.guild then return false end
    if U.IsMaster() then return true end
    local fn = CanGuildInvite or (C_GuildInfo and C_GuildInfo.CanInvite)
    if type(fn) ~= "function" then return false end
    local ok, allowed = pcall(fn)
    return ok and U.Public(allowed) and allowed == true
end
function U.IsOfficer()
    if not U.guild then return false end
    if U.IsMaster() then return true end
    local fn = C_GuildInfo and C_GuildInfo.IsGuildOfficer or IsGuildOfficer
    if type(fn) == "function" then
        local ok, allowed = pcall(fn)
        if ok and U.Public(allowed) and allowed == true then return true end
    end
    local row = U.own and U.own[U.me]
    return U.CanInvite() or (row and row.rank <= 1) or false
end
function U.ChatLocked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
        if not ok or not U.Public(locked) or locked then return true end
    end
    return false
end
function U.UpdateIdentity()
    local previous = U.guild
    U.me = U.PlayerName() or U.me
    local guild = GetGuildInfo("player")
    U.guild = U.Public(guild) and U.GuildIndex(guild) or nil
    if previous ~= U.guild and U.NetworkReset then U.NetworkReset() end
    if U.IdentityChanged then U.IdentityChanged(previous) end
end
function U.NewID()
    U.sequence = (U.sequence or 0) + 1
    return tostring(U.session) .. "." .. tostring(U.sequence)
end
function U.Command(input)
    local cmd, rest = U.Trim(input):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "ui" then U.Toggle()
    elseif cmd == "link" then U.Link(rest)
    elseif cmd == "accept" then U.AcceptLink(U.Name(rest))
    elseif cmd == "decline" then U.DeclineLink(U.Name(rest))
    elseif cmd == "relay" then
        local mode, name = rest:match("^(%S+)%s+(.+)$")
        if (mode ~= "on" and mode ~= "off") or not U.Name(name) then U.Print("/cz relay on|off Полное Имя") return end
        U.AuthorizeRelay(name, mode == "on")
    elseif cmd == "trust" and rest == "sync" then U.ShareTrust()
    elseif cmd == "sync" then U.RequestRoster(); U.snapshotDue = 0; U.SayHello(); U.Print("Обновление состава запрошено.")
    elseif cmd == "status" then U.Print(U.Status())
    elseif cmd == "badge" then
        if rest ~= "on" and rest ~= "off" then U.Print("/cz badge on|off") return end
        U.SetGuildBadge(rest == "on")
    elseif cmd == "chatwindow" then
        local ok, why = U.SetChatWindow(rest ~= "auto" and rest or nil)
        if not ok then U.Print(why) end
    elseif cmd == "guildchat" then
        if rest ~= "on" and rest ~= "off" then U.Print("/cz guildchat on|off") return end
        U.db.bridgeGuildChat = rest == "on"
        U.Print("Передача вашего гильдейского чата: " .. (U.db.bridgeGuildChat and "включена" or "выключена"))
    elseif cmd == "help" then
        U.Print("/cz accept Полное Имя; /cz decline Полное Имя; /cz relay on|off Полное Имя; /cz trust sync — передать подтверждённые настройки.")
        U.Print("/cz — окно; /czu текст — общий чат; /cz link Имя Фамилия — связать гильдии; /cz sync; /cz status; /cz guildchat on|off.")
        U.Print("/чз — синоним /cz; /cz текст и /чз текст — общий чат.")
    else U.SendChat(input) end
end

local f = CreateFrame("Frame")
U.frame = f
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_GUILD_UPDATE")
f:RegisterEvent("GUILD_ROSTER_UPDATE")
f:RegisterEvent("CHAT_MSG_ADDON")
pcall(f.RegisterEvent, f, "CHAT_MSG_ADDON_LOGGED")
f:RegisterEvent("CHAT_MSG_GUILD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= "ChillZoneUnion" then return end
        ChillZoneUnionDB = ChillZoneUnionDB or {}
        local db = ChillZoneUnionDB
        db.realms = db.realms or {}
        local realm = GetNormalizedRealmName() or GetRealmName()
        local faction = UnitFactionGroup("player") or "Alliance"
        local key = realm .. ":" .. faction
        db.realms[key] = db.realms[key] or {}
        U.db = db.realms[key]
        if U.db.trustSchema ~= 2 then
            local hadSavedState = next(U.db.contacts or {}) ~= nil or next(U.db.rosters or {}) ~= nil
            U.db.contacts, U.db.rosters, U.db.approvedRelays = {}, {}, {}
            U.db.tickets, U.db.announcement, U.db.addonPresence = {}, nil, {}
            U.db.setupContact, U.db.setupIntroSeen = nil, {}
            U.db.trustSchema = 2
            U.trustMigrated = hadSavedState
        end
        U.db.contacts = U.db.contacts or {}
        U.db.rosters = U.db.rosters or {}
        if U.db.bridgeGuildChat == nil then U.db.bridgeGuildChat = true end
        if U.db.showGuildBadge == nil then U.db.showGuildBadge = false end
        if U.db.memberNotices == nil then U.db.memberNotices = false end
        U.session = tostring(U.stamp()) .. tostring(math.random(10000, 99999))
        U.UpdateIdentity()
        C_ChatInfo.RegisterAddonMessagePrefix(U.PREFIX)
        SLASH_CHILLZONEUNION1, SLASH_CHILLZONEUNION2 = "/cz", "/чиллзон"
        SLASH_CHILLZONEUNION3 = "/чз"
        SlashCmdList.CHILLZONEUNION = U.Command
        SLASH_CHILLZONECHAT1 = "/czu"
        SlashCmdList.CHILLZONECHAT = function(s) U.SendChat(s) end
        BINDING_HEADER_CHILLZONEUNION = "Чиллзон — Союз гильдий"
        BINDING_NAME_CHILLZONEUNION_ROSTER = "Открыть общий состав"
        return
    end
    if not U.db then return end
    if event == "PLAYER_LOGIN" then
        U.UpdateIdentity(); U.RequestRoster(); U.SayHello()
        if U.trustMigrated then
            U.Print("Проверка безопасности: старые контакты и данные соединения сброшены. Настройте связь заново с подтверждением второй стороны.")
            U.trustMigrated = nil
        end
    elseif event == "PLAYER_GUILD_UPDATE" then U.UpdateIdentity(); U.RequestRoster()
    end
    for _, fn in ipairs(U.events[event] or {}) do fn(...) end
end)
local elapsed, lastChatClean = 0, -100
f:SetScript("OnUpdate", function(_, dt)
    if not U.db then return end
    elapsed = elapsed + dt
    if elapsed < 0.1 then return end
    elapsed = 0
    U.Pump()
    U.NetworkTick()
    U.RosterTick()
    U.TransferTick()
    if U.ExtensionTick then U.ExtensionTick() end
    if U.clock() - lastChatClean > 60 then
        lastChatClean = U.clock()
        for id, at in pairs(U.chatSeen) do if U.clock() - at > 600 then U.chatSeen[id] = nil end end
    end
end)
