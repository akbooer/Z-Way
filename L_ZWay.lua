module (..., package.seeall)

local ABOUT = {
  NAME          = "L_ZWay",
  VERSION       = "2016.08.25c",
  DESCRIPTION   = "Z-Way interface for openLuup",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2016 AKBooer",
  DOCUMENTATION = "",
}


local loader  = require "openLuup.loader"
local json    = require "openLuup.json"
local http    = require "socket.http"
local ltn12   = require "ltn12"

--[[
local u = require "userdata"
local i = luup.attr_get "InstalledPlugins2"
i[#i+1] = u.preinstalled.ZWay
--]]

local Z         -- the Zway API object

local cclass_update   -- table of command_class updaters indexed by altid

------------------

local devNo

local service_schema = {}    -- serviceId ==> schema implementation

local DEV = {
    controller  = "D_SceneController1.xml", -- these preset devices don't correspond to and ZWay vDev
    combo       = "D_ComboDevice1.xml",
    rgb         = "D_DimmableRGBLight1.xml",

  }
local SID = {          -- schema implementation or shorthand name ==> serviceId
    AltUI   = "urn:upnp-org:serviceId:altui1",
    ZWave   = "urn:micasaverde-com:serviceId:ZWaveNetwork1",
    ZWay    = "urn:akbooer-com:serviceId:ZWay1",
    
    controller  = "urn:micasaverde-com:serviceId:SceneController1",
    combo       = "urn:micasaverde-com:serviceId:ComboDevice1",
    rgb         = "urn:micasaverde-com:serviceId:Color1",
  }

-- LUUP utility functions 


local function log(text, level)
	luup.log(("%s: %s"): format ("ZWay", text), (level or 50))
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
  
    GetApplication        = {returns = {CurrentApplication = "Application"}},  -- return value handled by action request mechanism
    GetCurrentTemperature = {returns = {CurrentTemp = "CurrentTemperature"}},
    GetName               = {returns = {CurrentName = "Name"}},
    
    SetApplication = function (d, args)
      local allowedValue = {"Room", "Outdoor", "Pipe", "AirDuct"}
      for _, value in ipairs(allowedValue) do allowedValue[value] = true end
      if allowedValue [args.NewApplication] then
        luup.variable_set (args.serviceId, "Application", args.NewApplication, d)
      end
    end,
    
    SetName = function (d, args)
      if args.NewName then
        luup.variable_set (args.serviceId, "Name", args.NewName, d)
      end
    end,
      
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
 

--D_HVAC_ZoneThermostat1.xml uses these default serviceIds and variables...

local S_HVAC_FanMode = { }
--[[
-- command_class ["68"] Fan_mode
        --ThermostatFanMode
        --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite

urn:upnp-org:serviceId:HVAC_FanOperatingMode1,Mode=Auto
urn:upnp-org:serviceId:HVAC_FanOperatingMode1,FanStatus=On
   
   <name>SetMode</name>
         <name>NewMode</name>
         <relatedStateVariable>Mode</relatedStateVariable>
   <name>GetMode</name>
         <name>CurrentMode</name>
         <relatedStateVariable>Mode</relatedStateVariable>
   <name>GetFanStatus</name>
         <name>CurrentStatus</name>
         <relatedStateVariable>FanStatus</relatedStateVariable>
   <name>GetName</name>
         <name>CurrentName</name>
         <relatedStateVariable>Name</relatedStateVariable>
   <name>SetName</name>
         <name>NewName</name>
         <relatedStateVariable>Name</relatedStateVariable>
--]]

local S_HVAC_State = { }
--[[
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

local S_HVAC_UserMode = { }

--  ["64"]      --ThermostatMode
        --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
        --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific
--[[
urn:upnp-org:serviceId:HVAC_UserOperatingMode1,ModeTarget=Off
urn:upnp-org:serviceId:HVAC_UserOperatingMode1,ModeStatus=Off
urn:upnp-org:serviceId:HVAC_UserOperatingMode1,EnergyModeTarget=Normal
urn:upnp-org:serviceId:HVAC_UserOperatingMode1,EnergyModeStatus=Normal

   <name>SetModeTarget</name>
         <name>NewModeTarget</name>
         <relatedStateVariable>ModeTarget</relatedStateVariable>
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

local S_HVAC_FanSpeed = { }
--[[
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
SID [S_Unknown]         = "urn:upnp-org:serviceId:TemperatureSetpoint1"


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
    if inst.deviceType == "toggleButton" then
      local click = inst.updateTime
--      setVar ("LastUpdate_" .. meta.altid, click, SID.ZWay, d)
      if click ~= meta.click then -- force variable updates
        local scene = meta.scale
        local time  = os.time()     -- "◷" == json.decode [["\u25F7"]]
        local date  = os.date ("◷ %Y-%m-%d %H:%M:%S", time): gsub ("^0",'')
        
        luup.variable_set (SID[S_SceneController], "sl_SceneActivated", scene, d)
        luup.variable_set (SID[S_SceneController], "LastSceneTime",time, d)
        
        if time then luup.variable_set (SID.AltUI, "DisplayLine1", date,  d) end
        luup.variable_set (SID.AltUI, "DisplayLine2", "Last Scene: " .. scene, d)
        
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
      local armed = getVar ("Armed", sid, d)
      if armed == "1" then
        setVar ("ArmedTripped", tripped, sid, d)
      end
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
    if var then setVar (var, inst.metrics.level, meta.service, d) end
  end,
  
  -- door lock
  ["98"] = function (d, inst)
      setVar ("Status",open_or_close (inst.metrics.level), SID[S_DoorLock], d)
  end,

  -- thermostat
  
--   ["64"]       --ThermostatMode
        --	Off,Heat,Cool,Auto,Auxiliary,Resume,Fan Only,Furnace,Dry Air,Moist Air,Auto Change Over,
        --  Energy Save Heat,Energy Save Cool,Away Heat,Away Cool,Full Power,Manufacturer Specific
 
--["66"] Operating_state
--  ["67"] - { } -- Setpoint
        --Setpoint
        --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
--["68"] Fan_mode
        --ThermostatFanMode
        --	Auto Low,On Low,Auto High,On High,Auto Medium,On Medium,Circulation,Humidity and circulation,Left and right,Up and down,Quite

  
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
 
command_class ["113"] = command_class ["48"]      -- alarm
command_class ["156"] = command_class ["48"]      -- tamper switch

    
function command_class.new (dino, meta) 
  local updater = command_class[meta.c_class] or command_class["0"]
  return function (inst, ...) 
      setVar (inst.id, inst.metrics.level, SID.ZWay, dino)    -- diagnostic, for the moment
      setVar (inst.id .. "_LastUpdate", inst.updateTime, SID.ZWay, dino)    -- diagnostic, for the moment
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
  for _,instance in pairs (D) do 
    local altid = instance.id: match "^ZWayVDev_zway_.-([%w%-]+)$"
    if altid and cclass_update [altid] then
      cclass_update [altid] (instance)
    end
  end
  luup.call_delay ("updateChildren", 2)
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
      ["2"]  = { nil,      S_Generic },
      ["3"]  = { "D_LightSensor1.xml",        S_Light},
      ["4"]  = { nil,       S_EnergyMetering},
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
  ["67"] = { nil, S_HVAC_State }, -- Setpoint
        --	Heating,Cooling,Furnace,Dry Air,Moist Air,Auto Change Over,Energy Save Heating,Energy Save Cooling,Away Heating,Away Cooling,Full Power
  
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



--[[

ZWayVDev [Node ID]:[Instance ID]:[Command Class ID]:[Scale ID] 

The Node Id is the node id of the physical device, 
the Instance ID is the instance id of the device or ’0’ if there is only one instance. 
The command class ID refers to the command class the function is embedded in. 
The scale id is usually ’0’ unless the virtual device is generated from a Z-Wave device 
that supports multiple sensors with different scales in one single command class.

--]]

local NICS_pattern = "^(%d+)%-(%d+)%-(%d+)%-?(%d*)%-?(%d*)%-?(%d*)%-?(.-)$"

-- create metadata for each virtual device instance
local function vDev_meta (v)
  local altid = v.id: match "([%-%w]+)$"
  local node, instance, c_class, scale, sub_class, sub_scale, tail = altid: match (NICS_pattern)
  local N = tonumber (c_class) or 0
    
  local x = vMap[c_class] or {}
  local y = (x.scale or {})[scale] or {}
  local z = setmetatable (y, {__index = x})
  
--  local upnp_file = (0 < N and N < 128) and z[1] 
  local upnp_file = z[1] 
  local service   = SID[z[2]]
  local json_file = z[3]
  
  local devtype = (json_file or upnp_file or ''): match "^D_(%u+%l*)"
--  if devtype then devtype = devtype: lower () end

  return {
    upnp_file = upnp_file,
    service   = service,
    json_file = json_file,
    devtype   = devtype,
    altid     = altid,
    node      = node,
    instance  = instance,
    c_class   = c_class,
    scale     = scale,
    sub_class = sub_class,
    sub_scale = sub_scale,
    tail      = tail,
  }
end



-- transform each node into some sort of Luup device structure with parents and children
local function luupDevice (node, instances) 

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
    
    -- HOWEVER... 
    
    -- if there are lots of dimmers, ...
    if dimmers and dimmers > 3 then           -- ... we'll asume that it's an RGB(W) switch
      devtype = " RGB Controller" 
      upnp_file = DEV.rgb
      
    -- if there are any HVAC services, ...
--    elseif thermos and thermos > 0 then       -- ... it's a thermostat
--      devtype = " Thermostat" 
--      upnp_file = "D_HVAC_ZoneThermostat1.xml"
      
    else                                      -- just a vanilla combination device
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
    name = name,
    node = node,
    devices = dev,
    variables = var,
    parameters = parameters,
  } 

end

-- index virtual devices number by node number and build instance metadata
local function index_nodes (d)
  local index = {}
  for _,v in pairs (d) do 
    local node = v.id: match "^ZWayVDev_zway_.-(%d+)" 
    if node then
      v.meta = vDev_meta (v)        -- construct metadata
      local t = index[node] or {}
      t[#t+1] = v
      index[node] = t
    end
  end
  return index
end


-- intepret the vDev structure and devices or services with variables
-- define the top-level devices with other instances as children
local function analyze (devices)    
  local luupDevs = {}
  local vDevs = index_nodes (devices)
  for node, instances in pairs(vDevs) do
    local d = luupDevice (node, instances)
    luupDevs[#luupDevs+1] = d
    luupDevs[node] = d            -- also index by node id (string)
  end
  return luupDevs
end


-- this reads a device file and its service files returning a list of variables
-- which can be used in the luup.chdev.append() call to preset device variables
local function parameter_list (upnp_file)
  local parameters
  if upnp_file then
    local d = loader.read_device (upnp_file)          -- read the device file
    local p = {}
    local parameter = "%s,%s=%s"
    for _, s in ipairs (d.service_list or {}) do
      if s.SCPDURL then 
        local svc = loader.read_service (s.SCPDURL)   -- read the service file(s)
        for _,v in ipairs (svc.variables or {}) do
          local default = v.defaultValue
          if default and default ~= '' then            -- only variables with defaults
            p[#p+1] = parameter: format (s.serviceId, v.name, default)
          end
        end
      end
    end
    parameters = table.concat (p, '\n')
  end
  return parameters
end

local function appendZwayDevice (lul_device, handle, name, altid, upnp_file, extra)
  local parameters = parameter_list (upnp_file)
  parameters = table.concat ({parameters, extra}, '\n')
  luup.chdev.append (
    lul_device, handle,   -- parent device and handle
    altid, name, 				   -- id and description
    nil,                  -- device type
    upnp_file, nil,       -- device filename and implementation filename
    parameters  				   -- parameters: "service,variable=value\nservice..."
  )
end


-- create correct parent/child relationship between instances
local function createChildren(devNo, devices)

  local no_reload = true
	local updater = {}
  local luupDevs = analyze (devices)
  
  getmetatable(luup.devices[devNo]).__index.handle_children = true       -- ensure we handle Zwave actions
  
  -- first the top-level node devices...
    
  local handle = luup.chdev.start(devNo);
	for _, ldv in ipairs(luupDevs) do
    appendZwayDevice (devNo, handle, ldv.name, ldv.altid, ldv.upnp_file, ldv.parameters)
	end
	local reload = luup.chdev.sync(devNo, handle, no_reload)   -- sync all the top-level devices

  local info = "%d vDevs, %d nodes"
  setVar ("DisplayLine1", info: format (#devices, #luupDevs), SID.AltUI)

  -- ...and then the child instances and additional device variables
  
	local top_level = {}
  for dino, dev in pairs(luup.devices) do
    if dev.device_num_parent == devNo then
      top_level[dino] = true
      local node = dev.id: match "^(%d+)"
      local handle = luup.chdev.start(dino);
      
      getmetatable(dev).__index.handle_children = true       -- ensure parent handles Zwave actions
 
      -- child devices
      local this = luupDevs[node]
      for _, instance in ipairs (this.devices) do
        local m = instance.meta
        if m.upnp_file then
          if m.altid == dev.id then                         -- don't create duplicate device!
            updater[m.altid] = command_class.new (dino, m)  -- just create its updater
          else
            local title = "%3s: %s %s %s"
            local metrics = instance.metrics
            local suffix = m.instance ~= '0' and m.instance or ''
            local name = title: format (node, metrics.title: match "%w+",  m.devtype or '?', suffix)
            updater[m.altid] = m
            appendZwayDevice (dino, handle, name, m.altid, m.upnp_file)
          end
        end
      end
      
      -- top-level device variables
      for _, instance in ipairs (this.variables) do
        local m = instance.meta
        updater[m.altid] = command_class.new (dino, m)    -- create specific updaters for each device variable
      end

      local reload2 = luup.chdev.sync(dino, handle, no_reload)   -- sync the lower-level devices for this top-level one
      reload = reload or reload2
    end
	end
    
  -- now go through devices and create custom updaters for the individual child devices
  for dino, dev in pairs (luup.devices) do
    if top_level[dev.device_num_parent] then
      local altid = dev.id
      updater[altid] = command_class.new (dino, updater[altid])    -- create specific updaters for each device service
      -- TODO: json_file 
    end
  end
  
  if reload then luup.reload () end
  return updater
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
    return status, json.decode (json_response)
  end

  local function authenticate ()
    local url = "http://%s:8083/ZAutomation/api/v1/login"
    local data = json.encode {login=user, password = password}
    local _, j = HTTP_request (url: format (ip), data)
    
    if j then
      local sid = j and j.data and j.data.sid
      if sid then cookie = "ZWAYSession=" .. sid end
    end
    return j
  end

  local function devices ()
    local url = "http://%s:8083/ZAutomation/api/v1/devices"
    local _, d = HTTP_request (url: format (ip))    
    return d and d.data and d.data.devices
  end
  
  -- send a command
  local function command (id, cmd)
    local url = "http://%s:8083/ZAutomation/api/v1/devices/ZWayVDev_zway_%s/command/%s"
    local request = url: format (ip, id, cmd)
    return HTTP_request (request)
  end
  
  -- ZWayVDev()
  if authenticate () then
    return {
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
	
	local user     = uiVar ("Username", "admin")
	local password = uiVar ("Password", "razberry")
  
  Z = ZWayVDev_API (ip, user, password)

  setVar ("DisplayLine1", '', SID.AltUI)
  setVar ("DisplayLine2", ip, SID.AltUI)

  local status, comment     
  if Z then
    luup.set_failure (0, devNo)	        -- openLuup is UI7 compatible
    status, comment = true, "OK"
  
    -- device-specific ID for HTTP handler allows multiple plugin instances
    local handler = "HTTP_Z-Way_" .. devNo
    _G[handler] = function () return json.encode (D), "application/json" end
    luup.register_handler (handler, 'z' .. devNo)
    
    local vDevs = Z.devices ()
    cclass_update = createChildren (devNo, vDevs)
    _G.updateChildren (vDevs)
  
  else
    luup.set_failure (2, devNo)	        -- authorisation failure
    status, comment = false, "Failed to authenticate"
  end
	
  return status, comment, ABOUT.NAME

end
	 
-----
