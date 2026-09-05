--[[
    LowPlayerServerFinder.lua  (v2 - có xác minh sau khi vào server)

    Vấn đề của v1: API servers/Public trả số người bị cache trễ 30-60s.
    Server hiện "1/7" lúc quét có thể đã 5/7 lúc bạn vào.

    v2 xử lý bằng cách:
      1. Ước lượng người chơi = max(playing, #playerTokens)  -> bắt được server
         bị thiếu field "playing" (v1 tính nhầm thành 0 người).
      2. Ngưỡng MaxPlayers = SỐ NGƯỜI KHÁC (không tính bản thân bạn).
      3. Chọn ngẫu nhiên trong nhóm ít người nhất -> tránh mọi người dồn
         vào cùng một jobId.
      4. Sau khi teleport, đếm lại người thật trong server. Nếu vượt ngưỡng
         thì blacklist server đó và nhảy tiếp, tối đa MaxHopAttempts lần.
      5. Blacklist + tiến độ được lưu qua teleport (file hoặc queue_on_teleport).

    QUAN TRỌNG: muốn bước 4-5 hoạt động thì PHẢI đặt ScriptUrl, vì script bị
    hủy khi teleport và cần tự chạy lại ở server mới.

    Cách dùng:
        getgenv().LPSF_CONFIG = {
            MaxPlayers = 1,
            AutoHop    = true,
            ScriptUrl  = "https://raw.githubusercontent.com/<user>/<repo>/main/LowPlayerServerFinder.lua",
        }
        loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/LowPlayerServerFinder.lua"))()
--]]

------------------------------------------------------------------------
-- CẤU HÌNH
------------------------------------------------------------------------

local DEFAULTS = {
    -- Bộ lọc
    MaxPlayers   = 1,       -- số NGƯỜI KHÁC tối đa cho phép (0 = server rỗng)
    MinPlayers   = 0,       -- đặt 1 nếu không muốn server hoàn toàn rỗng
    Pages        = 6,       -- số trang quét (100 server/trang)
    PageSize     = 100,     -- Roblox chỉ nhận 10 / 25 / 50 / 100
    SortOrder    = "Asc",
    ExcludeFull  = true,

    -- Chống dữ liệu cache cũ
    UseTokenCount   = true, -- lấy max(playing, #playerTokens)
    RandomizePick   = true, -- chọn ngẫu nhiên trong nhóm ít người nhất
    VerifyAfterJoin = true, -- vào rồi đếm lại, sai thì nhảy tiếp
    VerifyDelay     = 6,    -- giây chờ cho người khác load xong mới đếm
    VerifySamples   = 4,    -- số lần lấy mẫu trong khoảng chờ (lấy giá trị cao nhất)
    MaxHopAttempts  = 8,    -- số lần nhảy tối đa trong một chuỗi tìm kiếm
    BlacklistTTL    = 900,  -- giây giữ server xấu trong blacklist
    RehopIfFills    = false,-- server đạt chuẩn rồi nhưng sau đó đông lên -> nhảy tiếp

    -- Mạng
    PageDelay        = 0.3,
    RetryDelay       = 4,
    MaxRetries        = 5,
    CacheBust        = true, -- thêm tham số ?_=tick (chỉ vượt được cache CDN)
    TeleportCooldown = 3,
    TeleportTimeout  = 15,

    -- Hành vi
    AutoHop      = false,
    KeepScanning = true,    -- chưa có server phù hợp thì quét lại
    ScanInterval = 10,

    -- Bắt buộc nếu muốn xác minh sau khi vào
    ScriptUrl    = "",

    ShowUI       = true,
    ToggleKey    = Enum.KeyCode.RightShift,
}

local genv = (type(getgenv) == "function") and getgenv() or _G

local CONFIG = {}
for key, value in pairs(DEFAULTS) do
    CONFIG[key] = value
end
if type(genv.LPSF_CONFIG) == "table" then
    for key, value in pairs(genv.LPSF_CONFIG) do
        if CONFIG[key] ~= nil then
            CONFIG[key] = value
        end
    end
end

------------------------------------------------------------------------
-- SERVICES
------------------------------------------------------------------------

local Players          = game:GetService("Players")
local HttpService      = game:GetService("HttpService")
local TeleportService  = game:GetService("TeleportService")
local StarterGui       = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

repeat task.wait() until Players.LocalPlayer
local LocalPlayer = Players.LocalPlayer

local PLACE_ID    = game.PlaceId
local CURRENT_JOB = game.JobId
local STATE_FILE  = "LPSF_state_" .. tostring(PLACE_ID) .. ".json"

local state = {
    busy           = false,
    stopRequested  = false,
    lastResults    = {},
    blacklist      = {},   -- jobId -> os.time() lúc bị loại
    attempts       = 0,
    teleportFailed = false,
    teleportFlood  = false,
    lastTeleportAt = 0,
    statusLabel    = nil,
    liveLabel      = nil,
    listFrame      = nil,
    gui            = nil,
    refreshList    = nil,
    verified       = false,
}

if genv.LPSF_CLEANUP then
    pcall(genv.LPSF_CLEANUP)
end

------------------------------------------------------------------------
-- TIỆN ÍCH
------------------------------------------------------------------------

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title, Text = text, Duration = duration or 4,
        })
    end)
end

local function setStatus(message)
    print("[LPSF] " .. message)
    if state.statusLabel and state.statusLabel.Parent then
        state.statusLabel.Text = message
    end
end

local function shortId(jobId)
    if type(jobId) ~= "string" then return "?" end
    return string.sub(jobId, 1, 8) .. "..."
end

-- Số người KHÁC trong server hiện tại (không tính bản thân)
local function countOthers()
    return math.max(#Players:GetPlayers() - 1, 0)
end

------------------------------------------------------------------------
-- LƯU TRẠNG THÁI QUA TELEPORT
------------------------------------------------------------------------

local hasFS = type(writefile) == "function"
    and type(readfile) == "function"
    and type(isfile) == "function"

local function pruneBlacklist()
    local now = os.time()
    for jobId, stamp in pairs(state.blacklist) do
        if type(stamp) ~= "number" or now - stamp > CONFIG.BlacklistTTL then
            state.blacklist[jobId] = nil
        end
    end
end

local function buildStatePayload()
    pruneBlacklist()
    return {
        version    = 2,
        placeId    = PLACE_ID,
        attempts   = state.attempts,
        blacklist  = state.blacklist,
        savedAt    = os.time(),
        maxPlayers = CONFIG.MaxPlayers,
        minPlayers = CONFIG.MinPlayers,
        chainActive = true,
    }
end

local function saveState()
    if not hasFS then return end
    pcall(function()
        writefile(STATE_FILE, HttpService:JSONEncode(buildStatePayload()))
    end)
end

local function clearState()
    state.attempts = 0
    if hasFS then
        pcall(function()
            if isfile(STATE_FILE) then
                writefile(STATE_FILE, HttpService:JSONEncode({ chainActive = false, savedAt = os.time() }))
            end
        end)
    end
end

local function loadState()
    -- Ưu tiên biến truyền qua queue_on_teleport, sau đó tới file
    local raw = genv.LPSF_RESUME
    if type(raw) ~= "table" and hasFS then
        local ok, contents = pcall(function()
            if isfile(STATE_FILE) then return readfile(STATE_FILE) end
            return nil
        end)
        if ok and type(contents) == "string" and contents ~= "" then
            local decoded
            ok, decoded = pcall(function() return HttpService:JSONDecode(contents) end)
            if ok and type(decoded) == "table" then
                raw = decoded
            end
        end
    end
    genv.LPSF_RESUME = nil

    if type(raw) ~= "table" or not raw.chainActive then
        return nil
    end
    -- Bỏ trạng thái quá cũ (đã hơn 30 phút)
    if type(raw.savedAt) == "number" and os.time() - raw.savedAt > 1800 then
        return nil
    end
    if type(raw.blacklist) == "table" then
        state.blacklist = raw.blacklist
    end
    state.attempts = tonumber(raw.attempts) or 0
    if tonumber(raw.maxPlayers) then CONFIG.MaxPlayers = tonumber(raw.maxPlayers) end
    if tonumber(raw.minPlayers) then CONFIG.MinPlayers = tonumber(raw.minPlayers) end
    pruneBlacklist()
    return raw
end

------------------------------------------------------------------------
-- HTTP
------------------------------------------------------------------------

local rawRequest =
    (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

local function httpGet(url)
    if type(rawRequest) == "function" then
        local ok, response = pcall(rawRequest, {
            Url = url,
            Method = "GET",
            Headers = { ["Cache-Control"] = "no-cache" },
        })
        if ok and type(response) == "table" and response.Body then
            return tonumber(response.StatusCode) or 0, tostring(response.Body)
        end
    end

    local ok, result = pcall(function()
        return game:HttpGet(url, true)
    end)
    if ok and type(result) == "string" then
        return 200, result
    end

    local message = tostring(result)
    if message:find("429") or message:find("Too Many Requests") then
        return 429, message
    end
    return nil, message
end

local function buildUrl(cursor)
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&limit=%d&excludeFullGames=%s",
        PLACE_ID, CONFIG.SortOrder, CONFIG.PageSize, CONFIG.ExcludeFull and "true" or "false"
    )
    if CONFIG.CacheBust then
        url = url .. "&_=" .. tostring(math.floor(tick() * 1000))
    end
    if type(cursor) == "string" and cursor ~= "" then
        url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
    end
    return url
end

local function fetchPage(cursor)
    for attempt = 1, CONFIG.MaxRetries do
        if state.stopRequested then return nil end
        local status, body = httpGet(buildUrl(cursor))

        if status == 200 then
            local ok, decoded = pcall(function() return HttpService:JSONDecode(body) end)
            if ok and type(decoded) == "table" then
                return decoded
            end
            setStatus("Phản hồi không phải JSON, thử lại...")
            task.wait(1)

        elseif status == 429 then
            local wait = CONFIG.RetryDelay * attempt
            setStatus(string.format("Rate-limit (429), chờ %.0fs...", wait))
            task.wait(wait)

        elseif status == 400 or status == 404 then
            setStatus("API từ chối placeId này (400/404).")
            return nil

        else
            setStatus(string.format("Lỗi HTTP (%s), thử lại %d/%d...",
                tostring(status or body), attempt, CONFIG.MaxRetries))
            task.wait(1.5 * attempt)
        end
    end
    return nil
end

------------------------------------------------------------------------
-- QUÉT SERVER
------------------------------------------------------------------------

-- Ước lượng số người: Roblox có thể bỏ hẳn field "playing", nên lấy giá trị
-- lớn hơn giữa "playing" và số playerTokens trả về.
local function estimatePlayers(raw)
    local playing = tonumber(raw.playing) or 0
    local tokens  = 0
    if CONFIG.UseTokenCount and type(raw.playerTokens) == "table" then
        tokens = #raw.playerTokens
    end
    return math.max(playing, tokens), playing, tokens
end

local function scanServers()
    local results, seen = {}, {}
    local scanned, skippedBlacklist = 0, 0
    local cursor = nil

    pruneBlacklist()

    for page = 1, CONFIG.Pages do
        if state.stopRequested then break end
        setStatus(string.format("Quét trang %d/%d...", page, CONFIG.Pages))

        local payload = fetchPage(cursor)
        if not payload then break end

        for _, raw in ipairs(payload.data or {}) do
            local jobId = raw.id
            if type(jobId) == "string" and jobId ~= "" and not seen[jobId] then
                seen[jobId] = true
                scanned = scanned + 1

                if jobId == CURRENT_JOB then
                    -- bỏ qua server đang ở
                elseif state.blacklist[jobId] then
                    skippedBlacklist = skippedBlacklist + 1
                else
                    local estimated, playing, tokens = estimatePlayers(raw)
                    if estimated >= CONFIG.MinPlayers and estimated <= CONFIG.MaxPlayers then
                        table.insert(results, {
                            jobId      = jobId,
                            playing    = estimated,
                            reported   = playing,
                            tokens     = tokens,
                            maxPlayers = tonumber(raw.maxPlayers) or 0,
                            ping       = tonumber(raw.ping),
                        })
                    end
                end
            end
        end

        cursor = payload.nextPageCursor
        if type(cursor) ~= "string" or cursor == "" then break end
        task.wait(CONFIG.PageDelay)
    end

    table.sort(results, function(a, b)
        if a.playing == b.playing then
            return (a.ping or 9999) < (b.ping or 9999)
        end
        return a.playing < b.playing
    end)

    -- Xáo trộn trong từng nhóm cùng số người: vẫn ưu tiên server ít người nhất,
    -- nhưng không phải ai chạy script cũng nhảy vào đúng một jobId.
    if CONFIG.RandomizePick and #results > 1 then
        local index = 1
        while index <= #results do
            local last = index
            while last < #results and results[last + 1].playing == results[index].playing do
                last = last + 1
            end
            for i = last, index + 1, -1 do
                local j = math.random(index, i)
                results[i], results[j] = results[j], results[i]
            end
            index = last + 1
        end
    end

    setStatus(string.format("Quét %d server | khớp: %d | bỏ qua (blacklist): %d",
        scanned, #results, skippedBlacklist))
    return results
end

------------------------------------------------------------------------
-- TELEPORT
------------------------------------------------------------------------

local teleportConnection = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
    if player ~= LocalPlayer then return end
    state.teleportFailed = true
    state.teleportFlood = (result == Enum.TeleportResult.Flooded)
    setStatus("Teleport lỗi: " .. tostring(message))
end)

local function queueSelf()
    if CONFIG.ScriptUrl == "" then return false end
    local queueFn =
        (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
        or queue_on_teleport
    if type(queueFn) ~= "function" then return false end

    local payload = string.format(
        'getgenv().LPSF_RESUME = game:GetService("HttpService"):JSONDecode(%q); ' ..
        'getgenv().LPSF_CONFIG = game:GetService("HttpService"):JSONDecode(%q); ' ..
        'loadstring(game:HttpGet(%q))()',
        HttpService:JSONEncode(buildStatePayload()),
        HttpService:JSONEncode({
            MaxPlayers      = CONFIG.MaxPlayers,
            MinPlayers      = CONFIG.MinPlayers,
            Pages           = CONFIG.Pages,
            AutoHop         = false, -- để luồng xác minh tự quyết định
            KeepScanning    = CONFIG.KeepScanning,
            ScanInterval    = CONFIG.ScanInterval,
            VerifyAfterJoin = CONFIG.VerifyAfterJoin,
            VerifyDelay     = CONFIG.VerifyDelay,
            MaxHopAttempts  = CONFIG.MaxHopAttempts,
            RehopIfFills    = CONFIG.RehopIfFills,
            ScriptUrl       = CONFIG.ScriptUrl,
            ShowUI          = CONFIG.ShowUI,
        }),
        CONFIG.ScriptUrl
    )

    local ok = pcall(queueFn, payload)
    return ok
end

local function teleportTo(server)
    -- Giữ khoảng cách giữa các lần teleport, tránh bị Roblox chặn (Flooded)
    local sinceLast = tick() - state.lastTeleportAt
    if sinceLast < CONFIG.TeleportCooldown then
        task.wait(CONFIG.TeleportCooldown - sinceLast)
    end

    state.teleportFailed = false
    state.teleportFlood  = false
    state.attempts = state.attempts + 1

    -- Đánh dấu server này là "đã thử" trước khi đi, để nếu nó đông thì
    -- vòng sau không quay lại nữa.
    state.blacklist[server.jobId] = os.time()
    saveState()

    if CONFIG.VerifyAfterJoin then
        if not queueSelf() then
            setStatus("CẢNH BÁO: không queue được script -> sẽ không tự kiểm tra sau khi vào.")
        end
    end

    setStatus(string.format("Vào %s (%d/%d theo API) - lần thử %d/%d",
        shortId(server.jobId), server.playing, server.maxPlayers,
        state.attempts, CONFIG.MaxHopAttempts))

    state.lastTeleportAt = tick()
    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(PLACE_ID, server.jobId, LocalPlayer)
    end)
    if not ok then
        setStatus("Không gọi được teleport: " .. tostring(err))
        return false
    end

    local waited = 0
    while waited < CONFIG.TeleportTimeout do
        if state.teleportFailed then
            if state.teleportFlood then
                setStatus("Bị chặn vì teleport quá nhanh, chờ 8s...")
                task.wait(8)
            end
            return false
        end
        task.wait(0.5)
        waited = waited + 0.5
    end
    return true
end

------------------------------------------------------------------------
-- XÁC MINH SAU KHI VÀO SERVER
------------------------------------------------------------------------

-- Người khác có thể còn đang load, nên lấy mẫu nhiều lần và giữ giá trị cao nhất.
local function sampleOthers()
    local worst = countOthers()
    local samples = math.max(CONFIG.VerifySamples, 1)
    local step = math.max(CONFIG.VerifyDelay / samples, 0.5)
    for _ = 1, samples do
        if state.stopRequested then break end
        task.wait(step)
        local current = countOthers()
        if current > worst then worst = current end
    end
    return worst
end

local runScan -- forward declaration

local function watchForFill()
    if not CONFIG.RehopIfFills then return end
    Players.PlayerAdded:Connect(function()
        task.wait(1)
        if state.busy or state.stopRequested then return end
        if countOthers() > CONFIG.MaxPlayers then
            setStatus(string.format("Server đông lên (%d người khác), tìm server mới...", countOthers()))
            runScan(true)
        end
    end)
end

local function verifyCurrentServer()
    state.busy = true
    setStatus(string.format("Đang xác minh server (chờ %ds cho người khác load)...", CONFIG.VerifyDelay))

    local others = sampleOthers()

    if others <= CONFIG.MaxPlayers then
        state.verified = true
        clearState()
        setStatus(string.format("ĐẠT: %d người khác (ngưỡng <= %d). Ở lại server này.",
            others, CONFIG.MaxPlayers))
        notify("Low Player Finder", string.format("Đã vào server %d người khác", others))
        state.busy = false
        watchForFill()
        return true
    end

    state.blacklist[CURRENT_JOB] = os.time()
    saveState()
    setStatus(string.format("KHÔNG ĐẠT: %d người khác (API báo sai vì cache). Nhảy tiếp...", others))

    if state.attempts >= CONFIG.MaxHopAttempts then
        setStatus(string.format("Đã nhảy %d lần mà không đạt. Dừng lại. Thử tăng MaxPlayers hoặc chờ giờ vắng.",
            state.attempts))
        notify("Low Player Finder", "Hết số lần thử. Xem console.")
        clearState()
        state.busy = false
        return false
    end

    state.busy = false
    runScan(true)
    return false
end

------------------------------------------------------------------------
-- VÒNG QUÉT CHÍNH
------------------------------------------------------------------------

function runScan(hopAfter)
    if state.busy then
        setStatus("Đang chạy, chờ chút...")
        return
    end
    state.busy = true
    state.stopRequested = false

    task.spawn(function()
        repeat
            local results = scanServers()
            state.lastResults = results
            if state.refreshList then
                pcall(state.refreshList, results)
            end

            if #results > 0 then
                if not hopAfter then
                    notify("Low Player Finder",
                        string.format("%d server <= %d người khác", #results, CONFIG.MaxPlayers))
                    break
                end

                -- Nhảy ngay, không chờ thêm: mỗi giây trôi qua là dữ liệu càng cũ.
                local hopped = false
                for index = 1, #results do
                    if state.stopRequested then break end
                    if state.attempts >= CONFIG.MaxHopAttempts then
                        setStatus("Đã hết số lần nhảy cho phép.")
                        break
                    end
                    if teleportTo(results[index]) then
                        hopped = true
                        break -- script sẽ chết ở đây do teleport
                    end
                    task.wait(1)
                end

                if hopped then
                    state.busy = false
                    return
                end
                setStatus("Không teleport được vào server nào trong danh sách.")
                if not CONFIG.KeepScanning then break end
            end

            if CONFIG.KeepScanning and not state.stopRequested then
                setStatus(string.format("Chưa có server <= %d người khác. Quét lại sau %ds...",
                    CONFIG.MaxPlayers, CONFIG.ScanInterval))
                task.wait(CONFIG.ScanInterval)
            end
        until not CONFIG.KeepScanning or state.stopRequested

        state.busy = false
    end)
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

local function makeButton(parent, text, color, order)
    local button = Instance.new("TextButton")
    button.Size            = UDim2.new(1, -16, 0, 26)
    button.BackgroundColor3 = color
    button.BorderSizePixel = 0
    button.Text            = text
    button.TextColor3      = Color3.fromRGB(255, 255, 255)
    button.Font            = Enum.Font.GothamMedium
    button.TextSize        = 13
    button.LayoutOrder     = order
    button.Parent          = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button
    return button
end

local function makeNumberRow(parent, labelText, value, order, onChange)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 26)
    row.BackgroundTransparency = 1
    row.LayoutOrder = order
    row.Parent = parent

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.62, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text = labelText
    label.TextColor3 = Color3.fromRGB(190, 190, 200)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.Parent = row

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0.38, 0, 1, 0)
    box.Position = UDim2.new(0.62, 0, 0, 0)
    box.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
    box.BorderSizePixel = 0
    box.Text = tostring(value)
    box.TextColor3 = Color3.fromRGB(240, 240, 245)
    box.ClearTextOnFocus = false
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.Parent = row

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = box

    box.FocusLost:Connect(function()
        local parsed = tonumber(box.Text)
        if parsed then
            onChange(math.floor(parsed))
        end
        box.Text = tostring(onChange())
    end)
    return box
end

local function buildUI()
    local parent = game:GetService("CoreGui")
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then parent = result end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name           = "LowPlayerServerFinder"
    gui.ResetOnSpawn   = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local parented = pcall(function() gui.Parent = parent end)
    if not parented then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
    if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
    state.gui = gui

    local frame = Instance.new("Frame")
    frame.Size            = UDim2.new(0, 310, 0, 350)
    frame.Position        = UDim2.new(0, 24, 0.5, -175)
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    frame.BorderSizePixel = 0
    frame.Active          = true
    frame.Parent          = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 10)
    frameCorner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 60, 70)
    stroke.Parent = frame

    local header = Instance.new("Frame")
    header.Size            = UDim2.new(1, 0, 0, 32)
    header.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    header.BorderSizePixel = 0
    header.Parent          = frame

    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 10)
    headerCorner.Parent = header

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -40, 1, 0)
    title.Position = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text = "Server ít người (v2)"
    title.TextColor3 = Color3.fromRGB(235, 235, 240)
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Font = Enum.Font.GothamBold
    title.TextSize = 14
    title.Parent = header

    local closeButton = Instance.new("TextButton")
    closeButton.Size = UDim2.new(0, 30, 0, 30)
    closeButton.Position = UDim2.new(1, -32, 0, 1)
    closeButton.BackgroundTransparency = 1
    closeButton.Text = "X"
    closeButton.TextColor3 = Color3.fromRGB(200, 90, 90)
    closeButton.Font = Enum.Font.GothamBold
    closeButton.TextSize = 14
    closeButton.Parent = header

    local body = Instance.new("Frame")
    body.Size = UDim2.new(1, 0, 1, -32)
    body.Position = UDim2.new(0, 0, 0, 32)
    body.BackgroundTransparency = 1
    body.Parent = frame

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 5)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = body

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 8)
    padding.Parent = body

    local liveLabel = Instance.new("TextLabel")
    liveLabel.Size = UDim2.new(1, -16, 0, 18)
    liveLabel.BackgroundTransparency = 1
    liveLabel.Text = "Server này: ? người khác"
    liveLabel.TextColor3 = Color3.fromRGB(140, 200, 140)
    liveLabel.TextXAlignment = Enum.TextXAlignment.Left
    liveLabel.Font = Enum.Font.Code
    liveLabel.TextSize = 12
    liveLabel.LayoutOrder = 1
    liveLabel.Parent = body
    state.liveLabel = liveLabel

    makeNumberRow(body, "Người khác tối đa:", CONFIG.MaxPlayers, 2, function(value)
        if value ~= nil and value >= 0 then CONFIG.MaxPlayers = value end
        return CONFIG.MaxPlayers
    end)

    makeNumberRow(body, "Số trang quét:", CONFIG.Pages, 3, function(value)
        if value ~= nil and value >= 1 then CONFIG.Pages = value end
        return CONFIG.Pages
    end)

    makeNumberRow(body, "Chờ xác minh (giây):", CONFIG.VerifyDelay, 4, function(value)
        if value ~= nil and value >= 1 then CONFIG.VerifyDelay = value end
        return CONFIG.VerifyDelay
    end)

    local scanButton = makeButton(body, "Chỉ quét (không nhảy)", Color3.fromRGB(48, 96, 168), 5)
    local hopButton  = makeButton(body, "Quét + nhảy + xác minh", Color3.fromRGB(46, 140, 86), 6)
    local stopButton = makeButton(body, "Dừng / Xoá blacklist", Color3.fromRGB(120, 60, 60), 7)

    local listFrame = Instance.new("ScrollingFrame")
    listFrame.Size = UDim2.new(1, -16, 0, 110)
    listFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
    listFrame.BorderSizePixel = 0
    listFrame.ScrollBarThickness = 4
    listFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    listFrame.LayoutOrder = 8
    listFrame.Parent = body
    state.listFrame = listFrame

    local listCorner = Instance.new("UICorner")
    listCorner.CornerRadius = UDim.new(0, 6)
    listCorner.Parent = listFrame

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding = UDim.new(0, 3)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent = listFrame

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, -16, 0, 44)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = "Sẵn sàng."
    statusLabel.TextColor3 = Color3.fromRGB(170, 170, 180)
    statusLabel.TextWrapped = true
    statusLabel.TextXAlignment = Enum.TextXAlignment.Left
    statusLabel.TextYAlignment = Enum.TextYAlignment.Top
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 11
    statusLabel.LayoutOrder = 9
    statusLabel.Parent = body
    state.statusLabel = statusLabel

    state.refreshList = function(results)
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then child:Destroy() end
        end
        for index, server in ipairs(results) do
            if index > 30 then break end
            local ping = server.ping and string.format("%dms", server.ping) or "-"
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, -8, 0, 22)
            row.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
            row.BorderSizePixel = 0
            row.Text = string.format("  %d/%d  api:%d tok:%d  %s  %s",
                server.playing, server.maxPlayers, server.reported, server.tokens, ping, shortId(server.jobId))
            row.TextColor3 = Color3.fromRGB(220, 220, 230)
            row.TextXAlignment = Enum.TextXAlignment.Left
            row.Font = Enum.Font.Code
            row.TextSize = 11
            row.LayoutOrder = index
            row.Parent = listFrame

            local rowCorner = Instance.new("UICorner")
            rowCorner.CornerRadius = UDim.new(0, 4)
            rowCorner.Parent = row

            row.MouseButton1Click:Connect(function()
                task.spawn(teleportTo, server)
            end)
        end
        listFrame.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 6)
    end

    scanButton.MouseButton1Click:Connect(function() runScan(false) end)
    hopButton.MouseButton1Click:Connect(function()
        state.attempts = 0
        runScan(true)
    end)
    stopButton.MouseButton1Click:Connect(function()
        state.stopRequested = true
        state.blacklist = {}
        clearState()
        setStatus("Đã dừng và xoá blacklist.")
    end)
    closeButton.MouseButton1Click:Connect(function()
        state.stopRequested = true
        gui:Destroy()
    end)

    -- Kéo cửa sổ
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == CONFIG.ToggleKey then
            frame.Visible = not frame.Visible
        end
    end)

    -- Cập nhật số người thật trong server hiện tại
    task.spawn(function()
        while gui.Parent do
            if state.liveLabel and state.liveLabel.Parent then
                state.liveLabel.Text = string.format("Server này: %d người khác / tối đa %d",
                    countOthers(), Players.MaxPlayers)
            end
            task.wait(1)
        end
    end)

    return gui
end

------------------------------------------------------------------------
-- KHỞI ĐỘNG
------------------------------------------------------------------------

genv.LPSF_CLEANUP = function()
    state.stopRequested = true
    if teleportConnection then teleportConnection:Disconnect() end
    if state.gui then state.gui:Destroy() end
end

math.randomseed(os.time() + math.floor(tick() * 1000) % 100000)

local resume = loadState()

if CONFIG.ShowUI then
    local ok, err = pcall(buildUI)
    if not ok then
        warn("[LPSF] Không tạo được UI: " .. tostring(err))
    end
end

setStatus(string.format("placeId=%d | server này: %d người khác | ngưỡng <= %d",
    PLACE_ID, countOthers(), CONFIG.MaxPlayers))

if CONFIG.VerifyAfterJoin and CONFIG.ScriptUrl == "" then
    setStatus("Chưa đặt ScriptUrl -> không thể tự kiểm tra và nhảy tiếp sau khi teleport.")
end

if resume then
    -- Vừa teleport tới từ vòng trước: kiểm tra server này có thật sự vắng không
    notify("Low Player Finder", "Đang xác minh server vừa vào...")
    task.spawn(verifyCurrentServer)
elseif CONFIG.AutoHop then
    -- Nếu server đang ở đã đạt yêu cầu thì khỏi cần nhảy
    if countOthers() <= CONFIG.MaxPlayers then
        setStatus(string.format("Server hiện tại đã đạt (%d người khác). Không cần nhảy.", countOthers()))
        watchForFill()
    else
        state.attempts = 0
        runScan(true)
    end
else
    watchForFill()
end

return {
    scan      = scanServers,
    hop       = function() state.attempts = 0; runScan(true) end,
    verify    = verifyCurrentServer,
    teleport  = teleportTo,
    config    = CONFIG,
    blacklist = function() return state.blacklist end,
    results   = function() return state.lastResults end,
}