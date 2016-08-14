module (..., package.seeall)

local ABOUT = {
  NAME          = "L_ZWay",
  VERSION       = "2016.08.14",
  DESCRIPTION   = "Z-Way interface for openLuup",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2016 AKBooer",
  DOCUMENTATION = "",
}


local loader  = require "openLuup.loader"
local json    = require "openLuup.json"
local http    = require "socket.http"
local ltn12   = require "ltn12"


local Z         -- the Zway object

local service_update   -- table of service updaters indexed by altid

------------------

local devNo

local ACT = {}
local DEV = {}
local SID = {
    AltUI   = "urn:upnp-org:serviceId:altui1",
    Energy  = "urn:micasaverde-com:serviceId:EnergyMetering1",
    ZWave   = "urn:micasaverde-com:serviceId:ZWaveNetwork1",
    ZWay    = "urn:akbooer-com:serviceId:ZWay1",
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
        
        luup.variable_set (SID.controller, "sl_SceneActivated", scene, d)
        luup.variable_set (SID.controller, "LastSceneTime",time, d)
        
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
    setVar ("Status", status, SID.switch, d)
  end,
  
  -- binary sensor
  ["48"] = function (d, inst)
    local sid = SID.security
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
  ["49"] = function (d, inst, meta)
    local name = {
      [SID.temperature] = "CurrentTemperature",
      [SID.energy] = "Watts",
    }
    local var = name[meta.service] or "CurrentLevel"
    setVar (var, inst.metrics.level, meta.service, d)
  end,

  -- meter
  ["50"] = function (d, inst, meta)
    local var = (inst.metrics.scaleTitle or '?'): upper ()
    if var then setVar (var, inst.metrics.level, meta.service, d) end
  end,
  
  -- door lock
  ["98"] = function (d, inst)
      setVar ("Status",open_or_close (inst.metrics.level), SID.door, d)
  end,

  
  -- battery
  ["128"] = function (d, inst)
    setVar ("BatteryLevel", inst.metrics.level, SID.hadevice, d)
  end,

}

--command_class["113"] = command_class["48"]      -- alarm
command_class["102"] = command_class["98"]      -- barrier (garage door)
    
function command_class.new (dino, meta) 
  local updater = command_class[meta.c_class] or command_class["0"]
  return function (inst, ...) 
      setVar (inst.id, inst.metrics.level, SID.ZWay, dino)    -- diagnostic, for the moment
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
    if altid and service_update [altid] then
      service_update [altid] (instance)
    end
  end
  luup.call_delay ("updateChildren", 2)
end


----------------------------------------------------
--
-- SERVICES - virtual services
--

local services = {}

--[[
vDev commands:
1. ’update’: updates a sensor value
2. ’on’: turns a device on. Only valid for binary commands
3. ’off’: turns a device off. Only valid for binary commands
4. ’exact’: sets the device to an exact value. This will be a temperature for thermostats or a percentage value of motor controls or dimmers
--]]


-- urn:upnp-org:serviceId:SwitchPower1
local S_SwitchPower = {
    
    SetTarget = function (d, args)
      local value = on_or_off (args.newTargetValue or '0')
      local altid = luup.devices[d].id
      altid = altid: match "^%d+$" and altid.."-0-37" or altid
      Z.command (altid, value)
    end,
    
  }


-- urn:upnp-org:serviceId:Dimming1
local S_Dimming = {
    
    SetLoadLevelTarget = function (d, args)
      local level = tonumber (args.newLoadlevelTarget or '0')
      local value = "exact?level=" .. level
      local altid = luup.devices[d].id
      altid = altid: match "^%d+$" and altid.."-0-38" or altid
      Z.command (altid, value)
    end,
    
  }


-- urn:schemas-micasaverde-com:service:HaDevice:1
local S_HaDevice = {
    
    ToggleState = function (d) 
      local toggle = {['0'] = '1', ['1']= '0'}
      local status = getVar ("Status", SID.switch, d)
      S_SwitchPower.SetTarget (d, {newTargetValue = toggle [status] or '0'})
    end,
    
  }


local S_Temperature = {
    
  GetCurrentTemperature = function () end,  -- return value handled by action request mechanism
   }


  -- urn:micasaverde-com:serviceId:SecuritySensor1
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

local S_Generic   = { }
local S_Light     = { }
local S_Humidity  = { }
local S_Camera    = { }

local S_EnergyMetering  = { }   -- urn:micasaverde-com:serviceId:EnergyMetering1
local S_SceneController = { }
local S_Unknown = { }   -- "catch-all" service


-----------------------------------------
--
-- ACTION command callbacks: openLuup => Zway
--

local function generic_action (serviceId, action)
  local function noop(lul_device) 
    local message = "service/action not implemented: %d.%s.%s"
    log (message: format (lul_device, serviceId, action))
    return false
  end 
  local service = services[serviceId] or {}
  return { run = service [action] or noop }
end


----------------------------------------------------

-- DEVICES

-- use Device maps to lookup Vera category, hence device type...
-- ...and from the device file we can then get services...
-- ...and from the service files, the actions and variables.
--

local function vMap (name, _, sid, dev, act)
  ACT[name] = act
  DEV[name] = dev
  SID[name] = sid
  if sid and act then services[sid] = act end
end
  
-- TODO: JSON files for sub-types ?
-- D_UVSensor.json
-- D_LeakSensor1.json
-- D_SmokeCoSensor1.json"

vMap ( "multilevel",   38, "urn:upnp-org:serviceId:Dimming1",                "D_DimmableLight1.xml",     S_Dimming)
vMap ( "ultraviolet",  49, "urn:micasaverde-com:serviceId:LightSensor1",     "D_LightSensor1.xml",       S_Generic)
vMap ( "hadevice",      0, "urn:micasaverde-com:serviceId:HaDevice1",        "D_ComboDevice1.xml",       S_HaDevice)        
vMap ( "humidity",     49, "urn:micasaverde-com:serviceId:HumiditySensor1",  "D_HumiditySensor1.xml",    S_Humidity)
vMap ( "luminosity",   49, "urn:micasaverde-com:serviceId:LightSensor1",     "D_LightSensor1.xml",       S_Light)
vMap ( "security",     48, "urn:micasaverde-com:serviceId:SecuritySensor1",  "D_MotionSensor1.xml",      S_Security)
vMap ( "motion",       48, "urn:micasaverde-com:serviceId:SecuritySensor1",  "D_MotionSensor1.xml",      S_Security)
vMap ( "smoke",        48, "urn:micasaverde-com:serviceId:SecuritySensor1",  "D_SmokeSensor1.xml",       S_Security)
vMap ( "switch",       37, "urn:upnp-org:serviceId:SwitchPower1",            "D_BinaryLight1.xml",       S_SwitchPower)
vMap ( "temperature",  49, "urn:upnp-org:serviceId:TemperatureSensor1",      "D_TemperatureSensor1.xml", S_Temperature)
vMap ( "switchRGBW",    0, "urn:micasaverde-com:serviceId:Color1",           "D_DimmableRGBLight1.xml",  S_Color)
vMap ( "controller",    0, "urn:micasaverde-com:serviceId:SceneController1", "D_SceneController1.xml",   S_SceneController)
vMap ( "thermostat",   56, "urn:upnp-org:serviceId:TemperatureSetpoint1",    "D_HVAC_ZoneThermostat1.xml", S_Unknown)
vMap ( "camera",        0, "urn:micasaverde-com:serviceId:Camera1",          "D_DigitalSecurityCamera1.xml", S_Camera)
vMap ( "combo",         0, "urn:micasaverde-com:serviceId:ComboDevice1",     "D_ComboDevice1.xml",       S_Unknown)
vMap ( "door",         98, "urn:micasaverde-com:serviceId:DoorLock1",        "D_DoorLock1.xml",          S_DoorLock)

-- D_Siren1.xml
-- D_SmokeSensor1.xml"

vMap ( "generic",      49, "urn:micasaverde-com:serviceId:GenericSensor1",   nil,     S_Generic)
vMap ( "battery",     128, "urn:micasaverde-com:serviceId:HaDevice1",         nil,                       S_HaDevice)
vMap ( "energy",       50, "urn:micasaverde-com:serviceId:EnergyMetering1",    nil,                      S_EnergyMetering)
--vMap ( "meter",       50, "urn:micasaverde-com:serviceId:EnergyMetering1",    "D_PowerMeter1.xml",     S_EnergyMetering)


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

  -- icon types
  
  defaults.metrics.icon = "motion";
  defaults.metrics.icon = "smoke";
  defaults.metrics.icon = "co";
  defaults.metrics.icon = "flood";
  defaults.metrics.icon = "cooling";
  defaults.metrics.icon = "door";
  defaults.metrics.icon = "motion";
  defaults.metrics.icon = "temperature";
  defaults.metrics.icon = "luminosity";
  defaults.metrics.icon = "energy";
  defaults.metrics.icon = "humidity";
  defaults.metrics.icon = "barometer";
  defaults.metrics.icon = "ultraviolet";
  
  a_defaults.metrics.icon = 'door';
  a_defaults.metrics.icon = 'smoke';
  a_defaults.metrics.icon = 'co';
  a_defaults.metrics.icon = 'alarm';
  a_defaults.metrics.icon = 'flood';

--]]


--[[

All Widgets belong to one specific type. At the moment the following types are defined and supported by the Z-Way-HA UI:
– sensorBinary: A binary sensor, only showing on or off
– sensorMultilevel: The type, the value and the scale of the sensor are shown
– switchBinary: The device can be switched on and off
– switchMultilevel: The device can be switched on and off plus set to any percentage level between 0 % and 100 %.
– switchRGBW: This device allows setting RGB colors
– switchControl:
– toggleButton: The device can only be turned on. This is for scene activation.
– thermostat: The thermostat shows the setpoint temperature plus a drop down list of thermostat modes if available
– battery: The battery widget just shows the percentage of charging capacity left
– camera: A camera will show the image and can be operated
– fan: A fan can be turned on and off

--]]


local wMap = {
  sensorBinary      = "security",
  sensorMultilevel  = "generic",
  switchBinary      = "switch",
  switchMultilevel  = "multilevel",
  switchRGBW        = "switchRGBW",
  switchControl     = "switch",
  toggleButton      = "controller",
  thermostat        = "thermostat",
  battery           = "battery",
  camera            = "camera",
  fan               = nil,
}


--[[

ZWayVDev [Node ID]:[Instance ID]:[Command Class ID]:[Scale ID] 

The Node Id is the node id of the physical device, 
the Instance ID is the instance id of the device or ’0’ if there is only one instance. 
The command class ID refers to the command class the function is embedded in. 
The scale id is usually ’0’ unless the virtual device is generated from a Z-Wave device 
that supports multiple sensors with different scales in one single command class.

--]]

local NICS_pattern = "^(%d+)%-(%d+)%-(%d+)%-?(%d*)%-?(.-)%-?(%a*)$"

-- create metadata for each virtual device instance
local function vDev_meta (v)
  local altid = v.id: match "([%-%w]+)$"
  local node, instance, c_class, scale, other, char = altid: match (NICS_pattern)
  local met = v.metrics or {}
  local itype = met.icon
  local dtype = wMap[v.deviceType]
  local N = tonumber (c_class) or 0
  return {
    device    = command_class[c_class] and (0 < N and N < 128) and (DEV[itype] or DEV[dtype]),
    service   = SID[itype] or SID[dtype] or SID.generic,
    altid     = altid,
    node      = node,
    instance  = instance,
    c_class   = c_class,
    scale     = scale,
    other     = other,
    char      = char,
  }
end


-- transform each node into some sort of Luup device structure with parents and children
local function luupDevice (node, instances) 

  -- split into devices and variables
  local dev, var = {}, {}
  local children = {}         -- count of children indexed by (shorthand) device type
  for _, v in ipairs (instances) do
    if v.meta.device then
      local t= v.meta.device: match "^D_(%a%l+)"
      children[t] = (children[t] or 0) + 1
      dev[#dev+1] = v
    else
      var[#var+1] = v
    end
  end
      
  -- create top-level device: three different sorts:
  local Ndev = #dev
  local upnp_file, altid, dtype, parameters
  
  -- a controller has no devices and is just a collection of buttons and switches or other services 
  if Ndev == 0 then
    upnp_file, altid, dtype = DEV.controller, var[1].meta.node, "controller"
    local txt = [[Define scene triggers to watch sl_SceneActivated]] ..
                [[ with Lua Expression: new == "button_number"]]
    parameters = table.concat { SID.controller, ',', "Scenes", '=', txt }
    
  -- a singleton device is a node with only one vDev device
  elseif Ndev == 1 then
    upnp_file, altid = dev[1].meta.device, dev[1].meta.altid 
    
  -- a combo device is a collection of more than one vDev device, and may have service variables
  else
    upnp_file, altid, dtype = DEV.combo, dev[1].meta.node, " combo"  -- (the space is important)
    
    -- HOWEVER... if there are lots of dimmers, assume it's an RGB(W) combo
 
    local dimmers = children.Dimmable
    if dimmers and dimmers > 3 then     -- ... we'll asume that it's an RGB(W) switch
      dtype = " RGB" 
      upnp_file = DEV.switchRGBW
      
    else                                -- just a vanilla combination device
      local label = {}
      for a,b in pairs(children) do
        label[#label+1] = table.concat {a,':', b}
      end
      table.sort (label)
      parameters = table.concat { SID.AltUI, ',', "DisplayLine1", '=', table.concat (label, ' ') }
    end
  end
  
  -- return structure with info for creating the top-level device
  local m = (dev[1] or var[1]).metrics
--  local alias = {smoke = "alarm"}  TODO: alias for 'smoke' alarms
  dtype = dtype or m.icon or '?'
  local name = ("%3s: %s %s"): format (node, m.title: match "%w+", dtype) 
  
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
    altid, name, 				  -- id and description
    nil,                  -- device type
    upnp_file, nil,       -- device filename and implementation filename
    parameters  				   -- parameters: "service,variable=value\nservice..."
  )
end


-- create correct parent/child relationship between instances
local function syncChildren(devNo, devices)

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
        if m.device then
          if m.altid == dev.id then                         -- don't create duplicate device!
            updater[m.altid] = command_class.new (dino, m)  -- just create its updater
          else
            local title = "%3s: %s %s %s"
            local metrics = instance.metrics
            local scale = m.scale
            local suffix = table.concat ({m.instance, (scale ~= '') and scale or nil}, '.')
            local name = title: format (node, metrics.title: match "%w+",  metrics.icon or '?', suffix)
            updater[m.altid] = m
            appendZwayDevice (dino, handle, name, m.altid, m.device)
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
    service_update = syncChildren (devNo, vDevs)
    _G.updateChildren (vDevs)
  
  else
    luup.set_failure (2, devNo)	        -- authorisation failure
    status, comment = false, "Failed to authenticate"
  end
	
  return status, comment, ABOUT.NAME

end
	 
-----
