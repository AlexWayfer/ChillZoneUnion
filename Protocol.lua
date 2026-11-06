local _, U = ...
-- The bundled decoder is private so another addon's shared library cannot
-- replace the output-bound enforcement used for incoming protocol data.
local D = U.Deflate
U.Deflate = D

function U.Pack(fields)
    local out = {}
    for i, value in ipairs(fields) do
        local s = tostring(value)
        out[i] = tostring(#s) .. ":" .. s
    end
    return table.concat(out)
end
function U.Unpack(s, maxFields)
    if not U.Text(s, 30000) then return nil end
    local out, at = {}, 1
    while at <= #s do
        if #out >= (maxFields or 1024) then return nil end
        local first, last, n = s:find("^(%d+):", at)
        if not first or last - first > 5 then return nil end
        n = tonumber(n)
        if n > 25000 or last + n > #s then return nil end
        out[#out + 1] = s:sub(last + 1, last + n)
        at = last + n + 1
    end
    return out
end

local queues = { {}, {} }
local buffers, seen, lastSend = {}, {}, -100
local perSender, retryAt = {}, 0
U.queueStats = { sent = 0, failed = 0, received = 0, dropped = 0 }
function U.QueueSize() return #queues[1] + #queues[2] end
function U.ClearQueue()
    queues = { {}, {} }; buffers = {}; seen = {}; perSender = {}
end
local function Plan(kind, fields, dist, target, priority, logged, fixedID, requiresGateway, expiresAt, cancelKey)
    if not U.guild and kind ~= "READY" then return nil end
    if dist ~= "GUILD" and dist ~= "WHISPER" then return nil end
    if dist == "WHISPER" and not U.Name(target) then return nil end
    local raw = kind .. "~" .. U.Pack(fields)
    local encoded = "R" .. raw
    -- Player-written chat remains plaintext for the logged messaging API.
    if #raw > 180 and D and not logged then
        local zipped = D:EncodeForWoWAddonChannel(D:CompressDeflate(raw, { level = 3 }))
        if #zipped < #raw then encoded = "Z" .. zipped end
    end
    if #encoded > 10000 then return nil end
    local id = fixedID or U.NewID()
    local pieces, at = {}, 1
    while at <= #encoded do
        local last = math.min(at + 189, #encoded)
        if logged then
            while last < #encoded do
                local byte = encoded:byte(last + 1)
                if byte < 128 or byte > 191 then break end
                last = last - 1
                if last < at then return nil end
            end
        end
        pieces[#pieces + 1] = encoded:sub(at, last)
        at = last + 1
    end
    local count = #pieces
    if count > 54 then return nil end
    local jobs = {}
    for i = 1, count do
        jobs[#jobs + 1] = { text = id .. "~" .. i .. "~" .. count .. "~" .. pieces[i],
            dist = dist, target = target, logged = logged, tries = 0,
            priority = priority and 1 or 2, requiresGateway = requiresGateway, expiresAt = expiresAt, cancelKey = cancelKey }
    end
    return jobs
end
-- Every fragment is planned before committing, including multi-page roster batches.
function U.QueueBatch(items)
    local jobs, available = {}, 1500 - U.QueueSize()
    for _, item in ipairs(items) do
        local plan = Plan(item.kind, item.fields, item.dist, item.target, item.priority,
            item.logged, item.fixedID, item.requiresGateway, item.expiresAt, item.cancelKey)
        if not plan or #jobs + #plan > available then return false end
        for _, job in ipairs(plan) do jobs[#jobs + 1] = job end
    end
    for _, job in ipairs(jobs) do
        local q = queues[job.priority]; q[#q + 1] = job
    end
    return true
end
function U.Queue(kind, fields, dist, target, priority, logged, fixedID, requiresGateway, expiresAt, cancelKey)
    return U.QueueBatch({ { kind = kind, fields = fields, dist = dist, target = target,
        priority = priority, logged = logged, fixedID = fixedID, requiresGateway = requiresGateway, expiresAt = expiresAt, cancelKey = cancelKey } })
end
function U.CancelQueued(key)
    if not key then return 0 end
    local removed = 0
    for i, q in ipairs(queues) do
        local kept = {}
        for _, job in ipairs(q) do
            if job.cancelKey == key then removed = removed + 1 else kept[#kept + 1] = job end
        end
        queues[i] = kept
    end
    return removed
end
function U.Pump()
    local now = U.clock()
    if now < retryAt or now - lastSend < 0.13 or U.ChatLocked() then return end
    local q, job
    while true do
        q = #queues[1] > 0 and queues[1] or queues[2]
        job = q[1]
        if not job then return end
        if (job.expiresAt and now > job.expiresAt) or (job.dist == "GUILD" and not U.guild) or (job.requiresGateway and not U.IsGateway()) then
            table.remove(q, 1); U.queueStats.dropped = U.queueStats.dropped + 1
        else break end
    end
    local send = job.logged and C_ChatInfo.SendAddonMessageLogged or C_ChatInfo.SendAddonMessage
    if not send then send = C_ChatInfo.SendAddonMessage end
    local ok, result = pcall(send, U.PREFIX, job.text, job.dist, job.target)
    lastSend = now
    if ok and (result == nil or result == true or result == 0) then
        table.remove(q, 1); U.queueStats.sent = U.queueStats.sent + 1
    elseif ok and (result == 3 or result == 8 or result == 9 or result == 11) then
        job.tries = job.tries + 1
        retryAt = now + math.min(15, 2 * job.tries)
        if job.tries > 8 and result ~= 11 then table.remove(q, 1); U.queueStats.failed = U.queueStats.failed + 1 end
    else
        table.remove(q, 1); U.queueStats.failed = U.queueStats.failed + 1
    end
end
function U.Receive(prefix, message, distribution, sender)
    if not U.Public(prefix) or prefix ~= U.PREFIX or not U.Text(message, 255) or not U.Text(distribution, 16) then return end
    if not U.Text(sender, 160) then return end
    local senderRealm = sender:match("%-([^%-]+)$")
    if senderRealm then
        local normalized = GetNormalizedRealmName and GetNormalizedRealmName()
        local display = GetRealmName and GetRealmName()
        local suffix = U.Fold(senderRealm):gsub("%s", "")
        local sameNormalized = U.Text(normalized, 100) and suffix == U.Fold(normalized):gsub("%s", "")
        local sameDisplay = U.Text(display, 100) and suffix == U.Fold(display):gsub("%s", "")
        if not sameNormalized and not sameDisplay then return end
    end
    sender = U.Name(sender)
    if not sender or sender == U.me or (distribution ~= "GUILD" and distribution ~= "WHISPER") then return end
    -- Unknown whispers can carry only a tiny connection handshake. Never decompress them.
    local trusted = distribution == "GUILD" and U.own and U.own[sender]
    trusted = trusted or (distribution == "WHISPER" and U.TrustedPeer(sender))
    local id, part, total, data = message:match("^([%d%.]+)~(%d+)~(%d+)~(.*)$")
    part, total = tonumber(part), tonumber(total)
    if not id or #id > 40 or not part or total < 1 or total > 54 or part < 1 or part > total then return end
    local transferReady = distribution == "WHISPER" and U.TrustedTransferPeer
        and U.TrustedTransferPeer(sender) and total == 1 and data:sub(1, 7) == "RREADY~"
    if not trusted and not transferReady and (total ~= 1 or data:sub(1, 6) ~= "RLINK~") then return end
    local rate = perSender[sender]
    if not rate or U.clock() - rate.at > 10 then rate = { at = U.clock(), n = 0 }; perSender[sender] = rate end
    rate.n = rate.n + 1
    if rate.n > 220 then return end
    local key = sender .. ":" .. distribution .. ":" .. id
    if seen[key] then return end
    local b = buffers[key]
    if not b then
        local n = 0; for _ in pairs(buffers) do n = n + 1 end
        if n >= 80 then return end
        b = { at = U.clock(), total = total, n = 0, bytes = 0, parts = {} }; buffers[key] = b
    end
    if b.total ~= total then buffers[key] = nil return end
    if not b.parts[part] then
        if b.bytes + #data > 10000 then buffers[key] = nil; return end
        b.parts[part] = data; b.n = b.n + 1; b.bytes = b.bytes + #data
    end
    if b.n ~= total then return end
    buffers[key] = nil; seen[key] = U.clock()
    local encoded = table.concat(b.parts)
    if #encoded > 10000 then return end
    local raw
    if encoded:sub(1, 1) == "R" then raw = encoded:sub(2)
    elseif trusted and D and type(D.DecompressDeflateLimited) == "function" and encoded:sub(1, 1) == "Z" then
        local zipped = D:DecodeForWoWAddonChannel(encoded:sub(2))
        if zipped then raw = D:DecompressDeflateLimited(zipped, 25000) end
    end
    if not U.Text(raw, 25000) then return end
    local kind, payload = raw:match("^([A-Z]+)~(.*)$")
    local fields = payload and U.Unpack(payload)
    if not kind or not fields then return end
    U.queueStats.received = U.queueStats.received + 1
    U.Handle(kind, fields, distribution, sender, id)
end
function U.ProtocolClean()
    local now = U.clock()
    for k, b in pairs(buffers) do if now - b.at > 90 then buffers[k] = nil end end
    for k, t in pairs(seen) do if now - t > 180 then seen[k] = nil end end
    for k, r in pairs(perSender) do if now - r.at > 60 then perSender[k] = nil end end
end
U.On("CHAT_MSG_ADDON", U.Receive)
U.On("CHAT_MSG_ADDON_LOGGED", U.Receive)
