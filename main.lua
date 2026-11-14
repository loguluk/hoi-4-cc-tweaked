-- main.lua: каркас HOI-подобной стратегии для CC:Tweaked
-- Запуск: main   (рядом должен лежать data.lua)
-- Выход: клавиша Q на самом компьютере.

local dir = fs.getDir(shell.getRunningProgram())
local data = dofile(fs.combine(dir, "data.lua"))
local countries, provinces = data.countries, data.provinces

------------------------------------------------------------ монитор
local mon = peripheral.find("monitor")
if not mon then error("Монитор не найден", 0) end
if not mon.isColor() then error("Нужен Advanced Monitor", 0) end
local monName = peripheral.getName(mon)
mon.setTextScale(0.5)

local PANEL_W = 30
local SEA = colors.lightBlue
local DARK = {
  [colors.gray] = true, [colors.blue] = true, [colors.red] = true,
  [colors.brown] = true, [colors.green] = true, [colors.purple] = true,
  [colors.black] = true,
}

local W, H, mapW, mapH
local grid = {}       -- grid[y][x] = индекс провинции или 0 (море)
local seedCell = {}   -- центр провинции в клетках

------------------------------------------------------------ состояние
local selected = nil
local paused = true
local speed = 2
local SPEEDS = { 1.0, 0.5, 0.2, 0.05 }   -- секунд реального времени на игровой день
local date = { y = 1936, m = 1, d = 1 }
local timerId = nil
local buttons = {}

local function daysInMonth(y, m)
  local t = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if m == 2 and (y % 4 == 0) then return 29 end
  return t[m]
end

local function advanceDay()
  date.d = date.d + 1
  if date.d > daysInMonth(date.y, date.m) then
    date.d = 1
    date.m = date.m + 1
    if date.m > 12 then date.m = 1; date.y = date.y + 1 end
  end
  -- сюда позже: экономика, движение дивизий, бои, ИИ
end

------------------------------------------------------------ карта
local function buildGrid()
  W, H = mon.getSize()
  mapW = W - PANEL_W
  mapH = H - 1
  grid, seedCell = {}, {}

  -- клетка 6x9 пикселей, поэтому считаем расстояние в «пикселях»
  local sx, sy = {}, {}
  for i, p in ipairs(provinces) do
    sx[i] = p.fx * mapW * 6
    sy[i] = p.fy * mapH * 9
    seedCell[i] = {
      x = math.max(1, math.min(mapW, math.floor(p.fx * mapW + 0.5))),
      y = math.max(1, math.min(mapH, math.floor(p.fy * mapH + 0.5))),
    }
  end
  local R = 0.16 * mapW * 6   -- дальше этого расстояния от любого центра — море

  for y = 1, mapH do
    grid[y] = {}
    for x = 1, mapW do
      local px, py = (x - 0.5) * 6, (y - 0.5) * 9
      local best, bd = 0, math.huge
      for i = 1, #provinces do
        local dx, dy = px - sx[i], py - sy[i]
        local d = dx * dx + dy * dy
        if d < bd then bd = d; best = i end
      end
      if bd > R * R then best = 0 end
      grid[y][x] = best
    end
  end
end

local function g(x, y)
  return (grid[y] and grid[y][x]) or 0
end

local function drawMap()
  local rows = {}
  for y = 1, mapH do
    local ch, fg, bg = {}, {}, {}
    for x = 1, mapW do
      local p = g(x, y)
      local col = SEA
      if p ~= 0 then
        col = countries[provinces[p].owner].color
        local r, d = g(x + 1, y), g(x, y + 1)
        local diff = (r ~= p) or (d ~= p)
        if diff then
          local hl = (r ~= p and (p == selected or r == selected))
                  or (d ~= p and (p == selected or d == selected))
          col = hl and colors.white or colors.black
        end
      end
      ch[x] = " "
      bg[x] = col
      fg[x] = DARK[col] and colors.white or colors.black
    end
    rows[y] = { ch = ch, fg = fg, bg = bg }
  end

  -- подписи провинций
  for i, p in ipairs(provinces) do
    local name = p.name:sub(1, 11)
    local c = seedCell[i]
    local x0 = math.max(1, math.min(mapW - #name + 1, c.x - math.floor(#name / 2)))
    local row = rows[c.y]
    local base = countries[p.owner].color
    for k = 1, #name do
      row.ch[x0 + k - 1] = name:sub(k, k)
      row.bg[x0 + k - 1] = base
      row.fg[x0 + k - 1] = DARK[base] and colors.white or colors.black
    end
  end

  for y = 1, mapH do
    local r = rows[y]
    local t, f, b = {}, {}, {}
    for x = 1, mapW do
      t[x] = r.ch[x]
      f[x] = colors.toBlit(r.fg[x])
      b[x] = colors.toBlit(r.bg[x])
    end
    mon.setCursorPos(1, y + 1)
    mon.blit(table.concat(t), table.concat(f), table.concat(b))
  end
end

------------------------------------------------------------ интерфейс
local function put(x, y, text, fg, bg)
  mon.setCursorPos(x, y)
  mon.setTextColor(fg or colors.white)
  mon.setBackgroundColor(bg or colors.black)
  mon.write(text)
end

local function drawTopBar()
  mon.setBackgroundColor(colors.gray)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, 1)
  mon.write(string.rep(" ", W))
  local s = string.format(" HOI-CC  |  %02d.%02d.%04d  |  %s  |  speed %d/%d",
    date.d, date.m, date.y, paused and "PAUSED" or "RUNNING", speed, #SPEEDS)
  mon.setCursorPos(1, 1)
  mon.write(s:sub(1, W))
end

local function drawPanel()
  local x0 = mapW + 1
  for y = 2, H do put(x0, y, string.rep(" ", PANEL_W)) end

  local y = 3
  put(x0 + 1, y, "PROVINCE", colors.yellow); y = y + 1
  if selected then
    local p = provinces[selected]
    local c = countries[p.owner]
    put(x0 + 1, y, p.name, colors.white); y = y + 1
    put(x0 + 1, y, "Owner: ", colors.lightGray)
    put(x0 + 8, y, c.name, colors.white); y = y + 1
    put(x0 + 1, y, "    ", colors.white, c.color)
  else
    put(x0 + 1, y, "(tap a province)", colors.lightGray)
  end

  y = 9
  put(x0 + 1, y, "COUNTRIES", colors.yellow); y = y + 1
  local counts = {}
  for _, p in ipairs(provinces) do counts[p.owner] = (counts[p.owner] or 0) + 1 end
  local ids = {}
  for id in pairs(countries) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local c = countries[id]
    put(x0 + 1, y, "  ", colors.white, c.color)
    put(x0 + 4, y, string.format("%-8s %2d prov", c.name, counts[id] or 0), colors.white)
    y = y + 1
  end

  -- кнопки
  buttons = {}
  local by = H - 1
  local function btn(label, bx, fn, col)
    buttons[#buttons + 1] = { x1 = bx, x2 = bx + #label - 1, y = by, fn = fn }
    put(bx, by, label, colors.black, col or colors.lightGray)
  end
  btn(paused and " PLAY  " or " PAUSE ", x0 + 1, function()
    paused = not paused
    timerId = (not paused) and os.startTimer(SPEEDS[speed]) or nil
  end, paused and colors.lime or colors.orange)
  btn(" - ", x0 + 10, function()
    speed = math.max(1, speed - 1)
    if not paused then timerId = os.startTimer(SPEEDS[speed]) end
  end)
  btn(" + ", x0 + 14, function()
    speed = math.min(#SPEEDS, speed + 1)
    if not paused then timerId = os.startTimer(SPEEDS[speed]) end
  end)
end

local function redrawAll()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  drawMap()
  drawTopBar()
  drawPanel()
end

------------------------------------------------------------ ввод
local function onTouch(x, y)
  if x <= mapW and y >= 2 then
    local p = g(x, y - 1)
    selected = (p ~= 0) and p or nil
    drawMap()
    drawPanel()
    return
  end
  for _, b in ipairs(buttons) do
    if y == b.y and x >= b.x1 and x <= b.x2 then
      b.fn()
      drawTopBar()
      drawPanel()
      return
    end
  end
end

------------------------------------------------------------ старт
buildGrid()
redrawAll()

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "monitor_touch" and a == monName then
    onTouch(b, c)
  elseif ev == "timer" and a == timerId then
    advanceDay()
    drawTopBar()
    if not paused then timerId = os.startTimer(SPEEDS[speed]) end
  elseif ev == "monitor_resize" and a == monName then
    buildGrid()
    redrawAll()
  elseif ev == "key" and a == keys.q then
    break
  end
end

mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1, 1)
