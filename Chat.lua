local _, U = ...

local function Number(value, minimum, maximum)
    return U.Public(value) and type(value) == "number" and value == value
        and value >= minimum and value <= maximum
end

local function GuildColor()
    local c = ChatTypeInfo and ChatTypeInfo.GUILD
    if c and Number(c.r, 0, 1) and Number(c.g, 0, 1) and Number(c.b, 0, 1) then
        return c.r, c.g, c.b
    end
    return 0.25, 1, 0.25
end

local function Color(r, g, b)
    return ("|cff%02x%02x%02x"):format(math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

local function WindowCount()
    return Number(NUM_CHAT_WINDOWS, 1, 50) and math.floor(NUM_CHAT_WINDOWS) or 10
end

local function Window(index)
    local frame = _G["ChatFrame" .. index]
    if not U.Public(frame) or (type(frame) ~= "table" and type(frame) ~= "userdata")
        or type(frame.AddMessage) ~= "function" then return end
    local name
    local info = GetChatWindowInfo or FCF_GetChatWindowInfo
    if type(info) == "function" then
        local ok, value = pcall(info, index)
        if ok and U.Text(value, 128) and value ~= "" then name = value end
    end
    if not name and U.Text(frame.name, 128) and frame.name ~= "" then name = frame.name end
    return frame, name
end

local function ReceivesGuild(frame, index)
    if type(GetChatWindowMessages) == "function" then
        local types = { pcall(GetChatWindowMessages, index) }
        if types[1] then
            for i = 2, #types do
                if U.Text(types[i], 64) and types[i] == "GUILD" then return true end
            end
        end
    end
    local list = frame.messageTypeList
    if U.Public(list) and type(list) == "table" then
        for key, value in pairs(list) do
            if (U.Text(value, 64) and value == "GUILD")
                or (U.Text(key, 64) and key == "GUILD" and U.Public(value) and value == true) then return true end
        end
    end
    return false
end

local function NameKey(name)
    return U.Text(name, 128) and U.Fold(U.Trim(name)) or nil
end

function U.ChatWindowNames()
    local names, seen = {}, {}
    for i = 1, WindowCount() do
        local _, name = Window(i)
        local key = NameKey(name)
        if key and not seen[key] then names[#names + 1], seen[key] = name, true end
    end
    return names
end

function U.SetChatWindow(name)
    if not U.db then return false, "Настройки ещё не загружены." end
    if not U.Public(name) then return false, "Недоступное название вкладки чата." end
    if name == nil or (U.Text(name, 128) and U.Trim(name) == "") then
        U.db.chatFrameName = nil
        return true
    end
    local wanted = NameKey(name)
    if wanted then
        for _, existing in ipairs(U.ChatWindowNames()) do
            if NameKey(existing) == wanted then
                U.db.chatFrameName = existing
                return true
            end
        end
    end
    return false, "Вкладка чата с таким названием не найдена."
end

function U.SetGuildBadge(enabled)
    if not U.db or not U.Public(enabled) or type(enabled) ~= "boolean" then return false end
    U.db.showGuildBadge = enabled
    if U.RefreshChat then U.RefreshChat() end
    return true
end

local function Sender(entry, base)
    local name = U.Text(entry.name, 160) and U.Trim(entry.name) or "?"
    if name == "" then name = "?" end
    local row, class
    local guild = Number(entry.guild, 1, #U.GUILDS) and entry.guild or nil
    local roster = guild and U.db and U.db.rosters and U.db.rosters[guild]
    if roster and type(roster.rows) == "table" then row = roster.rows[name] end
    if not row and U.own then row = U.own[name] end
    if row then class = row.class end
    if U.Text(entry.class, 32) then class = entry.class end
    local c = U.Text(class, 32) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    local display = U.SafeDisplay(name)
    if c and Number(c.r, 0, 1) and Number(c.g, 0, 1) and Number(c.b, 0, 1) then
        display = Color(c.r, c.g, c.b) .. display .. base
    end
    -- A standard player hyperlink keeps native whisper/context-menu behaviour.
    if name ~= "?" and not name:find("[:|%c]") then
        return "|Hplayer:" .. name .. "|h[" .. display .. "]|h"
    end
    return "[" .. display .. "]"
end

function U.ChatLine(entry, includeTime)
    if not U.Public(entry) or type(entry) ~= "table" or not U.Text(entry.text, 8192) then return "" end
    local r, g, b = GuildColor()
    local base, prefix = Color(r, g, b), ""
    if U.Public(includeTime) and includeTime and Number(entry.time, 0, 100000000000) and type(date) == "function" then
        local ok, value = pcall(date, "%H:%M", entry.time)
        if ok and U.Text(value, 32) then prefix = "|cff999999[" .. value .. "]|r " end
    end
    local badge, suffix = "", ""
    if U.db and U.db.showGuildBadge == true and Number(entry.guild, 1, #U.GUILDS) then
        badge = "|cff999999[" .. entry.guild .. "]" .. base .. " "
    end
    -- Delivery changes redraw the pane; previously printed native lines remain plain.
    if U.Public(includeTime) and includeTime and U.Text(entry.status, 32) then
        if entry.status == "pending" then suffix = " |cff999999(ожидает доставки)"
        elseif entry.status == "local-only" then suffix = " |cff999999(доставка в союз не подтверждена)" end
    end
    return prefix .. base .. "[Гильдия] " .. badge .. Sender(entry, base) .. ": " .. U.ChatText(entry.text) .. suffix .. "|r"
end

local function Output(line)
    local targets, added = {}, {}
    local wanted = NameKey(U.db and U.db.chatFrameName)
    for i = 1, WindowCount() do
        local frame, name = Window(i)
        if frame and ((wanted and NameKey(name) == wanted) or (not wanted and ReceivesGuild(frame, i))) then
            if not added[frame] then targets[#targets + 1], added[frame] = frame, true end
        end
    end
    -- A renamed/deleted chosen tab falls back to the current guild-chat tabs.
    if #targets == 0 and wanted then
        for i = 1, WindowCount() do
            local frame = Window(i)
            if frame and not added[frame] and ReceivesGuild(frame, i) then
                targets[#targets + 1], added[frame] = frame, true
            end
        end
    end
    if #targets == 0 and DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        targets[1] = DEFAULT_CHAT_FRAME
    end
    local r, g, b = GuildColor()
    local count = 0
    for _, frame in ipairs(targets) do
        if pcall(frame.AddMessage, frame, line, r, g, b) then count = count + 1 end
    end
    return count
end

function U.DisplayChat(entry, native)
    if not U.Public(native) or native then return 0 end -- Blizzard already displayed our own guild's line.
    if U.Public(entry) and type(entry) == "table" then
        if not U.Public(entry.replayed) or entry.replayed == true then return 0 end
    end
    local line = U.ChatLine(entry)
    return line ~= "" and Output(line) or 0
end

function U.SystemNotice(text)
    if not U.Text(text, 8192) or U.Trim(text) == "" then return 0 end
    local r, g, b = GuildColor()
    return Output(Color(r, g, b) .. "[Союз] " .. U.SafeDisplay(text) .. "|r")
end
