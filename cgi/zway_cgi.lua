#!/usr/bin/env wsapi.cgi

module(..., package.seeall)

ABOUT = {
  NAME          = "zway_cgi",
  VERSION       = "2020.02.22",
  DESCRIPTION   = "a WSAPI CGI proxy configuring the ZWay plugin",
  AUTHOR        = "@akbooer",
  COPYRIGHT     = "(c) 2013-2016 AKBooer",
  DOCUMENTATION = "",
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


-- 2016.10.17  original version

-- 2020.02.16  update for I_ZWay2 device configuration
local wsapi = require "openLuup.wsapi" 
local xml   = require "openLuup.xml"

local xhtml = xml.createHTMLDocument ()       -- factory for all HTML tags

local _log    -- defined from WSAPI environment as wsapi.error:write(...) in run() method.

local SID = {
    ZWay    = "urn:akbooer-com:serviceId:ZWay1",
  }
  
-- simple proxy 
--[[
local ZWay = require "L_ZWay"

function run(wsapi_env)
  
  local status, txt = ZWay.HTTP_request (wsapi_env.SCRIPT_NAME)
  
  local ctype = (status == 200) and "application/json" or "text/plain" 
  local headers = { ["Content-Type"] = ctype }
  txt = txt or ''
  
  local function content()
    local result = txt
    txt = nil
    return result
  end

  return 200, headers, content
end
--]]

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

-- find ZWay bridges only
local function find_ZWay_bridge ()
  local bridge = {}
  local B = luup.openLuup.bridge
  local info = B.get_info()
  for n,d in pairs (info.by_devNo) do
    local dev = luup.devices[n]
    if dev.device_type == "ZWay" then
      local dev = luup.devices[n]
      bridge[#bridge+1] = {id = n, offset = d.offset, dev = dev}
    end
  end
  return bridge
end

-- display bridge info as HTML table
--       bridge = {id = n, offset = d.offset, dev = dev}
local function show_bridge (bridge)
  local dev = bridge.dev
  local children = dev:get_children()
--  print ('', "#children", #children)
  local title = xhtml.div {class = "w3-container w3-grey", 
    xhtml.h3 {'[', bridge.id, '] ', dev.description} }

  local D = luup.devices
  table.sort (children)
  local tbl = xhtml.table {class="w3-small w3-hoverable w3-border"}
  tbl.header {"devNo", '', "altid", 'x', "device file", "node", ''}
  
--  local dropdowns = xhtml.div {}
  for _,n in ipairs (children) do
    local c = luup.devices[n]
    local cvar = luup.variable_get (SID.ZWay, "Children", n) or ''
    local cs = {}
    for alt in cvar: gmatch "[%-%w]+" do cs[alt] = true end   -- note specified children
    
    local altid = c.id
    print ('', altid, c.description)
    tbl.row {n, '', altid, '', c.attributes.device_file or '', c.description}
    for _,v in ipairs (c.variables) do
      local vtype, nics = v.name: match "zway_(%D*)(.*)"
      nics = nics or ''
      local node, instance, command_class, scale, sub_class, sub_scale, tail = nics: match (NICS_pattern)
      if node and not tail: match "LastUpdate$" then
        local checked = cs[nics] and nics or nil
        tbl.row {'', vtype, nics, xhtml.input {type = "checkbox", checked = checked} }
      end
    end
--    dropdowns[#dropdowns+1] = xhtml.div { --class = "w3-dropdown-hover", 
--      style="clear:both; float:left",
--      c.description , xhtml.div {tbl} } -- {class = "w3-dropdown-content", tbl} }

  end
  
  return xhtml.div {class = "w3-panel",
    xhtml.div {class = "w3-panel", title, tbl } }
end

---------
--
--  CGI
--
function run(wsapi_env)

  _log = function (...) wsapi_env.error:write(...) end      -- set up the log output, note colon syntax
  
  local req = wsapi.request.new (wsapi_env)   -- use request library to get object with useful methods
  local res = wsapi.response.new ()           -- and the response library to build the response!
    
  local h = xml.createHTMLDocument "ZWay-config"
  
  -- find the ZWay bridges

  local bridges = find_ZWay_bridge ()    
  
  local d = h.div {class = "w3=container"}
  for _, b in ipairs(bridges) do
    local tbl = show_bridge (b)
    d[#d+1] = tbl
  end
    
  h.body:appendChild {
    h.meta {charset="utf-8", name="viewport", content="width=device-width, initial-scale=1"}, 
    h.link {rel="stylesheet", href="https://www.w3schools.com/w3css/4/w3.css"},
    h.div {class = "w3-grey", 
      h.div {class = "w3-bar", h.h2 "Device configuration for ZWay plugin"} },
    d }
    
  res:write (tostring(h))
  res:content_type "text/html" 
  return res:finish()
end
 
-----
