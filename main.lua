-- main.lua v2: HOI-подобная стратегия для CC:Tweaked
-- Мир больше экрана: двигай карту стрелками на панели, масштаб кнопками +/-.
-- Всё управляется только нажатиями на монитор. Выход: клавиша Q на компьютере.

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

------------------------------------------------------------ мир
local WW, WH = 180, 100          -- размер мира в клетках (при масштабе 1)
local world = {}                 -- world[y][x] = индекс провинции или 0 (море)
local ZOOMS = { 0.5, 1, 2, 3 }
local zi = 2
local vx, vy = 0, 0              -- левый верхний угол вида в клетках мира

local function buildWorld()
  local sx, sy = {}, {}
  for i, p in ipairs(provinces) do
    sx[i] = p.fx * WW * 6
    sy[i] = p.fy * WH * 9
  end
  local R = 0.16 * WW * 6
  for y = 1, WH do
    world[y] = {}
    for x = 1, WW do
      local px, py = (x - 0.5) * 6, (y - 0.5) * 9
      local best, bd = 0, math.huge
      for i = 1, #provinces do
        local dx, dy = px - sx[i], py - sy[i]
        local d = dx * dx + dy * dy
        if d < bd then bd = d; best = i end
      end
      if bd > R * R then best = 0 end
      world[y][x] = best
    end
    if y % 10 == 0 then sleep(0) end
  end
end

local function layout()
  W, H = mon.getSize()
  mapW = W - PANEL_W
  mapH = H - 1
end

local function viewSize()
  local z = ZOOMS[zi]
  return mapW / z, mapH / z
end

local function clampView()
  local vw, vh = viewSize()
  if vw >= WW then vx = (WW - vw) / 2 else vx = math.max(0, math.min(WW - vw, vx)) end
  if vh >= WH then vy = (WH - vh) / 2 else vy = math.max(0, math.min(WH - vh, vy)) end
end

-- провинция в клетке экрана карты (sx, sy), 0 = море/вне мира
local function pAt(sx, sy)
  local z = ZOOMS[zi]
  local wx = math.floor(vx + (sx - 1) / z) + 1
  local wy = math.floor(vy + (sy - 1) / z) + 1
  if wx < 1 or wx > WW or wy < 1 or wy > WH then return 0 end
  return world[wy][wx]
end

------------------------------------------------------------ состояние
local selected = nil
local paused = true
local speed = 2
local SPEEDS = { 1.0, 0.5, 0.2, 0.05 }
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

------------------------------------------------------------ отрисовка карты
local function drawMap()
  local z = ZOOMS[zi]
  local rows = {}
  for y = 1, mapH do
    local ch, fg, bg = {}, {}, {}
    for x = 1, mapW do
      local p = pAt(x, y)
      local col = SEA
      if p ~= 0 then
        col = countries[provinces[p].owner].color
        local r, d = pAt(x + 1, y), pAt(x, y + 1)
        if r ~= p or d ~= p then
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

  -- подписи
  for _, p in ipairs(provinces) do
    local cx = math.floor((p.fx * WW - vx) * z) + 1
    local cy = math.floor((p.fy * WH - vy) * z) + 1
    if cx >= 1 and cx <= mapW and cy >= 1 and cy <= mapH then
      local name = p.name:sub(1, 11)
      local x0 = math.max(1, math.min(mapW - #name + 1, cx - math.floor(#name / 2)))
      local row = rows[cy]
      local base = countries[p.owner].color
      for k = 1, #name do
        row.ch[x0 + k - 1] = name:sub(k, k)
        row.bg[x0 + k - 1] = base
        row.fg[x0 + k - 1] = DARK[base] and colors.white or colors.black
      end
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
  local s = string.format(" HOI-CC  |  %02d.%02d.%04d  |  %s  |  speed %d/%d  |  zoom x%s",
    date.d, date.m, date.y, paused and "PAUSED" or "RUNNING", speed, #SPEEDS,
    tostring(ZOOMS[zi]))
  mon.setCursorPos(1, 1)
  mon.write(s:sub(1, W))
end

-- кнопка w x h клеток; fn возвращает true, если надо перерисовать карту
local function btn(label, x, y, w, h, col, fn)
  buttons[#buttons + 1] = { x1 = x, x2 = x + w - 1, y1 = y, y2 = y + h - 1, fn = fn }
  for r = 0, h - 1 do put(x, y + r, string.rep(" ", w), colors.black, col) end
  put(x + math.floor((w - #label) / 2), y + math.floor(h / 2), label, colors.black, col)
end

local function panStep()
  local vw, vh = viewSize()
  return math.max(3, math.floor(vw / 4)), math.max(3, math.floor(vh / 4))
end

local function restartTimer()
  if not paused then timerId = os.startTimer(SPEEDS[speed]) end
end

local function drawPanel()
  local x0 = mapW + 1
  for y = 2, H do put(x0, y, string.rep(" ", PANEL_W)) end

  -- информация
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

  -- кнопки (снизу вверх)
  buttons = {}
  local bx = x0 + 1

  -- масштаб
  local zy = H - 2
  btn("-", bx, zy, 7, 3, colors.lightGray, function()
    local vw, vh = viewSize()
    local cx, cy = vx + vw / 2, vy + vh / 2
    zi = math.max(1, zi - 1)
    vw, vh = viewSize()
    vx, vy = cx - vw / 2, cy - vh / 2
    clampView()
    return true
  end)
  put(bx + 8, zy + 1, string.format("x%-5s", tostring(ZOOMS[zi])), colors.white)
  btn("+", bx + 16, zy, 7, 3, colors.lightGray, function()
    local vw, vh = viewSize()
    local cx, cy = vx + vw / 2, vy + vh / 2
    zi = math.min(#ZOOMS, zi + 1)
    vw, vh = viewSize()
    vx, vy = cx - vw / 2, cy - vh / 2
    clampView()
    return true
  end)

  -- крестовина прокрутки
  local function pan(dx, dy)
    return function()
      local sx, sy = panStep()
      vx, vy = vx + dx * sx, vy + dy * sy
      clampView()
      return true
    end
  end
  local py = H - 14
  btn("^", bx + 8, py,     7, 3, colors.cyan, pan(0, -1))
  btn("<", bx,     py + 4, 7, 3, colors.cyan, pan(-1, 0))
  btn("o", bx + 8, py + 4, 7, 3, colors.yellow, function()
    local vw, vh = viewSize()
    if selected then
      vx = provinces[selected].fx * WW - vw / 2
      vy = provinces[selected].fy * WH - vh / 2
    else
      vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
    end
    clampView()
    return true
  end)
  btn(">", bx + 16, py + 4, 7, 3, colors.cyan, pan(1, 0))
  btn("v", bx + 8, py + 8, 7, 3, colors.cyan, pan(0, 1))

  -- время
  local ty = H - 18
  btn(paused and "PLAY" or "PAUSE", bx, ty, 9, 3, paused and colors.lime or colors.orange, function()
    paused = not paused
    timerId = nil
    restartTimer()
    return false
  end)
  btn("-", bx + 10, ty, 5, 3, colors.lightGray, function()
    speed = math.max(1, speed - 1); restartTimer(); return false
  end)
  btn("+", bx + 16, ty, 5, 3, colors.lightGray, function()
    speed = math.min(#SPEEDS, speed + 1); restartTimer(); return false
  end)
end

local function redrawAll()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  clampView()
  drawMap()
  drawTopBar()
  drawPanel()
end

------------------------------------------------------------ ввод
local function onTouch(x, y)
  if x <= mapW and y >= 2 then
    local p = pAt(x, y - 1)
    selected = (p ~= 0) and p or nil
    drawMap()
    drawPanel()
    return
  end
  for _, b in ipairs(buttons) do
    if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
      if b.fn() then drawMap() end
      drawTopBar()
      drawPanel()
      return
    end
  end
end

------------------------------------------------------------ старт
layout()
buildWorld()
do
  local vw, vh = viewSize()
  vx, vy = WW / 2 - vw / 2, WH / 2 - vh / 2
end
redrawAll()

while true do
  local ev, a, b, c = os.pullEvent()
  if ev == "monitor_touch" and a == monName then
    onTouch(b, c)
  elseif ev == "timer" and a == timerId then
    advanceDay()
    drawTopBar()
    restartTimer()
  elseif ev == "monitor_resize" and a == monName then
    layout()
    redrawAll()
  elseif ev == "key" and a == keys.q then
    break
  end
end

mon.setBackgroundColor(colors.black)
mon.clear()
mon.setCursorPos(1, 1)
