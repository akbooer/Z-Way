module (..., package.seeall)

ABOUT = {
  NAME          = "L_ZWay2",
  VERSION       = "2020.03.13",
  DESCRIPTION   = "Z-Way interface for openLuup",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2020 AKBooer",
  DOCUMENTATION = "https://community.getvera.com/t/openluup-zway-plugin-for-zwave-me-hardware/193746",
  DEBUG         = false,
  LICENSE       = [[
  Copyright 2013-2020 AK Booer

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
]]
}

-- 2017.10.03  added test_from_file function

-- 2018.03.15  remove command class 113 from being Security sensor CC 48 equivalent
--             see: http://forum.micasaverde.com/index.php/topic,62975.0.html
-- 2018.07.16  name = dv.metrics.title, for @DesT
-- 2018.08.25  check for missing device file in parameter_list()  (thanks @ramwal)

-- 2020.02.10  fixed meter variable names, thanks @rafale77
--             ditto, CurrentSetpoint in command class 67
--             see: https://community.getvera.com/t/zway-plugin/212312/40

-----------------

-- 2020.02.12  L_ZWay2 -- rethink of device presentation and numbering
-- 2020.02.25  add intermediate instance nodes
-- 2020.02.26  change node numbering scheme
-- 2020.03.02  significant improvements to dimmer handling thanks to @rafale77
-- ...         sundry iterations on GitHub
-- 2020.03.11  add SendData action (thanks @DesT), fix nil setpoint serviceId
-- 2020.03.12  complete restructure in progress...




local json    = require "openLuup.json"
local chdev   = require "openLuup.chdev"    -- NOT the same as the luup.chdev module! (special create fct)
local http    = require "socket.http"
local ltn12   = require "ltn12"

local empty = setmetatable ({}, {__newindex = function() error ("read-only", 2) end})

------------------

local function _log(text, level)
	luup.log(("%s: %s"): format ("ZWay", text), (level or 50))
end

local function debug (info)
  if ABOUT.DEBUG then
    print (info)
    _log(info, "DEBUG")
  end
end

------------------

local Z         -- the Zway API object

local cclass_update   -- table of command_class updaters indexed by altid

local devNo     -- our device number
local OFFSET    -- bridge offset for child devices
local POLLRATE  -- poll rate for Zway devices

local CLONEROOMS    --
local NAMEDEVICES   --
local ZERODIMMER    --

local DEV = setmetatable ({
    --
    dimmer      = "D_DimmableLight1.xml",
    thermos     = "D_HVAC_ZoneThermostat1.xml",
    motion      = "D_MotionSensor1.xml",

    -- these preset devices don't correspond to any ZWay vDev
    controller  = "D_SceneController1.xml",
    combo       = "D_ComboDevice1.xml",
    rgb         = "D_DimmableRGBLight1.xml",
  },{
    __index = function (_,n) _log ("ERROR: Unknown DEV: "..(n or '?')) end})


local KnownSID = {          -- list of all implemented serviceIds
  
    "urn:akbooer-com:serviceId:ZWay1",
    
    "urn:micasaverde-com:serviceId:Camera1",
    "urn:micasaverde-com:serviceId:Color1",
    "urn:micasaverde-com:serviceId:ComboDevice1",
    "urn:micasaverde-com:serviceId:DoorLock1",
    "urn:micasaverde-com:serviceId:EnergyMetering1",
    "urn:micasaverde-com:serviceId:GenericSensor1",
    "urn:micasaverde-com:serviceId:HVAC_OperatingState1",
    "urn:micasaverde-com:serviceId:HaDevice1",
    "urn:micasaverde-com:serviceId:HumiditySensor1",
    "urn:micasaverde-com:serviceId:LightSensor1",
    "urn:micasaverde-com:serviceId:SceneController1",
    "urn:micasaverde-com:serviceId:SceneControllerLED1",
    "urn:micasaverde-com:serviceId:SecuritySensor1",
    "urn:micasaverde-com:serviceId:WindowCovering1",
    "urn:micasaverde-com:serviceId:ZWaveNetwork1",
    
    "urn:upnp-org:serviceId:Dimming1",
    "urn:upnp-org:serviceId:FanSpeed1",
    "urn:upnp-org:serviceId:HVAC_FanOperatingMode1",
    "urn:upnp-org:serviceId:HVAC_UserOperatingMode1",
    "urn:upnp-org:serviceId:SwitchPower1",
    "urn:upnp-org:serviceId:TemperatureSensor1",
    "urn:upnp-org:serviceId:TemperatureSetpoint1",
    "urn:upnp-org:serviceId:TemperatureSetpoint1_Cool",
    "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat",

}

-- build list of shorthand names for known serviceId

local SID = setmetatable ({
    AltUI   = "urn:upnp-org:serviceId:altui1",
    bridge  = luup.openLuup.bridge.SID,                         -- for Remote_ID variable
  },{
    __index = function (_,n) _log ("ERROR: Unknown SID: "..(n or '?')) end})

for _,name in ipairs (KnownSID) do
  local short_name = name: match "[^:]+$" :gsub ("%d*$",'')
  SID[short_name] = name
  SID[name] = short_name
end


--[[

ZWayVDev [Node ID]:[Instance ID]:[Command Class ID]:[Scale ID]

The Node Id is the node id of the physical device,
the Instance ID is the instance id of the device or ’0’ if there is only one instance.
The command class ID refers to the command class the function is embedded in.
The scale id is usually ’0’ unless the virtual device is generated from a Z-Wave device
that supports multiple sensors with different scales in one single command class.

--]]

-- given vDev structure, return altid, vtype, etc...
--   ... node, instance, command_class, scale, sub_class, sub_scale, tail
local NICS_pattern = "^(%d+)%-(%d+)%-?(%d*)%-?(%d*)%-?(%d*)%-?(%d*)%-?(.-)$"
local function NICS_etc (vDev)
  local vtype, altid = vDev.id: match "^ZWayVDev_(zway_%D*)(.+)"
  if altid then
    return altid, vtype, altid: match (NICS_pattern)
  end
end

local NIaltid = "^(%d+)%-(%d+)$"      -- altid of just node-instance format (ie. not child vDev)

-- NB: for thermostats, see @rigpapa's useful post:
--   old:   http://forum.micasaverde.com/index.php/topic,79510.0.html
--    new:  https://community.getvera.com/t/need-help-getting-started-trying-to-get-themostat-with-heat-cool-setpoints/198983/2

-- LUUP utility functions


local function getVar (name, service, device)
  service = service or SID.ZWay
  device = device or devNo
  -- this needs to be fast because it is called for every vDev each update cycle
  -- use openLuup objects, rather than slower luup.variable_get() function call
  -- local x = luup.variable_get (service, name, device)
  local dev, srv, var, x
  dev = luup.devices[tonumber(device)]
  srv = dev.services[service]
  if srv then var = srv.variables[name] end
  if var then x = var.value end
  return x
end

local function setVar (name, value, service, device)
  service = service or SID.ZWay
  device = device or devNo
  -- use getVar(), above, rather than slower luup.variable_get () function call
  -- local old = luup.variable_get (service, name, device)
  local old = getVar (name, service, device)
  if tostring(value) ~= old then
   luup.variable_set (service, name, value, device)  -- no option here, because of logging, etc.
  end
end

-- get and check UI variables
local function uiVar (name, default, lower, upper)
  local value = getVar (name)
  local oldvalue = value
  if value and (value ~= "") then           -- bounds check if required
    if lower and (tonumber (value) < lower) then value = lower end
    if upper and (tonumber (value) > upper) then value = upper end
  else
    value = default
  end
  value = tostring (value)
  if value ~= oldvalue then setVar (name, value) end   -- default or limits may have modified value
  return value
end

-- given  "on" or "off" or "1"  or "0"
-- return "1"  or "0"   or "on" or "off"
local function on_or_off (x)
  local y = {["on"] = "1", ["off"] = "0", ["1"] = "on", ["0"] = "off", [true] = "on"}
  local z = tonumber (x)
  local on = z and z > 0
  return y[on or x] or x
end

local function open_or_close (x)
  local y = {["open"] = "0", ["close"] = "1", ["0"] = "open", ["1"] = "close"}
  return y[x] or x
end

local function rev_open_or_close (x)
  local y = {["open"] = "1", ["close"] = "0", ["1"] = "open", ["0"] = "close"}
  return y[x] or x
end

-- make either "1" or "true" work the same way
local function is_true (flag)
  local y = {["true"] = true, ["1"] = true}
  return y [flag]
end


----------------------------------------------------
--
-- SERVICE SCHEMAS - virtual services
-- openLuup => Zway
--

local SRV = setmetatable ({}, {__index = function (t,n) return t[SID[n]] end})  -- auto name alias

--[[
vDev commands:
1. ’update’: updates a sensor value
2. ’on’: turns a device on
3. ’off’: turns a device off
4. ’exact’: sets the device to an exact value. This will be a temperature for thermostats or a percentage value of motor controls or dimmers
--]]

SRV.SwitchPower = {

    ---------------
    -- 2020.03.02  thanks to @rafale77 for extensive testing and code changes
    --
    SetTarget = function (d, args)
      local level = tostring(args.newTargetValue or 0)
      local off = level == '0'
      local class ="-37"

      luup.variable_set (SID.SwitchPower, "Target", off and '0' or '1', d)
      local dimmer = luup.variable_get(SID.Dimming, "OnEffectLevel",d)  -- check for dimmer
      if dimmer then
        class =  "-38"
        if ZERODIMMER then
          luup.variable_set (SID.Dimming, "LoadLevelTarget", off and '0' or dimmer, d)
        end
      end
      local value = on_or_off (level)

      local gdo = luup.variable_get(SID.DoorLock, "Status",d) -- check garage door
      if gdo then
        class = "-102"
        value = rev_open_or_close(level)
      end

      local altid = luup.devices[d].id
      altid = altid: match (NIaltid) and altid..class or altid
      Z.command (altid, value)
    end,

  }


SRV.Dimming = {

    ---------------
    -- 2020.03.02   thanks to @rafale77 for extensive testing and code changes
    --
    SetLoadLevelTarget = function (d, args)
      local level = tostring (args.newLoadlevelTarget or 0)
      local off = level == '0'
      local class = "-38"
      
      luup.variable_set (SID.SwitchPower, "Target", off and '0' or '1', d)
      luup.variable_set (SID.Dimming, "OnEffectLevel", level, d)
      luup.variable_set (SID.Dimming, "LoadLevelTarget", level, d)

      local altid = luup.devices[d].id
      altid = altid: match (NIaltid) and altid..class or altid
      local value = "exact?level=" .. level
      Z.command (altid, value)
    end,

  }


SRV.HaDevice = {

    ToggleState = function (d)
      local toggle = {['0'] = '1', ['1']= '0'}
      local status = getVar ("Status", SID.SwitchPower, d)
      SRV.SwitchPower.SetTarget (d, {newTargetValue = toggle [status] or '0'})
    end,

    Poll = function (d)
      local cc = 32
      local cmd = "Get()"
      local altid = luup.devices[d].id
      local id, inst = altid: match (NIaltid)
      Z.zwcommand(id, inst, cc, cmd)
    end,
  }


SRV.TemperatureSensor = {
    
    GetCurrentTemperature = {returns = {CurrentTemp = "CurrentTemperature"}},
  
  }


  --
SRV.SecuritySensor = {

  SetArmed = function (d, args)
    luup.variable_set (SID.SecuritySensor, "Armed", args.newArmedValue or '0', d)
  end,

  }

SRV.Color = {

  -- args.newColorRGBTarget = "61,163,69"
  SetColorRGB = function (d, args)
    local rgb = { (args.newColorRGBTarget or ''): match "^(%d+),(%d+),(%d+)" }
    if #rgb ~= 3 then return end

    -- find our child devices...
    local c = {}
    for i,dev in pairs (luup.devices) do
      if dev.device_num_parent == d then
        c[#c+1] = {devNo = i, altid = dev.id}
      end
    end
    table.sort (c, function (a,b) return a.altid < b.altid end)
    if #c < 5 then return end

    -- assume the order M0 M1 R G B (w)

    for i = 1,3 do
      _log ("setting: " .. rgb[i])
      local level = math.floor ((rgb[i]/256)^2 * 100) -- map 0-255 to 0-100, with a bit of gamma
      SRV.Dimming.SetLoadLevelTarget (c[i+2].devNo, {newLoadlevelTarget = level})
    end
  end,

}


SRV.DoorLock = {

    SetTarget = function (d, args)
      local value = open_or_close (args.newTargetValue)
      local altid = luup.devices[d].id
      altid = altid: match (NIaltid) and altid.."-98" or altid
      Z.command (altid, value)
    end,

}

SRV.EnergyMetering  = {

    ResetKWH = function (d)
      local altid = luup.devices[d].id
      local id, inst = altid: match (NIaltid)
      local cc = 50     --command class
      local cmd = "Reset()"
      Z.zwcommand(id, inst, cc, cmd)
    end,

}

SRV.GenericSensor         = { }
SRV.HumiditySensor        = { }
SRV.LightSensor           = { }

SRV.SceneControllerLED = {

  SetLight = function (d, args)
    local altid = luup.devices[d].id
    local id, inst = altid: match (NIaltid)
    local cc = 145     --command class
    local color = tonumber(args.newValue)
    local indicator = args.Indicator
    local data = "[%s,0,29,13,1,255,%s,0,0,10]"
    local ItoL = {["1"] = 1, ["2"] = 2, ["3"] = 4, ["4"] = 8, ["5"] = 15}
    local led = ItoL[indicator]
    if led then
      local bit_lshift_led = led * 16                 --bit.lshift(led,4)
      if color == 2 then led = bit_lshift_led
      elseif color == 3 then led = led + bit_lshift_led
      elseif color == 0 then led = 0
      end
      data = data: format(cc,led)
      Z.zwsend(id,data)
    end
  end,

 }

SRV.WindowCovering  = { }
SRV.Unknown         = { }   -- "catch-all" service


------------
--
-- Thermostat info
--


-- D_HVAC_ZoneThermostat1.xml uses these default serviceIds and variables...

SRV.HVAC_FanOperatingMode = {
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite
  SetMode = function (d, args)
    local value = args.NewMode
    local altid = luup.devices[d].id
    local id, inst = altid: match (NIaltid)
    local cc = 68     --command class
    local sid = SID.HVAC_FanOperatingMode
    local VtoZ = {Auto = "Set(1,0)", ContinuousOn = "Set(1,1)", PeriodicOn = "Set(1,0)"}
    local cmd = VtoZ[value]
    if cmd then
      Z.zwcommand(id, inst, cc, cmd)
      luup.variable_set (sid, "Mode", value, d)
    end
  end,

  GetMode      = { returns = {CurrentMode    = "Mode"      } },

  GetFanStatus = { returns = {CurrentStatus  = "FanStatus" } },

  }

SRV.HVAC_OperatingState = { --[[
--["66"] Operating_state
--  ["67"]  -- Setpoint
        --Setpoint
        --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
urn:micasaverde-com:serviceId:HVAC_OperatingState1,ModeState=Off

  <allowedValue>Idle</allowedValue>
  <allowedValue>Heating</allowedValue>
  <allowedValue>Cooling</allowedValue>
  <allowedValue>FanOnly</allowedValue>
  <allowedValue>PendingHeat</allowedValue>
  <allowedValue>PendingCool</allowedValue>
  <allowedValue>Vent</allowedValue>
--]]
}

SRV.HVAC_UserOperatingMode = {

  SetModeTarget = function (d, args)
    local valid = {Off = true, AutoChangeOver = true, CoolOn = true, HeatOn = true}
    local value = args.NewModeTarget
    local altid = luup.devices[d].id
    local id, inst = altid: match (NIaltid)
    local cc = 64     --command class
    local sid = SID.HVAC_UserOperatingMode
    if valid[value] then
      local VtoZ = {Off = "Set(0)", HeatOn = "Set(1)", CoolOn = "Set(2)", AutoChangeOver = "Set(3)"}
      local cmd = VtoZ[value]
      Z.zwcommand(id, inst, cc, cmd)
      luup.variable_set (sid, "ModeTarget", value, d)
      luup.variable_set (sid, "ModeStatus", value, d)
    end
  end,
        --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
        --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific
  }


SRV.FanSpeed = { --[[
urn:upnp-org:serviceId:FanSpeed1,FanSpeedTarget=0
urn:upnp-org:serviceId:FanSpeed1,FanSpeedStatus=0
urn:upnp-org:serviceId:FanSpeed1,DirectionTarget=0
urn:upnp-org:serviceId:FanSpeed1,DirectionStatus=0
   <name>SetFanSpeed</name>
         <name>NewFanSpeedTarget</name>
         <relatedStateVariable>FanSpeedTarget</relatedStateVariable>
   <name>GetFanSpeed</name>
         <name>CurrentFanSpeedStatus</name>
         <relatedStateVariable>FanSpeedStatus</relatedStateVariable>
   <name>GetFanSpeedTarget</name>
         <name>CurrentFanSpeedTarget</name>
         <relatedStateVariable>FanSpeedTarget</relatedStateVariable>
   <name>SetFanDirection</name>
         <name>NewDirectionTarget</name>
         <relatedStateVariable>DirectionTarget</relatedStateVariable>
   <name>GetFanDirection</name>
         <name>CurrentDirectionStatus</name>
         <relatedStateVariable>DirectionStatus</relatedStateVariable>
    <name>GetFanDirectionTarget</name>
         <name>CurrentDirectionTarget</name>
         <relatedStateVariable>DirectionTarget</relatedStateVariable>
--]]
}


local function SetCurrentSetpoint (sid, d, args)
  local level = args.NewCurrentSetpoint
  if level then
    luup.variable_set (sid, "CurrentSetpoint", level, d)
    local value = "exact?level=" .. level
    local altid = luup.devices[d].id
    if altid: match (NIaltid) then
      local suffix = {
        [SID.TemperatureSetpoint]      = "-67",
        [SID.TemperatureSetpoint1_Heat]  = "-67-1",
        [SID.TemperatureSetpoint1_Cool]  = "-67-2",
      }
      altid = altid .. (suffix[sid] or '')
      Z.command (altid, value)
    end
  end
end

SRV.TemperatureSetpoint = {

    GetCurrentSetpoint  = {returns = {CurrentSP  = "CurrentSetpoint"}},
    GetSetpointAchieved = {returns = {CurrentSPA = "SetpointAchieved"}},

    SetCurrentSetpoint = function (...) 
      return SetCurrentSetpoint (SID.TemperatureSetpoint, ...) 
    end
    
}

local function shallow_copy (x)
  local y = {}
  for a,b in pairs (x) do y[a] = b end
  return y
end

-- these copies MUST be separate tables, since they're used to index the SID table
SRV.TemperatureSetpoint1_Heat = shallow_copy (SRV.TemperatureSetpoint)

SRV.TemperatureSetpoint1_Heat.SetCurrentSetpoint = function (...) 
  return SetCurrentSetpoint (SID.TemperatureSetpoint1_Heat, ...) 
end

SRV.TemperatureSetpoint1_Cool = shallow_copy (SRV.TemperatureSetpoint)

SRV.TemperatureSetpoint1_Cool.SetCurrentSetpoint = function (...) 
  return SetCurrentSetpoint (SID.TemperatureSetpoint1_Cool, ...) 
end


----------------------------------------------------
--
-- COMMAND CLASSES - virtual device updates
--

local command_class = {

  -- catch-all
  ["0"] = function (d, inst, meta)

    -- scene controller
    local dev = luup.devices[d]
    if dev.attributes.device_file == DEV.controller then   -- this is the Luup device file
      local click = inst.updateTime
--      setVar ("LastUpdate_" .. meta.altid, click, SID.ZWay, d)
      if click ~= meta.click then -- force variable updates
        local scene = meta.scale
        local time  = os.time()     -- "◷" == json.decode [["\u25F7"]]

        luup.variable_set (SID.SceneController, "sl_SceneActivated", scene, d)
        luup.variable_set (SID.SceneController, "LastSceneTime",time, d)
        
        meta.click = click
      end

    else
--        local message = "no update for device %d [%s] %s %s"
--        log (message: format (d, inst.id, inst.deviceType or '?', (inst.metrics or {}).icon or ''))
      --...
    end
  end,

  -- binary switch
  ["37"] = function (d, inst, meta)
    setVar ("Status",on_or_off (inst.metrics.level), meta.service, d)
  end,

  -- multilevel switch
  ["38"] = function (d, inst, meta)
    local level = tonumber (inst.metrics.level) or 0
    setVar ("LoadLevelStatus", level, meta.service, d)
    local status = (level > 0 and "1") or "0"
    setVar ("Status", status, SID.SwitchPower, d)
  end,

  -- binary sensor
  ["48"] = function (d, inst)
    local sid = SID.SecuritySensor
    local tripped = on_or_off (inst.metrics.level)
    local old = getVar ("Tripped", sid)
    -- 2020.02.15  ArmedTripped now generated by openLuup itself for all security sensor services
    if tripped ~= old then
      setVar ("Tripped", tripped, sid, d)
      setVar ("LastTrip", inst.updateTime, sid, d)
    end
  end,

  -- multilevel sensor
  ["49"] = function (d, inst, meta)   -- TODO: more to do here to sub-type?
    local sensor_variable_name = {
      [SID.TemperatureSensor]    = "CurrentTemperature",
      [SID.EnergyMetering] = "W",    --  2020.03.05  "Watts" conflicts with meter "50-2" if both present
    }
    local var = sensor_variable_name[meta.service] or "CurrentLevel"
    local value = inst.metrics.level
    local round = "%0.4f"
    value = tonumber(round: format (value) )       -- 2020.02.22 TODO: why are some values not rounded?
    setVar (var, value, meta.service, d)
  end,

  -- meter
  ["50"] = function (d, inst, meta)
    local var = (inst.metrics.scaleTitle or '?'): upper ()
    local translate = {W = "Watts", A = "Amps", V = "Volts"}      -- 2020.02.10 thanks @rafale77
    if var then setVar (translate[var] or var, inst.metrics.level, meta.service, d) end
  end,

  -- door lock
  ["98"] = function (d, inst)
      setVar ("Status",open_or_close (inst.metrics.level), SID.DoorLock, d)
  end,

  -- thermostat

  ["64"] = function (d, inst, meta)       -- ThermostatMode
    -- ZWay modes:
    --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
    --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific.
    -- Vera modes:
    --  {Off = true, AutoChangeOver = true, CoolOn = true, HeatOn = true, }
      local ZtoV = {Off = "Off", Heat = "HeatOn", Cool = "CoolOn", Auto = "AutoChangeOver", ["Auto Change Over"] = "AutoChangeOver"}
      local level = inst.metrics.level
    --  setVar ("ModeStatus", ZtoV[level] or level, meta.service, d)
  end,

  ["66"] = function (d, inst)       -- Operating_state
  end,

  ["67"] = function (d, inst, meta)       -- Setpoint
    --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
    local scale = meta.scale
    local sid
    if scale == "1" then  -- heat
      sid = SID.TemperatureSetpoint1_Heat
    elseif scale == "2" then  -- cool
      sid = SID.TemperatureSetpoint1_Cool
    end
    if sid then
      setVar ("CurrentSetpoint", inst.metrics.level, sid, d)      -- 2020.02.10, thanks @rafale77
    end
  end,

  ["68"] = function (d, inst)       -- ThermostatFanMode
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite
  end,


  -- barrier operator (eg. garage door)
  ["102"] = function (d, inst)
    local status = rev_open_or_close (inst.metrics.level)
    setVar ("Status", status, SID.DoorLock, d)
    setVar ("Status", status, SID.SwitchPower, d) -- correct readback for garage door
  end,

  -- battery
  ["128"] = function (d, inst)
    local level = tonumber (inst.metrics.level)
    local warning = (level < 10) and "1" or "0"
    setVar ("BatteryLevel", level, SID.HaDevice, d)
    setVar ("sl_BatteryAlarm", warning, SID.HaDevice, d)
  end,

}

command_class ["113"] = command_class ["48"]      -- alarm
command_class ["156"] = command_class ["48"]      -- tamper switch


function command_class.new (dino, meta)
  local updater = command_class[meta.c_class] or command_class["0"]
  return function (inst, ...)
      -- call with deviceNo, instance object, and metadata (for persistent data)
      return updater (dino, inst, meta, ...)
    end
end

-----------------------------------------
--
-- DEVICE status updates: ZWay => openLuup
--

local D = {}    -- device structure simply for the HTTP callback diagnostic

function _G.updateChildren (d)
  D = d or Z.devices () or {}
  for _,inst in pairs (D) do
    local altid, vtype, node, instance = NICS_etc (inst)
    if node then
      local zDevNo = OFFSET + node * 10 + instance    -- determine device number from node and id
      local zDev = luup.devices[zDevNo]
      if zDev then
        -- set all the Vdev variables in the Zwave node devices
        local id = vtype .. altid
        setVar (id, inst.metrics.level, SID.ZWay, zDevNo)
        setVar (id .. "_LastUpdate", inst.updateTime, SID.ZWay, zDevNo)
        setVar ("CommFailure", inst.metrics.isFailed, SID.HaDevice, zDevNo)

        local update = cclass_update [altid]
        if update then update (inst) end
      end
    end
  end
  luup.call_delay ("updateChildren", POLLRATE)
end


----------------------------------------------------

-- DEVICES

-- use Device maps to lookup Vera category, hence device type...
-- ...and from the device file we can then get services...
-- ...and from the service files, the actions and variables.
--


-- c_class, {upnp_file, serviceId, json_file}, [scale = {...}] }
local vMap = {
  ["0"]  = { nil, SID.HaDevice },   -- not really a NO_OP, but a "catch-all"

  ["37"] = { "D_BinaryLight1.xml",      SID.SwitchPower       },
  ["38"] = { "D_DimmableLight1.xml",    SID.Dimming },
  ["45"] = { "D_SceneControllerLED1.xml", SID.SceneControllerLED, "D_SceneControllerLED1.json"}, -- Leviton Zone/scene controller
  ["48"] = { "D_MotionSensor1.xml",     SID.SecuritySensor ,        -- SensorBinary
    scale = {
        ["1"] = { nil, nil, "D_GlassBreakSensorWithTamper.json" }, --	1	"Glass Break"
--	2	"Smoke"     -- "D_SmokeSensor1.xml"
--	3	"CO"        -- "D_SmokeCoSensor1.json"
--	4	"CO2"
--	5	"Heat"
        ["6"] = { "D_FloodSensor1.xml", nil, "D_FloodSensor1.json" }, --	6	"Water"
--	7	"Freeze"
--	8	"Tamper"
--	9	"Aux"
        ["10"] = { "D_DoorSensor1.xml" }, --	10	"Door/Window"
--	11	"Tilt"
--	12	"Motion"
--	13	"Glass Break"
--	14	"First supported Sensor Type"
--]]
    }},
  ["49"] = {  -- SensorMultilevel: no default device or service
    scale = {
      ["1"]  = { "D_TemperatureSensor1.xml",  SID.TemperatureSensor },
      ["2"]  = { "D_GenericSensor1.xml",      SID.GenericSensor },
      ["3"]  = { "D_LightSensor1.xml",        SID.LightSensor},
      ["4"]  = { "D_PowerMeter1.xml",         SID.EnergyMetering},
      ["5"]  = { "D_HumiditySensor1.xml",     SID.HumiditySensor},
      ["27"] = { "D_LightSensor1.xml",        SID.LightSensor,     "D_UVSensor1.json" } -- .json for icon
    }},
  --[[

SensorMultilevel
	1	"Temperature"	 - scale: {"C","F"}
	2	"Generic"	 - scale: {"","%"}
	3	"Luminiscence"	 - scale: {"%","Lux"}
	4	"Power"	 - scale: {"W","Btu/h"}
	5	"Humidity"	 - scale: {"%","Absolute humidity"}
	6	"Velocity"	 - scale: {"m/s","mph"}
	7	"Direction"
	8	"Athmospheric Pressure"	 - scale: {"kPa","inch Mercury"}
	9	"Barometric Pressure"	 - scale: {"kPa","inch Mercury"}
	10	"Solar Radiation"
	11	"Dew Point"	 - scale: {"C","F"}
	12	"Rain Rate"	 - scale: {"mm/h","inch/h"}
	13	"Tide Level"	 - scale: {"m","feet"}
	14	"Weigth"	 - scale: {"kg","pounds"}
	15	"Voltage"	 - scale: {"V","mV"}
	16	"Current"	 - scale: {"A","mA"}
	17	"CO2 Level"
	18	"Air Flow"	 - scale: {"m3/h","cfm"}
	19	"Tank Capacity"	 - scale: {"l","cbm","gallons"}
	20	"Distance"	 - scale: {"m","cm","Feet"}
	21	"Angle Position"	 - scale: {"%","Degree to North Pole","Degree to South Pole"}
	22	"Rotation"	 - scale: {"rpm","Hz"}
	23	"Water temperature"	 - scale: {"C","F"}
	24	"Soil temperature"	 - scale: {"C","F"}
	25	"Seismic intensity"	 - scale: {"Mercalli","European Macroseismic","Liedu","Shindo"}
	26	"Seismic magnitude"	 - scale: {"Local","Moment","Surface wave","Body wave"}
	27	"Ultraviolet"
	28	"Electrical resistivity"
	29	"Electrical conductivity"
	30	"Loudness"	 - scale: {"Absolute loudness (dB)","A-weighted decibels (dBA)"}
	31	"Moisture"	 - scale: {"%","Volume water content (m3/m3)","Impedance (kΩ)","Water activity (aw)"}
	32	"Frequency"	 - scale: {"Hz","kHz"}
	33	"Time"
	34	"Target Temperature"	 - scale: {"C","F"}
	35	"Particulate Matter"	 - scale: {"mol/m3","μg/m3"}
	36	"Formaldehyde (CH2O)"
	37	"Radon Concentration"	 - scale: {"bq/m3","pCi/L"}
	38	"Methane Density (CH4)"
	39	"Volatile Organic Compound (VOC)"
	40	"Carbon Monoxide (CO)"
	41	"Soil Humidity"
	42	"Soil Reactivity"
	43	"Soil Salinity"
	44	"Heart Rate"
	45	"Blood Pressure"	 - scale: {"Systolic (mmHg)","Diastolic (mmHg)"}
	46	"Muscle Mass"
	47	"Fat Mass"
	48	"Bone Mass"
	49	"Total Body Water"
	50	"Basic Metabolic Rate"
	51	"Body Mass Index"
	52	"Acceleration￼X-axis"
	53	"Acceleration￼Y-axis"
	54	"Acceleration￼Z-axis"
	55	"Smoke Density"
  --]]
  ["50"] = { "D_PowerMeter1.xml", SID.EnergyMetering },   -- device is "D_PowerMeter1.xml"
  --[[
  Meter
    1	"Electric"	 - scale: {"kWh","kVAh","W","Pulse Count","V","A","Power Factor"}
    2	"Gas"	 - scale: {"Cubic meter","Cubic feet","reserved","Pulse Count"}
    3	"Water"	 - scale: {"Cubic meter","Cubic feet","US Gallon","Pulse Count"}
  --]]
  ["51"] = { nil, SID.Dimming },   -- SWITCH COLOUR

  ["64"] = { "D_HVAC_ZoneThermostat1.xml", SID.HVAC_UserOperatingMode},    -- Thermostat_mode
    --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
    --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific
  ["66"] = { nil, SID.HVAC_OperatingState }, -- Operating_state
  ["67"] = { nil, SID.TemperatureSetpoint, -- Setpoint
    --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
    scale = {
      ["1"]  = { nil, SID.TemperatureSetpoint1_Heat },
      ["2"]  = { nil, SID.TemperatureSetpoint1_Cool },
    },
  },

  ["68"] = {nil, SID.HVAC_FanOperatingMode}, -- ThermostatFanMode
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite

  ["98"] = { "D_DoorLock1.xml",   SID.DoorLock },

  ["102"] = { "D_BinaryLight1.xml",  SID.SwitchPower, "D_GarageDoor_Linear.json" },    -- "Barrier Operator"
  ["113"] = { "D_DoorSensor1.xml", SID.SecuritySensor, "D_DoorSensor1.json",    -- "Alarm Notifications" 
     scale = {
--  1	"Smoke"
--	2	"CO"     -- "D_SmokeSensor1.xml"
--	3	"CO2"    -- "D_SmokeCoSensor1.json"
--	4	"Heat"
      ["5"] = { "D_FloodSensor1.xml", SID.SecuritySensor, "D_FloodSensor1.json" }, -- "Water"
      ["6"] = { "D_DoorSensor1.xml", SID.SecuritySensor, "D_DoorSensor1.json" }, -- "Access Control"
      ["7"] = { "D_MotionSensor1.xml", SID.SecuritySensor, "D_MotionSensor1.json" }, --	7	"Tamper or generic motion"
--	8	"Power"
--	9	"System"
--  10 "Emergency"
--	11 "Tilt"
--	12 "Motion"
--]]
    }},
  ["128"] = { nil, SID.EnergyMetering },
  ["145"] = { "D_SceneControllerLED1.xml", SID.SceneControllerLED, "D_SceneControllerLED1.json"}, -- Leviton Zone/scene controller proprietary
  ["152"] = { "D_MotionSensor1.xml", SID.SecuritySensor },
  ["156"] = { "D_FloodSensor1.xml", SID.SecuritySensor, "D_FloodSensor1.json" },    -- "Old alarm sensor"
-- D_Siren1.xml
-- D_SmokeSensor1.xml
}


--[[

instance = {
    creationTime = 1468168215,
    creatorId = 1,
    deviceType = "sensorMultilevel",
    h = 618053595,
    hasHistory = false,
    id = "ZWayVDev_zway_9-0-49-3",
    location = 0,
    metrics = {
      icon = "luminosity",
      level = 9,
      probeTitle = "Luminiscence",
      scaleTitle = "Lux",
      title = "Aeon Labs Luminiscence (9.0.49.3)",
      isFailed =	false,
},
    permanently_hidden = false,
    probeType = "luminosity",
    tags = {},
    updateTime = 1468837030,
    visibility = true
  }

--]]


-- create metadata for each virtual device instance
local function vDev_meta (v)
  local altid, vtype, node, instance, c_class, scale, sub_class, sub_scale, tail = NICS_etc(v)

  if node then
    local x = vMap[c_class] or {}
    local y = (x.scale or {})[scale] or {}
    local z = setmetatable (y, {__index = x})

    local upnp_file = z[1]
    local service   = z[2]
    local json_file = z[3]

    local devtype = (json_file or upnp_file or ''): match "^D_(%u+%l*)"

    return {
      name      = v.metrics.title,
      level     = v.metrics.level,

      upnp_file = upnp_file,
      service   = service,
      json_file = json_file,
      devtype   = devtype,
      altid     = altid,
      vtype     = vtype,
      node      = node,
      instance  = instance,
      c_class   = c_class,
      scale     = scale,
      sub_class = sub_class,
      sub_scale = sub_scale,
      tail      = tail,
    }
  end
end


----------------------------
---
---  CREATE DEVICES
---


local function createZwaveDevice (parent, id, name, altid, upnp_file, json_file, room)
  local dev = chdev.create {
    devNo = id,                         -- place device into bridge block
    internal_id = altid,                -- ZWave node number (string)
    description = name,
    upnp_file = upnp_file,
    json_file = json_file,
    parent = parent,
    room = room,
--    statevariables = vars,        --NB. NOT the string "service,variable=value\nservice..."
  }
  dev.handle_children = true      -- ensure that any child devices are handled
  luup.devices[id] = dev          -- add to Luup devices
  return dev
end


local function move_to_room_101 (devices)
  -- 2020.02.05, put into Room 101, instead of deleting...
  -- to retain information in scene triggers and actions
  for n in pairs (devices) do
    if not luup.rooms[101] then luup.rooms.create ("Room 101", 101) end
    local dev = luup.devices[n]
    _log (table.concat {"Room 101: [", n, "] ", dev.description})
    dev: rename (nil, 101)            -- move to Room 101
    dev: attr_set ("disabled", 1)     -- and make sure it can't run
  end
end

-- index list of vDevs by command class, saving altids of occurrences
local dont_count = {
  ["0"] = true,         -- generic
  ["1"] = true,         -- ???
  ["50"] = true,        -- power
  ["51"] = true,        -- switch colour
  ["128"] = true,       -- batteries
}
local function index_by_command_class (vDevs)
  local classes = {}
  local n = 0
  for _, ldv in pairs(vDevs) do
    local cc = ldv.meta.c_class
    local scale = ldv.meta.scale
    local ignore = dont_count[cc]
--    or (cc == "113" and scale == "7" and ldv.meta.sub_class == "3")  -- tamper switch to be removed later in the code @rafale77
    if cc == "49" and scale == "4" then cc= "50" end   --  a class["50"]  -- (power)
    local x = classes[cc] or {}
    x[#x+1] = ldv
    classes[cc] = x
    if not ignore then n = n + 1 end
  end
  classes.n  = n    -- total WITHOUT uncounted classes
  return classes
end

---  CONFIGURE DEVICES
-- optional child parameters forces new vDev children
local function configureDevice (id, name, ldv, updaters, child)
  child = child or {}
  local classes = index_by_command_class (ldv)

  local function add_updater (v)
    local meta = v.meta
    updaters[meta.altid] = command_class.new (id, meta)
    return meta.upnp_file, meta.json_file, v.metrics.title
  end

  -- determine default device type
  local upnp_file = DEV.combo
  local json_file

  if classes.n == 0 and classes["0"] and #classes["0"] > 0 then    -- just buttons?
    upnp_file = DEV.controller
    name = classes["0"][1].metrics.title
    -- TODO: some work here on class["0"] updaters
    for _,button in ipairs (classes["0"]) do
--      print ("adding", button.metrics.title)
      add_updater (button)    -- should work for Minimote, at least
    end

  elseif classes.n <= 1 then                                 -- a singleton device
    local vDev = ldv[1]           -- there may be a better choice selected below
    for _,v in ipairs (ldv) do
      local cc = v.meta.c_class
      local scale = v.meta.c_class
      local ignore = dont_count[cc] or (cc == "49" and scale == "4")
        or (cc == "113" and scale == "7" and ldv.meta.sub_class == "3")  -- tamper switch
        or (cc == "113" and scale == "8")                                -- low battery notification
      if not ignore then vDev = v end  -- find a useful command class
    end
    upnp_file, json_file, name = add_updater (vDev)                    -- create specific updater

  elseif classes["64"] and classes["67"] and classes["49"] then    -- a thermostat
    -- may have temp sensor [49], fan speed [68], setpoints [67], ...
    -- ... operating state, operating mode, energy metering, ...
    -- command_class ["68"] Fan_mode
    local tstat = classes["64"][1]
    upnp_file, json_file, name = add_updater (tstat)
    local fmode = classes["68"]
    if fmode then
      add_updater(fmode[1])              -- TODO: extra fan modes
    end
    local temp = classes["49"]
    add_updater(temp[1])
    for _, setpoint in ipairs (classes["67"]) do
      add_updater(setpoint)
    end

--  elseif classes["38"] and #classes["38"] > 3 then    -- ... we'll assume that it's an RGB(W) switch
--    upnp_file = DEV.rgb
--    name = "rgb #" .. id

  elseif ((classes["37"] and #classes["37"] == 1)             -- ... just one switch
  or      (classes["38"] and #classes["38"] == 1) )           -- ... OR just one dimmer
  and not classes["49"] then                                  -- ...but NOT any sensors
    local v = (classes["38"] or {})[1] or classes["37"][1]    -- then go for the dimmer
    upnp_file, json_file, name = add_updater(v)

  elseif classes["48"] and #classes["48"] == 1                -- ... just one alarm
  and not classes["49"] then                                  -- ...and no sensors
--  and    classes["49"] and #classes["49"] <= 1 then           -- ...and max only one sensor
    local v = classes["48"][1]
    -- ignore embedded sensor
    upnp_file, json_file, name = add_updater (v)

  elseif classes["50"] and classes.n == 0 then    -- no other devices, so a power meter
    local v = classes["50"][1]
    upnp_file = v.meta.upnp_file
    name = v.metrics.title
    -- updaters are set at the end of this if-then-elseif statement

  elseif classes["102"] and #classes["102"] == 1 then         -- door lock (barrier)
    local v = classes["102"][1]
    upnp_file, json_file, name = add_updater (v)

  elseif classes["98"] and #classes["98"] == 1 then         -- door lock
    local v = classes["98"][1]
    upnp_file, json_file, name = add_updater(v)

  elseif classes["156"] and #classes["156"] == 1 then         -- legacy water sensor
    local v = classes["156"][1]
    upnp_file, json_file, name = add_updater(v)

  elseif classes["49"]  then                              -- a multi-sensor combo
    local meta = classes["49"][1].meta
    name = table.concat {"multi #", meta.node, '-', meta.instance}
    local types = {}
    for _, v in ipairs (classes["49"]) do
      local scale = v.meta.devtype
      if scale then
        types[scale] = (types[scale] or 0) + 1
        child[v.meta.altid] = true                            -- force child creation
      end
    end
    for _, v in ipairs (classes["48"] or {}) do    -- add motion sensors
      v.meta.upnp_file = DEV.motion
      types["Alarm"] = (types["Alarm"] or 0) + 1
      child[v.meta.altid] = true                            -- force child creation
    end
    for _, v in ipairs (classes["113"] or {}) do    -- add motion sensors
      if v.meta.sub_class ~= "3" and v.meta.scale ~= "8" then         -- not a tamper switch or low battery notification
        v.meta.upnp_file = DEV.motion
        types["Alarm"] = (types["Alarm"] or 0) + 1
        child[v.meta.altid] = true                            -- force child creation
      end
    end
    local display = {}
    for s in pairs (types) do display[#display+1] = s end
    table.sort(display)
    for i,s in ipairs (display) do display[i] = table.concat {s,':',types[s], ' '} end
    luup.variable_set (SID.AltUI, "DisplayLine1", table.concat (display), id)

  elseif classes["113"] and #classes["113"] > 1 then   -- sensor with tamper @rafale77
    local v = classes["113"][1]
    if v.meta.sub_class ~= "3" and v.meta.scale ~= "8" then         -- ignore tamper switch and low battery notification
      upnp_file, json_file, name = add_updater(v)
    end
  end
  -- power meter service variables (for any device)
  if classes["50"] then
    for _, meter in ipairs (classes["50"]) do
      add_updater (meter)
    end
  end

  if classes["128"] then
    add_updater (classes["128"][1])
  end

  return upnp_file, json_file, name
end


-- index virtual devices number by node-instance number and build instance metadata
-- also index all vDevs by altid
-- also index locations (rooms) by node-instance
local function index_nodes (d, room0)
  local index = {}
  local room_index = setmetatable ({}, {__index = function() return room0 end})   -- default to room '0'
  for _,v in pairs (d) do
    local meta = vDev_meta (v) or {} -- construct metadata
    local node = meta.node
    local instance = meta.instance
    if node and node ~= "0" then    -- 2017.10.04  ignore device "0" (appeared in new firmware update)
      v.meta = meta
      local n_i = table.concat {node, '-', instance}
      local t = index[n_i] or {}   -- construct index
      t[#t+1] = v
      index[n_i] = t
      local location = v.location or 0
      if CLONEROOMS and location ~= 0 then
        room_index[n_i] =
          luup.rooms.create (v.locationName or ("ZWay Room " .. location))  -- may already exist
      end
    end
  end
  return index, room_index
end


-- create the child devices managed by the bridge
local function createChildren (bridgeDevNo, vDevs, room, OFFSET)
  local N = 0
  local list = {}           -- list of created or deleted devices (for logging)
  local something_changed = false
  local current = luup.openLuup.bridge.all_descendants (bridgeDevNo)

  local currentIndexedByAltid = {}
  for n,v in pairs(current) do
    if n > luup.openLuup.bridge.BLOCKSIZE then        -- ignore anything not in the block
      currentIndexedByAltid[v.id] = n                 -- 'id' is actually altid!
    end
  end

  local function validOrNewId (altid)
    local id = currentIndexedByAltid[altid]                 -- does it already exist?
    if not id then                                          -- no, ...
      -- ...so get a new device number, starting at halfway through the block
      -- node/instance numbering only goes up to 2310
      id = luup.openLuup.bridge.nextIdInBlock(OFFSET, 5000)
    end
    return id
  end

  local function checkDeviceExists (parent, id, name, altid, upnp_file, json_file, room)
    local dev = luup.devices[id]
    if not dev then
      something_changed = true
      dev = createZwaveDevice (parent, id, name, altid, upnp_file, json_file, room)
    end
    dev.handle_children = true                              -- ensure that any child devices are handled
    if CLONEROOMS then dev: rename (nil, room) end          -- force to given room name
    if dev.room_num == 101 then dev: rename (nil, room) end -- ensure it's not in Room 101!!
    list[#list+1] = id   -- add to new list
    current[id] = nil    -- mark as done
  end

  --------------
  --
  -- first the Zwave node-instance devices...
  --
  local zDevs, room_index = index_nodes (vDevs, room)  -- structure into Zwave node-instances with children
  debug(json.encode(room_index))

  --  debug(json.encode(zDevs))
  local updaters = {}
  for nodeInstance, ldv in pairs(zDevs) do
    local n,i = nodeInstance: match  "(%d+)%-(%d+)"
    local ZnodeId = n * 10 + i + OFFSET
    N = N + 1                         -- count the nodes

    -- get specified children for this node
    local child = {}
    local children = luup.variable_get (SID.ZWay, "Children", ZnodeId) or ''
    for alt in children: gmatch "[%-%w]+" do child[alt] = true end
    local updated_children = {}  -- actual vDev children created

    -- default node parameters
    local parent = bridgeDevNo
    local id = ZnodeId
    local name = "zNode #" .. nodeInstance
    local altid = nodeInstance
    local upnp_file, json_file

    upnp_file, json_file, name = configureDevice (id, name, ldv, updaters, child)  -- note extra child param
    room = CLONEROOMS and room_index[nodeInstance] or room
    checkDeviceExists (parent, id, name, altid, upnp_file, json_file, room)

    -- now any specified child devices...
    -- ... by definition (a single vDev) they are singleton devices
    for _, vDev in ipairs (ldv) do
      local meta = vDev.meta
      local altid = meta.altid
      if child[altid] then                                    -- this vDev should be a child device
        local childId = validOrNewId(altid)                   -- ...with this device number
        name = vDev.metrics.title                             -- use actual name
        upnp_file = meta.upnp_file
        json_file = meta.json_file
        checkDeviceExists (id, childId, name, altid, upnp_file, json_file, room)
        updaters[altid] = command_class.new (childId, meta)   -- create specific updater
        updated_children[#updated_children+1] = altid
      end
    end

    -- write back list of changed children
    table.sort (updated_children)
    updated_children = table.concat (updated_children, ', ')
--    print ("update", updated_children)
    if children ~= updated_children then
      luup.variable_set (SID.ZWay, "Children", updated_children, ZnodeId)
    end
  end

  if #list > 0 then luup.log ("creating device numbers: " .. json.encode(list)) end

  move_to_room_101 (current)        -- park any remaining (lost) devices in room 101

  if something_changed then luup.reload() end

  local info = "%d vDevs, %d zNodes"
  setVar ("DisplayLine1", info: format (#vDevs, N), SID.AltUI)

  return updaters
end


-----------------------------------------
--
-- DUMMY Z-WayVDev() API, for testing from file
--

local function ZWayVDev_DUMMY_API (filename)
  local function noop() end
  local f = assert (io.open (filename), "TEST filename not found")
  local D = json.decode (f: read "*a")
  f: close()

  if D then
    return {
      request = noop,
      command = noop,
      devices = function () return D end,
      status  = function () return {data = "OK"} end,
      zwcommand = noop,
      zwsend = noop,
    }
  end
end

-----------------------------------------
--
-- Z-WayVDev() API
--


local function ZWayVDev_API (ip, sid)

  local cookie = "ZWAYSession=" .. (sid or '')

  local function HTTP_request (url, body)
    local response_body = {}
    local method = body and "POST" or "GET"
--    local response, status, headers = http.request{
    local _, status = http.request{
      method = method,
      url=url,
      headers = {
          ["Content-Length"] = body and #body,
          ["Cookie"]= cookie,
        },
      source = body and ltn12.source.string(body),
      sink = ltn12.sink.table(response_body)
    }
    local json_response = table.concat (response_body)
    if status ~= 200 then
      _log (url)
      _log (json_response)
    end
    return status, json_response
  end

  local function HTTP_request_json (url, body)
    local  status, json_response = HTTP_request (url, body)
    return status, json.decode (json_response)
  end

  local function authenticate (user, password)
    cookie = nil      -- not valud any more
    local url = "http://%s:8083/ZAutomation/api/v1/login"
    local data = json.encode {login=user, password = password}
    local _, j = HTTP_request_json (url: format (ip), data)

    if j then
      local sid = j and j.data and j.data.sid
      if sid then
        cookie = "ZWAYSession=" .. sid
        setVar ("ZWAYSession", sid)
      end
    end
    return j
  end

  local function devices ()
    local url = "http://%s:8083/ZAutomation/api/v1/devices"
    local _, d = HTTP_request_json (url: format (ip))
    return d and d.data and d.data.devices or {}
  end

  -- send a command
  local function command (id, cmd)
    local url = "http://%s:8083/ZAutomation/api/v1/devices/ZWayVDev_zway_%s/command/%s"
    local request = url: format (ip, id, cmd)
    return HTTP_request_json (request)
  end

  -- send a zwave command

  local function zwcommand (id, inst, cc, cmd)
    local url = "http://%s:8083/ZWaveAPI/Run/devices[%s].instances[%s].commandClasses[%s].%s"
    local request = url: format (ip, id, inst, cc, cmd)
    return HTTP_request_json (request)
  end

  local function zwsend (id, data)
    local url = "http://%s:8083/ZWaveAPI/Run/SendData(%s,%s)"
    local request = url: format (ip, id, data)
    return HTTP_request_json (request)
  end

  -- send a generic request
  local function request (req)
    local url = "http://%s:8083%s"
    local request = url: format (ip, req)
    return HTTP_request (request)
  end

  local function status ()
    local url = "http://%s:8083/ZAutomation/api/v1/status"
    local _, d = HTTP_request_json (url: format (ip))
    return d
  end

  -- ZWayVDev()
  return {
    request = request,    -- for low-level access
    status  = status,
    command = command,
    zwcommand = zwcommand,
    zwsend = zwsend,
    devices = devices,
    authenticate = authenticate}

end

--
-- Generic ACTIONS
--

local function generic_action (serviceId, action)
  local function noop(lul_device)
    local message = "service/action not implemented: %d.%s.%s"
    _log (message: format (lul_device, serviceId, action))
    return false
  end
  local service = SRV[serviceId] or {}
  local act = service [action] or noop
  if type(act) == "function" then act = {run = act} end
  return act
end

--
-- Specific ACTIONS
--

--Login
function _G.Login (p)
  debug (json.encode(p))
  local j = Z.authenticate (p.Username, p.Password)
  if j then
    setVar ("DisplayLine1", "Restart required", SID.AltUI)
    luup.set_failure (0, devNo)
  end
end

--SendData
function SendData (p)
  debug (json.encode(p))
  local node, data = p.Node, p.Data
  if node and data then 
    Z.zwsend (node, data)
  end
end


-----------------------------------------
--
-- Z-Way()  STARTUP
--

function init (lul_device)
	devNo = tonumber (lul_device)

  do -- version number
    local y,m,d = ABOUT.VERSION:match "(%d+)%D+(%d+)%D+(%d+)"
    local version = ("v%d.%d.%d"): format (y%2000,m,d)
    _log (version)
    setVar ("Version", version)
  end

	local ip = luup.attr_get ("ip", devNo)   -- use specified IP, if present
	ip = ip:match "%d+%.%d+%.%d+%.%d+" and ip or "127.0.0.1"

	luup.devices[devNo].action_callback (generic_action)     -- catch all undefined action calls

	POLLRATE = uiVar ("Pollrate", 2)
  POLLRATE = math.min (tonumber(POLLRATE) or 0, 0.5)

--  local user     = uiVar ("Username", "admin")
--	local password = uiVar ("Password", "razberry")

  CLONEROOMS  = uiVar ("CloneRooms", '')              -- if true, clone rooms and place devices there
  NAMEDEVICES = uiVar ("NameDevices", '')             -- if true, copy device names from ZWay
  ZERODIMMER  = uiVar ("ZeroDimmerWhenOff", "true")   -- if true, zero dimmer sliders when off

  CLONEROOMS  = is_true (CLONEROOMS)
  NAMEDEVICES = is_true (NAMEDEVICES)
  ZERODIMMER  = is_true (ZERODIMMER)

  local testfile = uiVar ("Test_JSON_File", '')

  -- Authenticate
  do
    if testfile ~= '' then
      Z = ZWayVDev_DUMMY_API (testfile)
    else
      local session = getVar "ZWAYSession"
      Z = ZWayVDev_API (ip, session)
    end
  end
  --

  setVar ("DisplayLine1", '', SID.AltUI)
  setVar ("DisplayLine2", ip, SID.AltUI)

  OFFSET = tonumber (getVar "Offset") or luup.openLuup.bridge.nextIdBlock()
  setVar ("Offset", OFFSET)

  local status, comment

  luup.set_failure (0, devNo)	        -- openLuup is UI7 compatible
  status, comment = true, "OK"

  HTTP_request = function (url) return Z.request (url) end        -- global low-level access

  -- device-specific ID for HTTP handler allows multiple plugin instances
  local handler = "HTTP_Z-Way_" .. devNo
  _G[handler] = function () return json.encode (D), "application/json" end
  luup.register_handler (handler, 'z' .. devNo)

  -- make sure room exists
  local Remote_ID = 31415926
  setVar ("Remote_ID", Remote_ID, SID.bridge)  -- 2020.02.12   use as unique remote ID

  local room_name = "ZWay-" .. Remote_ID
  local room_number = luup.rooms.create (room_name)   -- may already exist

  local ok = Z.status()
  if ok and ok.data == "OK" then
    local vDevs = Z.devices ()
    cclass_update = createChildren (devNo, vDevs, room_number, OFFSET)
    _G.updateChildren (vDevs)
  else
    luup.set_failure (2, devNo)	        -- authorisation failure
    setVar ("DisplayLine1", 'Login required', SID.AltUI)
    status, comment = false, "Failed to authenticate"
  end
  
  return status, comment, ABOUT.NAME

end

-----
