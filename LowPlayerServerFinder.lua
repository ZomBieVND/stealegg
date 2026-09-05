--[[
    LowPlayerServerFinder.lua
    Tìm và nhảy sang server (game instance) ít người chơi của experience đang mở.

    Dùng qua executor:
        loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/LowPlayerServerFinder.lua"))()

    Tuỳ chọn cấu hình trước khi load:
        getgenv().LPSF_CONFIG = { MaxPlayers = 1, AutoHop = true, KeepScanning = true }
        loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/main/LowPlayerServerFinder.lua"))()

    Yêu cầu: executor có game:HttpGet (hoặc request/http_request).
--]]

------------------------------------------------------------------------
-- CẤU HÌNH
------------------------------------------------------------------------

local DEFAULT_CONFIG = {
    MaxPlayers        = 3,      -- chỉ nhận server có <= N người
    MinPlayers        = 0,      -- đặt 1 nếu không muốn server rỗng hoàn toàn
    Pages             = 4,      -- số trang API cần quét (100 server/trang)
    PageSize          = 100,    -- Roblox chỉ nhận 10 / 25 / 50 / 100
    SortOrder         = "Asc",  -- "Asc" hoặc "Desc"
    ExcludeFull       = true,   -- bỏ server đã full
    PageDelay         = 0.35,   -- nghỉ giữa các trang, tránh 429
    RetryDelay        = 4,      -- thời gian chờ cơ bản khi bị rate-limit
    MaxRetries        = 5,      -- số lần thử lại mỗi trang
    MaxHopAttempts    = 5,      -- thử tối đa bao nhiêu server nếu teleport lỗi
    TeleportTimeout   = 12,     -- giây chờ xác nhận teleport
    AutoHop           = false,  -- quét xong nhảy luôn, không cần bấm
    KeepScanning      = false,  -- lặp lại tới khi tìm được server phù hợp
    ScanInterval      = 12,     -- nghỉ giữa các vòng quét lại
    ReExecuteAfterHop = false,  -- tự chạy lại script sau khi sang server mới
    ScriptUrl         = "",     -- raw URL của chính file này (cần cho tuỳ chọn trên)
    ShowUI            = true,   -- hiện bảng điều khiển
    ToggleKey         = Enum.KeyCode.RightShift,
}

local genv = (type(getgenv) == "function") and getgenv() or _G

local CONFIG = {}
for key, value in pairs(DEFAULT_CONFIG) do
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
-- SERVICES & TRẠNG THÁI
------------------------------------------------------------------------

local Players           = game:GetService("Players")
local HttpService       = game:GetService("HttpService")
local TeleportService   = game:GetService("TeleportService")
local StarterGui        = game:GetService("StarterGui")
local UserInputService  = game:GetService("UserInputService")

repeat task.wait() until Players.LocalPlayer
local LocalPlayer = Players.LocalPlayer

local PLACE_ID    = game.PlaceId
local CURRENT_JOB = game.JobId

local state = {
    busy           = false,
    stopRequested  = false,
    lastResults    = {},
    teleportFailed = false,
    statusLabel    = nil,
    listFrame      = nil,
    gui            = nil,
}

-- Huỷ instance cũ nếu script được chạy lại trong cùng session
if genv.LPSF_CLEANUP then
    pcall(genv.LPSF_CLEANUP)
end

------------------------------------------------------------------------
-- TIỆN ÍCH
------------------------------------------------------------------------

local function notify(title, text, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title    = title,
            Text     = text,
            Duration = duration or 4,
        })
    end)
end

local function setStatus(message)
    print("[LPSF] " .. message)
    if state.statusLabel and state.statusLabel.Parent then
        state.statusLabel.Text = message
    end
end

-- Gom mọi biến thể HTTP của các executor lại một chỗ
local rawRequest =
    (syn and syn.request)
    or (http and http.request)
    or http_request
    or (fluxus and fluxus.request)
    or request

local function httpGet(url)
    if type(rawRequest) == "function" then
        local ok, response = pcall(rawRequest, { Url = url, Method = "GET" })
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
        PLACE_ID,
        CONFIG.SortOrder,
        CONFIG.PageSize,
        CONFIG.ExcludeFull and "true" or "false"
    )
    if type(cursor) == "string" and cursor ~= "" then
        url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
    end
    return url
end

local function shortId(jobId)
    return string.sub(jobId, 1, 8) .. "..."
end

------------------------------------------------------------------------
-- GỌI API
------------------------------------------------------------------------

local function fetchPage(cursor)
    for attempt = 1, CONFIG.MaxRetries do
        local status, body = httpGet(buildUrl(cursor))

        if status == 200 then
            local ok, decoded = pcall(function()
                return HttpService:JSONDecode(body)
            end)
            if ok and type(decoded) == "table" then
                return decoded
            end
            setStatus("Phản hồi không phải JSON, thử lại...")
            task.wait(1)

        elseif status == 429 then
            local wait = CONFIG.RetryDelay * attempt
            setStatus(string.format("Bị rate-limit (429), chờ %.0fs...", wait))
            task.wait(wait)

        elseif status == 400 or status == 404 then
            setStatus("API từ chối placeId này (400/404). Game có thể không công khai.")
            return nil

        else
            setStatus(string.format("Lỗi HTTP (%s), thử lại lần %d...", tostring(status or body), attempt))
            task.wait(1.5 * attempt)
        end
    end
    return nil
end

local function scanServers()
    local results, seen = {}, {}
    local scanned = 0
    local cursor = nil

    for page = 1, CONFIG.Pages do
        if state.stopRequested then break end

        setStatus(string.format("Đang quét trang %d/%d...", page, CONFIG.Pages))
        local payload = fetchPage(cursor)
        if not payload then break end

        for _, raw in ipairs(payload.data or {}) do
            local jobId = raw.id
            if type(jobId) == "string" and jobId ~= "" and not seen[jobId] then
                seen[jobId] = true
                scanned = scanned + 1

                -- Roblox có thể bỏ hẳn field "playing" khi server đang rỗng
                local playing = tonumber(raw.playing) or 0
                local capacity = tonumber(raw.maxPlayers) or 0

                if jobId ~= CURRENT_JOB
                    and playing >= CONFIG.MinPlayers
                    and playing <= CONFIG.MaxPlayers
                then
                    table.insert(results, {
                        jobId      = jobId,
                        playing    = playing,
                        maxPlayers = capacity,
                        ping       = tonumber(raw.ping),
                    })
                end
            end
        end

        cursor = payload.nextPageCursor
        if type(cursor) ~= "string" or cursor == "" then
            break
        end
        task.wait(CONFIG.PageDelay)
    end

    table.sort(results, function(a, b)
        if a.playing == b.playing then
            return (a.ping or 9999) < (b.ping or 9999)
        end
        return a.playing < b.playing
    end)

    setStatus(string.format("Quét %d server, khớp điều kiện: %d", scanned, #results))
    return results
end

------------------------------------------------------------------------
-- TELEPORT
------------------------------------------------------------------------

local teleportConnection = TeleportService.TeleportInitFailed:Connect(function(player, result, message)
    if player == LocalPlayer then
        state.teleportFailed = true
        setStatus("Teleport lỗi: " .. tostring(message))
    end
end)

local function queueReExecute()
    if not CONFIG.ReExecuteAfterHop or CONFIG.ScriptUrl == "" then
        return
    end
    local queueFn =
        (syn and syn.queue_on_teleport)
        or (fluxus and fluxus.queue_on_teleport)
        or queue_on_teleport
    if type(queueFn) == "function" then
        pcall(queueFn, string.format('loadstring(game:HttpGet(%q))()', CONFIG.ScriptUrl))
    end
end

local function teleportTo(server)
    state.teleportFailed = false
    queueReExecute()

    setStatus(string.format("Đang vào %s (%d/%d người)...", shortId(server.jobId), server.playing, server.maxPlayers))

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
            return false
        end
        task.wait(0.5)
        waited = waited + 0.5
    end
    return true
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

local refreshList -- forward declaration

local function runScan(hopAfter)
    if state.busy then
        setStatus("Đang chạy rồi, chờ chút...")
        return
    end

    state.busy = true
    state.stopRequested = false

    task.spawn(function()
        repeat
            local results = scanServers()
            state.lastResults = results

            if refreshList then
                refreshList(results)
            end

            if #results > 0 then
                notify("Low Player Finder", string.format("Tìm được %d server <= %d người", #results, CONFIG.MaxPlayers))

                if hopAfter then
                    local attempts = math.min(#results, CONFIG.MaxHopAttempts)
                    for index = 1, attempts do
                        if state.stopRequested then break end
                        if teleportTo(results[index]) then
                            state.busy = false
                            return
                        end
                        task.wait(1)
                    end
                    setStatus("Thử hết server khả dụng mà không vào được.")
                end
                break
            end

            if CONFIG.KeepScanning and not state.stopRequested then
                setStatus(string.format("Chưa có server <= %d người, quét lại sau %ds...", CONFIG.MaxPlayers, CONFIG.ScanInterval))
                task.wait(CONFIG.ScanInterval)
            end
        until not CONFIG.KeepScanning or state.stopRequested

        state.busy = false
    end)
end

local function makeButton(parent, text, color, order)
    local button = Instance.new("TextButton")
    button.Name             = "Btn_" .. text
    button.Size             = UDim2.new(1, -16, 0, 28)
    button.BackgroundColor3  = color
    button.BorderSizePixel  = 0
    button.Text             = text
    button.TextColor3       = Color3.fromRGB(255, 255, 255)
    button.Font             = Enum.Font.GothamMedium
    button.TextSize         = 13
    button.AutoButtonColor  = true
    button.LayoutOrder      = order
    button.Parent           = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button

    return button
end

local function buildUI()
    local parent = game:GetService("CoreGui")
    if type(gethui) == "function" then
        local ok, result = pcall(gethui)
        if ok and result then
            parent = result
        end
    end

    local gui = Instance.new("ScreenGui")
    gui.Name             = "LowPlayerServerFinder"
    gui.ResetOnSpawn     = false
    gui.IgnoreGuiInset   = true
    gui.ZIndexBehavior   = Enum.ZIndexBehavior.Sibling

    local parented = pcall(function()
        gui.Parent = parent
    end)
    if not parented then
        gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
    if syn and syn.protect_gui then
        pcall(syn.protect_gui, gui)
    end
    state.gui = gui

    local frame = Instance.new("Frame")
    frame.Name             = "Main"
    frame.Size             = UDim2.new(0, 300, 0, 300)
    frame.Position         = UDim2.new(0, 24, 0.5, -150)
    frame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    frame.BorderSizePixel  = 0
    frame.Active           = true
    frame.Parent           = gui

    local frameCorner = Instance.new("UICorner")
    frameCorner.CornerRadius = UDim.new(0, 10)
    frameCorner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color        = Color3.fromRGB(60, 60, 70)
    stroke.Thickness    = 1
    stroke.Parent       = frame

    -- Header (kéo di chuyển)
    local header = Instance.new("Frame")
    header.Name             = "Header"
    header.Size             = UDim2.new(1, 0, 0, 34)
    header.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    header.BorderSizePixel  = 0
    header.Parent           = frame

    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 10)
    headerCorner.Parent = header

    local title = Instance.new("TextLabel")
    title.Size                   = UDim2.new(1, -40, 1, 0)
    title.Position               = UDim2.new(0, 12, 0, 0)
    title.BackgroundTransparency = 1
    title.Text                   = "Server ít người"
    title.TextColor3             = Color3.fromRGB(235, 235, 240)
    title.TextXAlignment         = Enum.TextXAlignment.Left
    title.Font                   = Enum.Font.GothamBold
    title.TextSize               = 14
    title.Parent                 = header

    local closeButton = Instance.new("TextButton")
    closeButton.Size                   = UDim2.new(0, 30, 0, 30)
    closeButton.Position               = UDim2.new(1, -32, 0, 2)
    closeButton.BackgroundTransparency = 1
    closeButton.Text                   = "X"
    closeButton.TextColor3             = Color3.fromRGB(200, 90, 90)
    closeButton.Font                   = Enum.Font.GothamBold
    closeButton.TextSize               = 14
    closeButton.Parent                 = header

    -- Thân
    local body = Instance.new("Frame")
    body.Size                   = UDim2.new(1, 0, 1, -34)
    body.Position               = UDim2.new(0, 0, 0, 34)
    body.BackgroundTransparency = 1
    body.Parent                 = frame

    local layout = Instance.new("UIListLayout")
    layout.Padding             = UDim.new(0, 6)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.SortOrder           = Enum.SortOrder.LayoutOrder
    layout.Parent              = body

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 8)
    padding.Parent     = body

    -- Ô nhập số người tối đa
    local inputRow = Instance.new("Frame")
    inputRow.Size                   = UDim2.new(1, -16, 0, 28)
    inputRow.BackgroundTransparency = 1
    inputRow.LayoutOrder            = 1
    inputRow.Parent                 = body

    local inputLabel = Instance.new("TextLabel")
    inputLabel.Size                   = UDim2.new(0.6, 0, 1, 0)
    inputLabel.BackgroundTransparency = 1
    inputLabel.Text                   = "Số người tối đa:"
    inputLabel.TextColor3             = Color3.fromRGB(190, 190, 200)
    inputLabel.TextXAlignment         = Enum.TextXAlignment.Left
    inputLabel.Font                   = Enum.Font.Gotham
    inputLabel.TextSize               = 13
    inputLabel.Parent                 = inputRow

    local inputBox = Instance.new("TextBox")
    inputBox.Size             = UDim2.new(0.4, 0, 1, 0)
    inputBox.Position         = UDim2.new(0.6, 0, 0, 0)
    inputBox.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
    inputBox.BorderSizePixel  = 0
    inputBox.Text             = tostring(CONFIG.MaxPlayers)
    inputBox.PlaceholderText  = "vd: 2"
    inputBox.TextColor3       = Color3.fromRGB(240, 240, 245)
    inputBox.ClearTextOnFocus = false
    inputBox.Font             = Enum.Font.Gotham
    inputBox.TextSize         = 13
    inputBox.Parent           = inputRow

    local inputCorner = Instance.new("UICorner")
    inputCorner.CornerRadius = UDim.new(0, 6)
    inputCorner.Parent = inputBox

    inputBox.FocusLost:Connect(function()
        local value = tonumber(inputBox.Text)
        if value and value >= 0 then
            CONFIG.MaxPlayers = math.floor(value)
            setStatus("Ngưỡng: <= " .. CONFIG.MaxPlayers .. " người")
        end
        inputBox.Text = tostring(CONFIG.MaxPlayers)
    end)

    local scanButton = makeButton(body, "Quét server", Color3.fromRGB(48, 96, 168), 2)
    local hopButton  = makeButton(body, "Quét + nhảy server", Color3.fromRGB(46, 140, 86), 3)
    local stopButton = makeButton(body, "Dừng", Color3.fromRGB(120, 60, 60), 4)

    -- Danh sách kết quả
    local listFrame = Instance.new("ScrollingFrame")
    listFrame.Size                   = UDim2.new(1, -16, 0, 120)
    listFrame.BackgroundColor3       = Color3.fromRGB(18, 18, 22)
    listFrame.BorderSizePixel        = 0
    listFrame.ScrollBarThickness     = 4
    listFrame.CanvasSize             = UDim2.new(0, 0, 0, 0)
    listFrame.LayoutOrder            = 5
    listFrame.Parent                 = body
    state.listFrame = listFrame

    local listCorner = Instance.new("UICorner")
    listCorner.CornerRadius = UDim.new(0, 6)
    listCorner.Parent = listFrame

    local listLayout = Instance.new("UIListLayout")
    listLayout.Padding   = UDim.new(0, 4)
    listLayout.SortOrder = Enum.SortOrder.LayoutOrder
    listLayout.Parent    = listFrame

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size                   = UDim2.new(1, -16, 0, 32)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text                   = "Sẵn sàng. Server hiện tại: " .. #Players:GetPlayers() .. " người."
    statusLabel.TextColor3             = Color3.fromRGB(170, 170, 180)
    statusLabel.TextWrapped            = true
    statusLabel.TextXAlignment         = Enum.TextXAlignment.Left
    statusLabel.Font                   = Enum.Font.Gotham
    statusLabel.TextSize               = 12
    statusLabel.LayoutOrder            = 6
    statusLabel.Parent                 = body
    state.statusLabel = statusLabel

    refreshList = function(results)
        for _, child in ipairs(listFrame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        for index, server in ipairs(results) do
            if index > 25 then break end
            local ping = server.ping and string.format("%dms", server.ping) or "-"
            local row = Instance.new("TextButton")
            row.Size             = UDim2.new(1, -8, 0, 24)
            row.Position         = UDim2.new(0, 4, 0, 0)
            row.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
            row.BorderSizePixel  = 0
            row.Text             = string.format("  %d/%d người  •  %s  •  %s", server.playing, server.maxPlayers, ping, shortId(server.jobId))
            row.TextColor3       = Color3.fromRGB(220, 220, 230)
            row.TextXAlignment   = Enum.TextXAlignment.Left
            row.Font             = Enum.Font.Code
            row.TextSize         = 12
            row.LayoutOrder      = index
            row.Parent           = listFrame

            local rowCorner = Instance.new("UICorner")
            rowCorner.CornerRadius = UDim.new(0, 4)
            rowCorner.Parent = row

            row.MouseButton1Click:Connect(function()
                task.spawn(teleportTo, server)
            end)
        end

        listFrame.CanvasSize = UDim2.new(0, 0, 0, listLayout.AbsoluteContentSize.Y + 8)
    end

    scanButton.MouseButton1Click:Connect(function()
        runScan(false)
    end)

    hopButton.MouseButton1Click:Connect(function()
        runScan(true)
    end)

    stopButton.MouseButton1Click:Connect(function()
        state.stopRequested = true
        setStatus("Đã yêu cầu dừng.")
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
            dragging  = true
            dragStart = input.Position
            startPos  = frame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            frame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    UserInputService.InputBegan:Connect(function(input, processed)
        if not processed and input.KeyCode == CONFIG.ToggleKey then
            frame.Visible = not frame.Visible
        end
    end)

    return gui
end

------------------------------------------------------------------------
-- KHỞI ĐỘNG
------------------------------------------------------------------------

genv.LPSF_CLEANUP = function()
    state.stopRequested = true
    if teleportConnection then
        teleportConnection:Disconnect()
    end
    if state.gui then
        state.gui:Destroy()
    end
end

if CONFIG.ShowUI then
    local ok, err = pcall(buildUI)
    if not ok then
        warn("[LPSF] Không tạo được UI: " .. tostring(err) .. " — vẫn chạy được ở chế độ không UI.")
    end
end

setStatus(string.format(
    "placeId=%d | server hiện tại: %d người | ngưỡng: <= %d",
    PLACE_ID, #Players:GetPlayers(), CONFIG.MaxPlayers
))
notify("Low Player Finder", "Đã load. RightShift để ẩn/hiện bảng.")

if CONFIG.AutoHop then
    runScan(true)
end

-- Trả về API để dùng trực tiếp từ console của executor
return {
    scan     = scanServers,
    hop      = function() runScan(true) end,
    teleport = teleportTo,
    config   = CONFIG,
    results  = function() return state.lastResults end,
}