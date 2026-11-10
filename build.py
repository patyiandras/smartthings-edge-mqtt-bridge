"""
build.py -- egy upstream Edge drivert MQTT-hidas (st_bridge) valtozatta alakit.

    python st-edge/build.py <driver-mappa> [--key <bridge_key>] [--public]

  pl. python st-edge/build.py vendor/SmartThingsEdgeDrivers/drivers/SmartThings/zigbee-switch

A driver-mappa az st-edge/-hez relativ (vagy abszolut). Kimenet: st-edge/build/<packageKey>-stbridge/
A forrast NEM modositja; minden futas tiszta masolatbol indul, igy az upstream
frissitese = git pull a vendor/ alatt + ujrabuildeles.

Amit a masolaton csinal:
  1. config.yml: nev + " (ST Bridge)", packageKey + "-stbridge", permissions-be lan: {}
  2. native_capability_*_enabled = true -> false (kulonben a hub Lua nelkul kezelne az esemenyeket)
  3. a bridge/*.lua modulokat bemasolja a src/-be
  4. src/st_bridge_config.lua a HA-repo gyokereben levo .st-bridge.json-bol (gitignore-olt, titok!)
  5. init.lua: require("st_bridge").attach(<driver>) az utolso <driver>:run() ele
  6. src/test torlese (csomagmeret)

--public: kozzeteheto valtozat (titok nelkul). Nev + " (MQTT Bridge)", packageKey + "-mqtt"
  (mas driverId, mint a sajat "-stbridge" buildeke), ures st_bridge_config.lua, es minden
  profilba bekerulnek a broker-beallitasok (stbMqttHost/Port/User/Pass): a felhasznalo a
  SmartThings appban a driver BARMELY eszkozenel adja meg. Kimenet: st-edge/build/public/.
"""
import json
import os
import yaml
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent          # st-edge/
SECRETS = Path(os.environ.get("ST_BRIDGE_SECRETS") or ROOT.parent / ".st-bridge.json")  # gitignore-olt


def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    src = Path(argv[1])
    if not src.is_absolute():
        src = ROOT / src
    public = "--public" in argv
    key = None
    if "--key" in argv:
        key = argv[argv.index("--key") + 1]
    if not (src / "config.yml").exists():
        sys.exit(f"nincs config.yml: {src}")
    if public:
        secrets = {}
    elif not SECRETS.exists():
        sys.exit(f"hianyzik {SECRETS} -- minta: "
                 '{"host": "192.168.1.10", "port": 1883, "username": "st_bridge", "password": "..."}')
    else:
        secrets = json.loads(SECRETS.read_text(encoding="utf-8"))

    cfg_text = (src / "config.yml").read_text(encoding="utf-8")
    m = re.search(r"^packageKey:\s*['\"]?([^'\"\n]+)['\"]?\s*$", cfg_text, re.M)
    if not m:
        sys.exit("packageKey nem talalhato a config.yml-ben")
    pkg = m.group(1).strip()
    # a SmartThings max. 36 karakteres packageKey-t enged; csak a tul hosszut roviditjuk,
    # hogy a mar feltoltott driverek kulcsa (es igy driverId-ja) ne valtozzon
    suffix = "-mqtt" if public else "-stbridge"
    new_key = f"{pkg}{suffix}" if len(pkg) + len(suffix) <= 36 else f"{pkg[:36 - len(suffix)]}{suffix}"
    out = ROOT / "build" / ("public" if public else "") / new_key
    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("test", "tests", "*.md"))

    # 0. sajat javitasok (st-edge/patches/<forras-mappa>/patch.json) -- pl. hianyzo fingerprint.
    #    Minden "old"-nak pontosan egyszer kell szerepelnie, kulonben a build megall: igy egy
    #    upstream-valtozas nem csuszik at csendben.
    patch_file = ROOT / "patches" / src.name / "patch.json"
    patched = 0
    if patch_file.exists():
        for op in json.loads(patch_file.read_text(encoding="utf-8"))["ops"]:
            if "copy" in op:
                shutil.copy2(out / op["copy"], out / op["to"])
            elif "add" in op:  # sajat fajl a patch-mappabol (pl. uj modul, profil)
                shutil.copy2(patch_file.parent / op["add"], out / op["to"])
            elif "vendor_copy" in op:  # fajl atvetele egy masik upstream driverbol (st-edge/-hez relativ)
                shutil.copy2(ROOT / op["vendor_copy"], out / op["to"])
            elif "append" in op:
                f = out / op["file"]
                t = f.read_text(encoding="utf-8")
                f.write_text(t.rstrip("\n") + "\n" + op["append"], encoding="utf-8", newline="\n")
            else:
                f = out / op["file"]
                t = f.read_text(encoding="utf-8").replace("\r\n", "\n")
                if t.count(op["old"]) != 1:
                    sys.exit(f"patch nem alkalmazhato ({t.count(op['old'])} talalat): {op['file']}: {op['old'][:60]!r}")
                f.write_text(t.replace(op["old"], op["new"]), encoding="utf-8", newline="\n")
            patched += 1

    # 1. config.yml
    label = "MQTT Bridge" if public else "ST Bridge"
    cfg_text = re.sub(r"^(name:\s*)(['\"]?)(.+?)\2\s*$", lambda mm: f"{mm.group(1)}'{mm.group(3)} ({label})'",
                      cfg_text, count=1, flags=re.M)
    cfg_text = re.sub(r"^(packageKey:\s*).*$", rf"\1'{new_key}'", cfg_text, count=1, flags=re.M)
    if not re.search(r"^\s+lan:", cfg_text, re.M):
        cfg_text = re.sub(r"^(permissions:\s*\n)", r"\1  lan: {}\n", cfg_text, count=1, flags=re.M)
    if public:
        cfg_text = public_metadata(cfg_text, src)
    (out / "config.yml").write_text(cfg_text, encoding="utf-8", newline="\n")

    # 2. native handlers off
    patched_native = 0
    for f in (out / "src").rglob("*.lua"):
        t = f.read_text(encoding="utf-8")
        n = re.sub(r"(native_capability_(?:cmds|attrs)_enabled\s*=\s*)true", r"\1false", t)
        if n != t:
            patched_native += 1
            f.write_text(n, encoding="utf-8", newline="\n")

    # 3. bridge modules
    for f in (ROOT / "bridge").glob("*.lua"):
        shutil.copy2(f, out / "src" / f.name)

    # 4. config (secrets; public build: empty -> broker from device preferences)
    if public:
        add_broker_preferences(out / "profiles")
    conf = [
        "-- GENERALT (st-edge/build.py), ne szerkeszd. Forras: .st-bridge.json",
        "return {",
        f"  host = {lua_str(secrets['host'])}," if secrets.get("host") else "",
        f"  port = {int(secrets.get('port', 1883))},",
        f"  username = {lua_str(secrets['username'])}," if secrets.get("username") else "",
        f"  password = {lua_str(secrets['password'])}," if secrets.get("password") else "",
        f"  bridge_key = {lua_str(key or (new_key if public else pkg))},",
        "}",
    ]
    (out / "src" / "st_bridge_config.lua").write_text("\n".join(l for l in conf if l) + "\n",
                                                      encoding="utf-8", newline="\n")

    # 5. attach before run()
    init = out / "src" / "init.lua"
    t = init.read_text(encoding="utf-8")
    runs = list(re.finditer(r"^([ \t]*)([A-Za-z_][\w]*):run\(\)", t, re.M))
    if not runs:
        sys.exit("nem talalom a <driver>:run() hivast az init.lua-ban")
    r = runs[-1]
    line = f'{r.group(1)}require("st_bridge").attach({r.group(2)})\n'
    t = t[:r.start()] + line + t[r.start():]
    init.write_text(t, encoding="utf-8", newline="\n")

    print(f"OK: {out}")
    print(f"  driver valtozo: {r.group(2)}, native-flag patch: {patched_native} fajl, sajat patch: {patched} lepes, kulcs: {key or pkg}")


PUBLIC_REPO = "https://github.com/patyiandras/smartthings-edge-mqtt-bridge"


def public_metadata(cfg_text, src):
    """Kozzeteheto build: a leiras es a tamogatasi link ne a Samsungra/Marianora mutasson
    (az upstreambol orokolt "https://support.smartthings.com" felrevezeto lenne)."""
    m = re.search(r"^description:\s*(['\"]?)(.*?)\1\s*$", cfg_text, re.M)
    orig = m.group(2).strip() if m else ""
    if "Mariano-Github" in orig or "Edge-Drivers-Beta" in str(src):
        based = "based on Mariano's community driver (" + (orig or src.name) + ")"
    elif "SmartThingsEdgeDrivers" in str(src):
        based = "based on the open-source SmartThings driver (" + (orig or src.name) + ")"
    else:
        based = orig
    if based == orig:  # sajat driver (drivers/): a sajat leirasa marad
        desc = orig + ". Unofficial community driver, not supported by Samsung. Help: " + PUBLIC_REPO
    else:
        desc = "Community driver with a local MQTT bridge to Home Assistant, " + based \
            + ". Unofficial, not supported by Samsung. Help: " + PUBLIC_REPO
    line = "description: " + json.dumps(desc)
    cfg_text = re.sub(r"^description:.*$", lambda _: line, cfg_text, count=1, flags=re.M) if m \
        else cfg_text.rstrip("\n") + "\n" + line + "\n"
    support = "vendorSupportInformation: " + json.dumps(PUBLIC_REPO + "/issues")
    if re.search(r"^vendorSupportInformation:", cfg_text, re.M):
        cfg_text = re.sub(r"^vendorSupportInformation:.*$", lambda _: support, cfg_text, count=1, flags=re.M)
    else:
        cfg_text = cfg_text.rstrip("\n") + "\n" + support + "\n"
    return cfg_text


BROKER_PREFS = [
    {"name": "stbMqttHost", "title": "MQTT broker host",
     "description": "MQTT bridge: IP address or host name of the MQTT broker (e.g. the Home Assistant "
                    "Mosquitto add-on). Set it on ONE device of this driver; it applies to all of them.",
     "required": False, "preferenceType": "string",
     "definition": {"stringType": "text", "minLength": 0, "maxLength": 100, "default": ""}},
    {"name": "stbMqttPort", "title": "MQTT broker port", "description": "Default: 1883",
     "required": False, "preferenceType": "integer",
     "definition": {"minimum": 1, "maximum": 65535, "default": 1883}},
    {"name": "stbMqttUser", "title": "MQTT user name", "description": "Leave empty for anonymous access",
     "required": False, "preferenceType": "string",
     "definition": {"stringType": "text", "minLength": 0, "maxLength": 100, "default": ""}},
    {"name": "stbMqttPass", "title": "MQTT password",
     "required": False, "preferenceType": "string",
     "definition": {"stringType": "password", "minLength": 0, "maxLength": 100, "default": ""}},
]


NL, TAB, CR = chr(10), chr(9), chr(13)  # (sortores / tab / CR -- escape nelkul)


def add_broker_preferences(profiles_dir):
    """A kozzeteheto buildben minden profil megkapja a broker-beallitasokat.
    Szoveges beszuras, NEM yaml-ujrairas: a PyYAML a YAML 1.1 szerint az on/off/yes/no ertekeket
    logikaiva alakitana, es a SmartThings elutasitja (vagy csendben mast jelentene) a profilt.
    Az upstream szoveg a beszurt blokkon kivul bajtra azonos marad."""
    ws = "[ " + TAB + "]*"
    for f in sorted(profiles_dir.glob("*.y*ml")):
        text = f.read_text(encoding="utf-8").replace(CR + NL, NL)
        if "stbMqttHost" in text:
            continue
        m = re.search("^preferences:" + ws + "(?:" + re.escape("[]") + ")?" + ws + "$", text, re.M)
        if m and "[" in m.group(0):  # "preferences: []" -> ures lista helyett a mieink
            text = text[:m.start()] + "preferences:" + text[m.end():]
            m = re.search("^preferences:" + ws + "$", text, re.M)
        if m:
            rest = text[m.end():]
            im = re.search("^(" + ws + ")- ", rest, re.M)
            indent = im.group(1) if im else ""
            dump = yaml.safe_dump(BROKER_PREFS, sort_keys=False, allow_unicode=True)
            block = "".join(indent + line + NL for line in dump.splitlines())
            text = text[:m.end()] + NL + block.rstrip(NL) + rest
        else:
            dump = yaml.safe_dump({"preferences": BROKER_PREFS}, sort_keys=False, allow_unicode=True)
            text = text.rstrip(NL) + NL + dump
        yaml.safe_load(text.replace(TAB, "  "))  # ervenyes YAML maradt?
        f.write_text(text, encoding="utf-8", newline=NL)


if __name__ == "__main__":
    main(sys.argv)
