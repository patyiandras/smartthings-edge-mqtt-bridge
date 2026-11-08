// node st-edge/test/run.js [test/x.lua]  -- runs bridge_test.lua (default) on fengari (Lua 5.3 in JS)
// fengari: npm i fengari (st-edge/.tmp alatt van telepitve)
const path = require("path");
// fengari: "npm i fengari" (st-edge/.tmp alatt, vagy barhol, ahonnan a require megtalalja)
let fengari;
try { fengari = require(path.join(__dirname, "..", ".tmp", "node_modules", "fengari")); }
catch (e) { fengari = require("fengari"); }
const { lua, lauxlib, lualib, to_luastring } = fengari;

process.chdir(path.join(__dirname, ".."));
const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
const status = lauxlib.luaL_dofile(L, to_luastring(process.argv[2] || "test/bridge_test.lua"));
if (status !== lua.LUA_OK) {
  console.error("FAIL:", lua.lua_tojsstring(L, -1));
  process.exit(1);
}
