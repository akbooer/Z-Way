module (..., package.seeall)

local ABOUT = {
  NAME          = "L_ZWay",
  VERSION       = "2016.07.28",
  DESCRIPTION   = "Z-Way interface for openLuup",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2016 AKBooer",
  DOCUMENTATION = "",
}

local pretty  = require "pretty"

local loader  = require "openLuup.loader"
local json    = require "openLuup.json"
local http    = require "socket.http"
local ltn12   = require "ltn12"

local Z         -- the Zway object
local index     -- bi-directional index device no. <--> altid
local updater   -- table of updaters indexed by altid

------------------

local devNo


local SID = {
  dimming     = "urn:upnp-org:serviceId:Dimming1",
  generic     = "urn:micasaverde-com:serviceId:GenericSensor1",
  hadevice    = "urn:micasaverde-com:serviceId:HaDevice1",
  humidity    = "urn:micasaverde-com:serviceId:HumiditySensor1",
  light       = "urn:micasaverde-com:serviceId:LightSensor1",
  security    = "urn:micasaverde-com:serviceId:SecuritySensor1",
  switch      = "urn:upnp-org:serviceId:SwitchPower1",
  temperature = "urn:upnp-org:serviceId:TemperatureSensor1",
  Zway        = "urn:micasaverde-com:serviceId:ZWaveNetwork1",
}

-- LUUP utility functions 


local function log(text, level)
	luup.log(("%s: %s"): format ("ZWay", text), (level or 50))
end

local function getAttr (name)
  return luup.attr_get (name, devNo) or ''
end

local function setAttr (name, value)
  luup.attr_set (name, value or '', devNo)
end

local function uiAttr (name, default)
  local value = getAttr (name)
  if not value or value == '' then
    value = default
    setAttr (value)
  end
  return value
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


----------------------------------------------------
--
-- SERVICES - virtual services
--


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


vDev commands:
1. ’update’: updates a sensor value
2. ’on’: turns a device on. Only valid for binary commands
3. ’off’: turns a device off. Only valid for binary commands
4. ’exact’: sets the device to an exact value. This will be a temperature for thermostats or a percentage value of motor controls or dimmers

--]]

local function update_ (d, inst)
--  local message = "no update for device %d [%s]"
--  log (message: format (d, inst.id))
end


-- urn:schemas-micasaverde-com:service:HaDevice:1
local S_HaDevice = {
    
    ToggleState = function (d, args) 
      log "ToggleState"
      local status = getVar ("Status", SID.switch, tonumber(d))
      status = ({['0'] = '1', ['1']= '0'}) [status] or '0'
      local value = on_or_off (status) 
      local altid = luup.devices[d].id
      Z.command (altid, value)
    end,
    
    update = update_,
  }


--  local serviceId = "urn:upnp-org:serviceId:SwitchPower1"
local S_SwitchPower = {
    
    SetTarget = function (d, args)
      log "SetTarget"
      local value = on_or_off (args.newTargetValue)
      local altid = luup.devices[d].id
      Z.command (altid, value)
    end,
    
    update = function (d, inst)
      setVar ("Status",on_or_off (inst.metrics.level), SID.switch, d)
    end,
  }


-- urn:upnp-org:serviceId:Dimming1
local S_Dimming = {
    
    SetLoadLevelTarget = function (d, args)
      local value = "exact?level=" .. (args.newLoadlevelTarget or '0')
      local altid = luup.devices[d].id
      local _,b = Z.command (altid, value)
    end,
    
    update = function (d, inst)
      local level = tonumber (inst.metrics.level) or 0
      setVar ("LoadLevelTarget", level, SID.dimming, d)
      setVar ("LoadLevelStatus", level, SID.dimming, d)
      local status = (level > 0 and "1") or "0"
      setVar ("Status", status, SID.switch, d)
    end,
  }


local S_Generic = {
    
    command = function (d, args)
      
    end,
    
    update = function (d, inst)
      setVar ("CurrentLevel", inst.metrics.level, SID.generic, d)
    end,
  }


local S_Light = {
    
    command = function (d, args)
      
    end,
    
    update = function (d, inst)
      setVar ("CurrentLevel", inst.metrics.level, SID.light, d)
    end
  }


local S_Humidity = {
    
    command = function (d, args)
      
    end,
    
    update = function (d, inst)
      setVar ("CurrentLevel", inst.metrics.level, SID.humidity, d)
    end,
  }


local S_Temperature = {
    
    command = function (d, args)
      
    end,
    
    update = function (d, inst)
      setVar ("CurrentTemperature", inst.metrics.level, SID.temperature, d)
    end,
  }


  -- urn:micasaverde-com:serviceId:SecuritySensor1
local S_Security = {
    
    SetArmed = function (d, args)
      luup.variable_set (SID.security, "Armed", args.newArmedValue or '0', tonumber(d))
    end,
    
    update = function (d, inst)
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
  }

local S_Unknown = {
 
  unknown = function (d)      -- "catch-all" service
    luup.log ("unknown" .. (d or '?'))
  end,

  update = update_,
}


local services = {
    [SID.dimming]     = S_Dimming, 
    [SID.generic]     = S_Generic,
    [SID.hadevice]    = S_HaDevice,
    [SID.humidity]    = S_Humidity,
    [SID.light]       = S_Light,
    [SID.security]    = S_Security,
    [SID.switch]      = S_SwitchPower,
    [SID.temperature] = S_Temperature,
    [SID.Zway]        = S_ZWave,
  }



----------------------------------------------------

-- DEVICES

-- use Device maps to lookup Vera category, hence device type...
-- ...and from the device file we can then get services...
-- ...and from the service files, the actions and variables.
--

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


D_RemoteControl1.xml
D_DimmableRGBLight1.xml

urn:schemas-micasaverde-com:device:PowerMeter:1
urn:schemas-upnp-org:device:DimmableRGBLight:1
--]]

  local WidgetDeviceMap = {
    toggleButton = {label="Remote Controller",    category = 1,   upnp_file = "D_SceneController1.xml", service=S_Unknown},
    toggleButton = {label="Static Controller",    category = 1,   upnp_file = "D_SceneController1.xml", service=S_Unknown},
    thermostat = {label="Thermostat",       category = 5,   upnp_file = "D_HVAC_ZoneThermostat1.xml", service=S_Unknown},
    [0x09] = {label="Window Covering",      category = 8,   upnp_file = "D_WindowCovering1.xml", service=S_Unknown},
    switchBinary = {label="Binary Switch",  category = 3,   upnp_file = "D_BinaryLight1.xml", service=S_SwitchPower},
    switchMultilevel = {label="Multilevel Switch",  category = 2,   upnp_file = "D_DimmableLight1.xml", service=S_Dimming},
    [0x12] = {label="Remote Switch",        category = 3,   upnp_file = "D_BinaryLight1.xml", service=S_Unknown},
    [0x13] = {label="Toggle Switch",        category = 3,   upnp_file = "D_BinaryLight1.xml", service=S_Unknown},
    [0x16] = {label="Ventilation",          category = 5,   upnp_file = "D_HVAC_ZoneThermostat1.xml", service=S_Unknown},
    sensorBinary = {label="Binary Sensor",  category = 4,   upnp_file = "D_MotionSensor1.xml", service=S_Security},
    sensorMultilevel = {label="Multilevel Sensor",  category = 12,  upnp_file = "D_GenericSensor1.xml", service=S_Unknown},
    [0x30] = {label="Pulse Meter",        category = 21,  upnp_file = "D_PowerMeter1.xml", service=S_Unknown},
    [0x31] = {label="Meter",              category = 21,  upnp_file = "D_PowerMeter1.xml", service=S_Unknown},
    [0x40] = {label="Entry Control",      category = 7,   upnp_file = "D_DoorLock1.xml", service=S_Unknown},
    camera = {upnp_file = "D_DigitalSecurityCamera1.xml", device_type="urn:schemas-upnp-org:device:DigitalSecurityCamera:1", service=S_Unknown},
  }

  local ProbeDeviceMap = {
    ["generic"]     = {upnp_file="D_GenericSensor1.xml", device_type="urn:schemas-micasaverde-com:device:GenericSensor:1", service=S_Generic},
    ["luminosity"]  = {upnp_file="D_LightSensor1.xml", device_type="urn:schemas-micasaverde-com:device:LightSensor:1", service=S_Light},
    ["humidity"]    = {upnp_file="D_HumiditySensor1.xml", device_type="urn:schemas-micasaverde-com:device:HumiditySensor:1", service=S_Humidity},
    ["temperature"] = {upnp_file="D_TemperatureSensor1.xml", device_type="urn:schemas-micasaverde-com:device:TemperatureSensor:1", service=S_Temperature},
  }
  
----------------------------------------------------
--
-- return a Vera device description
--

local function findDeviceDescription (ZWayVDev)	
	
  local DFile, devicetype, service 
  local dtype = ZWayVDev.deviceType
  local ptype = ZWayVDev.probeType
  local wtype = ptype or dtype
  if wtype then
--    print (dtype, ptype, DFile)
    local map   = ProbeDeviceMap[ptype] or WidgetDeviceMap[dtype] or {}
    DFile       = map.upnp_file
    devicetype  = map.device_type
    service     = map.service
  end
  
  local parameters
  if DFile then
    local d = loader.read_device (DFile)          -- read the device file
    
    local p = {}
    for _, s in ipairs (d.service_list) do
      if s.SCPDURL then 
        local svc = loader.read_service (s.SCPDURL)   -- read the service file(s)
        local parameter = "%s,%s=%s"
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
  
  return {
    devicetype  = devicetype or "urn:schemas-micasaverde-com:device:ComboDevice:1",
    DFile       = DFile or "D_ComboDevice1.xml",
    IFile       = '',
    Parameters  = parameters or '',    -- "service,variable=value\nservice..."
    service     = service or S_Unknown,
  }
end


local function appendZwayDevice (lul_device, handle, name, altid, descr)
  luup.chdev.append (
    lul_device, handle, 	      -- parent device and handle
    altid , name, 				      -- id and description
    descr.devicetype, 		      -- device type
    descr.DFile, descr.IFile,   -- device filename and implementation filename
    descr.Parameters  				  -- parameters: "service,variable=value\nservice..."
  )
end


-- create correct parent/child relationship between instances
local function syncChildren(devNo, tree)
  local no_reload = true
  local index = {}          -- bi-directional index of luup device numbers / altid
	updater = {}
  
  -- ZWayVDev [Node ID]:[Instance ID]:[Command Class ID]:[Scale ID] 
  -- for all top-level devices
	
  getmetatable(luup.devices[devNo]).__index.handle_children = true       -- ensure we handle Zwave actions
  local handle = luup.chdev.start(devNo);
	for node in pairs(tree) do
    local name = "ZWayVDev_" .. node
    appendZwayDevice (devNo, handle, name, node, findDeviceDescription {})
	end
	local reload = luup.chdev.sync(devNo, handle, no_reload)   -- sync all the top-level devices

  -- ...and the child instances  
  
	local top_level = {}
  for dino, dev in pairs(luup.devices) do
    if dev.device_num_parent == devNo then
      top_level[dino] = true
      getmetatable(dev).__index.handle_children = true       -- ensure parent handles Zwave actions
      local node = dev.id
      index[node], index[dino] = dino, node      -- index this device
      local handle = luup.chdev.start(dino);
      
      for altid, instance in pairs (tree[node]) do
        local name = altid
        local vDev = findDeviceDescription (instance)
        updater[altid] = vDev.service.update
        appendZwayDevice (dino, handle, name, altid, vDev)
      end
      local reload2 = luup.chdev.sync(dino, handle, no_reload)   -- sync the lower-level devices for this top-level one
      reload = reload or reload2
    end
	end
		
  -- now go through devices and index them by altid
  for dino, dev in pairs (luup.devices) do
    if top_level[dev.device_num_parent] then
      local altid = dev.id
      index[altid], index[dino] = dino, altid      -- index this device
    end
  end
  
  if reload then luup.reload () end
  return index
end


-----------------------------------------
--
-- DEVICE status updates
--

function _G.updateChildren (tree)
  tree = tree or Z.tree ()
  
  for node, instances in pairs(tree) do
    for altid, instance in pairs (instances) do
      updater[altid] (index[altid], instance)
    end
  end

  luup.call_delay ("updateChildren", 2)
end


-----------------------------------------
--
-- ACTION command callbacks
--

local function generic_action (serviceId, action)
  local function noop(lul_device) 
    local message = "service/action not implemented: %d.%s.%s"
    log (message: format (lul_device, serviceId, action))
    return false
  end 
  return { run = (services[serviceId] or {}) [action] or noop  }
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
    local response, status, headers = http.request{
      method = method,
      url=url,
      headers = {
          ["Content-Length"] = body and #body,
          ["Cookie"]= cookie,
        },
      source = body and ltn12.source.string(body),
      sink = ltn12.sink.table(response_body)
    }
    local j = table.concat (response_body)
    return status, json.decode (j)
  end

  local function authenticate ()
    local url = "http://%s:8083/ZAutomation/api/v1/login"
    local data = json.encode {login=user, password = password}
    local status, j = HTTP_request (url: format (ip), data)
    
    if j then
      local sid = j and j.data and j.data.sid
      if sid then cookie = "ZWAYSession=" .. sid end
    end
    return j
  end

  -- device

  --[[
  
  ZWayVDev [Node ID]:[Instance ID]:[Command Class ID]:[Scale ID] 
  
  The Node Id is the node id of the physical device, 
  the Instance ID is the instance id of the device or ’0’ if there is only one instance. 
  The command class ID refers to the command class the function is embedded in. 
  The scale id is usually ’0’ unless the virtual device is generated from a Z-Wave device 
  that supports multiple sensors with different scales in one single command class.

  --]]

  local function devices ()
    local url = "http://%s:8083/ZAutomation/api/v1/devices"
    local status, d = HTTP_request (url: format (ip))
    return d and d.data and d.data.devices
  end

  -- return a device tree, indexed by node number (ie. the top-level devices)
  local function device_tree (d)
    d = d or devices ()
    local tree = {}     -- indexed by node number
    local n = 0
    for i,v in pairs (d) do 
      local altid = v.id: match "^ZWayVDev_zway_.-([%w%-]+)$"
      if altid then
        local node, instance, command_class, other = altid: match "(%d+)%-(%d+)%-(%d+)%-?(.*)"
        tree[node] = tree[node] or {}
        tree[node][altid] = v
        n = n + 1
      end
    end
    return tree
  end
  
  -- send a command
  local function command (id, cmd)
    local url = "http://%s:8083/ZAutomation/api/v1/devices/ZWayVDev_zway_%s/command/%s"
    local request = url: format (ip, id, cmd)
    log (request)
    local status, d = HTTP_request (request)
    log (status)
    return status, d
  end
  
  -- ZWayVDev()
  if authenticate () then
    return {
      command = command,
      devices = devices,
      tree    = device_tree,
    }
  end
end


-----------------------------------------
--
-- Z-Way()
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
	
	local user      = uiAttr ("username", "admin")
	local password  = uiAttr ("password", "razberry")
  
  Z = ZWayVDev_API (ip ,user,password)

  local status, comment     
  if Z then
    luup.set_failure (0, devNo)	        -- openLuup is UI7 compatible
    status, comment = true, "OK"
  
    local tree = Z.tree ()
    index = syncChildren (devNo, tree)
    _G.updateChildren (tree)
  
  else
    luup.set_failure (2, devNo)	        -- authorisation failure
    status, comment = false, "Failed to authenticate"
  end
	
  return status, comment, ABOUT.NAME

end
	 
-----
