local _, U = ...
local syncDue, lastSync = 0, -100
local function Fields(t) return { t.guild, t.author, t.at, t.id, t.text } end
local function Parse(f)
    if #f ~= 5 then return nil end
    local guild, author, at = tonumber(f[1]), U.Name(f[2]), tonumber(f[3])
    if not guild or not U.GUILDS[guild] or not author or not at or at < 0 or at > U.stamp() + 60 then return nil end
    if not U.Text(f[4], 100) or f[4] == "" or not U.Text(f[5], 1000) then return nil end
    return { guild = guild, author = author, at = at, id = f[4], text = f[5] }
end
local function Newer(a, b)
    if not b or a.at > b.at then return true end
    if a.at < b.at then return false end
    local as, an = a.id:match("^(.*)%.(%d+)$")
    local bs, bn = b.id:match("^(.*)%.(%d+)$")
    if as and as == bs then return tonumber(an) > tonumber(bn) end
    return a.id > b.id
end
local function Apply(t, announce)
    local previous = U.db.announcement
    if not Newer(t, previous) then return false end
    U.db.announcement = t
    if announce and t.text ~= "" and U.stamp() - t.at < 30 and U.SystemNotice then
        U.SystemNotice("Объявление союза: " .. t.text)
    end
    if U.Refresh then U.Refresh() end
    return true
end
function U.GetAnnouncement()
    local t = U.db and U.db.announcement
    return t and t.text ~= "" and t or nil
end
function U.SetAnnouncement(text)
    if not U.IsMaster() then U.Print("Общее объявление может изменить глава гильдии.") return false end
    if not U.Text(text, 1000) then U.Print("Объявление слишком длинное: максимум 1000 байт.") return false end
    text = U.Trim(text):gsub("[\r\n]", " ")
    local t = { guild = U.guild, author = U.me, at = U.stamp(), id = U.NewID(), text = text }
    if not U.Emit("ANNOUNCE", Fields(t), true) then U.Print("Объявление не отправлено. Повторите через несколько секунд.") return false end
    syncDue = 0
    return true
end
function U.SendAnnouncement()
    syncDue = 0
end
function U.ExtensionMessage(kind, f, sender, remote)
    if kind ~= "ANNOUNCE" and kind ~= "ANNSTATE" then return false end
    local t = Parse(f)
    if not t then return false end
    if kind == "ANNSTATE" then
        if remote then
            local expected = U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
            if not U.Connected() or expected ~= sender or not U.TrustedPeer(sender) then return false end
            local cache = U.db.rosters[t.guild]
            local rows = t.guild == U.guild and U.own or cache and cache.rows
            if not rows or not rows[t.author] or rows[t.author].rank ~= 0 then return false end
            if t.guild ~= U.guild and (not cache or U.stamp() - cache.at > 600) then return false end
            Apply(t, false)
            return true
        end
        -- Cached state is distributed only by our server-stamped elected guildmate.
        if not U.own[sender] or sender ~= U.GatewayName() then return false end
        Apply(t, false)
        return false -- Local cache synchronization must never loop back across guilds.
    end
    if remote then
        if t.guild ~= U.OtherGuild() or U.TrustedPeer(sender) ~= t.guild then return false end
        local cache = U.db.rosters[t.guild]
        if not cache or U.stamp() - cache.at > 600 or not cache.rows[t.author] or cache.rows[t.author].rank ~= 0 then return false end
    else
        if t.guild ~= U.guild or sender ~= t.author or not U.own[sender] or U.own[sender].rank ~= 0 then return false end
    end
    Apply(t, true)
    return true
end
function U.ExtensionSync() syncDue = 0 end
function U.ExtensionTick()
    local now = U.clock()
    if not U.guild or not U.IsGateway() or now < syncDue or now - lastSync < 5 or U.QueueSize() > 100 then return end
    local t = U.db.announcement
    if not t then return end
    lastSync = now
    local queued = U.Queue("ANNSTATE", Fields(t), "GUILD", nil, false, true, nil, true, now + 15, "announcement:cache")
    if U.Connected() and t.guild == U.guild and U.own[t.author] and U.own[t.author].rank == 0 then
        queued = U.Queue("ANNOUNCE", Fields(t), "WHISPER", U.remote.name, false, true, nil, true, now + 15, "announcement:remote") and queued
    elseif U.Connected() and t.guild ~= U.guild then
        queued = U.Queue("ANNSTATE", Fields(t), "WHISPER", U.remote.name, false, true, nil, true, now + 15, "announcement:remote") and queued
    end
    syncDue = now + (queued and 60 or 10)
end
function U.OnRosterChanges(guild, changes, initial)
    if initial or guild == U.guild or not U.db.memberNotices or not U.SystemNotice then return end
    if #(changes.joined or {}) + #(changes.left or {}) > 5 then
        U.SystemNotice("Изменения состава союза: вступили " .. #(changes.joined or {}) .. ", вышли " .. #(changes.left or {}) .. ".")
        return
    end
    for _, row in ipairs(changes.joined or {}) do U.SystemNotice(row.name .. " вступил в «" .. U.GUILDS[guild] .. "».") end
    for _, row in ipairs(changes.left or {}) do U.SystemNotice(row.name .. " покинул «" .. U.GUILDS[guild] .. "».") end
end
