module (..., package.seeall)

ABOUT = {
  NAME          = "L_ZWay2",
  VERSION       = "2020.02.22b",
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

local json    = require "openLuup.json"
local chdev   = require "openLuup.chdev"    -- NOT the same as the luup.chdev module! (special create fct)
local http    = require "socket.http"
local ltn12   = require "ltn12"

local Z         -- the Zway API object

local cclass_update   -- table of command_class updaters indexed by altid

------------------

local devNo     -- out device number
local OFFSET    -- bridge offset for child devices
local POLLRATE  -- poll rate for Zway devices

local service_schema = {}    -- serviceId ==> schema implementation

local DEV = {
    --
    dimmer      = "D_DimmableLight1.xml",
    thermos     = "D_HVAC_ZoneThermostat1.xml",
    motion      = "D_MotionSensor1.xml",
    
    -- these preset devices don't correspond to any ZWay vDev
    controller  = "D_SceneController1.xml", 
    combo       = "D_ComboDevice1.xml",
    rgb         = "D_DimmableRGBLight1.xml",

  }
local SID = {          -- schema implementation or shorthand name ==> serviceId
    AltUI   = "urn:upnp-org:serviceId:altui1",
    bridge  = luup.openLuup.bridge.SID,                         -- for Remote_ID variable
    ZWave   = "urn:micasaverde-com:serviceId:ZWaveNetwork1",
    ZWay    = "urn:akbooer-com:serviceId:ZWay1",
    
    controller  = "urn:micasaverde-com:serviceId:SceneController1",
    combo       = "urn:micasaverde-com:serviceId:ComboDevice1",
    rgb         = "urn:micasaverde-com:serviceId:Color1",
    
    setpoint      = "urn:upnp-org:serviceId:TemperatureSetpoint1",
    setpointHeat  = "urn:upnp-org:serviceId:TemperatureSetpoint1_Heat",
    setpointCool  = "urn:upnp-org:serviceId:TemperatureSetpoint1_Cool",
 
 }

-- NB: for thermostats, see @rigpapa's useful post:
--   old:   http://forum.micasaverde.com/index.php/topic,79510.0.html
--    new:  https://community.getvera.com/t/need-help-getting-started-trying-to-get-themostat-with-heat-cool-setpoints/198983/2

-- LUUP utility functions 


local function log(text, level)
	luup.log(("%s: %s"): format ("ZWay", text), (level or 50))
end

local function debug (info)
  if ABOUT.DEBUG then 
    print (info)
    log(info, "DEBUG") 
  end
end

local function getVar (name, service, device) 
  service = service or SID.ZWay
  device = device or devNo
  local x = luup.variable_get (service, name, device)
  return x
end

local function setVar (name, value, service, device)
  service = service or SID.ZWay
  device = device or devNo
  local old = luup.variable_get (service, name, device)
  if tostring(value) ~= old then 
   luup.variable_set (service, name, value, device)
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


----------------------------------------------------
--
--  Device numbering and child management
--


----------------------------------------------------
--
-- GENERIC GET/SET SERVICES - used by several actual services
--                          - local effect only (no ZWay communication)
--
 
local Name = {
  get = {returns = {CurrentName = "Name"}},
  
  set = function (d, args)
    if args.NewName then
      luup.variable_set (args.serviceId, "Name", args.NewName, d)
    end
  end,
}
  
local Application  = {
  get = {returns = {CurrentApplication = "Application"}},  -- return value handled by action request mechanism
    
  set = function (d, args, allowedValue)
    local valid = true
    if allowedValue then
      for _, value in ipairs(allowedValue) do allowedValue[value] = true end
      valid = allowedValue [args.NewApplication]
    end
    if valid then
      luup.variable_set (args.serviceId, "Application", args.NewApplication, d)
    end
  end,
}  


----------------------------------------------------
--
-- SERVICE SCHEMAS - virtual services
-- openLuup => Zway
--

--[[
vDev commands:
1. ’update’: updates a sensor value
2. ’on’: turns a device on. Only valid for binary commands
3. ’off’: turns a device off. Only valid for binary commands
4. ’exact’: sets the device to an exact value. This will be a temperature for thermostats or a percentage value of motor controls or dimmers
--]]


local S_SwitchPower = {
    
    SetTarget = function (d, args)
      local value = on_or_off (args.newTargetValue or '0')
      local altid = luup.devices[d].id
      altid = altid: match "^%d+$" and altid.."-0-37" or altid
      Z.command (altid, value)
    end,
    
  }


local S_Dimming = {
    
    SetLoadLevelTarget = function (d, args)
      local level = tonumber (args.newLoadlevelTarget or '0')
      local value = "exact?level=" .. level
      local altid = luup.devices[d].id
      altid = altid: match "^%d+$" and altid.."-0-38" or altid
      Z.command (altid, value)
    end,
    
  }


local S_HaDevice = {
    
    ToggleState = function (d) 
      local toggle = {['0'] = '1', ['1']= '0'}
      local status = getVar ("Status", SID[S_SwitchPower], d)
      S_SwitchPower.SetTarget (d, {newTargetValue = toggle [status] or '0'})
    end,
    
  }


local S_Temperature = {
  
    GetApplication = Application.get,
    SetApplication = function (d, args) return Application.set (d, args, {"Room", "Outdoor", "Pipe", "AirDuct"}) end,
    
    GetCurrentTemperature = {returns = {CurrentTemp = "CurrentTemperature"}},
    
    GetName = Name.get,
    SetName = Name.set,
      
   }


  -- 
local S_Security = {
    
    SetArmed = function (d, args)
      luup.variable_set (args.serviceId, "Armed", args.newArmedValue or '0', d)
    end,
    
  }

local S_Color = {

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
      log ("setting: " .. rgb[i])
      local level = math.floor ((rgb[i]/256)^2 * 100) -- map 0-255 to 0-100, with a bit of gamma
      S_Dimming.SetLoadLevelTarget (c[i+2].devNo, {newLoadlevelTarget = level}) 
    end
  end,
  
}


local S_DoorLock = {
     
    SetTarget = function (d, args)
      local value = open_or_close (args.newTargetValue)
      local altid = luup.devices[d].id
      altid = altid: match "^%d+$" and altid.."-0-98" or altid
      Z.command (altid, value)
    end,
 
}

local S_Camera          = { }
local S_EnergyMetering  = { }
local S_Generic         = { }
local S_Humidity        = { }
local S_Light           = { }
local S_SceneController = { }
local S_Unknown         = { }   -- "catch-all" service


------------
--
-- Thermostat info
--
 

-- D_HVAC_ZoneThermostat1.xml uses these default serviceIds and variables...

local S_HVAC_FanMode = { 
  
  --   <name>SetMode</name>
  --         <name>NewMode</name>
  --         <relatedStateVariable>Mode</relatedStateVariable>
    --ThermostatFanMode
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite
  SetMode = function (d, args)
    local valid = {Auto = true, ContinuousOn = true, PeriodicOn = true}
  end,
--[[

urn:upnp-org:serviceId:HVAC_FanOperatingMode1,Mode=Auto
urn:upnp-org:serviceId:HVAC_FanOperatingMode1,FanStatus=On
   --]]
  GetMode      = { returns = {CurrentMode    = "Mode"      } },
  GetFanStatus = { returns = {CurrentStatus  = "FanStatus" } },
  
  GetName = Name.get,
  SetName = Name.set,
  
  }
SID[S_HVAC_FanMode] = "urn:upnp-org:serviceId:HVAC_FanOperatingMode1"

local S_HVAC_State = { --[[
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
SID[S_HVAC_State] = "urn:micasaverde-com:serviceId:HVAC_OperatingState1"

local S_HVAC_UserMode = { 
  
  --   <name>SetModeTarget</name>
  --         <name>NewModeTarget</name>
  --         <relatedStateVariable>ModeTarget</relatedStateVariable>
  SetModeTarget = function (d, args)
    local valid = {Off = true, AutoChangeOver = true, CoolOn = true, HeatOn = true, }

    local value = args.NewModeTarget
    if valid[value] then
--      luup.variable_set (args.serviceId, "ModeTarget", value, d)
    end
  end, 
 
--  ["64"]      --ThermostatMode
        --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
        --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific

--urn:upnp-org:serviceId:HVAC_UserOperatingMode1,ModeTarget=Off
--urn:upnp-org:serviceId:HVAC_UserOperatingMode1,ModeStatus=Off
--urn:upnp-org:serviceId:HVAC_UserOperatingMode1,EnergyModeTarget=Normal
--urn:upnp-org:serviceId:HVAC_UserOperatingMode1,EnergyModeStatus=Normal

   --[[
   <name>SetEnergyModeTarget</name>
         <name>NewModeTarget</name>
         <relatedStateVariable>EnergyModeTarget</relatedStateVariable>
   <name>GetModeTarget</name>
         <name>CurrentModeTarget</name>
         <relatedStateVariable>ModeTarget</relatedStateVariable>
   <name>GetModeStatus</name>
         <name>CurrentModeStatus</name>
         <relatedStateVariable>ModeStatus</relatedStateVariable>
   <name>GetName</name>
         <name>CurrentName</name>
   <name>SetName</name>
         <name>NewName</name>
         <relatedStateVariable>Name</relatedStateVariable>
--]]
 
  }
SID[S_HVAC_UserMode] = "urn:upnp-org:serviceId:HVAC_UserOperatingMode1"

local S_HVAC_FanSpeed = { --[[
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
SID[S_HVAC_FanSpeed] = "urn:upnp-org:serviceId:FanSpeed1"


local S_TemperatureSetpoint = {
    
    GetApplication = Application.get,
    SetApplication = Application.set,
    
    GetCurrentSetpoint  = {returns = {CurrentSP  = "CurrentSetpoint"}},
    GetSetpointAchieved = {returns = {CurrentSPA = "SetpointAchieved"}},
    
    GetName = Name.get,
    SetName = Name.set,
  
    SetCurrentSetpoint = function (d, args)
      local level = args.NewCurrentSetpoint
      if level then
        local sid = args.serviceId
        luup.variable_set (sid, "CurrentSetpoint", level, d)
        local value = "exact?level=" .. level
        local altid = luup.devices[d].id
        if altid: match "^%d+$" then
          local suffix = {
            [SID.setpoint]      = "-0-67",
            [SID.setpointHeat]  = "-0-67-1",
            [SID.setpointCool]  = "-0-67-2",
          }
          altid = altid .. (suffix[args.serviceId] or '')
        end
        Z.command (altid, value)
      end
    end,
    
}

local function shallow_copy (x)
  local y = {}
  for a,b in pairs (x) do y[a] = b end
  return y
end

-- these copies MUST be separate tables, since they're used to index the SID table
local S_TemperatureSetpointHeat = shallow_copy (S_TemperatureSetpoint)
local S_TemperatureSetpointCool = shallow_copy (S_TemperatureSetpoint)

SID [S_TemperatureSetpoint]         = SID.setpoint
SID [S_TemperatureSetpointHeat]     = SID.setpointHeat
SID [S_TemperatureSetpointCool]     = SID.setpointCool

--[[
--]]

SID [S_Camera]          = "urn:micasaverde-com:serviceId:Camera1"
SID [S_Color]           = "urn:micasaverde-com:serviceId:Color1"
SID [S_Dimming]         = "urn:upnp-org:serviceId:Dimming1"
SID [S_DoorLock]        = "urn:micasaverde-com:serviceId:DoorLock1"
SID [S_EnergyMetering]  = "urn:micasaverde-com:serviceId:EnergyMetering1"
SID [S_Generic]         = "urn:micasaverde-com:serviceId:GenericSensor1"
SID [S_HaDevice]        = "urn:micasaverde-com:serviceId:HaDevice1"
SID [S_Humidity]        = "urn:micasaverde-com:serviceId:HumiditySensor1"
SID [S_Light]           = "urn:micasaverde-com:serviceId:LightSensor1"
SID [S_Security]        = "urn:micasaverde-com:serviceId:SecuritySensor1"
SID [S_SwitchPower]     = "urn:upnp-org:serviceId:SwitchPower1"
SID [S_Temperature]     = "urn:upnp-org:serviceId:TemperatureSensor1"


for schema, sid in pairs (SID) do -- reverse look-up  sid ==> schema
  if type(schema) == "table" then service_schema[sid] = schema end
end

-- Generic ACTION callbacks
local function generic_action (serviceId, action)
  local function noop(lul_device) 
    local message = "service/action not implemented: %d.%s.%s"
    log (message: format (lul_device, serviceId, action))
    return false
  end 
  local service = service_schema[serviceId] or {}
  local act = service [action] or noop 
  if type(act) == "function" then act = {run = act} end
  act.serviceId = serviceId
  act.action = action
  return act
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
    if dev.device_type == DEV.controller then   -- this is the Luup device type, not the vDev
      local click = inst.updateTime
--      setVar ("LastUpdate_" .. meta.altid, click, SID.ZWay, d)
      if click ~= meta.click then -- force variable updates
        local scene = meta.scale
        local time  = os.time()     -- "◷" == json.decode [["\u25F7"]]
--        local date  = os.date ("◷ %Y-%m-%d %H:%M:%S", time): gsub ("^0",'')
        
        luup.variable_set (SID[S_SceneController], "sl_SceneActivated", scene, d)
        luup.variable_set (SID[S_SceneController], "LastSceneTime",time, d)
        
--        if time then luup.variable_set (SID.AltUI, "DisplayLine1", date,  d) end
--        luup.variable_set (SID.AltUI, "DisplayLine2", "Last Scene: " .. scene, d)
        
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
    setVar ("LoadLevelTarget", level, meta.service, d)
    setVar ("LoadLevelStatus", level, meta.service, d)
    local status = (level > 0 and "1") or "0"
    setVar ("Status", status, SID[S_SwitchPower], d)
  end,
  
  -- binary sensor
  ["48"] = function (d, inst)
    local sid = SID [S_Security]
    local tripped = on_or_off (inst.metrics.level)
    local old = getVar ("Tripped", sid)
    if tripped ~= old then
      setVar ("Tripped", tripped, sid, d)
      setVar ("LastTrip", inst.updateTime, sid, d)
-- 2020.02.15  ArmedTripped now generated by openLuup itself for all security sensor services
--      local armed = getVar ("Armed", sid, d)
--      if armed == "1" then
--        setVar ("ArmedTripped", tripped, sid, d)
--      end
    end
  end,

  -- multilevel sensor
  ["49"] = function (d, inst, meta)   -- TODO: more to do here to sub-type?
    local sensor_variable_name = {
      [SID[S_Temperature]]    = "CurrentTemperature",
      [SID[S_EnergyMetering]] = "Watts",
    }
    local var = sensor_variable_name[meta.service] or "CurrentLevel"
    setVar (var, inst.metrics.level, meta.service, d)
  end,

  -- meter
  ["50"] = function (d, inst, meta)
    local var = (inst.metrics.scaleTitle or '?'): upper ()
    local translate = {W = "Watts", A = "Amps", V = "Volts"}      -- 2020.02.10 thanks @rafale77
    if var then setVar (translate[var] or var, inst.metrics.level, meta.service, d) end
  end,
  
  -- door lock
  ["98"] = function (d, inst)
      setVar ("Status",open_or_close (inst.metrics.level), SID[S_DoorLock], d)
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
      setVar ("ModeStatus", ZtoV[level] or level, meta.service, d)
  end,

  ["66"] = function (d, inst)       -- Operating_state
  end,
  
  ["67"] = function (d, inst, meta)       -- Setpoint
    --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
    local scale = meta.scale
    local sid
    if scale == "1" then  -- heat
      sid = SID.setpointHeat
    elseif scale == "2" then  -- cool
      sid = SID.setpointCool
    end
    if sid then
      setVar ("CurrentSetpoint", inst.metrics.level, sid, d)      -- 2020.02.10, thanks @rafale77
--      setVar ("SetpointAchieved", inst.metrics.level, sid, d)
    end
  end,
  
  ["68"] = function (d, inst)       -- ThermostatFanMode
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite
  end,

  
  -- barrier operator (eg. garage door)
  ["102"] = function (d, inst)
      setVar ("Status",open_or_close (inst.metrics.level), SID[S_DoorLock], d)
  end,
 
  -- battery
  ["128"] = function (d, inst)
    local level = tonumber (inst.metrics.level)
    local warning = (level < 10) and "1" or "0"
    setVar ("BatteryLevel", level, SID[S_HaDevice], d)
    setVar ("sl_BatteryAlarm", warning, SID[S_HaDevice], d)
  end,

}
 
--command_class ["113"] = command_class ["48"]      -- alarm
--command_class ["156"] = command_class ["48"]      -- tamper switch

    
function command_class.new (dino, meta) 
  local updater = command_class[meta.c_class] or command_class["0"]
  return function (inst, ...) 
--      setVar (inst.id, inst.metrics.level, SID.ZWay, dino)    -- diagnostic, for the moment
--      setVar (inst.id .. "_LastUpdate", inst.updateTime, SID.ZWay, dino)    -- diagnostic, for the moment
      -- call with deviceNo, instance object, and metadata (for persistent data)
      return updater (dino, inst, meta, ...) 
    end
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
local NICS_pattern = "^(%d+)%-(%d+)%-(%d+)%-?(%d*)%-?(%d*)%-?(%d*)%-?(.-)$"
local function NICS_etc (vDev)
  local vtype, altid = vDev.id: match "^ZWayVDev_(zway_%D*)(.+)" 
  if altid then 
    return altid, vtype, altid: match (NICS_pattern)
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
    local altid, vtype, node, instance, c_class = NICS_etc (inst)
    if node then
      local zDevNo = OFFSET + node
      -- set all the Vdev variables in the Zwave node devices
      local zDev = luup.devices[zDevNo] 
      if zDev then
        -- update device name, if changed
        if altid == zDev.id 
        and inst.metrics.title ~= zDev.description then
          log (table.concat {"renaming device, old --> new: ", zDev.description, " --> ", inst.metrics.title})
          zDev: rename (inst.metrics.title)
        end
        -- add the vDev variable info
        local id = vtype .. altid
        setVar (id, inst.metrics.level, SID.ZWay, zDevNo)
        setVar (id .. "_LastUpdate", inst.updateTime, SID.ZWay, zDevNo)   
      end

    if cclass_update [altid] then
      cclass_update [altid] (inst)
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
  ["0"]  = { nil, S_HaDevice },   -- not really a NO_OP, but a "catch-all"
  
  ["37"] = { "D_BinaryLight1.xml",      S_SwitchPower       },
  ["38"] = { "D_DimmableLight1.xml",    S_Dimming },
  ["48"] = { "D_MotionSensor1.xml",     S_Security ,        -- SensorBinary
    scale = {
--  1	"General purpose"
--	2	"Smoke"     -- "D_SmokeSensor1.xml"
--	3	"CO"        -- "D_SmokeCoSensor1.json"
--	4	"CO2"
--	5	"Heat"
        ["6"] = { nil, nil, "D_LeakSensor1.json" }, --	6	"Water"
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
      ["1"]  = { "D_TemperatureSensor1.xml",  S_Temperature },
      ["2"]  = { "D_GenericSensor1.xml",      S_Generic },
      ["3"]  = { "D_LightSensor1.xml",        S_Light},
      ["4"]  = { "D_PowerMeter1.xml",         S_EnergyMetering},
      ["5"]  = { "D_HumiditySensor1.xml",     S_Humidity},
      ["27"] = { "D_LightSensor1.xml",        S_Light,           "D_UVSensor.json" }    -- special .json file for icon
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
  ["50"] = { nil, S_EnergyMetering },   -- device is "D_PowerMeter1.xml"
  --[[
  Meter
    1	"Electric"	 - scale: {"kWh","kVAh","W","Pulse Count","V","A","Power Factor"}
    2	"Gas"	 - scale: {"Cubic meter","Cubic feet","reserved","Pulse Count"}
    3	"Water"	 - scale: {"Cubic meter","Cubic feet","US Gallon","Pulse Count"}
  --]]
  
  ["64"] = { "D_HVAC_ZoneThermostat1.xml", S_HVAC_UserMode},    -- Thermostat_mode  
    --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
    --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific
  ["66"] = { nil, S_HVAC_State }, -- Operating_state
  ["67"] = { nil, S_TemperatureSetpoint, -- Setpoint
    --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
    scale = {
      ["1"]  = { nil, S_TemperatureSetpointHeat },
      ["2"]  = { nil, S_TemperatureSetpointCool },
    },
  },
    
  ["68"] = {nil, S_HVAC_FanMode}, -- ThermostatFanMode
    --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite
  
  ["98"] = { "D_DoorLock1.xml",   S_DoorLock },
  
  ["102"] = { "D_DoorLock1.xml",   S_DoorLock },    -- "Barrier Operator"
  ["113"] = { nil, S_Security },  -- Switch
  ["128"] = { nil, S_EnergyMetering },
  ["152"] = { "D_MotionSensor1.xml", S_Security },
  ["156"] = { nil, S_Security },    -- Tamper switch?


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
      title = "Aeon Labs Luminiscence (9.0.49.3)"
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
    local service   = SID[z[2]]
    local json_file = z[3]
    
  --  local devtype = (json_file or upnp_file or ''): match "^D_(%u+%l*)"

    return {
      upnp_file = upnp_file,
      service   = service,
      json_file = json_file,
  --    devtype   = devtype,
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

--------------------------------------------------
--
-- BUILD LUUP DEVICE STRUCTURE
--


--[=[
-- transform each node into some sort of Luup device structure with parents and children
local function luupDeviceOLD (node, instances) 

  -- split into devices and variables
  local dev, var = {}, {}
  local children = {}         -- count of children indexed by (shorthand) device type
  for _, v in ipairs (instances) do
    local t = v.meta.devtype
    if t then
      children[t] = (children[t] or 0) + 1
      dev[#dev+1] = v
    else
      var[#var+1] = v
    end
  end
      
  -- create top-level device: three different sorts:
  local Ndev = #dev
  local upnp_file, altid, devtype, parameters
  
  ------------------------
  -- a controller has no devices and is just a collection of buttons and switches or other services 
  if Ndev == 0 then
    upnp_file, altid, devtype = DEV.controller, var[1].meta.node, " Controller"
    local txt = [[Define scene triggers to watch sl_SceneActivated]] ..
                [[ with Lua Expression: new == "button_number"]]
    parameters = table.concat { SID.controller, ',', "Scenes", '=', txt }
    
  ------------------------
  -- a singleton device is a node with only one vDev device
  elseif Ndev == 1 then
    upnp_file, altid = dev[1].meta.upnp_file, dev[1].meta.altid 
    
  ------------------------
  -- a combo device is a collection of more than one vDev device, and may have service variables
  else
    upnp_file, altid, devtype = DEV.combo, dev[1].meta.node, " Combo"  -- (the space is important)
    local dimmers = children.Dimmable
    local thermos = children.HVAC
    
    -- HOWEVER... 
    
    -- if there are lots of dimmers, ...
    if dimmers and dimmers > 3 then           -- ... we'll asume that it's an RGB(W) switch
      devtype = " RGB Controller" 
      upnp_file = DEV.rgb
      
    -- if there are any HVAC services, ...
    elseif thermos and thermos > 0 then       -- ... it's a thermostat
      devtype = " Thermostat" 
      upnp_file = "D_HVAC_ZoneThermostat1.xml"
      local newdev = {}
      for i, d in ipairs (dev) do             -- convert instance 0 devices to embeded variables
        if d.meta.instance ~= "0" then 
          newdev[#newdev+1] = d
        else
          var[#var+1] = d
          d.meta.upnp_file = nil
          d.meta.devtype = nil
        end
      end
      dev = newdev
      
    -- otherwise...
    else                                      -- ... it's just a vanilla combination device
      local label = {}
      for a,b in pairs(children) do
        label[#label+1] = table.concat {a,':', b}
      end
      table.sort (label)
      parameters = table.concat { SID.AltUI, ',', "DisplayLine1", '=', table.concat (label, ' ') }
    end
  end
  
  -- return structure with info for creating the top-level device
  local dv = (dev[1] or var[1])
  devtype = devtype or dv.meta.devtype or '?'
  local name = ("%3s: %s %s"): format (node, dv.metrics.title: match "%w+", devtype) 
  
  return { 
    upnp_file = upnp_file,
    altid = altid,
--    name = name,
    name = dv.metrics.title,      -- 2018.07.16, for @DesT
    node = node,
    devices = dev,
    variables = var,
    parameters = parameters,
  } 

end
--]=]

-- index virtual devices number by node number and build instance metadata
-- also index all vDevs by altid
local function index_nodes (d)
  local index = {}
  for _,v in pairs (d) do 
    local meta = vDev_meta (v) or {} -- construct metadata
    local node = meta.node
    if node and node ~= "0" then    -- 2017.10.04  ignore device "0" (appeared in new firmware update)
      v.meta = meta
      local t = index[node] or {}   -- construct index
      t[#t+1] = v
      index[node] = t
    end
  end
  return index
end


----------------------------
---
---  CREATE DEVICES
---


local function createZwaveDevice (parent, id, name, altid, upnp_file, room)
  local dev = chdev.create {
    devNo = id,                         -- place device into bridge block
    internal_id = altid,                -- ZWave node number (string)
    description = name, 
    upnp_file = upnp_file,
    parent = parent,
    room = room,
--    statevariables = vars,        --NB. NOT the string "service,variable=value\nservice..."
  }
  dev.handle_children = true      -- ensure that any child devices are handled
  luup.devices[id] = dev          -- add to Luup devices
end


local function move_to_room_101 (devices)
  -- 2020.02.05, put into Room 101, instead of deleting...
  -- to retain information in scene triggers and actions
  for n in pairs (devices) do
    if not luup.rooms[101] then luup.rooms.create ("Room 101", 101) end 
    local dev = luup.devices[n]
    log (table.concat {"Room 101: [", n, "] ", dev.description})
    dev: rename (nil, 101)            -- move to Room 101
    dev: attr_set ("disabled", 1)     -- and make sure it can't run 
  end
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
  
  -- index list of vDevs by command class, saving altids of occurrences
  local function index_by_command_class (vDevs)
    local ignored = {["128"] = true}      -- batteries
    local classes = {}
    local n = 0
    for _, ldv in pairs(vDevs) do
      local cc = ldv.meta.c_class
      if not ignored[cc] then
        local x = classes[cc] or {}
        x[#x+1] = ldv
        classes[cc] = x
        n = n + 1
      end
    end
    classes.n = n   -- add total count
    return classes
  end
  
  -- add updaters for some variables
  local function configure_device (id, name)
    local dev = luup.devices[id]
    dev.description = name        -- force any change of name from ZWay (thanks @DesT)
    if dev.device_type == DEV.controller then
      for _, var in pairs(dev.variables) do
        local name, altid = var.name
        print (name)
        if altid then 
          -- add some updaters
        end
      end
    end
  end
  
  local function checkDeviceExists (bridgeDevNo, id, name, ...)
    if not current[id] then 
      something_changed = true
      createZwaveDevice (bridgeDevNo, id, name, ...)     
    end
    list[#list+1] = id   -- add to new list
    current[id] = nil    -- mark as done
    configure_device (id, name)
  end
  
--  local indexByAltid = {}
--  for _, desc in pairs(current) do 
--    indexByAltid[desc.id or ''] = desc 
--  end  -- id is really altid!
    
  local updaters = {}
  local zDevs = index_nodes (vDevs)   -- structure into Zwave nodes with children
  debug(json.encode(zDevs))
  
  --------------
  --
  -- first the Zwave node devices...
  --
	for id, ldv in pairs(zDevs) do
    N = N + 1
    local altid = id
    local cloneId = id + OFFSET
    local classes = index_by_command_class (ldv)
--    print (json.encode {node = id, classes = classes})
    
    local default_children = ''

    local name = "node #" .. id
    -- determine default device type
    local upnp_file = DEV.combo
    
    if classes.n == 1 then                                  -- a singleton device
      local meta = ldv[1].meta
      upnp_file = meta.upnp_file 
      name = ldv[1].metrics.title                           -- use actual name
--      altid = meta.altid                                    -- use actual vDev id (WHY?)
--      statevariables = nil                                  -- no need to specify children
      updaters[altid] = command_class.new (cloneId, meta)    -- create specific updater
      
    elseif classes["64"] and classes["67"] and classes["49"] then    -- a thermostat
      -- may have temp sensor [49], fan speed [68], setpoints [67], ...
      -- ... operating state, operating mode, energy metering, ...
  -- command_class ["68"] Fan_mode
      upnp_file = DEV.thermos
      local tstat = classes["64"][1]
      name = tstat.metrics.title
      updaters[tstat.meta.altid] = command_class.new (cloneId, tstat.meta)
      local fmode = classes["68"]
      if fmode then
        fmode = fmode[1]
        updaters[fmode.meta.altid] = command_class.new (cloneId, fmode.meta)
      end
      local temp = classes["49"][1]
      updaters[temp.meta.altid] = command_class.new (cloneId, temp.meta)
      for _, setpoint in ipairs (classes["67"]) do
        updaters[setpoint.meta.altid] = command_class.new (cloneId, setpoint.meta)
      end
      
    elseif classes["37"] and #classes["37"] == 1            -- a single switch...
    and classes["38"] and #classes["38"] == 1 then          -- ... with a single dimmer
      upnp_file = DEV.dimmer
      local c37 = classes["37"][1]
      updaters[c37.meta.altid] = command_class.new (cloneId, c37.meta)
      local c38 = classes["38"][1]
      name = c38.metrics.title
      updaters[c38.meta.altid] = command_class.new (cloneId, c38.meta)
      
    elseif classes["38"] and #classes["38"] > 3 then    -- ... we'll assume that it's an RGB(W) switch
      upnp_file = DEV.rgb
      name = "rgb #" .. id
      
    elseif classes["49"] then                                -- a multi-sensor combo
      name = "multisensor #" .. id
      local c = {}
      for n, v in ipairs (classes["49"]) do
        c[n] = v.meta.altid
      end
      default_children = table.concat (c, ', ')   -- add all multi-sensor children
      
    elseif classes["37"] and #classes["37"] == classes.n then   -- just a bank of switches
      name = classes["37"][1].metrics.title
      
    elseif classes["102"] and #classes["102"] == 1 then     -- door lock
      local v = classes["102"][1]
      upnp_file = v.meta.upnp_file
      name = v.metrics.title
      
    elseif classes["113"] and #classes["113"] == 1 then
      upnp_file = DEV.motion
      name = classes["113"][1].metrics.title
    end
    
    checkDeviceExists (bridgeDevNo, cloneId, name, altid, upnp_file, room)     
    local children = luup.variable_get (SID.ZWay, "Children", cloneId) 
    if not children then
      luup.variable_set (SID.ZWay, "Children", default_children, cloneId)
      children = default_children
    end
  
    --------------
    --
    -- now any specified child devices...
    -- ... by definition (a single vDev) they are singleton devices
    --
    local child = {}
    for alt in children: gmatch "[%-%w]+" do child[alt] = true end
    local N = 0
    for _, vDev in ipairs (ldv) do
      N = N + 1
      local meta = vDev.meta
      local altid = meta.altid
      local c_class = meta.c_class
      if child[altid] then                                -- this vDev should be a child device
        local childId = currentIndexedByAltid[altid]      -- already exists, or...
          or luup.openLuup.bridge.nextIdInBlock(OFFSET)   -- ... get a new device number
        upnp_file = meta.upnp_file 
        name = vDev.metrics.title                             -- use actual name
        updaters[altid] = command_class.new (childId, meta)    -- create specific updater
        checkDeviceExists (cloneId, childId, name, altid, upnp_file, room)  
      elseif c_class == "128"then
        updaters[altid] = command_class.new (cloneId, meta)    -- parent holds battery info
      end
    end
  end
    
  if #list > 0 then luup.log ("creating device numbers: " .. json.encode(list)) end
  
  move_to_room_101 (current)        -- park any remaining (lost) devices in room 101
  
  if something_changed then luup.reload() end
  
  local info = "%d vDevs, %d nodes"
  setVar ("DisplayLine1", info: format (#vDevs, N), SID.AltUI)

  return updaters
end


-----------------------------------------
--
-- DUMMY Z-WayVDev() API, for testing from file
--

local function ZWayVDev_DUMMY_API (filename)

  local f = assert (io.open (filename), "TEST filename not found")
  local D = json.decode (f: read "*a")
  f: close()
  
  if D then
    return {
      request = function () end,
      command = function () end,
      devices = function () return D end,
    }
  end
end  

-----------------------------------------
--
-- Z-WayVDev() API
--


local function ZWayVDev_API (ip, user, password)
  
  local cookie

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
      log (url)
      log (json_response)
    end
    return status, json_response
  end
  
  local function HTTP_request_json (url, body)
    local  status, json_response = HTTP_request (url, body)
    return status, json.decode (json_response)
  end

  local function authenticate ()
    local url = "http://%s:8083/ZAutomation/api/v1/login"
    local data = json.encode {login=user, password = password}
    local _, j = HTTP_request_json (url: format (ip), data)
    
    if j then
      local sid = j and j.data and j.data.sid
      if sid then cookie = "ZWAYSession=" .. sid end
    end
    return j
  end

  local function devices ()
    local url = "http://%s:8083/ZAutomation/api/v1/devices"
    local _, d = HTTP_request_json (url: format (ip))    
    return d and d.data and d.data.devices
  end
  
  -- send a command
  local function command (id, cmd)
    local url = "http://%s:8083/ZAutomation/api/v1/devices/ZWayVDev_zway_%s/command/%s"
    local request = url: format (ip, id, cmd)
    return HTTP_request_json (request)
  end
  
  -- send a generic request
  local function request (req)
    local url = "http://%s:8083%s"
    local request = url: format (ip, req)
    return HTTP_request (request)
  end
  
  -- ZWayVDev()
  if authenticate () then
    return {
      request = request,    -- for low-level access
      command = command,
      devices = devices,
    }
  end
end


-----------------------------------------
--
-- Z-Way()  STARTUP
--

function init(devNo)
	devNo = tonumber(devNo)
  
  do -- version number
    local y,m,d = ABOUT.VERSION:match "(%d+)%D+(%d+)%D+(%d+)"
    local version = ("v%d.%d.%d"): format (y%2000,m,d)
    log (version)
    setVar ("Version", version)
  end

	local ip = luup.attr_get ("ip", devNo)   -- use specified IP, if present
	ip = ip:match "%d+%.%d+%.%d+%.%d+" and ip or "127.0.0.1"

	luup.devices[devNo].action_callback (generic_action)     -- catch all undefined action calls  
	
	POLLRATE = uiVar ("Pollrate", 2)
  POLLRATE = math.min (tonumber(POLLRATE) or 0, 0.5)
  
  local user     = uiVar ("Username", "admin")
	local password = uiVar ("Password", "razberry")
  
  local testfile = uiVar ("Test_JSON_File", '')
  if testfile ~= '' then
    Z = ZWayVDev_DUMMY_API (testfile)
  else
    Z = ZWayVDev_API (ip, user, password)
  end

  setVar ("DisplayLine1", '', SID.AltUI)
  setVar ("DisplayLine2", ip, SID.AltUI)

  OFFSET = tonumber (getVar "Offset") or luup.openLuup.bridge.nextIdBlock()
  setVar ("Offset", OFFSET)

  local status, comment     
  if Z then
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
    
    local vDevs = Z.devices ()

    -- device-specific ID for HTTP handler allows multiple plugin instances
    handler = "HTTP_Z-Way_TEST_" .. devNo
    _G[handler] = function () return json.encode (vDevs), "application/json" end
    luup.register_handler (handler, 'test' .. devNo)
    
    cclass_update = createChildren (devNo, vDevs, room_number, OFFSET)
    _G.updateChildren (vDevs)
  
  else
    luup.set_failure (2, devNo)	        -- authorisation failure
    status, comment = false, "Failed to authenticate"
  end
	
  return status, comment, ABOUT.NAME

end

-----
