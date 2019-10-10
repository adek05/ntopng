--
-- (C) 2019 - ntop.org
--

local dirs = ntop.getDirs()
package.path = dirs.installdir .. "/scripts/lua/modules/?.lua;" .. package.path
require "lua_utils"
require "alert_utils"

local alerts_api = require("alerts_api")
local user_scripts = require("user_scripts")
local alert_consts = require("alert_consts")

local do_benchmark = true          -- Compute benchmarks and store their results
local do_print_benchmark = false   -- Print benchmarks results to standard output
local do_trace = false             -- Trace lua calls

local config_alerts_local = nil
local config_alerts_remote = nil
local available_modules = nil
local ifid = nil

-- #################################################################

-- The function below ia called once (#pragma once)
function setup(str_granularity)
   if(do_trace) then print("alert.lua:setup("..str_granularity..") called\n") end
   ifid = interface.getId()
   local ifname = interface.setActiveInterfaceId(ifid)

   -- Load the threshold checking functions
   available_modules = user_scripts.load(user_scripts.script_types.traffic_element, ifid, "host", str_granularity, nil, do_benchmark)

   config_alerts_local = getLocalHostsConfiguredAlertThresholds(ifname, str_granularity, available_modules.modules)
   config_alerts_remote = getRemoteHostsConfiguredAlertThresholds(ifname, str_granularity, available_modules.modules)
end

-- #################################################################

-- The function below ia called once (#pragma once)
function teardown(str_granularity)
   if(do_trace) then print("alert.lua:teardown("..str_granularity..") called\n") end

   user_scripts.teardown(available_modules, do_benchmark, do_print_benchmark)
end

-- #################################################################

-- The function below is called once per host
function checkAlerts(granularity)
  if table.empty(available_modules.hooks[granularity]) then
    if(do_trace) then print("host:checkAlerts("..granularity.."): no modules, skipping\n") end
    return
  end

  local suppressed_alerts = host.hasAlertsSuppressed()

  if suppressed_alerts then
     releaseAlerts(granularity)
  end

  local info = host.getFullInfo()
  local host_key   = hostinfo2hostkey({ip = info.ip, vlan = info.vlan}, nil, true --[[ force @[vlan] even when vlan is 0 --]])
  local config_alerts = ternary(info["localhost"], config_alerts_local, config_alerts_remote)
  local host_config = config_alerts[host_key] or {}
  local global_config = ternary(info["localhost"], config_alerts["local_hosts"], config_alerts["remote_hosts"]) or {}
  local has_configuration = (table.len(host_config) or table.len(global_config))
  local entity_info = alerts_api.hostAlertEntity(info.ip, info.vlan)

  if has_configuration then
    for mod_key, hook_fn in pairs(available_modules.hooks[granularity]) do
      local check = available_modules.modules[mod_key]
      local config = host_config[check.key] or global_config[check.key]
      local do_call

      if(check.is_alert) then
         -- Alert modules are only called if there is a configuration defined or always_enabled is set
         do_call = ((not suppressed_alerts) and (config or check.always_enabled))
      else
         -- always call non alert scripts. available_modules does not contain scripts disabled by the user
         do_call = true
      end

      if(do_call) then
        hook_fn({
           granularity = granularity,
           alert_entity = entity_info,
           entity_info = info,
           alert_config = config,
           user_script = check,
        })
      end
    end
  end

  alerts_api.releaseEntityAlerts(entity_info, host.getExpiredAlerts(granularity2id(granularity)))
end

-- #################################################################

function releaseAlerts(granularity)
  local info = host.getFullInfo()
  local entity_info = alerts_api.hostAlertEntity(info.ip, info.vlan)

  alerts_api.releaseEntityAlerts(entity_info, host.getAlerts(granularity))
end
