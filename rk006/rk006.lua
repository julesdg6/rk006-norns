-- rk006 / rk006.lua
-- Retrokits RK-006 Configuration Tool for norns
--
-- Connects to a Retrokits RK-006 MIDI router over USB and lets you
-- configure every setting that the official web page exposes:
--   • MIDI routing matrix (7 inputs × 7 outputs)
--   • Port direction (IN / OUT) and connector type (TRS-A / TRS-B / DIN-5)
--   • Per-port message-type filter (NOTE, CC, PC, AT, PBND, SYX, RT, ASNS)
--   • Per-port MIDI channel filter
--   • Clock source, divider and output destinations
--   • USB mode
--
-- Controls
--   E1          navigate pages
--   E2          select row / item
--   E3          select column / change value
--   K2          back / cancel edit
--   K3          toggle / confirm / execute
--   K1 hold     alt modifier (shows extra info)
--
-- SysEx protocol: see lib/rk006_sysex.lua
-- Parameter IDs are based on the RK006 SysEx manual
-- (retrokits.com/rk006/RK006_sysex_manual.pdf).
-- Verify PARAM_* constants in the library against that document.

engine.name = "None"

local syx = include("lib/rk006_sysex")

-- ─────────────────────────────────────────────────────────────────
-- State
-- ─────────────────────────────────────────────────────────────────

local NUM_PORTS = 6   -- TRS ports
local NUM_IN    = 7   -- 6 TRS + 1 USB
local NUM_OUT   = 7

-- Current device settings (mirrors NVRAM on the RK-006)
local cfg = {
  -- routing[in_port][out_port] = true/false  (in/out both 1-based)
  routing    = {},
  -- port direction: "IN" or "OUT"
  dir        = {"IN","IN","IN","OUT","OUT","OUT"},
  -- connector type index 1=TRS-A, 2=TRS-B, 3=DIN-5
  ctype      = {1,1,1,1,1,1},
  -- channel filter per input (1=pass all, 2-17 = channel 1-16)
  ch_in      = {1,1,1,1,1,1,1},
  -- message-type filter per input: bitmask (0xFF = pass all)
  filter     = {0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF},
  -- clock
  clock_src  = 1,  -- 1=Internal, 2-7=P1-P6, 8=USB
  clock_div  = 1,  -- index into CLOCK_DIV_NAMES
  clock_out  = 0x7F, -- bitmask of output ports that receive clock
  -- USB
  usb_mode   = 1,  -- 1=Device (computer), 2=Host (USB gear)
}

local function init_cfg()
  for i = 1, NUM_IN do
    cfg.routing[i] = {}
    for j = 1, NUM_OUT do
      cfg.routing[i][j] = (i == j)
    end
  end
end

-- MIDI device handle
local m            = nil
local midi_port    = 1          -- 1-based norns vport index
local connected    = false
local pending_resp = {}         -- queue of pending param nr awaiting response

-- ─────────────────────────────────────────────────────────────────
-- MIDI helpers
-- ─────────────────────────────────────────────────────────────────

local function send(bytes)
  if m then m:send(bytes) end
end

-- Build and send setparam request; also update local state.
local function set_param(nr, val)
  send(syx.set_param_msg(nr, val))
end

-- Request current value of a single parameter.
local function get_param(nr)
  pending_resp[nr] = true
  send(syx.get_param_msg(nr))
end

-- Request the full settings dump from the device.
local function query_all()
  -- The getnmbparams request initiates a full dump sequence; we also
  -- fire individual getparam requests for every known parameter so that
  -- the state table is fully populated even on devices with different
  -- parameter counts.
  send(syx.get_num_params_msg())
  for _, nr in pairs(syx.PARAM) do
    get_param(nr)
  end
end

-- ─────────────────────────────────────────────────────────────────
-- Translate cfg ↔ parameter values
-- ─────────────────────────────────────────────────────────────────

-- Rebuild routing mask for a single input and push to device.
local function push_routing(in_port)
  local mask = 0
  for j = 1, NUM_OUT do
    if cfg.routing[in_port][j] then
      mask = mask | (1 << (j - 1))
    end
  end
  local nr = syx.PARAM.ROUTE_P1 + (in_port - 1)
  set_param(nr, mask)
end

-- Push port direction for TRS port p (1-6).
local function push_dir(p)
  local val = (cfg.dir[p] == "OUT") and 1 or 0
  set_param(syx.PARAM.DIR_P1 + (p - 1), val)
end

-- Push connector type for TRS port p.
local function push_ctype(p)
  set_param(syx.PARAM.TYPE_P1 + (p - 1), cfg.ctype[p] - 1)
end

-- Push channel filter for input in_port (1-7).
local function push_ch(in_port)
  set_param(syx.PARAM.CH_P1 + (in_port - 1), cfg.ch_in[in_port] - 1)
end

-- Push message-type filter for input in_port.
local function push_filter(in_port)
  set_param(syx.PARAM.FILTER_P1 + (in_port - 1), cfg.filter[in_port])
end

-- Push all clock settings.
local function push_clock()
  set_param(syx.PARAM.CLOCK_SRC, cfg.clock_src - 1)
  set_param(syx.PARAM.CLOCK_DIV, cfg.clock_div - 1)
  set_param(syx.PARAM.CLOCK_OUT, cfg.clock_out)
end

-- Push all settings to device.
local function push_all()
  for i = 1, NUM_IN do push_routing(i) end
  for i = 1, NUM_PORTS do
    push_dir(i)
    push_ctype(i)
  end
  for i = 1, NUM_IN do
    push_ch(i)
    push_filter(i)
  end
  push_clock()
  set_param(syx.PARAM.USB_MODE, cfg.usb_mode - 1)
end

-- ─────────────────────────────────────────────────────────────────
-- Incoming SysEx handler
-- ─────────────────────────────────────────────────────────────────

-- Apply a received parameter value to cfg.
local function apply_param(nr, val)
  -- routing
  if nr >= syx.PARAM.ROUTE_P1 and nr <= syx.PARAM.ROUTE_P1 + NUM_IN - 1 then
    local in_port = nr - syx.PARAM.ROUTE_P1 + 1
    for j = 1, NUM_OUT do
      cfg.routing[in_port][j] = (val & (1 << (j - 1))) ~= 0
    end
  -- direction
  elseif nr >= syx.PARAM.DIR_P1 and nr <= syx.PARAM.DIR_P1 + NUM_PORTS - 1 then
    local p = nr - syx.PARAM.DIR_P1 + 1
    cfg.dir[p] = (val == 0) and "IN" or "OUT"
  -- connector type
  elseif nr >= syx.PARAM.TYPE_P1 and nr <= syx.PARAM.TYPE_P1 + NUM_PORTS - 1 then
    local p = nr - syx.PARAM.TYPE_P1 + 1
    cfg.ctype[p] = val + 1
  -- channel filter
  elseif nr >= syx.PARAM.CH_P1 and nr <= syx.PARAM.CH_P1 + NUM_IN - 1 then
    local p = nr - syx.PARAM.CH_P1 + 1
    cfg.ch_in[p] = val + 1
  -- message filter
  elseif nr >= syx.PARAM.FILTER_P1 and nr <= syx.PARAM.FILTER_P1 + NUM_IN - 1 then
    local p = nr - syx.PARAM.FILTER_P1 + 1
    cfg.filter[p] = val
  -- clock
  elseif nr == syx.PARAM.CLOCK_SRC then
    cfg.clock_src = val + 1
  elseif nr == syx.PARAM.CLOCK_DIV then
    cfg.clock_div = val + 1
  elseif nr == syx.PARAM.CLOCK_OUT then
    cfg.clock_out = val
  -- USB mode
  elseif nr == syx.PARAM.USB_MODE then
    cfg.usb_mode = val + 1
  end
end

local function on_midi_event(data)
  if not data or #data < 2 then return end

  -- Only handle SysEx
  if data[1] ~= 0xF0 then return end

  local pkt = syx.parse(data)
  if not pkt then return end

  connected = true

  if pkt.cmd == syx.CMD.GET_PARAM_RSP or pkt.cmd == syx.CMD.SET_PARAM_RSP then
    -- payload: [nr_lo, nr_hi, val_lo, val_hi]
    if #pkt.payload >= 4 then
      local nr  = syx.payload_u16(pkt.payload, 1)
      local val = syx.payload_u16(pkt.payload, 3)
      pending_resp[nr] = nil
      apply_param(nr, val)
      redraw()
    end
  elseif pkt.cmd == syx.CMD.GET_NUM_RSP then
    -- payload: [n_lo, n_hi]
    -- (we just use this as a connection confirmation)
    if #pkt.payload >= 2 then
      connected = true
      redraw()
    end
  end
end

-- ─────────────────────────────────────────────────────────────────
-- Device auto-detect using Universal Device Identity Request
-- ─────────────────────────────────────────────────────────────────

-- F0 7E 7F 06 01 F7  — send to all connected devices; devices reply with
-- their manufacturer ID embedded in the response.
local UNIVERSAL_INQUIRY = {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7}

local function send_inquiry()
  send(UNIVERSAL_INQUIRY)
end

local function try_connect(port)
  midi_port = port
  m         = midi.connect(port)
  m.event   = on_midi_event
  send_inquiry()
  clock.run(function()
    clock.sleep(0.5)
    query_all()
  end)
end

-- Scan all ports for an RK-006 by name.
local function auto_detect()
  for _, dev in pairs(midi.devices) do
    if dev.name then
      local n = dev.name:lower()
      if n:find("rk%-?006") or n:find("retrokits") then
        try_connect(dev.port)
        return
      end
    end
  end
  -- Fall back to port 1
  try_connect(1)
end

-- ─────────────────────────────────────────────────────────────────
-- UI State
-- ─────────────────────────────────────────────────────────────────

local PAGES = {"ROUTE","PORTS","FILTER","CLOCK","SETTINGS"}
local ui = {
  page       = 1,
  row        = 1,   -- selected row within page
  col        = 1,   -- selected column (routing matrix)
  alt        = false,
  blink      = true,
  -- filter sub-page
  flt_port   = 1,   -- which port's filter we are editing
  flt_row    = 1,   -- which filter bit is selected
  -- clock sub-page
  clk_row    = 1,
  clk_edit   = false,
  -- settings sub-page
  set_row    = 1,
}

-- Blink timer (for cursor animation)
local blink_id = nil

-- ─────────────────────────────────────────────────────────────────
-- Drawing helpers
-- ─────────────────────────────────────────────────────────────────

local function draw_dots()
  -- Page indicator: small dots along the bottom
  local n = #PAGES
  local x0 = math.floor((128 - n * 4) / 2)
  for i = 1, n do
    if i == ui.page then
      screen.level(15)
      screen.rect(x0 + (i-1)*4, 62, 2, 2)
      screen.fill()
    else
      screen.level(4)
      screen.pixel(x0 + (i-1)*4, 63)
      screen.fill()
    end
  end
end

local function draw_header(title)
  screen.level(6)
  screen.font_size(8)
  screen.font_face(0)
  screen.move(0, 8)
  screen.text(title)
  -- page name on the right
  screen.level(4)
  screen.move(128, 8)
  screen.text_right("E1:pg")
end

-- ─────────────────────────────────────────────────────────────────
-- Page 1: ROUTING MATRIX
-- ─────────────────────────────────────────────────────────────────
--
-- Columns = outputs (O1-O6, OU)
-- Rows    = inputs  (I1-I6, IU)
-- Cell cursor moves with E2(row) / E3(col); K3 toggles.
-- Ports configured as OUTPUT are shown dimmed for inputs (and vice-versa).

local function draw_route()
  draw_header("ROUTE")

  local ox, oy = 16, 10   -- top-left of matrix area
  local cw, ch = 15, 7    -- cell width/height

  -- Column headers
  screen.font_size(5)
  for j = 1, NUM_OUT do
    local x = ox + (j-1)*cw + 3
    screen.level(ui.col == j and 15 or 5)
    screen.move(x, oy)
    screen.text(j <= 6 and tostring(j) or "U")
  end

  -- Row headers + cells
  screen.font_size(8)
  for i = 1, NUM_IN do
    local y = oy + i*ch
    local row_sel = (ui.row == i)

    -- Row label
    screen.level(row_sel and 15 or 5)
    screen.font_size(5)
    screen.move(0, y)
    screen.text(i <= 6 and ("I"..i) or "IU")

    for j = 1, NUM_OUT do
      local x   = ox + (j-1)*cw
      local sel = (row_sel and ui.col == j)

      -- Selection box
      if sel then
        screen.level(4)
        screen.rect(x, y-6, cw-1, ch)
        screen.fill()
      end

      -- Routing dot
      local on = cfg.routing[i][j]
      if sel then
        -- blink when selected
        if ui.blink or on then
          screen.level(on and 15 or 8)
        else
          screen.level(0)
        end
      else
        screen.level(on and 12 or 2)
      end
      screen.font_size(8)
      screen.move(x+3, y)
      screen.text(on and "*" or ".")
    end
  end

  -- Bottom hint
  screen.level(3)
  screen.font_size(5)
  screen.move(0, 59)
  screen.text("E2:row E3:col K3:toggle")

  draw_dots()
end

-- ─────────────────────────────────────────────────────────────────
-- Page 2: PORT CONFIGURATION
-- ─────────────────────────────────────────────────────────────────

local function draw_ports()
  draw_header("PORTS")

  screen.font_size(8)
  local labels = syx.TYPE_NAMES  -- {"TRS-A","TRS-B","DIN-5"}

  for i = 1, NUM_PORTS do
    local y   = 10 + i*9
    local sel = (ui.row == i)

    screen.level(sel and 15 or 7)
    screen.move(0, y)
    screen.text("P"..i)

    -- Direction
    screen.level(sel and 14 or 8)
    screen.move(20, y)
    screen.text(cfg.dir[i])

    -- Connector type
    screen.level(sel and 12 or 5)
    screen.move(50, y)
    screen.text(labels[cfg.ctype[i]])

    -- Selection indicator
    if sel then
      screen.level(15)
      screen.move(124, y)
      screen.text_right(ui.col == 1 and "<DIR" or "<TYP")
    end
  end

  screen.level(3)
  screen.font_size(5)
  screen.move(0, 59)
  screen.text("E2:port  E3:col  K3:change")
  draw_dots()
end

-- ─────────────────────────────────────────────────────────────────
-- Page 3: MESSAGE FILTER
-- ─────────────────────────────────────────────────────────────────

local function draw_filter()
  -- Port selector at top
  draw_header("FILTER")

  screen.font_size(8)

  -- Port tabs
  screen.move(0, 18)
  screen.level(4)
  screen.text("Port:")
  for i = 1, NUM_IN do
    local x = 28 + (i-1)*14
    if i == ui.flt_port then
      screen.level(15)
      screen.rect(x-1, 10, 12, 8)
      screen.fill()
      screen.level(0)
    else
      screen.level(6)
    end
    screen.move(x+1, 18)
    screen.text(i <= 6 and tostring(i) or "U")
  end

  -- Filter bits
  local fmask = cfg.filter[ui.flt_port]
  for f = 1, #syx.FILTER_NAMES do
    local y   = 20 + f*6
    local sel = (ui.flt_row == f)
    local on  = (fmask & syx.FILTER_BITS[f]) ~= 0

    if sel then
      screen.level(4)
      screen.rect(0, y-5, 128, 6)
      screen.fill()
    end

    screen.level(sel and 15 or 6)
    screen.font_size(6)
    screen.move(2, y)
    screen.text(syx.FILTER_NAMES[f])

    -- Pass / Block indicator
    if on then
      screen.level(sel and 15 or 12)
      screen.move(52, y)
      screen.text("PASS")
    else
      screen.level(sel and 8 or 3)
      screen.move(52, y)
      screen.text("block")
    end

    -- Per-filter channel
    screen.level(sel and 10 or 4)
    screen.move(80, y)
    local ch = cfg.ch_in[ui.flt_port]
    if f == 1 and ch > 1 then
      screen.text("ch"..tostring(ch-1))
    end
  end

  screen.level(3)
  screen.font_size(5)
  screen.move(0, 59)
  screen.text("E2:filter  E3:port  K3:toggle")
  draw_dots()
end

-- ─────────────────────────────────────────────────────────────────
-- Page 4: CLOCK
-- ─────────────────────────────────────────────────────────────────

local function draw_clock()
  draw_header("CLOCK")

  local rows = {
    {"Source",  syx.CLOCK_SRC_NAMES[cfg.clock_src] or "?"},
    {"Divider", syx.CLOCK_DIV_NAMES[cfg.clock_div] or "?"},
    {"Outputs", string.format("%02X", cfg.clock_out)},
  }

  for i, row in ipairs(rows) do
    local y   = 14 + i*12
    local sel = (ui.clk_row == i)

    if sel and ui.clk_edit then
      screen.level(4)
      screen.rect(0, y-8, 128, 10)
      screen.fill()
    end

    screen.level(sel and 15 or 7)
    screen.font_size(8)
    screen.move(2, y)
    screen.text(row[1])

    screen.level(sel and (ui.clk_edit and 15 or 13) or 8)
    screen.move(60, y)
    screen.text(row[2])

    if sel then
      screen.level(ui.clk_edit and 15 or 5)
      screen.move(124, y)
      screen.text_right(ui.clk_edit and "<-->" or "K3")
    end
  end

  -- Clock output port boxes
  local y2 = 53
  screen.level(4)
  screen.font_size(5)
  screen.move(0, y2)
  screen.text("out:")
  for j = 1, NUM_OUT do
    local x = 20 + (j-1)*15
    local on = (cfg.clock_out & (1 << (j-1))) ~= 0
    if on then
      screen.level(13)
      screen.rect(x, y2-6, 12, 7)
      screen.fill()
      screen.level(0)
    else
      screen.level(5)
      screen.rect(x, y2-6, 12, 7)
      screen.stroke()
    end
    screen.move(x+2, y2)
    screen.text(j <= 6 and tostring(j) or "U")
  end

  screen.level(3)
  screen.font_size(5)
  screen.move(0, 63)
  screen.text("E2:row E3:val K3:edit")
  draw_dots()
end

-- ─────────────────────────────────────────────────────────────────
-- Page 5: SETTINGS / TOOLS
-- ─────────────────────────────────────────────────────────────────

local function draw_settings()
  draw_header("SETTINGS")

  local items = {
    {label="Query device",      hint="read all params"},
    {label="Push all settings", hint="write to device"},
    {label="MIDI port: "..midi_port, hint="E3 to change"},
    {label="USB mode: "..
           (cfg.usb_mode==1 and "Device" or "Host"),
           hint="E3 to change"},
    {label="Connection: "..
           (connected and "OK" or "?"),
           hint=""},
  }

  for i, item in ipairs(items) do
    local y   = 12 + i*10
    local sel = (ui.set_row == i)

    if sel then
      screen.level(4)
      screen.rect(0, y-7, 128, 9)
      screen.fill()
    end

    screen.level(sel and 15 or 8)
    screen.font_size(8)
    screen.move(4, y)
    screen.text(item.label)

    if sel then
      screen.level(4)
      screen.font_size(5)
      screen.move(124, y)
      screen.text_right(item.hint)
    end
  end

  screen.level(3)
  screen.font_size(5)
  screen.move(0, 59)
  screen.text("E2:item  K3:execute  E3:change")
  draw_dots()
end

-- ─────────────────────────────────────────────────────────────────
-- Main redraw
-- ─────────────────────────────────────────────────────────────────

function redraw()
  screen.clear()
  screen.aa(0)

  local p = PAGES[ui.page]
  if     p == "ROUTE"    then draw_route()
  elseif p == "PORTS"    then draw_ports()
  elseif p == "FILTER"   then draw_filter()
  elseif p == "CLOCK"    then draw_clock()
  elseif p == "SETTINGS" then draw_settings()
  end

  screen.update()
end

-- ─────────────────────────────────────────────────────────────────
-- Key handlers
-- ─────────────────────────────────────────────────────────────────

function key(n, z)
  if n == 1 then
    ui.alt = (z == 1)
    redraw()
    return
  end
  if z == 0 then return end  -- ignore key-up for K2/K3

  local p = PAGES[ui.page]

  if n == 2 then
    -- K2: back / exit edit mode
    if ui.clk_edit then
      ui.clk_edit = false
    else
      ui.page = ((ui.page - 2) % #PAGES) + 1
      ui.row = 1; ui.col = 1
    end

  elseif n == 3 then
    if p == "ROUTE" then
      -- Toggle routing cell
      local i, j = ui.row, ui.col
      cfg.routing[i][j] = not cfg.routing[i][j]
      push_routing(i)

    elseif p == "PORTS" then
      if ui.col == 1 then
        -- Toggle direction
        cfg.dir[ui.row] = (cfg.dir[ui.row] == "IN") and "OUT" or "IN"
        push_dir(ui.row)
      else
        -- Cycle connector type
        cfg.ctype[ui.row] = (cfg.ctype[ui.row] % #syx.TYPE_NAMES) + 1
        push_ctype(ui.row)
      end

    elseif p == "FILTER" then
      -- Toggle filter bit for selected port / filter type
      local bit = syx.FILTER_BITS[ui.flt_row]
      cfg.filter[ui.flt_port] = cfg.filter[ui.flt_port] ~ bit
      push_filter(ui.flt_port)

    elseif p == "CLOCK" then
      ui.clk_edit = not ui.clk_edit

    elseif p == "SETTINGS" then
      local r = ui.set_row
      if r == 1 then
        query_all()
      elseif r == 2 then
        push_all()
      end
    end
  end

  redraw()
end

-- ─────────────────────────────────────────────────────────────────
-- Encoder handlers
-- ─────────────────────────────────────────────────────────────────

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function wrap(v, lo, hi)
  local n = hi - lo + 1
  return lo + ((v - lo) % n)
end

function enc(n, d)
  local p = PAGES[ui.page]

  if n == 1 then
    -- E1: page navigation
    ui.page     = wrap(ui.page + d, 1, #PAGES)
    ui.row      = 1
    ui.col      = 1
    ui.clk_edit = false
    redraw()
    return
  end

  if p == "ROUTE" then
    if n == 2 then
      ui.row = wrap(ui.row + d, 1, NUM_IN)
    elseif n == 3 then
      ui.col = wrap(ui.col + d, 1, NUM_OUT)
    end

  elseif p == "PORTS" then
    if n == 2 then
      ui.row = wrap(ui.row + d, 1, NUM_PORTS)
    elseif n == 3 then
      ui.col = wrap(ui.col + d, 1, 2)  -- 1=DIR col, 2=TYPE col
    end

  elseif p == "FILTER" then
    if n == 2 then
      ui.flt_row = wrap(ui.flt_row + d, 1, #syx.FILTER_NAMES)
    elseif n == 3 then
      -- E3: change port
      ui.flt_port = wrap(ui.flt_port + d, 1, NUM_IN)
    end

  elseif p == "CLOCK" then
    if n == 2 then
      if ui.clk_edit then
        -- Change value for selected row
        if ui.clk_row == 1 then
          cfg.clock_src = wrap(cfg.clock_src + d, 1, #syx.CLOCK_SRC_NAMES)
        elseif ui.clk_row == 2 then
          cfg.clock_div = wrap(cfg.clock_div + d, 1, #syx.CLOCK_DIV_NAMES)
        elseif ui.clk_row == 3 then
          cfg.clock_out = wrap(cfg.clock_out + d, 0, 127)
        end
        push_clock()
      else
        ui.clk_row = wrap(ui.clk_row + d, 1, 3)
      end
    elseif n == 3 then
      -- E3 also changes value when in edit
      if ui.clk_edit then
        if ui.clk_row == 1 then
          cfg.clock_src = wrap(cfg.clock_src + d, 1, #syx.CLOCK_SRC_NAMES)
        elseif ui.clk_row == 2 then
          cfg.clock_div = wrap(cfg.clock_div + d, 1, #syx.CLOCK_DIV_NAMES)
        elseif ui.clk_row == 3 then
          -- Toggle individual output ports with E3
          local bit_j = wrap(ui.col + d, 1, NUM_OUT)
          ui.col = bit_j
          cfg.clock_out = cfg.clock_out ~ (1 << (bit_j - 1))
        end
        push_clock()
      end
    end

  elseif p == "SETTINGS" then
    if n == 2 then
      ui.set_row = wrap(ui.set_row + d, 1, 5)
    elseif n == 3 then
      local r = ui.set_row
      if r == 3 then
        -- Change MIDI port
        midi_port = wrap(midi_port + d, 1, 4)
        try_connect(midi_port)
      elseif r == 4 then
        -- Toggle USB mode
        cfg.usb_mode = (cfg.usb_mode == 1) and 2 or 1
        set_param(syx.PARAM.USB_MODE, cfg.usb_mode - 1)
      end
    end
  end

  redraw()
end

-- ─────────────────────────────────────────────────────────────────
-- init
-- ─────────────────────────────────────────────────────────────────

function init()
  init_cfg()

  -- Blink cursor for routing matrix
  blink_id = clock.run(function()
    while true do
      clock.sleep(0.5)
      ui.blink = not ui.blink
      redraw()
    end
  end)

  -- Connect and query
  auto_detect()

  redraw()
end

function cleanup()
  if blink_id then clock.cancel(blink_id) end
end
