# SmartThings Edge → MQTT bridge for Home Assistant

Run your SmartThings hub's **Zigbee and Z-Wave devices locally in Home Assistant**, over MQTT,
without the SmartThings cloud, and without re-pairing anything.

The drivers are the regular SmartThings Edge drivers (the official SmartThings ones and
[Mariano's community drivers](https://github.com/Mariano-Github/Edge-Drivers-Beta)), with a small
bridge module built in. The devices keep working in the SmartThings app, in routines and in STHM
exactly as before. In addition, every device shows up in Home Assistant through MQTT discovery, and
Home Assistant controls it directly on the hub, on your LAN.

- **Local**: hub ⇄ MQTT broker ⇄ Home Assistant. It keeps working when the internet is down.
- **Fast**: events usually reach HA ~0.3 s before the SmartThings cloud integration would deliver them.
- **No re-pairing**: you only switch the device's driver in the SmartThings app.
- **Both ways**: state goes to HA. Commands from HA go through the driver's own command handlers, so they
  behave exactly like commands from the SmartThings app.

> Unofficial community project. Not affiliated with Samsung SmartThings, Home Assistant or
> Mariano Colmenarejo. Use at your own risk.

## How it works

Every Edge driver gets the `st_bridge` module attached (one line before `driver:run()`):

- Each capability event the driver emits is also published to MQTT, retained:
  `stb/<device_id>/<component>/<capability>/<attribute>`.
- HA commands arrive on `stbc/<device_id>/<component>/<capability>/<command>` and are injected into the
  driver's capability dispatcher.
- Home Assistant entities are created with **MQTT discovery** from the device profile:
  light, switch, cover, binary_sensor, sensor, event (buttons), button (refresh).
- The hub-side "native" handlers are disabled, because with them the hub would emit events without
  running the Lua code, and the bridge would never see them.
- Every driver also gets a diagnostic device in HA, "ST Bridge <driver>": online, memory, uptime,
  events, commands, MQTT reconnects, and the last warning/error lines of the driver (`… last log`).
  This is useful because the hub's own log is only reachable on the LAN.
- Per-device availability: mains-powered switches (plugs, relays, lamps) that stay silent get a
  refresh after 10 minutes, and become `unavailable` in HA after 20 minutes without an answer.
  Battery devices, covers and sensors are always available.

## Drivers

All drivers are published as "<original name> (MQTT Bridge)". They install **next to** the original
driver (different package key), so you can switch devices one by one and switch back at any time.

| Driver | Based on | Typical devices |
|---|---|---|
| Zigbee Switch (MQTT Bridge) | SmartThings `zigbee-switch` | Zigbee bulbs, plugs, IKEA, Aqara switches |
| Zigbee Button | SmartThings `zigbee-button` | IKEA remotes, buttons |
| Zigbee Contact | SmartThings `zigbee-contact` | door/window sensors |
| Zigbee Humidity Sensor | SmartThings `zigbee-humidity-sensor` | temperature/humidity sensors |
| Zigbee Window Treatment | SmartThings `zigbee-window-treatment` | Zigbee blinds |
| Z-Wave Switch | SmartThings `zwave-switch` | Z-Wave relays, plugs, dimmers |
| Z-Wave Sensor | SmartThings `zwave-sensor` | Z-Wave door/motion sensors |
| Z-Wave Window Treatment | SmartThings `zwave-window-treatment` | Qubino Flush Shutter etc. |
| Zigbee Switch Mc | Mariano `zigbee-switch-v6.5` | SONOFF/eWeLink lamps and plugs, Xiaomi plugs |
| Zigbee Light Multifunction Mc | Mariano `zigbee-light-multifunction-v6` | color/CT bulbs, GLEDOPTO controllers |
| Zigbee Motion Sensor Mc | Mariano `zigbee-motion-sensor-v4` | SONOFF SNZB-06P, Aqara/Xiaomi motion |
| Zigbee Contact Mc | Mariano `zigbee-contact-mc-v3` | Aqara door sensors |
| Z-Wave Switch and Child Mc | Mariano `zwave-switch-mc-v4-childs-edge-config` | Qubino Flush 1/2 relays (2 channels) |
| STHM Bridge | own driver | SmartThings Home Monitor state + arming from HA (see below) |
| HA Motion Mirror | own driver | Home Assistant motion sensors as local SmartThings devices (see below) |

Small fixes on top of upstream are in `patches/` (for example: original Xiaomi `lumi.sensor_motion`
support, GLEDOPTO GL-C-007 white channel, Qubino 2-channel relay false "on" reports, Qubino Flush
Shutter "did not start" guard). LAN devices (Cast, Sonos, Shelly, …) and Matter devices are not
part of this, because Home Assistant has native local integrations for them.

## Installation

### 1. MQTT broker and Home Assistant

- An MQTT broker reachable from the hub, for example the **Mosquitto broker** add-on in Home Assistant.
  Create a user for the bridge (e.g. `st_bridge`), or allow anonymous access.
- The Home Assistant **MQTT** integration, with discovery enabled (this is the default).

### 2. Install the drivers on your hub

Open the channel invitation, sign in with your Samsung account, enroll your hub and install the
drivers you need:

**Channel invitation: https://bestow-regional.api.smartthings.com/invite/Boj0k8L37XlA**

### 3. Switch a device to the bridge driver

In the SmartThings app open the device → ⋮ → *Driver* → *Select a different driver* →
choose the "(MQTT Bridge)" variant of its current driver.
Or with the [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli):
`smartthings edge:drivers:switch <deviceId> --hub <hubId> --driver <driverId>`.

### 4. Set the broker: once per driver, on any one of its devices

In the SmartThings app open the settings of **one** device that uses the driver
(device → ⋮ → *Settings*) and fill in:

| Setting | Example |
|---|---|
| MQTT broker host | `192.168.1.10` (your Home Assistant / broker IP) |
| MQTT broker port | `1883` |
| MQTT user name | `st_bridge` (empty = anonymous) |
| MQTT password | … |

The driver has one MQTT connection for all its devices. The first device (by id) that has a broker
host set is used, so you only need to fill in the settings on one device per driver. Within about a
minute the "ST Bridge <driver>" device and the entities appear in Home Assistant
(*Settings → Devices & services → MQTT*).

If the broker cannot be reached, the device keeps working in SmartThings, and the bridge retries
with a backoff of up to 60 s. Spaces at the start or end of the values are ignored.

Troubleshooting: the diagnostic device only appears after the first successful connection, so look
at the **broker log** first (Home Assistant: *Settings → Add-ons → Mosquitto broker → Log*):
- `Client st_bridge_<driver> … disconnected: not authorised` → wrong user name or password.
  Phone keyboards like to capitalise the first letter of the user name. Once connected, the
  diagnostic device's *Last log* shows the earlier attempts, with the user name and password length
  (never the password itself). A password with only letters, digits and simple symbols is the
  safest choice.
- No line from the hub at all → wrong host or port, or a firewall. Use the IP address, because the
  hub cannot resolve `.local` names.

### Entity names

The entity ids come from the SmartThings device label, e.g. `light.kitchen_lamp`. If you used the
SmartThings cloud integration before, its entities already own these ids, so the bridge entities will
get a `_2` suffix. Rename them in Home Assistant if needed. Disable the cloud entities, so a device is
not controlled from two places.

## Own drivers

### STHM Bridge

A virtual LAN device that mirrors the SmartThings Home Monitor state (`armedAway` / `armedStay` /
`disarmed`), as a sensor in HA. It also gives HA an `alarm_control_panel`. Edge drivers cannot read or
change STHM, so:

- three SmartThings rules (Rules API, condition: location attribute `Security`) call `setSthmState`
  on the device;
- arming from HA sets a "request" attribute for 5 s, and SmartThings app routines
  ("if STHM request is …") do the actual arming. Disarming needs the PIN set in the device settings,
  so a bare MQTT message cannot disarm (3 wrong PINs → 5 minutes lockout).

The device has to be created as a hub-local virtual device with the virtual devices API
(`executionTarget: LOCAL`). See the comments in `drivers/sthm-bridge/src/init.lua`. This driver needs some
SmartThings API work to set up; the other drivers do not.

### HA Motion Mirror

Shows Home Assistant motion sensors as local SmartThings motion sensors, so the SmartThings app and STHM
can use sensors that HA receives directly (e.g. an alarm panel moved to ESPHome). HA publishes retained
messages:

```
stmirror/<key>/label    "Kitchen motion (HA)"   -> the device is created on first sight
stmirror/<key>/motion   "active" / "inactive"
```

The devices only have the standard `motionSensor` capability, so they cannot be switched from
anywhere: only HA changes them. The driver needs one device to start: create a hub-local virtual device
with this driver once, and delete it after the mirrored devices appear.

## Building from source

```
git clone --depth 1 https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers.git vendor/SmartThingsEdgeDrivers
git clone --depth 1 https://github.com/Mariano-Github/Edge-Drivers-Beta.git vendor/Edge-Drivers-Beta
pip install pyyaml
python build.py vendor/SmartThingsEdgeDrivers/drivers/SmartThings/zigbee-switch --public
smartthings edge:drivers:package build/public/zigbee-switch-mqtt --channel <yourChannelId>
```

`build.py` works on a copy of the upstream driver: it applies `patches/<driver>/patch.json`, disables
the native handlers, adds the bridge modules and the broker settings to every profile, and attaches
the bridge. `deploy-list.txt` lists the drivers that are published. The patches check that every
replaced text occurs exactly once, so an upstream change cannot silently break a patch.

Without `--public` the broker is baked into the driver from a `.st-bridge.json` file
(`{"host": …, "port": …, "username": …, "password": …}`, path from `ST_BRIDGE_SECRETS`). This is
for private builds only: never publish such a build.

Offline tests (Lua 5.3 on [fengari](https://github.com/fengari-lua/fengari), SmartThings `lua_libs`
from the SmartThingsEdgeDrivers releases in `vendor/lua_libs/`):

```
npm i fengari
node test/run.js                              # bridge
node test/run.js test/public_broker_test.lua  # broker from device settings
```

Notes from deployment:
- Upload with `--channel` but **without** `--hub`, wait ~90 s, then install. An immediate install
  can fail with a 404, and that version then cannot be installed.
- After about 10 uploads in a row the API rate-limits (`TooManyRequestError`); wait a few minutes.

## License and credits

Apache License 2.0, see `LICENSE` and `NOTICE`. The drivers are built from
[SmartThingsEdgeDrivers](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers)
(© SmartThings, Apache 2.0) and [Edge-Drivers-Beta](https://github.com/Mariano-Github/Edge-Drivers-Beta)
(© Mariano Colmenarejo, Apache 2.0). All credit for the device support goes to them. This project only
adds the MQTT bridge and the patches listed above.
