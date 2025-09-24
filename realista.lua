-- LightingMenu.lua
-- Última versión:
-- - Reflectancia global ahora con pasos de 0.1 desde 0 hasta 10.
-- - Reflectancia aplicada con "debounce" para evitar actualizaciones masivas continuas.
-- - Se bajó la intensidad por defecto de Bloom/SunRays para que el efecto sea menos agresivo.
-- - Pequeñas optimizaciones: menos allocations en bucles críticos, batched reflectance update,
--   búsqueda de efectos y propiedades reuseadas, y evitar tareas pesadas en cada frame.
-- - Mantiene: botón "X" para cerrar, botón móvil arrastrable, sliders visuales, adaptativo a pantalla.

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local LOCAL_PLAYER = Players.LocalPlayer

-----------------------------------------------------
-- Configuración inicial (no tocar color)
-----------------------------------------------------
local LightingConfig = {
    Brightness = 0.8,
    ExposureCompensation = 0.5,
    ShadowSoftness = 1.2,
    EnvironmentDiffuseScale = 0.6,
    EnvironmentSpecularScale = 1.1,
    ClockTime = 12,
    FogStart = 0,
    FogEnd = 100000,
    GlobalShadows = true,
}

for property, value in pairs(LightingConfig) do
    pcall(function() Lighting[property] = value end)
end

-----------------------------------------------------
-- Efectos iniciales -- intensidades suavizadas por defecto
-----------------------------------------------------
local EffectsConfig = {
    BloomEffect = {
        Name = "Bloom",
        Intensity = 0.25,    -- reducido (antes 0.35)
        Size = 22,
        Threshold = 2.4,
        Enabled = true
    },
    DepthOfFieldEffect = {
        Name = "DepthOfField",
        InFocusRadius = 70,
        NearIntensity = 0.4,
        FarIntensity = 0.7,
        FocusDistance = 6,
        Enabled = true
    },
    ColorCorrectionEffect = {
        Name = "ColorCorrection",
        Brightness = 0,
        Contrast = 0.2,
        Saturation = 0.25,
        Enabled = true
    },
    SunRaysEffect = {
        Name = "SunRays",
        Intensity = 0.20, -- reducido (antes 0.4)
        Spread = 2.8,
        Enabled = true
    },
}

local function addOrUpdateEffect(effectType, properties)
    local effect = Lighting:FindFirstChildOfClass(effectType) or Instance.new(effectType, Lighting)
    for property, value in pairs(properties) do
        if effect[property] ~= nil then
            pcall(function() effect[property] = value end)
        end
    end
    return effect
end

for effectType, properties in pairs(EffectsConfig) do
    addOrUpdateEffect(effectType, properties)
end

-----------------------------------------------------
-- Reflectancia global: niveles 0..10 step 0.1 (optimizado)
-----------------------------------------------------
-- Creamos la lista de niveles programáticamente (0, 0.1, 0.2, ..., 10)
local reflectanceLevels = {}
do
    local i = 0
    while i <= 100 do
        table.insert(reflectanceLevels, math.floor((i/10) * 100 + 0.5) / 100) -- asegurar 2 decimales
        i = i + 1
    end
end

-- valor por defecto pequeño (mantengo cercano a antes para evitar brillo fuerte)
local defaultReflectance = 0.03

-- Debounce para aplicar cambios de reflectance a todos los BaseParts:
local reflectUpdateScheduled = false
local reflectPendingValue = nil
local REFLECT_DEBOUNCE = 0.06 -- segundos, small delay to batch updates

local function applyReflectanceInstant(v)
    defaultReflectance = v
    -- recorrer GetDescendants una vez (pocos allocations)
    local descendants = Workspace:GetDescendants()
    for i = 1, #descendants do
        local part = descendants[i]
        if part and part:IsA("BasePart") then
            pcall(function() part.Reflectance = defaultReflectance end)
        end
    end
end

local function scheduleReflectanceUpdate(v)
    reflectPendingValue = v
    if reflectUpdateScheduled then return end
    reflectUpdateScheduled = true
    task.spawn(function()
        task.wait(REFLECT_DEBOUNCE)
        local v2 = reflectPendingValue
        if v2 ~= nil then
            applyReflectanceInstant(v2)
        end
        reflectUpdateScheduled = false
    end)
end

local function adjustReflectance(part)
    if part:IsA("BasePart") then
        pcall(function() part.Reflectance = defaultReflectance end)
    end
end

-- aplicar valor inicial y conectar DescendantAdded
applyReflectanceInstant(defaultReflectance)
Workspace.DescendantAdded:Connect(adjustReflectance)

-----------------------------------------------------
-- Alternar DepthOfField con Alt
-----------------------------------------------------
local depthOfField = Lighting:FindFirstChild("DepthOfField")
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
        depthOfField = Lighting:FindFirstChild("DepthOfField")
        if depthOfField then
            depthOfField.Enabled = not depthOfField.Enabled
        end
    end
end)

-----------------------------------------------------
-- UI: sliders visuales, X cerrar, botón móvil, UI adaptativa
-- Optimización: evitar listeners inútiles, usar closures y reusar funciones.
-----------------------------------------------------
local DEFAULT_WIDTH = 420
local DEFAULT_HEIGHT = 700
local SCREEN_MARGIN = 20

local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function formatValue(v)
    if type(v) ~= "number" then return tostring(v) end
    if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
        return tostring(math.floor(v + 0.5))
    else
        return string.format("%.2f", v)
    end
end

local function createScreenGui()
    local old = LOCAL_PLAYER.PlayerGui:FindFirstChild("LightingMenu")
    if old then old:Destroy() end

    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "LightingMenu"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.Parent = LOCAL_PLAYER:WaitForChild("PlayerGui")

    local Frame = Instance.new("Frame", ScreenGui)
    Frame.Name = "MainFrame"
    Frame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    Frame.BorderSizePixel = 0
    Frame.ClipsDescendants = true
    Frame.Visible = false
    local UICorner = Instance.new("UICorner", Frame)
    UICorner.CornerRadius = UDim.new(0, 10)

    -- Ajuste adaptativo al viewport (llamado en RenderStepped, pero ligero)
    local function adaptFrameToViewport()
        local cam = workspace.CurrentCamera
        if not cam then return end
        local vs = cam.ViewportSize
        local maxW = math.max(100, vs.X - SCREEN_MARGIN * 2)
        local maxH = math.max(100, vs.Y - SCREEN_MARGIN * 2)
        local w = math.min(DEFAULT_WIDTH, maxW)
        local h = math.min(DEFAULT_HEIGHT, maxH)
        Frame.Size = UDim2.new(0, w, 0, h)
        Frame.Position = UDim2.new(0.5, -w/2, 0.5, -h/2)
        -- clamp por si acaso (evitar force expensive ops)
        RunService.Heartbeat:Wait()
        local absPos = Frame.AbsolutePosition
        local absSize = Frame.AbsoluteSize
        local newX = clamp(absPos.X, SCREEN_MARGIN, vs.X - absSize.X - SCREEN_MARGIN)
        local newY = clamp(absPos.Y, SCREEN_MARGIN, vs.Y - absSize.Y - SCREEN_MARGIN)
        Frame.Position = UDim2.new(0, newX, 0, newY)
    end
    -- Conectar una vez (ligero)
    RunService.RenderStepped:Connect(adaptFrameToViewport)
    adaptFrameToViewport()

    -- Header + close button (X)
    local Header = Instance.new("TextLabel", Frame)
    Header.Size = UDim2.new(1, -60, 0, 40)
    Header.Position = UDim2.new(0, 10, 0, 10)
    Header.BackgroundTransparency = 1
    Header.Text = "Lighting Menu"
    Header.TextColor3 = Color3.fromRGB(240,240,240)
    Header.Font = Enum.Font.SourceSansBold
    Header.TextSize = 18
    Header.TextXAlignment = Enum.TextXAlignment.Left

    local CloseBtn = Instance.new("TextButton", Frame)
    CloseBtn.Name = "CloseButton"
    CloseBtn.Size = UDim2.new(0, 34, 0, 34)
    CloseBtn.Position = UDim2.new(1, -44, 0, 8)
    CloseBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
    CloseBtn.Text = "X"
    CloseBtn.TextColor3 = Color3.fromRGB(230, 230, 230)
    CloseBtn.Font = Enum.Font.SourceSansBold
    CloseBtn.TextSize = 20
    CloseBtn.AutoButtonColor = true
    local CloseCorner = Instance.new("UICorner", CloseBtn)
    CloseCorner.CornerRadius = UDim.new(0, 8)
    local CloseStroke = Instance.new("UIStroke", CloseBtn)
    CloseStroke.Color = Color3.fromRGB(30,30,30)
    CloseStroke.Thickness = 1
    CloseBtn.MouseButton1Click:Connect(function() Frame.Visible = false end)

    -- ScrollingFrame container
    local Scroll = Instance.new("ScrollingFrame", Frame)
    Scroll.Name = "ScrollArea"
    Scroll.Size = UDim2.new(1, -20, 1, -160)
    Scroll.Position = UDim2.new(0, 10, 0, 60)
    Scroll.BackgroundTransparency = 1
    Scroll.BorderSizePixel = 0
    Scroll.ScrollBarThickness = 8
    Scroll.CanvasSize = UDim2.new(0, 0, 0, 0)

    local UIListLayout = Instance.new("UIListLayout", Scroll)
    UIListLayout.Padding = UDim.new(0, 10)
    UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder
    UIListLayout.VerticalAlignment = Enum.VerticalAlignment.Top

    local UIPadding = Instance.new("UIPadding", Scroll)
    UIPadding.PaddingLeft = UDim.new(0, 10)
    UIPadding.PaddingRight = UDim.new(0, 10)
    UIPadding.PaddingTop = UDim.new(0, 4)
    UIPadding.PaddingBottom = UDim.new(0, 4)

    -- Bottom controls
    local ResetButton = Instance.new("TextButton", Frame)
    ResetButton.Size = UDim2.new(0, 200, 0, 40)
    ResetButton.Position = UDim2.new(0.5, -100, 1, -80)
    ResetButton.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
    ResetButton.Text = "Reiniciar configuración"
    ResetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    ResetButton.Font = Enum.Font.SourceSansBold
    ResetButton.TextSize = 14
    local UICornerButton = Instance.new("UICorner", ResetButton)
    UICornerButton.CornerRadius = UDim.new(0, 8)

    local CloseHint = Instance.new("TextLabel", Frame)
    CloseHint.Size = UDim2.new(1, -40, 0, 20)
    CloseHint.Position = UDim2.new(0, 20, 1, -40)
    CloseHint.BackgroundTransparency = 1
    CloseHint.Text = "RightControl: abrir/ocultar | Alt: alternar DOF"
    CloseHint.TextColor3 = Color3.fromRGB(200,200,200)
    CloseHint.Font = Enum.Font.SourceSans
    CloseHint.TextSize = 12
    CloseHint.TextXAlignment = Enum.TextXAlignment.Left

    -- Slider creator (soporta mouse y touch). onChange ejecuta rápido, pero reflectance uses debounce.
    local function createSliderControl(name, defaultValue, parent, minVal, maxVal, onChange)
        if minVal == nil then minVal = -100 end
        if maxVal == nil then maxVal = 100 end
        if minVal > maxVal then minVal, maxVal = maxVal, minVal end
        defaultValue = clamp(defaultValue, minVal, maxVal)

        local Container = Instance.new("Frame", parent)
        Container.Size = UDim2.new(1, 0, 0, 64)
        Container.BackgroundTransparency = 1

        local Label = Instance.new("TextLabel", Container)
        Label.Size = UDim2.new(1, -80, 0, 20)
        Label.Position = UDim2.new(0, 0, 0, 4)
        Label.Text = name .. " (" .. formatValue(defaultValue) .. ")"
        Label.TextColor3 = Color3.new(1, 1, 1)
        Label.BackgroundTransparency = 1
        Label.Font = Enum.Font.SourceSansBold
        Label.TextSize = 14
        Label.TextXAlignment = Enum.TextXAlignment.Left

        local ValueLabel = Instance.new("TextLabel", Container)
        ValueLabel.Size = UDim2.new(0, 70, 0, 20)
        ValueLabel.Position = UDim2.new(1, -70, 0, 4)
        ValueLabel.BackgroundTransparency = 1
        ValueLabel.Text = formatValue(defaultValue)
        ValueLabel.TextColor3 = Color3.fromRGB(200,200,200)
        ValueLabel.Font = Enum.Font.SourceSans
        ValueLabel.TextSize = 14
        ValueLabel.TextXAlignment = Enum.TextXAlignment.Right

        local Track = Instance.new("Frame", Container)
        Track.Size = UDim2.new(1, -20, 0, 12)
        Track.Position = UDim2.new(0, 10, 0, 30)
        Track.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
        local TrackCorner = Instance.new("UICorner", Track)
        TrackCorner.CornerRadius = UDim.new(0, 6)
        local TrackStroke = Instance.new("UIStroke", Track)
        TrackStroke.Color = Color3.fromRGB(45,45,45)
        TrackStroke.Thickness = 1

        local Fill = Instance.new("Frame", Track)
        Fill.Size = UDim2.new(0, 0, 1, 0)
        Fill.Position = UDim2.new(0, 0, 0, 0)
        Fill.BackgroundColor3 = Color3.fromRGB(50, 160, 255)
        local FillCorner = Instance.new("UICorner", Fill)
        FillCorner.CornerRadius = UDim.new(0, 6)

        local Knob = Instance.new("ImageButton", Track)
        Knob.Size = UDim2.new(0, 20, 0, 20)
        Knob.Position = UDim2.new(0, -10, 0.5, -10)
        Knob.BackgroundTransparency = 1
        Knob.Image = ""
        local KnobFrame = Instance.new("Frame", Knob)
        KnobFrame.Size = UDim2.new(1, 0, 1, 0)
        KnobFrame.Position = UDim2.new(0, 0, 0, 0)
        KnobFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
        local KnobCorner = Instance.new("UICorner", KnobFrame)
        KnobCorner.CornerRadius = UDim.new(0, 10)
        local KnobStroke = Instance.new("UIStroke", KnobFrame)
        KnobStroke.Color = Color3.fromRGB(200,200,200)
        KnobStroke.Thickness = 1

        Knob.AutoButtonColor = false

        -- Lógica del slider
        local dragging = false
        local dragInput = nil

        local function setValueFromRelative(rel)
            rel = clamp(rel, 0, 1)
            local value = minVal + rel * (maxVal - minVal)
            -- si min/max enteros y rango>=1 -> redondear
            if math.abs(minVal - math.floor(minVal)) < 1e-6 and math.abs(maxVal - math.floor(maxVal)) < 1e-6 and (maxVal - minVal) >= 1 then
                value = math.floor(value + 0.5)
            end
            Fill.Size = UDim2.new(rel, 0, 1, 0)
            Knob.Position = UDim2.new(rel, -10, 0.5, -10)
            Label.Text = name .. " (" .. formatValue(value) .. ")"
            ValueLabel.Text = formatValue(value)
            if onChange then
                -- Se llama en cada movimiento: quien reciba cambios puede hacer su propio debounce (ej. reflectance)
                pcall(function() onChange(value) end)
            end
        end

        local function setValueAbsolute(v)
            v = clamp(v, minVal, maxVal)
            local rel = 0
            if maxVal > minVal then rel = (v - minVal) / (maxVal - minVal) end
            setValueFromRelative(rel)
        end

        local function updateFromInputPosition(x)
            local absX = Track.AbsolutePosition.X
            local width = Track.AbsoluteSize.X
            if width <= 0 then return end
            local rel = (x - absX) / width
            setValueFromRelative(rel)
        end

        Knob.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragInput = input
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false
                        dragInput = nil
                    end
                end)
            end
        end)
        Knob.InputChanged:Connect(function(input)
            if (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) and dragging and input == dragInput then
                updateFromInputPosition(input.Position.X)
            end
        end)

        Track.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                updateFromInputPosition(input.Position.X)
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if input == dragInput and dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                updateFromInputPosition(input.Position.X)
            end
        end)
        UserInputService.InputEnded:Connect(function(input)
            if input == dragInput then
                dragging = false
                dragInput = nil
            end
        end)

        -- Inicializar visual
        RunService.Heartbeat:Wait()
        setValueAbsolute(defaultValue)

        return {
            setValue = setValueAbsolute,
            getValue = function() return tonumber(ValueLabel.Text) or defaultValue end,
            label = Label,
            valueLabel = ValueLabel,
            track = Track,
            fill = Fill,
            knob = Knob
        }
    end

    -- Stepper control para reflectancia (usa niveles con step 0.1)
    local function createStepperControl(name, defaultValue, parent, levels, onChange)
        local function findClosestIndex(val)
            local bestIdx, bestDiff = 1, math.huge
            for i = 1, #levels do
                local d = math.abs(levels[i] - val)
                if d < bestDiff then bestDiff = d; bestIdx = i end
            end
            return bestIdx
        end

        local idx = findClosestIndex(defaultValue)

        local Container = Instance.new("Frame", parent)
        Container.Size = UDim2.new(1, 0, 0, 64)
        Container.BackgroundTransparency = 1

        local Label = Instance.new("TextLabel", Container)
        Label.Size = UDim2.new(1, -120, 0, 20)
        Label.Position = UDim2.new(0, 0, 0, 6)
        Label.Text = name .. " (" .. tostring(levels[idx]) .. ")"
        Label.TextColor3 = Color3.new(1, 1, 1)
        Label.BackgroundTransparency = 1
        Label.Font = Enum.Font.SourceSansBold
        Label.TextSize = 14
        Label.TextXAlignment = Enum.TextXAlignment.Left

        local ValueLabel = Instance.new("TextLabel", Container)
        ValueLabel.Size = UDim2.new(0, 80, 0, 20)
        ValueLabel.Position = UDim2.new(1, -80, 0, 6)
        ValueLabel.BackgroundTransparency = 1
        ValueLabel.Text = tostring(levels[idx])
        ValueLabel.TextColor3 = Color3.fromRGB(200,200,200)
        ValueLabel.Font = Enum.Font.SourceSans
        ValueLabel.TextSize = 14
        ValueLabel.TextXAlignment = Enum.TextXAlignment.Right

        local BtnPrev = Instance.new("TextButton", Container)
        BtnPrev.Size = UDim2.new(0, 40, 0, 30)
        BtnPrev.Position = UDim2.new(0, 10, 0, 30)
        BtnPrev.Text = "‹"
        BtnPrev.Font = Enum.Font.SourceSansBold
        BtnPrev.TextSize = 20
        BtnPrev.BackgroundColor3 = Color3.fromRGB(70,70,70)
        BtnPrev.TextColor3 = Color3.fromRGB(240,240,240)
        local prevCorner = Instance.new("UICorner", BtnPrev)
        prevCorner.CornerRadius = UDim.new(0, 8)

        local BtnNext = Instance.new("TextButton", Container)
        BtnNext.Size = UDim2.new(0, 40, 0, 30)
        BtnNext.Position = UDim2.new(0, 60, 0, 30)
        BtnNext.Text = "›"
        BtnNext.Font = Enum.Font.SourceSansBold
        BtnNext.TextSize = 20
        BtnNext.BackgroundColor3 = Color3.fromRGB(70,70,70)
        BtnNext.TextColor3 = Color3.fromRGB(240,240,240)
        local nextCorner = Instance.new("UICorner", BtnNext)
        nextCorner.CornerRadius = UDim.new(0, 8)

        local function updateUI()
            local v = levels[idx]
            Label.Text = name .. " (" .. tostring(v) .. ")"
            ValueLabel.Text = tostring(v)
            if onChange then pcall(function() onChange(v) end) end
        end

        BtnPrev.MouseButton1Click:Connect(function()
            idx = math.max(1, idx - 1)
            updateUI()
        end)
        BtnNext.MouseButton1Click:Connect(function()
            idx = math.min(#levels, idx + 1)
            updateUI()
        end)

        ValueLabel.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                idx = idx + 1
                if idx > #levels then idx = 1 end
                updateUI()
            end
        end)

        local control = {}
        function control.setValue(v)
            local best = 1; local bestd = math.huge
            for i = 1, #levels do
                local d = math.abs(levels[i] - v)
                if d < bestd then bestd = d; best = i end
            end
            idx = best
            updateUI()
        end
        function control.getValue() return levels[idx] end
        function control.getIndex() return idx end

        -- inicializar y llamar onChange para aplicar default reflectance
        updateUI()
        return control
    end

    local function createToggleControl(name, defaultValue, parent, onToggle)
        local Container = Instance.new("Frame", parent)
        Container.Size = UDim2.new(1, 0, 0, 50)
        Container.BackgroundTransparency = 1

        local Label = Instance.new("TextLabel", Container)
        Label.Size = UDim2.new(0.7, 0, 1, 0)
        Label.Position = UDim2.new(0, 0, 0, 0)
        Label.Text = name
        Label.TextColor3 = Color3.new(1, 1, 1)
        Label.BackgroundTransparency = 1
        Label.Font = Enum.Font.SourceSansBold
        Label.TextSize = 14
        Label.TextXAlignment = Enum.TextXAlignment.Left

        local Button = Instance.new("TextButton", Container)
        Button.Size = UDim2.new(0.3, -4, 0, 30)
        Button.Position = UDim2.new(0.7, 4, 0, 10)
        Button.BackgroundColor3 = defaultValue and Color3.fromRGB(0,180,0) or Color3.fromRGB(180,40,40)
        Button.Text = defaultValue and "Activo" or "Inactivo"
        Button.TextColor3 = Color3.fromRGB(255,255,255)
        Button.Font = Enum.Font.SourceSans
        Button.TextSize = 14
        local UICornerBtn = Instance.new("UICorner", Button)
        UICornerBtn.CornerRadius = UDim.new(0, 8)

        Button.MouseButton1Click:Connect(function()
            local newVal = not (Button.Text == "Activo")
            Button.Text = newVal and "Activo" or "Inactivo"
            Button.BackgroundColor3 = newVal and Color3.fromRGB(0,180,0) or Color3.fromRGB(180,40,40)
            if onToggle then pcall(function() onToggle(newVal) end) end
        end)

        return Button, Label
    end

    -- References table for reset
    local controlRefs = {}

    -- Default slider ranges (most use -100..100 except where specific)
    local defaultMin, defaultMax = -100, 100

    controlRefs.Brightness = { ctrl = createSliderControl("Brillo", Lighting.Brightness or LightingConfig.Brightness, Scroll, defaultMin, defaultMax, function(v) Lighting.Brightness = v end), getter = function() return Lighting.Brightness end }
    controlRefs.Exposure   = { ctrl = createSliderControl("Exposición", Lighting.ExposureCompensation or LightingConfig.ExposureCompensation, Scroll, defaultMin, defaultMax, function(v) Lighting.ExposureCompensation = v end), getter = function() return Lighting.ExposureCompensation end }
    controlRefs.ShadowSoftness = { ctrl = createSliderControl("Suavidad de sombra", Lighting.ShadowSoftness or LightingConfig.ShadowSoftness, Scroll, 0, 100, function(v) Lighting.ShadowSoftness = v end), getter = function() return Lighting.ShadowSoftness end }
    controlRefs.EnvironmentDiffuseScale = { ctrl = createSliderControl("Escala de entorno difuso", Lighting.EnvironmentDiffuseScale or LightingConfig.EnvironmentDiffuseScale, Scroll, 0, 100, function(v) Lighting.EnvironmentDiffuseScale = v end), getter = function() return Lighting.EnvironmentDiffuseScale end }
    controlRefs.EnvironmentSpecularScale = { ctrl = createSliderControl("Escala de entorno especular", Lighting.EnvironmentSpecularScale or LightingConfig.EnvironmentSpecularScale, Scroll, 0, 100, function(v) Lighting.EnvironmentSpecularScale = v end), getter = function() return Lighting.EnvironmentSpecularScale end }

    -- Reflectance stepper: cuando cambia se usa scheduleReflectanceUpdate (debounced)
    local reflectStepper = createStepperControl("Reflectancia Global", defaultReflectance, Scroll, reflectanceLevels, function(v) scheduleReflectanceUpdate(v) end)
    controlRefs.Reflectance = { ctrl = reflectStepper, getter = function() return defaultReflectance end }

    controlRefs.ClockTime = { ctrl = createSliderControl("Hora del día (0-24)", Lighting.ClockTime or LightingConfig.ClockTime, Scroll, 0, 24, function(v) Lighting.ClockTime = v end), getter = function() return Lighting.ClockTime end }
    controlRefs.FogStart = { ctrl = createSliderControl("FogStart (inicio niebla)", Lighting.FogStart or LightingConfig.FogStart, Scroll, 0, 100000, function(v) Lighting.FogStart = v end), getter = function() return Lighting.FogStart end }
    controlRefs.FogEnd = { ctrl = createSliderControl("FogEnd (fin niebla)", Lighting.FogEnd or LightingConfig.FogEnd, Scroll, 0, 500000, function(v) Lighting.FogEnd = v end), getter = function() return Lighting.FogEnd end }

    controlRefs.GlobalShadows = { btn, lb = nil }
    do
        local b, l = createToggleControl("Sombras Globales", Lighting.GlobalShadows, Scroll, function(v) Lighting.GlobalShadows = v end)
        controlRefs.GlobalShadows.btn = b
        controlRefs.GlobalShadows.lb = l
        controlRefs.GlobalShadows.getter = function() return Lighting.GlobalShadows end
    end

    -- Si existen efectos, creamos sus controles (rangos conservadores)
    do
        local dof = Lighting:FindFirstChild("DepthOfField")
        if dof then
            controlRefs.DOF_Radius = { ctrl = createSliderControl("DOF - Radio enfoque", dof.InFocusRadius or EffectsConfig.DepthOfFieldEffect.InFocusRadius, Scroll, 0, 10000, function(v) dof.InFocusRadius = v end), getter = function() return dof.InFocusRadius end }
            controlRefs.DOF_NearIntensity = { ctrl = createSliderControl("DOF - NearIntensity", dof.NearIntensity or EffectsConfig.DepthOfFieldEffect.NearIntensity, Scroll, 0, 10, function(v) dof.NearIntensity = v end), getter = function() return dof.NearIntensity end }
            controlRefs.DOF_FarIntensity = { ctrl = createSliderControl("DOF - FarIntensity", dof.FarIntensity or EffectsConfig.DepthOfFieldEffect.FarIntensity, Scroll, 0, 10, function(v) dof.FarIntensity = v end), getter = function() return dof.FarIntensity end }
            controlRefs.DOF_FocusDistance = { ctrl = createSliderControl("DOF - FocusDistance", dof.FocusDistance or EffectsConfig.DepthOfFieldEffect.FocusDistance, Scroll, 0, 10000, function(v) dof.FocusDistance = v end), getter = function() return dof.FocusDistance end }
            local b, l = createToggleControl("DOF Activado", dof.Enabled, Scroll, function(v) dof.Enabled = v end)
            controlRefs.DOF_Enabled = { btn = b, lb = l, getter = function() return dof.Enabled end }
        end
    end

    do
        local bloom = Lighting:FindFirstChild("Bloom")
        if bloom then
            controlRefs.Bloom_Intensity = { ctrl = createSliderControl("Bloom - Intensidad", bloom.Intensity or EffectsConfig.BloomEffect.Intensity, Scroll, 0, 100, function(v) bloom.Intensity = v end), getter = function() return bloom.Intensity end }
            controlRefs.Bloom_Size = { ctrl = createSliderControl("Bloom - Tamaño", bloom.Size or EffectsConfig.BloomEffect.Size, Scroll, 0, 500, function(v) bloom.Size = v end), getter = function() return bloom.Size end }
            controlRefs.Bloom_Threshold = { ctrl = createSliderControl("Bloom - Threshold", bloom.Threshold or EffectsConfig.BloomEffect.Threshold, Scroll, -100, 100, function(v) bloom.Threshold = v end), getter = function() return bloom.Threshold end }
            local b, l = createToggleControl("Bloom Activado", bloom.Enabled, Scroll, function(v) bloom.Enabled = v end)
            controlRefs.Bloom_Enabled = { btn = b, lb = l, getter = function() return bloom.Enabled end }
        end
    end

    do
        local sun = Lighting:FindFirstChild("SunRays")
        if sun then
            controlRefs.Sun_Intensity = { ctrl = createSliderControl("Rayos solares - Intensidad", sun.Intensity or EffectsConfig.SunRaysEffect.Intensity, Scroll, 0, 100, function(v) sun.Intensity = v end), getter = function() return sun.Intensity end }
            controlRefs.Sun_Spread = { ctrl = createSliderControl("Rayos solares - Spread", sun.Spread or EffectsConfig.SunRaysEffect.Spread, Scroll, 0, 100, function(v) sun.Spread = v end), getter = function() return sun.Spread end }
            local b, l = createToggleControl("SunRays Activado", sun.Enabled, Scroll, function(v) sun.Enabled = v end)
            controlRefs.Sun_Enabled = { btn = b, lb = l, getter = function() return sun.Enabled end }
        end
    end

    do
        local cc = Lighting:FindFirstChild("ColorCorrection")
        if cc then
            controlRefs.CC_Brightness = { ctrl = createSliderControl("ColorCorrection - Brillo", cc.Brightness or EffectsConfig.ColorCorrectionEffect.Brightness, Scroll, -100, 100, function(v) cc.Brightness = v end), getter = function() return cc.Brightness end }
            controlRefs.CC_Contrast = { ctrl = createSliderControl("ColorCorrection - Contraste", cc.Contrast or EffectsConfig.ColorCorrectionEffect.Contrast, Scroll, -100, 100, function(v) cc.Contrast = v end), getter = function() return cc.Contrast end }
            controlRefs.CC_Saturation = { ctrl = createSliderControl("ColorCorrection - Saturación", cc.Saturation or EffectsConfig.ColorCorrectionEffect.Saturation, Scroll, -100, 100, function(v) cc.Saturation = v end), getter = function() return cc.Saturation end }
            local b, l = createToggleControl("ColorCorrection Activado", cc.Enabled, Scroll, function(v) cc.Enabled = v end)
            controlRefs.CC_Enabled = { btn = b, lb = l, getter = function() return cc.Enabled end }
        end
    end

    -- CanvasSize update (ligero)
    local function updateCanvasSize()
        local contentSize = UIListLayout.AbsoluteContentSize
        Scroll.CanvasSize = UDim2.new(0, 0, 0, contentSize.Y + 16)
    end
    UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvasSize)
    Scroll.ChildAdded:Connect(function() task.wait(0.03); updateCanvasSize() end)
    Scroll.ChildRemoved:Connect(function() task.wait(0.03); updateCanvasSize() end)
    RunService.Heartbeat:Wait()
    updateCanvasSize()

    -- Reset behavior (vuelve a LightingConfig, EffectsConfig y reflectance por defecto)
    ResetButton.MouseButton1Click:Connect(function()
        for property, value in pairs(LightingConfig) do
            pcall(function() Lighting[property] = value end)
        end
        for effectType, properties in pairs(EffectsConfig) do
            addOrUpdateEffect(effectType, properties)
        end
        -- aplicar reflectancia por defecto
        scheduleReflectanceUpdate(defaultReflectance)

        -- actualizar controles visuales desde getters (solo los que exponen setValue/btn)
        for k, ref in pairs(controlRefs) do
            if ref.ctrl and ref.ctrl.setValue then
                local ok, value = pcall(ref.getter)
                if ok and value ~= nil then
                    ref.ctrl.setValue(value)
                end
            elseif ref.btn and ref.lb then
                local ok, value = pcall(ref.getter)
                if ok and value ~= nil then
                    ref.btn.Text = value and "Activo" or "Inactivo"
                    ref.btn.BackgroundColor3 = value and Color3.fromRGB(0,180,0) or Color3.fromRGB(180,40,40)
                end
            end
        end
    end)

    -- Mobile draggable toggle (solo touch)
    local function createMobileToggle()
        if not UserInputService.TouchEnabled then return end
        if ScreenGui:FindFirstChild("MobileToggle") then return end

        local btn = Instance.new("TextButton", ScreenGui)
        btn.Name = "MobileToggle"
        btn.Size = UDim2.new(0, 56, 0, 56)
        btn.Position = UDim2.new(0, 14, 1, -90)
        btn.AnchorPoint = Vector2.new(0, 0)
        btn.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
        btn.Text = "Menu"
        btn.TextColor3 = Color3.fromRGB(255,255,255)
        btn.Font = Enum.Font.SourceSansBold
        btn.TextSize = 14
        btn.AutoButtonColor = true
        btn.ZIndex = 50
        local corner = Instance.new("UICorner", btn)
        corner.CornerRadius = UDim.new(0, 12)
        local stroke = Instance.new("UIStroke", btn)
        stroke.Color = Color3.fromRGB(30,30,30)
        stroke.Thickness = 1

        local dragging = false
        local dragInput = nil
        local dragStart = Vector2.new(0,0)
        local startPos = UDim2.new(0,0,0,0)
        local moved = false
        local moveThreshold = 6

        btn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.Touch then
                dragging = true
                dragInput = input
                dragStart = input.Position
                startPos = btn.Position
                moved = false
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then
                        dragging = false
                        dragInput = nil
                        if not moved then
                            Frame.Visible = not Frame.Visible
                        end
                        local cam = workspace.CurrentCamera
                        if cam then
                            local vs = cam.ViewportSize
                            local absSizeX = btn.AbsoluteSize.X
                            local absSizeY = btn.AbsoluteSize.Y
                            local absPosX = btn.AbsolutePosition.X
                            local absPosY = btn.AbsolutePosition.Y
                            local newX = clamp(absPosX, SCREEN_MARGIN, vs.X - absSizeX - SCREEN_MARGIN)
                            local newY = clamp(absPosY, SCREEN_MARGIN, vs.Y - absSizeY - SCREEN_MARGIN)
                            btn.Position = UDim2.new(0, newX, 0, newY)
                        end
                    end
                end)
            end
        end)

        UserInputService.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.Touch and input == dragInput then
                local delta = input.Position - dragStart
                if math.abs(delta.X) > moveThreshold or math.abs(delta.Y) > moveThreshold then
                    moved = true
                end
                btn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end)

        btn.Activated:Connect(function()
            if not dragging and not moved then
                Frame.Visible = not Frame.Visible
            end
        end)
    end

    createMobileToggle()

    return ScreenGui, Frame
end

local ScreenGui, Frame = createScreenGui()

-- Toggle menu con RightControl
local function toggleMenu()
    Frame.Visible = not Frame.Visible
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        toggleMenu()
    end
end)

-- Cerrar al hacer clic fuera
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if Frame.Visible and input.UserInputType == Enum.UserInputType.MouseButton1 then
        local mousePos = input.Position
        local absPos = Frame.AbsolutePosition
        local absSize = Frame.AbsoluteSize
        if not (
            mousePos.X >= absPos.X and mousePos.X <= absPos.X + absSize.X and
            mousePos.Y >= absPos.Y and mousePos.Y <= absPos.Y + absSize.Y
        ) then
            Frame.Visible = false
        end
    end
end)

-- REGENERAR UI TRAS MORIR (PlayerGui reset)
local function ensureUI()
    if not LOCAL_PLAYER.PlayerGui:FindFirstChild("LightingMenu") then
        ScreenGui, Frame = createScreenGui()
    end
end

LOCAL_PLAYER.CharacterAdded:Connect(function()
    RunService.RenderStepped:Wait()
    ensureUI()
end)

LOCAL_PLAYER.PlayerGui.ChildRemoved:Connect(function(child)
    if child.Name == "LightingMenu" then
        RunService.RenderStepped:Wait()
        ensureUI()
    end
end)