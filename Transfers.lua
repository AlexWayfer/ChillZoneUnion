local _, U = ...
local lastReady, lastResend = -100, -100
function U.Tickets()
    U.db.tickets = U.db.tickets or {}
    return U.db.tickets
end
local function ValidTicket(t)
    return t and U.stamp() - t.created < 1800 and t.state ~= "declined" and t.state ~= "done"
end
function U.TransferPeer(name)
    for _, t in pairs(U.Tickets()) do
        if ValidTicket(t) and t.member == name and t.dest == U.guild
            and (t.state == "accepted" or t.state == "ready") then return t.source end
    end
end
local function FreshRemoteRoster(guild)
    local cache = U.db and U.db.rosters and U.db.rosters[guild]
    if guild == U.guild or not cache or type(cache.at) ~= "number" or U.stamp() - cache.at > 600 or cache.at > U.stamp() + 60 then return nil end
    return cache.rows
end
local function LiveAddonMember(name)
    local peer = U.peers[name]
    return name == U.me or (peer and U.clock() - peer.at <= 65) or false
end
function U.CreateTransfer(name, guild)
    guild = guild or U.guild
    name = U.Name(name)
    if not name or not U.guild or not U.GUILDS[guild] then return false end
    if guild ~= U.guild then
        if not U.IsUnionLeader() then U.Print("Предложить переход из другой гильдии может руководитель союза.") return false end
        local remoteRows = FreshRemoteRoster(guild)
        local remoteRow = remoteRows and remoteRows[name]
        if not remoteRow or not remoteRow.online or remoteRow.rank == 0 or name == U.me then
            U.Print("Для перехода выбери участника второй гильдии в сети; её глава перейти не может. При необходимости обнови состав.") return false
        end
        if not U.Connected() then U.Print("Дождитесь связи со второй гильдией.") return false end
        return U.Emit("UTICKET", { guild, U.NewID(), name, U.guild, U.me, U.stamp(), U.guild }) == true
    end
    if not U.IsMaster() then U.Print("Предложить переход может глава текущей гильдии.") return false end
    local row = U.own[name]
    if not row or name == U.me or row.rank == 0 then U.Print("Выберите участника своей гильдии. Главу гильдии переводить нельзя.") return false end
    if not row.online or not U.peers[name] or U.clock() - U.peers[name].at > 65 then
        U.Print("Для согласованного перехода участник должен быть онлайн с установленным аддоном.") return false
    end
    if not U.Connected() then U.Print("Дождитесь связи со второй гильдией.") return false end
    return U.Emit("TICKET", { U.guild, U.NewID(), name, U.OtherGuild(), U.me, U.stamp() }) == true
end
local function FieldsMatch(t, f)
    return t and tonumber(f[1]) == t.source and f[2] == t.id and f[3] == t.member and tonumber(f[4]) == t.dest
end
function U.TransferMessage(kind, f, sender, remote)
    local tickets = U.Tickets()
    if kind == "TICKET" or kind == "UTICKET" then
        local union = kind == "UTICKET"
        if #f ~= (union and 7 or 6) then return false end
        local src, dest, member, master, created = tonumber(f[1]), tonumber(f[4]), U.Name(f[3]), U.Name(f[5]), tonumber(f[6])
        if not src or not dest or not U.GUILDS[src] or dest ~= (src == 1 and 2 or 1) or not member or not master then return false end
        if not U.Text(f[2], 40) or f[2] == "" or not created or U.stamp() - created > 1800 or created - U.stamp() > 60 then return false end
        local authority = union and tonumber(f[7]) or src
        if union then
            if authority ~= dest or not U.IsUnionLeader(master, authority) then return false end
            if remote then
                if src ~= U.guild or U.TrustedPeer(sender) ~= authority then return false end
                local row = U.own[member]
                if not row or not row.online or row.rank == 0 or not LiveAddonMember(member) then return false end
            else
                if authority ~= U.guild or sender ~= master then return false end
                local roster = FreshRemoteRoster(src)
                local row = roster and roster[member]
                if not row or not row.online or row.rank == 0 then return false end
            end
        elseif remote then
            if dest ~= U.guild or U.TrustedPeer(sender) ~= src then return false end
            local roster = U.db.rosters[src]
            if not roster or U.stamp() - roster.at > 600 or not roster.rows[master] or roster.rows[master].rank ~= 0 or not roster.rows[member] then return false end
        else
            if src ~= U.guild or sender ~= master or not U.own[master] or U.own[master].rank ~= 0 or not U.own[member] then return false end
        end
        local existing = tickets[f[2]]
        if existing then
            return existing.source == src and existing.dest == dest and existing.member == member and existing.master == master
                and existing.created == created and (existing.authorityGuild or existing.source) == authority
        end
        tickets[f[2]] = { id = f[2], source = src, dest = dest, member = member, master = master, created = created, authorityGuild = authority, state = "proposed" }
        if member == U.me then U.Notify("Глава предлагает перейти в «" .. U.GUILDS[dest] .. "». /cz → Переходы: согласиться или отказаться.")
        elseif remote and U.CanInvite() then U.Notify("Предложен переход: " .. U.SafeDisplay(member) .. ". /cz → Переходы.") end
        if U.Refresh then U.Refresh() end
        return true
    elseif kind == "ACCEPT" or kind == "DECLINE" then
        if #f ~= 4 then return false end
        local t = tickets[f[2]]
        if not FieldsMatch(t, f) or not ValidTicket(t) then return false end
        if remote then
            if U.TrustedPeer(sender) ~= t.source or t.dest ~= U.guild then return false end
        elseif sender ~= t.member or U.guild ~= t.source or not U.own[sender] then return false end
        if t.state ~= "proposed" then return kind == "ACCEPT" end
        t.state = kind == "ACCEPT" and "accepted" or "declined"
        if t.dest == U.guild and kind == "ACCEPT" and U.CanInvite() then U.Notify(U.SafeDisplay(t.member) .. " согласился на переход. Дождитесь выхода из старой гильдии.") end
        if U.Refresh then U.Refresh() end
        return true
    elseif kind == "READY" then
        if #f ~= 2 then return false end
        local t = tickets[f[1]]
        if not ValidTicket(t) or t.dest ~= U.guild or f[2] ~= t.member or sender ~= t.member
            or (t.state ~= "accepted" and t.state ~= "ready") then return false end
        local changed = t.state ~= "ready"
        t.state = "ready"
        if changed and U.CanInvite() then U.Notify(U.SafeDisplay(t.member) .. " сообщает о выходе. Можно отправить приглашение: /cz → Переходы.") end
        if U.Refresh then U.Refresh() end
        return true
    end
    return false
end
function U.AcceptTransfer(id, accept)
    local t = U.Tickets()[id]
    if not ValidTicket(t) or t.member ~= U.me or U.guild ~= t.source or t.state ~= "proposed" then return end
    U.Emit(accept and "ACCEPT" or "DECLINE", { t.source, t.id, t.member, t.dest })
    if accept then
        t.contact = U.remote and U.remote.name or U.linkState and U.linkState.name
        U.Print("Согласие отправлено. Дождитесь готовности офицера второй гильдии, затем нажмите «Подготовить выход».")
    end
end
function U.LeaveForTransfer(id)
    local t = U.Tickets()[id]
    if not ValidTicket(t) or t.member ~= U.me or U.guild ~= t.source or t.state ~= "accepted" then return end
    if U.IsMaster() then U.Print("Глава гильдии сначала должен передать руководство.") return end
    -- Leave/Invite are protected on modern clients. Prepare the native command;
    -- only the player's own Enter key executes it through Blizzard's chat handler.
    if InCombatLockdown() then U.Print("Подготовьте выход после боя.") return end
    ChatFrame_OpenChat("/gquit")
    U.Print("Подготовлена команда выхода. Нажмите Enter, только когда офицер второй гильдии готов пригласить вас.")
end
function U.InviteTransfer(id)
    local t = U.Tickets()[id]
    if not ValidTicket(t) or t.dest ~= U.guild or t.state ~= "ready" or not U.CanInvite() then return end
    if InCombatLockdown() then U.Print("Пригласите участника после боя.") return end
    ChatFrame_OpenChat("/ginvite " .. t.member)
    U.Print("Нажмите Enter, чтобы отправить штатное приглашение. Его принятие подтвердит сам участник.")
end
function U.IdentityChanged(previous)
    if not U.db then return end
    for _, t in pairs(U.Tickets()) do
        if t.member == U.me and ValidTicket(t) then
            if U.guild == t.dest then t.state = "done"; U.Print("Переход завершён: «" .. U.GUILDS[t.dest] .. "».")
            elseif previous == t.source and not U.guild and t.state == "accepted" then t.left = true; lastReady = -100 end
        end
    end
end
function U.TransferTick()
    if not U.db then return end
    local tickets, now = U.Tickets(), U.clock()
    for id, t in pairs(tickets) do
        if U.stamp() - t.created >= 1800 then tickets[id] = nil
        elseif t.dest == U.guild and U.own[t.member] then t.state = "done" end
    end
    if U.guild and U.IsGateway() and U.Connected() and now - lastResend > 45 then
        lastResend = now
        for _, t in pairs(tickets) do
            local authority = t.authorityGuild or t.source
            if authority == t.dest and authority == U.guild and ValidTicket(t) and U.IsUnionLeader(t.master, authority) then
                local roster = FreshRemoteRoster(t.source)
                local row = roster and roster[t.member]
                if row and row.online and row.rank ~= 0 then
                    U.Queue("UTICKET", { t.source, t.id, t.member, t.dest, t.master, t.created, authority }, "WHISPER", U.remote.name, true)
                end
            elseif authority == t.source and t.source == U.guild and ValidTicket(t) and U.own[t.member] and U.own[t.master] and U.own[t.master].rank == 0 then
                U.Queue("TICKET", { t.source, t.id, t.member, t.dest, t.master, t.created }, "WHISPER", U.remote.name, true)
                if t.state == "accepted" then U.Queue("ACCEPT", { t.source, t.id, t.member, t.dest }, "WHISPER", U.remote.name, true) end
            elseif authority == t.dest and t.source == U.guild and ValidTicket(t) and t.state == "accepted" and U.own[t.member] then
                U.Queue("ACCEPT", { t.source, t.id, t.member, t.dest }, "WHISPER", U.remote.name, true)
            end
        end
    end
    if now - lastReady < 30 then return end
    lastReady = now
    for _, t in pairs(tickets) do
        if t.member == U.me and t.left and not U.guild and ValidTicket(t) then
            local list = {}
            for n, c in pairs(U.db.contacts) do if c.guild == t.dest and n ~= t.contact then list[#list + 1] = n end end
            table.sort(list)
            if t.contact then table.insert(list, 1, t.contact) end
            for i = 1, math.min(4, #list) do U.Queue("READY", { t.id, U.me }, "WHISPER", list[i], true) end
        end
    end
end
