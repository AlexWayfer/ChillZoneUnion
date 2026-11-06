local _, U = ...
local observed, contexts, pending = {}, {}, {}
local published, epoch, revision = {}, nil, 0
local wasGateway, wasConnected, remoteName, nextScan, nextPublish, lastFull = false, false, nil, 0, 0, -1000
local fullNeeded, guildSync = true, false
local LIMIT, PAGE, LIVE_FOR = 1500, 40, 65

local function Version(value)
    return U.Text(value, 40) and value ~= "" and value:match("^[A-Za-z0-9%.%-]+$") and value or nil
end
local function Integer(value, minimum, maximum)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= minimum and n <= maximum and n or nil
end
local function History(guild)
    if not U.db then return nil end
    U.db.addonPresence = U.db.addonPresence or {}
    U.db.addonPresence[guild] = U.db.addonPresence[guild] or {}
    return U.db.addonPresence[guild]
end
local function Roster(guild)
    if guild == U.guild then return U.own end
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    return cache and cache.rows
end
local function Remember(guild, name, version, at)
    local history = History(guild)
    if history then history[name] = { version = version, lastSeen = at } end
end
local function ExpectedRemote()
    if not U.guild or not U.Connected() then return nil end
    return U.IsGateway() and U.remote and U.remote.name or U.linkState and U.linkState.name
end
local function OwnLive(name, member)
    if not member or member.online ~= true then return false end
    if name == U.me then return true end
    local record = observed[name]
    return record ~= nil and U.clock() - record.at <= LIVE_FOR
end
function U.AddonInfo(name, guild)
    name, guild = U.Name(name), guild or U.guild
    if not name or not U.GUILDS[guild] then return { known = false } end
    local rows = Roster(guild)
    if not rows or not rows[name] then return { known = false } end
    local known = History(guild)[name]
    if guild == U.guild and observed[name] then
        known = { version = observed[name].version, lastSeen = type(known) == "table" and known.lastSeen or U.stamp() }
    end
    if name == U.me and guild == U.guild and Version(U.VERSION) then
        known = { version = U.VERSION, lastSeen = U.stamp() }
    end
    if type(known) ~= "table" or not Version(known.version) or type(known.lastSeen) ~= "number" then return { known = false } end
    local live = false
    if guild == U.guild then live = OwnLive(name, rows[name])
    else
        local state = contexts[guild]
        local record = state and state.records[name]
        live = state ~= nil and state.active == true and state.source == ExpectedRemote()
            and U.RosterFresh(guild) and rows[name].online == true and record ~= nil and record.live == true
    end
    return { known = true, version = known.version, live = live and true or false, lastSeen = known.lastSeen }
end
function U.PresenceHello(name, version)
    version = Version(version)
    if not U.guild or not version or not U.own[name] then return false end
    local old = observed[name]
    local newlyLive = not old or U.clock() - old.at > LIVE_FOR
    observed[name] = { version = version, at = U.clock() }
    Remember(U.guild, name, version, U.stamp())
    if newlyLive then guildSync, fullNeeded = true, true end
    return true
end
function U.PresenceReset()
    observed, contexts, pending, published = {}, {}, {}, {}
    epoch, revision, wasGateway, wasConnected, remoteName = nil, 0, false, false, nil
    fullNeeded, guildSync, nextScan, nextPublish, lastFull = true, false, 0, 0, -1000
end
local function Signature(record) return record.version .. (record.live and ":1" or ":0") end
local function OwnRecords()
    local records, history = {}, History(U.guild)
    for name, member in pairs(U.own) do
        local known = history[name]
        if type(known) == "table" and Version(known.version) and type(known.lastSeen) == "number" then
            records[name] = { version = known.version, live = OwnLive(name, member), lastSeen = known.lastSeen }
        end
    end
    return records
end
local function Pages(guild, sourceEpoch, sourceRevision, mode, base, at, records, dist, target, envelope)
    local names, rows, jobs = {}, {}, {}
    for name in pairs(records) do names[#names + 1] = name end
    table.sort(names)
    if #names > LIMIT then return nil end
    for _, name in ipairs(names) do
        local record = records[name]
        rows[#rows + 1] = U.Pack({ name, record.version, record.live and "1" or "0", record.lastSeen })
    end
    local count = math.max(1, math.ceil(#rows / PAGE))
    for part = 1, count do
        local page = {}
        for i = (part - 1) * PAGE + 1, math.min(part * PAGE, #rows) do page[#page + 1] = rows[i] end
        local fields = { guild, sourceEpoch, sourceRevision, mode, base, part, count, at, U.Pack(page) }
        jobs[#jobs + 1] = { kind = envelope and "REMOTE" or "ADDONS",
            fields = envelope and { "ADDONS", U.Pack(fields), envelope } or fields,
            dist = dist, target = target, priority = false, requiresGateway = true }
    end
    return jobs
end
local function Current(guild, source, remote)
    if remote then return guild ~= U.guild and source == ExpectedRemote() and U.TrustedPeer(source) == guild end
    return guild == U.guild and U.own[source] ~= nil and source == U.GatewayName()
end
local function Admissible(batch)
    if not Current(batch.guild, batch.source, batch.remote) then return false end
    local previous = contexts[batch.guild]
    if previous and previous.source == batch.source then
        if previous.retired[batch.epoch] then return false end
        if previous.epoch == batch.epoch and batch.revision <= previous.revision then return false end
        if previous.epoch ~= batch.epoch and (batch.mode ~= "F" or batch.at < previous.at) then return false end
    end
    return true, previous
end
local function Apply(batch)
    local admissible, previous = Admissible(batch)
    if not admissible then return false end
    if batch.mode == "D" and (not previous or previous.source ~= batch.source or previous.epoch ~= batch.epoch or previous.revision ~= batch.base) then return false end
    -- A current, approved publisher may replay metadata before its roster arrives.
    -- Validate the whole message first; neither history nor contexts is changed
    -- until every name can be checked against that source's complete roster.
    local parsed, total = {}, 0
    for part = 1, batch.pages do
        for _, packed in ipairs(batch.parts[part]) do
            local f = U.Unpack(packed, 4)
            local name = f and #f == 4 and U.Name(f[1])
            local version = f and Version(f[2])
            local at = f and Integer(f[4], 0, batch.at)
            if not name or not version or not at or (f[3] ~= "0" and f[3] ~= "1") or parsed[name] then return false end
            total = total + 1
            if total > LIMIT then return false end
            parsed[name] = { version = version, live = f[3] == "1", lastSeen = at }
        end
    end
    local roster = Roster(batch.guild)
    if batch.guild ~= U.guild then
        local cache = U.db.rosters[batch.guild]
        if not cache or cache.source ~= batch.source then roster = nil end
    end
    if not roster then return nil end -- bounded pending batch, waiting for roster
    for name in pairs(parsed) do if not roster[name] then return nil end end
    local records = {}
    total = 0
    if batch.mode == "D" then
        for name, record in pairs(previous.records) do if roster[name] then records[name] = record; total = total + 1 end end
    end
    for name, record in pairs(parsed) do
        if not records[name] then total = total + 1 end
        if total > LIMIT then return false end
        records[name] = record
    end
    local retired = previous and previous.source == batch.source and previous.retired or {}
    if previous and previous.source == batch.source and previous.epoch ~= batch.epoch then
        retired[previous.epoch] = true
        local n = 0; for _ in pairs(retired) do n = n + 1 end
        if n > 32 then retired = { [previous.epoch] = true } end
    end
    contexts[batch.guild] = { source = batch.source, epoch = batch.epoch, revision = batch.revision,
        at = batch.at, records = records, retired = retired, active = true }
    for name, record in pairs(records) do Remember(batch.guild, name, record.version, record.lastSeen) end
    if U.Refresh then U.Refresh() end
    return true
end
function U.PresenceMessage(kind, f, sender, remote)
    if kind ~= "ADDONS" or #f ~= 9 then return false end
    local guild = Integer(f[1], 1, 2)
    if not guild or not Current(guild, sender, remote) or not U.Text(f[2], 80) or not f[2]:match("^%d[%d%.]*$") then return false end
    local rev, base = Integer(f[3], 1, 1000000000), Integer(f[5], 0, 1000000000)
    local part, count = Integer(f[6], 1, 38), Integer(f[7], 1, 38)
    local at, rows = Integer(f[8], 0, U.stamp() + 60), U.Unpack(f[9], PAGE)
    if not rev or not base or not part or not count or part > count or not at or not rows or (f[4] ~= "F" and f[4] ~= "D") then return false end
    if f[4] == "F" and base ~= 0 or f[4] == "D" and base >= rev then return false end
    local seen = {}
    for _, packed in ipairs(rows) do
        local row = U.Unpack(packed, 4)
        local name = row and #row == 4 and U.Name(row[1])
        if not name or not Version(row[2]) or (row[3] ~= "0" and row[3] ~= "1")
            or not Integer(row[4], 0, at) or seen[name] then return false end
        seen[name] = true
    end
    local previous = contexts[guild]
    if previous and previous.source == sender and (previous.retired[f[2]] or previous.epoch == f[2] and rev <= previous.revision) then return false end
    local key = tostring(guild) .. ":" .. sender .. ":" .. f[2] .. ":" .. rev
    local batch = pending[key]
    if not batch then
        local n = 0; for _ in pairs(pending) do n = n + 1 end
        if n >= 6 then return false end
        batch = { guild = guild, source = sender, remote = remote, epoch = f[2], revision = rev, mode = f[4], base = base,
            pages = count, at = at, started = U.clock(), parts = {}, raw = {}, n = 0, rowCount = 0 }
        pending[key] = batch
    end
    if batch.pages ~= count or batch.mode ~= f[4] or batch.base ~= base or batch.at ~= at then pending[key] = nil return false end
    if batch.parts[part] then
        if batch.raw[part] ~= f[9] then pending[key] = nil return false end
        return true
    end
    if batch.rowCount + #rows > LIMIT then pending[key] = nil; return false end
    batch.parts[part], batch.raw[part], batch.n = rows, f[9], batch.n + 1
    batch.rowCount = batch.rowCount + #rows
    if batch.n == batch.pages then
        local applied = Apply(batch)
        if applied ~= nil then pending[key] = nil end
        return applied ~= false
    end
    return true
end
local function RetryPending()
    local complete = {}
    for key, batch in pairs(pending) do
        if batch.n == batch.pages then complete[#complete + 1] = { key = key, batch = batch } end
    end
    table.sort(complete, function(a, b)
        local first, second = a.batch, b.batch
        if first.guild ~= second.guild then return first.guild < second.guild end
        if first.source ~= second.source then return first.source < second.source end
        if first.epoch == second.epoch then return first.revision < second.revision end
        if first.at ~= second.at then return first.at < second.at end
        return first.epoch < second.epoch
    end)
    for _, entry in ipairs(complete) do
        if pending[entry.key] == entry.batch and Apply(entry.batch) ~= nil then pending[entry.key] = nil end
    end
end
local function Prune()
    for guild = 1, 2 do
        local roster, history = Roster(guild), History(guild)
        local count = 0
        local ready = roster and (guild ~= U.guild or U.own[U.me] ~= nil)
        for name, record in pairs(history) do
            count = count + 1
            if ready and not roster[name] or type(record) ~= "table" or not Version(record.version)
                or type(record.lastSeen) ~= "number" or count > LIMIT then history[name] = nil end
        end
    end
    if U.own[U.me] then for name in pairs(observed) do if not U.own[name] then observed[name] = nil end end end
    for key, batch in pairs(pending) do
        if U.clock() - batch.started > 90 or not Admissible(batch) then pending[key] = nil end
    end
end
function U.PresenceTick()
    if not U.db or not U.guild or U.clock() < nextScan then return end
    nextScan = U.clock() + 2
    if U.own[U.me] then U.PresenceHello(U.me, U.VERSION) end
    Prune()
    RetryPending()
    local gateway, connected, source = U.IsGateway(), U.Connected(), ExpectedRemote()
    local remote = contexts[U.OtherGuild()]
    if remote and (not connected or remote.source ~= source) then remote.active = false end
    if gateway and (not wasGateway or connected and not wasConnected or source ~= remoteName) then
        fullNeeded = true
        if not wasGateway then epoch, revision, published = U.NewID(), 0, {} end
    end
    wasGateway, wasConnected, remoteName = gateway, connected, source
    if not gateway or not U.own[U.me] or U.clock() < nextPublish or U.QueueSize() >= 100 then return end
    if connected and (not U.RosterFresh(U.OtherGuild()) or not U.lastSnapshot) then return end
    local records, changed = OwnRecords(), {}
    for name, record in pairs(records) do if published[name] ~= Signature(record) then changed[name] = record end end
    local full = fullNeeded or connected and U.clock() - lastFull >= 180
    if full or next(changed) then
        local newRevision, jobs = revision + 1, {}
        local selected = full and records or changed
        local localJobs = Pages(U.guild, epoch, newRevision, full and "F" or "D", full and 0 or revision, U.stamp(), selected, "GUILD")
        if not localJobs then return end
        for _, job in ipairs(localJobs) do jobs[#jobs + 1] = job end
        if connected then
            for _, job in ipairs(Pages(U.guild, epoch, newRevision, full and "F" or "D", full and 0 or revision, U.stamp(), selected, "WHISPER", source)) do jobs[#jobs + 1] = job end
        end
        if not U.QueueBatch(jobs) then return end
        revision, published, fullNeeded, nextPublish = newRevision, {}, false, U.clock() + 5
        for name, record in pairs(records) do published[name] = Signature(record) end
        if full then lastFull = U.clock() end
    end
    if guildSync and remote and remote.active and remote.source == source then
        local jobs = Pages(U.OtherGuild(), remote.epoch, remote.revision, "F", 0, remote.at, remote.records, "GUILD", nil, source)
        if jobs and U.QueueBatch(jobs) then guildSync = false end
    elseif not connected or not remote or not remote.active then guildSync = false end
end
