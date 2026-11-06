local _, U = ...
U.own = {}
local lastRequest, lastRead, lastAttempt, changedAt, dirtySince = -100, -100, -100, 0, 0
local dirty, pending, deltaPending = true, {}, {}
local acceptedAt, needsFull = {}, {}
local published, wasGateway
local READ_RETRY, READ_GAP, MAX_DEBOUNCE, DELTA_EVERY, FRESH_FOR = 3, 5, 8, 5, 25
local function MarkDirty()
    local now = U.clock()
    if not dirty then dirtySince = now end
    dirty, changedAt = true, now
end
local function Incomplete()
    if not dirty then dirtySince = U.clock() end
    dirty = true
    return false
end
local function Integer(value, minimum, maximum)
    local n = tonumber(value)
    return n and n == math.floor(n) and n >= minimum and n <= maximum and n or nil
end
local function Count(rows)
    local n = 0
    for _ in pairs(rows or {}) do n = n + 1 end
    return n
end
local function Same(a, b)
    return a and b and a.rank == b.rank and a.rankName == b.rankName and a.level == b.level
        and a.class == b.class and a.zone == b.zone and a.online == b.online
end
local function Changes(before, after)
    local changes = { joined = {}, left = {}, online = {}, offline = {}, updated = {} }
    local n = 0
    for name, row in pairs(after) do
        local old = before and before[name]
        if not old then
            changes.joined[#changes.joined + 1] = row; n = n + 1
        elseif not Same(old, row) then
            changes.updated[#changes.updated + 1] = row; n = n + 1
            if row.online ~= old.online then
                local list = row.online and changes.online or changes.offline
                list[#list + 1] = row
            end
        end
    end
    for name, row in pairs(before or {}) do
        if not after[name] then changes.left[#changes.left + 1] = row; n = n + 1 end
    end
    for _, list in pairs(changes) do table.sort(list, function(a, b) return a.name < b.name end) end
    return changes, n
end
local function Announce(guild, before, after, initial)
    if not U.OnRosterChanges then return end
    local changes, n = Changes(before, after)
    if initial or n > 0 then U.OnRosterChanges(guild, changes, initial and true or false) end
end
local function RemoteSource()
    if U.IsGateway() then return U.remote and U.remote.name end
    return U.linkState and U.linkState.name
end
function U.RosterState(guild)
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    if guild == U.guild then
        local fresh = U.own[U.me] ~= nil and U.clock() - lastRead <= 60
        return { fresh = fresh, status = fresh and "own" or "loading",
            age = cache and math.max(0, U.stamp() - cache.at) or nil,
            at = cache and cache.at, fullAt = cache and cache.fullAt, source = U.me }
    end
    local connected = U.guild and U.Connected() and true or false
    local age = cache and math.max(0, U.stamp() - cache.at) or nil
    local limit = cache and cache.revision and FRESH_FOR or 240
    local sameSource = cache and (not RemoteSource() or RemoteSource() == cache.source)
    local fresh = connected and cache ~= nil and acceptedAt[guild] ~= nil and sameSource
        and not needsFull[guild] and U.clock() - acceptedAt[guild] <= limit
    local status
    if not cache then status = connected and "loading" or "disconnected"
    elseif not connected then status = "disconnected"
    elseif needsFull[guild] or not sameSource then status = "syncing"
    elseif not fresh then status = "stale"
    else status = "connected" end
    return { fresh = fresh and true or false, status = status, age = age, at = cache and cache.at,
        fullAt = cache and cache.fullAt, source = cache and cache.source,
        revision = cache and cache.revision, epoch = cache and cache.epoch }
end
function U.RosterFresh(guild) return U.RosterState(guild).fresh end
local function AskFull(guild, source, reason)
    needsFull[guild], deltaPending[guild] = true, nil
    if U.RequestFullRoster then U.RequestFullRoster(guild, source, reason) end
    if U.Refresh then U.Refresh() end
    return false
end
function U.RequestRoster()
    if not U.guild or U.clock() - lastRequest < 10 or U.ChatLocked() then return end
    lastRequest = U.clock()
    local fn = C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster
    if fn then pcall(fn) end
end
local function SafeNumber(v, fallback)
    return U.Public(v) and type(v) == "number" and v or fallback
end
function U.ReadRoster()
    lastAttempt = U.clock()
    if not U.guild or U.ChatLocked() then return Incomplete() end
    local count = GetNumGuildMembers()
    if not U.Public(count) or type(count) ~= "number" or count < 1 or count > 1500 then return Incomplete() end
    local rows = {}
    for i = 1, count do
        local name, rankName, rank, level, _, zone, _, _, online, _, class = GetGuildRosterInfo(i)
        name = U.Name(name)
        if not name or not U.Public(rank) or not U.Public(online) or not U.Public(level) then return Incomplete() end
        rows[name] = { name = name, rankName = U.Text(rankName, 120) and rankName or "",
            rank = SafeNumber(rank, 99), level = SafeNumber(level, 0),
            zone = U.Text(zone, 180) and zone or "", online = online and true or false,
            class = U.Text(class, 30) and class or "", guild = U.guild }
    end
    if not rows[U.me] then return Incomplete() end
    local before = U.own
    local firstReady = not before[U.me] or before[U.me].guild ~= U.guild
    U.own, lastRead, dirty = rows, U.clock(), false
    dirtySince = nil
    U.db.rosters[U.guild] = { rows = rows, at = U.stamp(), fullAt = U.stamp(), source = U.me }
    Announce(U.guild, before, rows, firstReady)
    if firstReady and U.OnRosterReady then U.OnRosterReady() end
    if U.Refresh then U.Refresh() end
    return true
end
function U.RowPack(row)
    return U.Pack({ row.name, row.rank, row.rankName, row.level, row.class, row.zone, row.online and "1" or "0" })
end
function U.RowUnpack(raw, guild)
    local f = U.Unpack(raw, 7)
    if not f or #f ~= 7 then return nil end
    local name, rank, level = U.Name(f[1]), Integer(f[2], 0, 99), Integer(f[4], 0, 100)
    if not name or not rank or not level then return nil end
    if #f[3] > 120 or #f[5] > 30 or #f[6] > 180 or (f[7] ~= "0" and f[7] ~= "1") then return nil end
    return { name = name, rank = rank, rankName = f[3], level = level, class = f[5], zone = f[6], online = f[7] == "1", guild = guild }
end
local function Context(target)
    if published and published.guild == U.guild and published.target == target and published.tenure == U.gatewaySince then return published end
    return { guild = U.guild, target = target, tenure = U.gatewaySince, epoch = U.NewID(), revision = 0 }
end
function U.PublishRoster(target, localOnly)
    if not U.guild or not next(U.own) or (not localOnly and not target) then return false end
    local rows, page, jobs = {}, {}, {}
    for _, row in pairs(U.own) do rows[#rows + 1] = row end
    table.sort(rows, function(a, b) return a.name < b.name end)
    local context = localOnly and { epoch = U.NewID(), revision = 0 } or Context(target)
    local version, revision, total = U.NewID(), context.revision + 1, math.ceil(#rows / 35)
    for i, row in ipairs(rows) do
        page[#page + 1] = U.RowPack(row)
        if #page == 35 or i == #rows then
            jobs[#jobs + 1] = { kind = "ROSTER",
                fields = { U.guild, version, math.ceil(i / 35), total, #rows, U.Pack(page), context.epoch, revision },
                dist = localOnly and "GUILD" or "WHISPER", target = not localOnly and target or nil,
                priority = false, requiresGateway = not localOnly }
            page = {}
        end
    end
    if not U.QueueBatch(jobs) then return false end
    if not localOnly then
        context.revision, context.rows, context.sentAt = revision, U.own, U.clock()
        published = context
        U.lastSnapshot, U.snapshotDue = U.clock(), U.clock() + 180
    end
    return true
end
function U.TakeRoster(fields, sender)
    if #fields ~= 6 and #fields ~= 8 then return false end
    local guild, version = Integer(fields[1], 1, 2), fields[2]
    local index, pages, count = Integer(fields[3], 1, 43), Integer(fields[4], 1, 43), Integer(fields[5], 1, 1500)
    local epoch = #fields == 8 and fields[7] or nil
    local revision = #fields == 8 and Integer(fields[8], 1, 1000000000) or nil
    if not guild or guild == U.guild or not U.Text(version, 40) or not index or not pages or index > pages then return false end
    if not count or math.ceil(count / 35) ~= pages then return false end
    if #fields == 8 and (not U.Text(epoch, 40) or epoch == "" or not revision) then return false end
    local expectedSource, cache = RemoteSource(), U.db.rosters[guild]
    if expectedSource and expectedSource ~= sender then return false end
    if epoch and cache and cache.epoch == epoch and cache.source == sender and (cache.revision or 0) > revision then return false end
    local strings = U.Unpack(fields[6], 35)
    if not strings or #strings == 0 then return false end
    local rows = {}
    for _, raw in ipairs(strings) do
        local row = U.RowUnpack(raw, guild)
        if not row then return false end
        rows[#rows + 1] = row
    end
    if (index < pages and #rows ~= 35) or (index == pages and #rows ~= count - (pages - 1) * 35) then return false end
    local p = pending[guild]
    if p and p.source == sender and p.epoch == epoch and p.revision and revision and p.revision > revision then return false end
    if not p or p.version ~= version or p.source ~= sender then
        p = { version = version, source = sender, epoch = epoch, revision = revision, count = count,
            pages = pages, received = 0, at = U.clock(), parts = {}, initial = not U.RosterFresh(guild) }
        pending[guild] = p
    end
    if p.pages ~= pages or p.count ~= count or p.epoch ~= epoch or p.revision ~= revision then return false end
    if cache and (cache.source ~= sender or cache.epoch ~= epoch) then needsFull[guild] = true end
    if not p.parts[index] then p.parts[index] = rows; p.received = p.received + 1 end
    if p.received ~= pages then return true end
    local all, n = {}, 0
    for i = 1, pages do
        for _, row in ipairs(p.parts[i]) do
            if all[row.name] then pending[guild] = nil return false end
            all[row.name] = row; n = n + 1
        end
    end
    if n ~= count then pending[guild] = nil return false end
    -- A newer complete delta may have arrived while this snapshot was assembling.
    cache = U.db.rosters[guild]
    if epoch and cache and cache.epoch == epoch and cache.source == sender and (cache.revision or 0) > revision then pending[guild] = nil return false end
    local before = cache and cache.rows
    U.db.rosters[guild] = { rows = all, at = U.stamp(), fullAt = U.stamp(), source = sender, epoch = epoch, revision = revision }
    acceptedAt[guild], needsFull[guild], pending[guild], deltaPending[guild] = U.clock(), nil, nil, nil
    Announce(guild, before, all, p.initial)
    if U.LearnRosterContacts then U.LearnRosterContacts(guild, all) end
    if U.Refresh then U.Refresh() end
    return true
end
function U.PublishRosterDelta(target)
    local context = published
    if not context or context.guild ~= U.guild or context.target ~= target or context.tenure ~= U.gatewaySince or not context.rows then return false end
    local ops = {}
    for name, row in pairs(U.own) do
        if not Same(context.rows[name], row) then ops[#ops + 1] = { name = name, row = row } end
    end
    for name in pairs(context.rows) do if not U.own[name] then ops[#ops + 1] = { name = name } end end
    if #ops > 140 then return U.PublishRoster(target) end
    table.sort(ops, function(a, b) return a.name < b.name end)
    local from, revision = context.revision, context.revision + (#ops > 0 and 1 or 0)
    local pages, count, jobs = math.max(1, math.ceil(#ops / 35)), Count(U.own), {}
    for page = 1, pages do
        local upserts, removals = {}, {}
        for i = (page - 1) * 35 + 1, math.min(page * 35, #ops) do
            local op = ops[i]
            if op.row then upserts[#upserts + 1] = U.RowPack(op.row) else removals[#removals + 1] = op.name end
        end
        jobs[#jobs + 1] = { kind = "DELTA",
            fields = { U.guild, context.epoch, from, revision, page, pages, U.Pack(upserts), U.Pack(removals), count },
            dist = "WHISPER", target = target, priority = false, requiresGateway = true }
    end
    if not U.QueueBatch(jobs) then return false end
    context.revision, context.rows, context.sentAt = revision, U.own, U.clock()
    return true
end
function U.TakeRosterDelta(fields, sender)
    if #fields ~= 9 then return false end
    local guild, epoch = Integer(fields[1], 1, 2), fields[2]
    local from, revision = Integer(fields[3], 1, 1000000000), Integer(fields[4], 1, 1000000000)
    local index, pages, count = Integer(fields[5], 1, 4), Integer(fields[6], 1, 4), Integer(fields[9], 1, 1500)
    if not guild or guild == U.guild or not U.Text(epoch, 40) or epoch == "" or not from or not revision or not index or not pages or index > pages or not count then return false end
    if revision ~= from and revision ~= from + 1 then return false end
    local up, remove = U.Unpack(fields[7], 35), U.Unpack(fields[8], 35)
    if not up or not remove or #up + #remove > 35 then return false end
    local empty = #up + #remove == 0
    if empty and (pages ~= 1 or revision ~= from) then return false end
    if not empty and revision ~= from + 1 then return false end
    local cache, expectedSource = U.db.rosters[guild], RemoteSource()
    if expectedSource and expectedSource ~= sender then return false end
    if not cache or cache.source ~= sender or cache.epoch ~= epoch or not cache.revision then return AskFull(guild, sender, "epoch") end
    if revision < cache.revision or (revision == cache.revision and not empty) then return false end
    if needsFull[guild] or from ~= cache.revision then return AskFull(guild, sender, "revision") end
    if empty then
        if count ~= Count(cache.rows) then return AskFull(guild, sender, "count") end
        cache.at, acceptedAt[guild] = U.stamp(), U.clock()
        return true
    end
    local page, named = { up = {}, remove = {} }, {}
    for _, raw in ipairs(up) do
        local row = U.RowUnpack(raw, guild)
        if not row or named[row.name] then return false end
        page.up[#page.up + 1], named[row.name] = row, true
    end
    for _, raw in ipairs(remove) do
        local name = U.Name(raw)
        if not name or named[name] then return false end
        page.remove[#page.remove + 1], named[name] = name, true
    end
    local p = deltaPending[guild]
    if p and (p.epoch ~= epoch or p.source ~= sender or p.from ~= from or p.revision ~= revision) then return AskFull(guild, sender, "overlap") end
    if not p then
        p = { epoch = epoch, source = sender, from = from, revision = revision, pages = pages, count = count,
            received = 0, parts = {}, at = U.clock(), initial = not U.RosterFresh(guild) }
        deltaPending[guild] = p
    end
    if p.pages ~= pages or p.count ~= count then return AskFull(guild, sender, "parts") end
    if not p.parts[index] then p.parts[index] = page; p.received = p.received + 1 end
    if p.received ~= pages then return true end
    local all, changed = {}, {}
    for name, row in pairs(cache.rows) do all[name] = row end
    for i = 1, pages do
        for _, row in ipairs(p.parts[i].up) do
            if changed[row.name] then return AskFull(guild, sender, "duplicate") end
            all[row.name], changed[row.name] = row, true
        end
        for _, name in ipairs(p.parts[i].remove) do
            if changed[name] or not all[name] then return AskFull(guild, sender, "removal") end
            all[name], changed[name] = nil, true
        end
    end
    if Count(all) ~= count then return AskFull(guild, sender, "count") end
    local before = cache.rows
    U.db.rosters[guild] = { rows = all, at = U.stamp(), fullAt = cache.fullAt or cache.at,
        source = sender, epoch = epoch, revision = revision }
    acceptedAt[guild], deltaPending[guild] = U.clock(), nil
    Announce(guild, before, all, p.initial)
    if U.Refresh then U.Refresh() end
    return true
end
function U.RosterTick()
    if not U.guild then return end
    local now, gateway = U.clock(), U.IsGateway()
    if wasGateway and not gateway then published = nil end
    wasGateway = gateway
    local settled = now - changedAt >= 2 or now - (dirtySince or now) >= MAX_DEBOUNCE
    if dirty and settled and now - lastAttempt >= READ_RETRY and now - lastRead >= READ_GAP then U.ReadRoster() end
    if now - lastRequest > (gateway and 15 or 45) then U.RequestRoster(); if not dirty then MarkDirty() end end
    for guild, p in pairs(pending) do
        if now - p.at > 60 then pending[guild] = nil; AskFull(guild, p.source, "snapshot_timeout") end
    end
    for guild, p in pairs(deltaPending) do
        if now - p.at > 20 then AskFull(guild, p.source, "delta_timeout") end
    end
    if gateway and U.remote and U.Connected() and now >= (U.snapshotDue or 0) and U.QueueSize() < 100 then
        local ready = not dirty and now - lastRead < 1 and U.own[U.me]
        if not ready and now - lastAttempt >= READ_RETRY then ready = U.ReadRoster() end
        if ready and U.PublishRoster(U.remote.name) then
            U.snapshotDue, U.lastSnapshot = now + 180, now
        else U.snapshotDue = now + READ_RETRY end
    end
    if gateway and U.remote and U.Connected() and published and not dirty and now - lastRead <= 60
        and now - published.sentAt >= DELTA_EVERY and U.QueueSize() < 100 then
        U.PublishRosterDelta(U.remote.name)
    end
end
U.On("GUILD_ROSTER_UPDATE", MarkDirty)
U.On("PLAYER_GUILD_UPDATE", MarkDirty)
U.On("PLAYER_REGEN_ENABLED", MarkDirty)
