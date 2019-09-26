--[[-----------------------------------------------------------
-- *--   DeChunk v1.0   --*
-- *--    Written by    --*
-- *-- EternalV3@github --*
--]]-----------------------------------------------------------

--[[-----------------------------------------------------------
-- Resulting structure
    {
       header = {
         signature,
         version,
         relVersion,
         endianness, 
         intSz,
         sizetSz,
         instructionSz, 
         numberSz,
         integral,
       },
       f = {
         source,
         linedefined,
         lastlinedefined,
         nups,
         numparams,
         is_vararg,
         maxstacksize,

         code = [...] { 
           instruction,
           opcode,
           opmode,
           A,
           B,
           C,
           Bx,
           sBx,
         },
         sizecode,
         k = [...] {
           tt,
           value,
         },
         sizek,
         p = [...] f,
         sizep,
         lineinfo = [...],
         sizelineinfo,
         locvars = [...] {
           varname,
           startpc,
           endpc,
         },
         upvalues = [...],
         sizeupvalues,
       }
    }
--]]-----------------------------------------------------------

--[[-----------------------------------------------------------
-- Default definitions for Lua 5.1
--]]-----------------------------------------------------------

---------------------------------------------------------------
-- Constant TValue types
---------------------------------------------------------------
local LUA_TNIL     = 0
local LUA_TBOOLEAN = 1
local LUA_TNUMBER  = 3
local LUA_TSTRING  = 4

---------------------------------------------------------------
-- Instruction data
--  - As for now, static register offsets/sizes are used
---------------------------------------------------------------

--- iABC = 0 | iABx = 1 | iAsBx = 2 --
local opmodes = {
  [0] = 0, 1, 0, 0, 
  0, 1, 0, 1, 0, 0, 
  0, 0, 0, 0, 0, 0, 
  0, 0, 0, 0, 0, 0, 
  2, 0, 0, 0, 0, 0, 
  0, 0, 0, 2, 2, 0, 
  0, 0, 1, 0,
}

---------------------------------------------------------------
-- Maximum call depth for a proto
---------------------------------------------------------------
local LUAI_MAXCCALLS = 200

---------------------------------------------------------------
-- Misc. header information
---------------------------------------------------------------
local LUAC_FORMAT = 0 -- Official 
local LUAC_VERSION = 0x51 -- 5.1

local LUA_SIGNATURE = "\27Lua" -- <esc>Lua
local LUA_DEFAULTHEADER = {
  signature = LUA_SIGNATURE, -- Lua signature (<esc>Lua)
  version = LUAC_VERSION, -- Lua version number (5.1)
  relVersion = LUAC_FORMAT, -- Binary header
  endianness = 1, -- Endianness (little endian by default)
  intSz = 4, -- sizeof(int)
  sizetSz = 4, -- sizeof(size_t)
  instructionSz = 4, -- sizeof(Instruction) (uint32 by default)
  numberSz = 8, -- sizeof(lua_Number) (double by default)
  integral = 0, -- Is integral? (non-fractional)
}

--[[-----------------------------------------------------------
-- Bit manipulation
--]]-----------------------------------------------------------

---------------------------------------------------------------
-- shiftLeft
-- Params: num<lua_Number>, amount<uint>
-- Desc: shifts left n times, replicates this:
--     num >>= amount
---------------------------------------------------------------
local function shiftLeft(num, amount)
  return math.ldexp(num, amount)
end

---------------------------------------------------------------
-- shiftRight
-- Params: num<lua_Number>, amount<uint>
-- Desc: shifts right n times, replicates this:
--     num <<= amount
---------------------------------------------------------------
local function shiftRight(num, amount)
  return math.floor(num / (2 ^ amount))
end

---------------------------------------------------------------
-- negateBts
-- Params: num<lua_Number>
-- Desc: Performs a logical negation, replicates this:
--     ~num
---------------------------------------------------------------
local function negateBits(num) 
  local res = 0
  for n = 0, 31 do
    local bit = shiftRight(num, n)
          bit = bit % 2
 
    res = res + shiftLeft(0 ^ bit, n)
  end
  
  return res
end

---------------------------------------------------------------
-- clearBits
-- Params: num<lua_Number>, start<uint>, end<uint>
-- Desc: Clears bits start-end, replicates this:
--     num &= ~(((~0) << end) << start)
---------------------------------------------------------------
local function clearBits(num, startBit, endBit)
  local res = num
  for i = startBit, endBit do
    local curBit = 2 ^ i
    res = res % (curBit + curBit) >= curBit  and res - curBit or res -- &= ~(1 << i)
  end
  
  return res
end

--[[-----------------------------------------------------------
-- Reading IEEE754 floating point types
--]]-----------------------------------------------------------

---------------------------------------------------------------
-- readSPFloat
-- Params: data<String>
-- Desc: Unpack a 4 byte IEEE754-Single-Precision floating 
-- point value from a string
---------------------------------------------------------------
local function readSPFloat(data)
    local number = 0.0
    for i = 4, 1, -1 do
      number = shiftLeft(number, 8) + string.byte(data, i)
    end

    local isNormal = 1
    local signed = shiftRight(number, 31)
    local exponent = shiftRight(number, 23)
          exponent = clearBits(exponent, 8, 9)
    local mantissa = clearBits(number, 23, 31)
    
    local sign = ((-1) ^ signed)
    if (exponent == 0) then
        if (mantissa == 0) then
            return sign * 0 -- +-0
        else
            exponent = 1
            isNormal = 0
        end
    elseif (exponent == 255) then
        if (mantissa == 0) then
            return sign * (1 / 0) -- +-Inf
        else
            return sign * 0 / 0 -- +-Q/NaN
        end
    end

    -- sign * 2**e-127 * isNormal.mantissa
    return math.ldexp(sign, exponent - 127) * (isNormal + (mantissa / (2 ^ 23)))
end

---------------------------------------------------------------
-- readSPFloat
-- Params: data<String>
-- Desc: Unpack a 8 byte IEEE754-Double-Precision floating
-- point value from a string
---------------------------------------------------------------
local function readDPFloat(data)
    local upper, lower = 0.0, 0.0

    for i = 8, 5, -1 do
      upper = shiftLeft(upper, 8) + string.byte(data, i)
    end

    for i = 4, 1, -1 do
      lower = shiftLeft(lower, 8) + string.byte(data, i)
    end

    local isNormal = 1
    local signed = shiftRight(upper, 31)
    local exponent = shiftRight(upper, 20)
          exponent = clearBits(exponent, 11, 12)
    local mantissa = shiftLeft(clearBits(upper, 20, 31), 32) + lower

    local sign = ((-1) ^ signed)
    if (exponent == 0) then
        if (mantissa == 0) then
            return sign * 0 -- +-0
        else
            exponent = 1
            isNormal = 0
        end
    elseif (exponent == 2047) then
        if (mantissa == 0) then
            return sign * (1 / 0) -- +-Inf
        else
            return sign * (0 / 0) -- +-Q/Nan
        end
    end
    
    -- sign * 2**e-1023 * isNormal.mantissa
    return math.ldexp(sign, exponent - 1023) * (isNormal + (mantissa / (2 ^ 52)))
end

--[[-----------------------------------------------------------
-- Chunk data loading functions
-- - Recreation of Lua's native loading system
--]]-----------------------------------------------------------

---------------------------------------------------------------
-- loadError
-- Params: msg<String>
-- Desc: Errors with the provided message
---------------------------------------------------------------
local function loadError(msg)
  local fmt = string.format("%s in precompiled chunk", msg)
  error(fmt)
end

---------------------------------------------------------------
-- loadBlock
-- Params: chunkData, size<uint>
-- Desc: Attempts to load data with the given size from the
-- chunk at the current working position
---------------------------------------------------------------
local function loadBlock(chunkData, size)
  local currentPos = chunkData.currentPos
  local chunk = chunkData.chunk
  local offset = currentPos + size

  if (#chunk < offset - 1) then
    loadError("unexpected end")
  else
    local data = chunk:sub(currentPos, offset)

    -- If chunk is big endian --
    if (chunkData.endianness == 0) then
      data = data:reverse()
    end

    chunkData.currentPos = currentPos + size

    return data
  end
end

---------------------------------------------------------------
-- loadChar
-- Params: chunkData
-- Desc: Attempts to load a character value from the given
-- chunk
---------------------------------------------------------------
local function loadChar(chunkData) 
  return loadBlock(chunkData, 1):byte()
end

---------------------------------------------------------------
-- loadInt
-- Params: chunkData
-- Desc: Attempts to load an integer value from the given chunk
--  - Integer must be positive
---------------------------------------------------------------
local function loadInt(chunkData)
  local sz = chunkData.header.intSz
  local intBytes = loadBlock(chunkData, sz)
  local int = 0

  for i = sz, 1, -1 do
    int = shiftLeft(int, 8) + string.byte(intBytes, i)
  end

  -- If signed, negate and add one --
  if (intBytes:byte(sz) > 127) then
    int = negateBits(int) + 1
    int = -int
  end

  if (int < 0) then
    loadError("bad integer")
  end

  return int
end

---------------------------------------------------------------
-- loadSizet
-- Params: chunkData
-- Desc: Attempts to load a size_t value from the given chunk
--  - size_t *should* be positive, but it will not error
---------------------------------------------------------------
local function loadSizet(chunkData)
  local sz = chunkData.header.sizetSz
  local intBytes = loadBlock(chunkData, sz)
  local sizet = 0

  for i = sz, 1, -1 do
    sizet = shiftLeft(sizet, 8) + string.byte(intBytes, i)
  end

  return sizet
end

---------------------------------------------------------------
-- loadNumber
-- Params: chunkData
-- Desc: Attempts to load a lua_Number value from the given
-- chunk
---------------------------------------------------------------
local function loadNumber(chunkData)
  local sz = chunkData.header.numberSz
  local numberBytes = loadBlock(chunkData, sz)
  local number

  if (sz == 4) then 
    number = readSPFloat(numberBytes)
  elseif (sz == 8) then
    number = readDPFloat(numberBytes)
  else
    loadError("number size mismatch")
  end

  return number
end

---------------------------------------------------------------
-- loadString
-- Params: chunkData
-- Desc: Attempts to load a string from the given chunk (- nul)
---------------------------------------------------------------
local function loadString(chunkData, forceSize)
  local sz = forceSize or loadSizet(chunkData)

  if (sz == 0) then
    return nil
  end

  -- Remove trailing nul --
  local str = loadBlock(chunkData, sz):sub(1, -3)
  return {len = #str, data = str}
end

---------------------------------------------------------------
-- loadFunction
-- Params: chunkData, chunkName<String>
-- Desc: Attempts to load a string from the given chunk
---------------------------------------------------------------
local function loadFunction(chunkData, chunkName)
  ---------------------------------------------------------------
  -- loadCode
  -- Params: nil
  -- Desc: Loads the code from the given chunk, not decoded yet
  ---------------------------------------------------------------
  local function loadCode()
    local sizecode = loadInt(chunkData)

    local code = {}
    for i = 1, sizecode do
      local sz = chunkData.header.instructionSz
      local instrBytes = loadBlock(chunkData, sz)
      local rawInstruction = 0

      for i = sz, 1, -1 do
        rawInstruction = shiftLeft(rawInstruction, 8) + string.byte(instrBytes, i)
      end

      local opcode = clearBits(rawInstruction, 6, 31)
      local opmode = opmodes[opcode]
      local A = shiftRight(rawInstruction, 6)
            A = clearBits(A, 7, 31)
      local B = shiftRight(rawInstruction, 23)
      local C = shiftRight(rawInstruction, 14)
            C = clearBits(C, 9, 17)
      local Bx = shiftLeft(B, 9) + C
      local sBx = Bx - 0x1ffff
      
      table.insert(code, {
        instruction = rawInstruction,
        opcode = opcode,
        opmode = opmode, 
        A = A,
        B = B,
        C = C,
        Bx = Bx,
        sBx = sBx
      })
    end

    return code, sizecode
  end

  ---------------------------------------------------------------
  -- loadCode
  -- Params: nil
  -- Desc: Loads constants from the given chunk
  ---------------------------------------------------------------
  local function loadConstants(source)
    local sizek = loadInt(chunkData)
    local k = {}

    for i = 1, sizek do
      local tt = loadChar(chunkData)
      local value

      if (tt == LUA_TNIL) then
        value = nil
      elseif (tt == LUA_TBOOLEAN) then
        value = loadChar(chunkData) ~= 0 -- 0 = false --
      elseif (tt == LUA_TNUMBER) then
        value = loadNumber(chunkData)
      elseif (tt == LUA_TSTRING) then
        value = loadString(chunkData)
      else 
        error("bad constant")
      end

      table.insert(k, {
        tt = tt,
        value = value
      })
    end

    -- Load protos --
    local sizep = loadInt(chunkData)
    local p = {}

    for i = 1, sizep do
      table.insert(p, loadFunction(chunkData, source))
    end

    return k, sizek, 
         p, sizep
  end

  ---------------------------------------------------------------
  -- loadDebug
  -- Params: nil
  -- Desc: Loads debug information from the given chunk
  ---------------------------------------------------------------
  local function loadDebug()
    -- Load line position info --
    local sizelineinfo = loadInt(chunkData)
    local lineinfo = {}

    for i = 1, sizelineinfo do
      table.insert(lineinfo, loadInt(chunkData))
    end

    -- Load local variable info --
    local sizelocvars = loadInt(chunkData)
    local locvars = {}

    for i = 1, sizelocvars do
      table.insert(locvars, {
        varname = loadString(chunkData),
        startpc = loadInt(chunkData),
        endpc = loadInt(chunkData),
      })
    end

    -- Load upvalue names --
    local sizeupvalues = loadInt(chunkData)
    local upvalues = {}

    for i = 1, sizeupvalues do
      table.insert(upvalues, loadString(chunkData))
    end

    return lineinfo, sizelineinfo,
         locvars, sizelocvars,
         upvalues, sizeupvalues
  end

  -- Actual loadFunction routine --
  local depth = chunkData.depth + 1
  chunkData.depth = depth

  if (depth > LUAI_MAXCCALLS) then
    loadError("code too deep")
  end

  local f = {
    source = loadString(chunkData) or chunkName,
    linedefined = loadInt(chunkData),
    lastlinedefined = loadInt(chunkData),
    nups = loadChar(chunkData),
    numparams = loadChar(chunkData),
    is_vararg = loadChar(chunkData),
    maxstacksize = loadChar(chunkData),
  }

  f.code, f.sizecode = loadCode()
  f.k, f.sizek, 
    f.p, f.sizep = loadConstants(f.source)

  f.lineinfo, f.sizelineinfo,
    f.locvars, f.sizelocvars,
    f.upvalues, f.sizeupvalues = loadDebug()

  chunkData.depth = depth - 1
  return f
end

local function loadHeader(chunkData, forceDefault)
  local header = {
    signature = loadString(chunkData, #LUA_SIGNATURE),
    version = loadChar(chunkData), 
    relVersion = loadChar(chunkData),
    endianness = loadChar(chunkData), 
    intSz = loadChar(chunkData),
    sizetSz = loadChar(chunkData),
    instructionSz = loadChar(chunkData), 
    numberSz = loadChar(chunkData),
    integral = loadChar(chunkData),
  }

  if (forceDefault) then
    header = LUA_DEFAULTHEADER
  end 

  return header
end

local function DeChunk(chunk)
  local str
  local tt = type(chunk)
  if (tt == "function") then
      str = string.dump(chunk)
  elseif (tt == "string") then
      str = chunk
  else
      error("Invalid chunk");
  end
  local chunkData = {
    depth = 0, -- Function depth --
    currentPos = 1, -- Chunk reading position --
    chunk = str, -- Actual binary chunk --
  } 

  local header = loadHeader(chunkData)
  chunkData.header = header

  local f = loadFunction(chunkData)
  chunkData.f = f

  return {header = header, f = f}
end

return DeChunk(...)
