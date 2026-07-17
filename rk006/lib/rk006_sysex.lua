-- rk006/lib/rk006_sysex.lua
-- Retrokits RK-006 SysEx Protocol Implementation
--
-- The RK-006 uses the same SysEx framing as other Retrokits devices.
--
-- HEADER:  F0 00 21 23 00 06
--          ^  \_________/  ^
--         SOX  mfr (Retrokits)  product = 0x06
--
-- COMMANDS (request→response pairs):
--   0x08 setparam_req   nr(uint16) val(uint16)  → set parameter value
--   0x48 setparam_rsp   nr(uint16) val(uint16)  ← confirmation
--   0x09 getparam_req   nr(uint16)              → request current value
--   0x49 getparam_rsp   nr(uint16) val(uint16)  ← current value
--   0x0A getnmbparams_req                       → how many parameters?
--   0x4A getnmbparams_rsp n(uint16)             ← count
--   0x0B getparamdef_req  nr(uint16)            → parameter definition
--   0x4B getparamdef_rsp  nr min max def flags label(32) ← definition
--
-- DATA ENCODING: 7-bit MIDI SysEx packing.
--   Every 8th byte in the payload is a "MSB byte" whose 7 bits are the
--   high bits (bit 7) of the following 7 data bytes.  Values ≥ 128 are
--   therefore representable without violating the MIDI SysEx constraint
--   that data bytes must be ≤ 0x7F.
--
-- PARAMETER IDs  (based on RK006_sysex_manual.pdf / retrokits.com/rk006/)
--   RK-006 hardware: 6 TRS ports (each IN or OUT) + USB-device + USB-host
--   Inputs  numbered 0-6: TRS P1-P6 (when direction=IN), then USB-device(6)
--   Outputs numbered 0-6: TRS P1-P6 (when direction=OUT), then USB-device(6)
--
--   NOTE: Verify all PARAM_* values against the official SysEx manual PDF.
--   The IDs below reflect the most commonly documented RK-006 layout;
--   consult retrokits.com/rk006/RK006_sysex_manual.pdf to confirm.
--
-- Reference implementation:  RK002lib.js by Retrokits (same protocol family)

local M = {}

-- -------------------------------------------------------------------------
-- SysEx framing constants
-- -------------------------------------------------------------------------
M.SOX     = 0xF0
M.EOX     = 0xF7
-- Retrokits manufacturer ID (same across RK002/RK005/RK006 family)
M.MFR     = {0x00, 0x21, 0x23}
M.PRODUCT = 0x06   -- RK-006

-- -------------------------------------------------------------------------
-- Command bytes
-- -------------------------------------------------------------------------
M.CMD = {
  SET_PARAM      = 0x08,  -- set a named parameter
  SET_PARAM_RSP  = 0x48,
  GET_PARAM      = 0x09,  -- get a named parameter
  GET_PARAM_RSP  = 0x49,
  GET_NUM_PARAMS = 0x0A,  -- how many parameters exist?
  GET_NUM_RSP    = 0x4A,
  GET_PARAM_DEF  = 0x0B,  -- parameter definition (min/max/default/label)
  GET_PARAM_DEF_RSP = 0x4B,
}

-- -------------------------------------------------------------------------
-- Known parameter IDs
-- All values are 16-bit unsigned (0-65535).
-- -------------------------------------------------------------------------
M.PARAM = {
  -- Routing: one param per input port. Value is a 7-bit bitmask of outputs.
  --   bit 0 = OUT P1, bit 1 = OUT P2, …, bit 5 = OUT P6, bit 6 = USB-out
  ROUTE_P1    =  0,   -- routing mask for TRS port 1 (when dir=IN)
  ROUTE_P2    =  1,
  ROUTE_P3    =  2,
  ROUTE_P4    =  3,
  ROUTE_P5    =  4,
  ROUTE_P6    =  5,
  ROUTE_USB   =  6,   -- routing mask for USB-device input

  -- Port direction: 0 = INPUT, 1 = OUTPUT
  DIR_P1      =  7,
  DIR_P2      =  8,
  DIR_P3      =  9,
  DIR_P4      = 10,
  DIR_P5      = 11,
  DIR_P6      = 12,

  -- Port connector type: 0 = TRS-A, 1 = TRS-B, 2 = DIN-5
  TYPE_P1     = 13,
  TYPE_P2     = 14,
  TYPE_P3     = 15,
  TYPE_P4     = 16,
  TYPE_P5     = 17,
  TYPE_P6     = 18,

  -- MIDI channel filter per input (0 = pass all, 1-16 = pass that channel only)
  CH_P1       = 19,
  CH_P2       = 20,
  CH_P3       = 21,
  CH_P4       = 22,
  CH_P5       = 23,
  CH_P6       = 24,
  CH_USB      = 25,

  -- Message-type filter per input (bitmask; 1 = pass, 0 = block)
  --   bit 0 = Note, bit 1 = CC, bit 2 = PC, bit 3 = AT, bit 4 = PBend
  --   bit 5 = SysEx, bit 6 = Realtime, bit 7 = Active Sensing
  FILTER_P1   = 26,
  FILTER_P2   = 27,
  FILTER_P3   = 28,
  FILTER_P4   = 29,
  FILTER_P5   = 30,
  FILTER_P6   = 31,
  FILTER_USB  = 32,

  -- Clock
  CLOCK_SRC   = 33,  -- 0 = internal, 1-6 = TRS port 1-6, 7 = USB
  CLOCK_DIV   = 34,  -- 0 = 1:1, 1 = 1:2, 2 = 1:4, 3 = 1:8, 4 = 1:16, 5 = 2:1, 6 = 4:1
  CLOCK_OUT   = 35,  -- bitmask: which output ports receive clock

  -- USB
  USB_MODE    = 36,  -- 0 = device (connect to computer), 1 = host (connect USB MIDI gear)
  USB_CH_OFF  = 37,  -- channel offset 0-15 for USB port
}

-- Filter bit masks
M.FILTER_BIT = {
  NOTE    = 0x01,
  CC      = 0x02,
  PC      = 0x04,
  AT      = 0x08,
  PBEND   = 0x10,
  SYSEX   = 0x20,
  RT      = 0x40,
  ASENS   = 0x80,
}

-- Human-readable names
M.PORT_NAMES = {"P1","P2","P3","P4","P5","P6","USB"}
M.DIR_NAMES  = {"IN","OUT"}
M.TYPE_NAMES = {"TRS-A","TRS-B","DIN-5"}

M.CLOCK_SRC_NAMES = {"Internal","P1","P2","P3","P4","P5","P6","USB"}
M.CLOCK_DIV_NAMES = {"1:1","1:2","1:4","1:8","1:16","2:1","4:1"}

M.FILTER_NAMES = {"NOTE","CC","PC","AT","PBND","SYX","RT","ASNS"}
M.FILTER_BITS  = {
  M.FILTER_BIT.NOTE,
  M.FILTER_BIT.CC,
  M.FILTER_BIT.PC,
  M.FILTER_BIT.AT,
  M.FILTER_BIT.PBEND,
  M.FILTER_BIT.SYSEX,
  M.FILTER_BIT.RT,
  M.FILTER_BIT.ASENS,
}

-- -------------------------------------------------------------------------
-- 7-bit MIDI SysEx encoding / decoding
-- -------------------------------------------------------------------------

-- Encode raw byte array into MIDI-safe 7-bit SysEx payload.
-- Every 8th byte is a MSB-header whose 7 bits are the high bits of the
-- following 7 data bytes.
function M.encode7(src)
  local dst = {}
  local msb_pos = nil
  local bit = 0

  for i = 1, #src do
    if bit == 0 then
      -- insert MSB-header placeholder
      msb_pos = #dst + 1
      dst[msb_pos] = 0
      bit = 0
    end
    local b = src[i]
    if b & 0x80 ~= 0 then
      dst[msb_pos] = dst[msb_pos] | (1 << bit)
    end
    dst[#dst + 1] = b & 0x7F
    bit = (bit + 1) % 7
  end

  return dst
end

-- Decode a 7-bit SysEx payload back to raw bytes.
function M.decode7(src, offset, n)
  offset = offset or 1
  n = n or (#src - offset + 1)
  local dst = {}
  local msb = 0
  local bit = 0

  for i = 0, n - 1 do
    local b = src[offset + i]
    if bit == 0 then
      msb = b
      bit = 1
    else
      local actual_bit = bit - 1
      if msb & (1 << actual_bit) ~= 0 then
        b = b | 0x80
      end
      dst[#dst + 1] = b
      bit = bit + 1
      if bit == 8 then bit = 0 end
    end
  end

  return dst
end

-- Encode a uint16 value into two 7-bit bytes (little-endian 7-bit).
-- Used directly for parameter number / value when working with simple params.
function M.u16_to_7bit(v)
  return {v & 0x7F, (v >> 7) & 0x7F}
end

-- Decode two 7-bit bytes back to uint16.
function M.u16_from_7bit(lo, hi)
  return lo | (hi << 7)
end

-- -------------------------------------------------------------------------
-- SysEx packet builder / parser
-- -------------------------------------------------------------------------

-- Build a complete SysEx message.
--   cmd    = command byte
--   args   = array of raw (pre-encoding) bytes, or nil
-- Returns a table of bytes including SOX, header, cmd, encoded args, EOX.
function M.build(cmd, args)
  local msg = {M.SOX}
  for _, b in ipairs(M.MFR)   do msg[#msg+1] = b end
  msg[#msg+1] = M.PRODUCT
  msg[#msg+1] = cmd
  if args and #args > 0 then
    local enc = M.encode7(args)
    for _, b in ipairs(enc) do msg[#msg+1] = b end
  end
  msg[#msg+1] = M.EOX
  return msg
end

-- Build setparam_req packet.
function M.set_param_msg(nr, val)
  local args = {}
  local nr_b  = M.u16_to_7bit(nr)
  local val_b = M.u16_to_7bit(val)
  args[1] = nr_b[1]; args[2] = nr_b[2]
  args[3] = val_b[1]; args[4] = val_b[2]
  return M.build(M.CMD.SET_PARAM, args)
end

-- Build getparam_req packet.
function M.get_param_msg(nr)
  local nr_b = M.u16_to_7bit(nr)
  return M.build(M.CMD.GET_PARAM, {nr_b[1], nr_b[2]})
end

-- Build getnmbparams_req packet.
function M.get_num_params_msg()
  return M.build(M.CMD.GET_NUM_PARAMS, nil)
end

-- Build getparamdef_req packet.
function M.get_param_def_msg(nr)
  local nr_b = M.u16_to_7bit(nr)
  return M.build(M.CMD.GET_PARAM_DEF, {nr_b[1], nr_b[2]})
end

-- Try to parse an incoming SysEx byte array.
-- Returns a table {cmd=N, payload={...}} or nil if not an RK-006 packet.
function M.parse(data)
  if not data or #data < 7 then return nil end
  if data[1] ~= M.SOX then return nil end
  -- check manufacturer bytes
  if data[2] ~= M.MFR[1] or data[3] ~= M.MFR[2] or data[4] ~= M.MFR[3] then
    return nil
  end
  if data[5] ~= M.PRODUCT then return nil end
  local cmd = data[6]
  -- collect payload (everything between cmd and EOX)
  local raw = {}
  for i = 7, #data - 1 do
    if data[i] == M.EOX then break end
    raw[#raw + 1] = data[i]
  end
  local payload = M.decode7(raw, 1, #raw)
  return {cmd = cmd, payload = payload}
end

-- Helper: extract uint16 from decoded payload at byte positions i, i+1.
function M.payload_u16(payload, i)
  return M.u16_from_7bit(payload[i] or 0, payload[i+1] or 0)
end

return M
