// CareerMP-PlayerList/app.js: the lost-connection banner, and the player rows it keeps
// empty while it shows. Runs the real app script against small stand-ins for the
// game's UI (Angular scope, bngApi, the page), with Node's standard library only.
//
//   node tests/player_list_test.js          (from the repository root)

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE = "Resources/Client/CareerMP/ui/modules/apps/CareerMP-PlayerList/app.js";

function element(id) {
	const el = {
		id, rows: [], children: [], cells: [], style: {setProperty() {}}, attributes: {},
		offsetHeight: 0, textContent: "",
		setAttribute(k, v) { el.attributes[k] = v; },
		getAttribute(k) { return el.attributes[k]; },
		appendChild(c) { el.children.push(c); return c; },
		removeChild() {},
		addEventListener() {},
		insertRow(i) { const r = element(); el.rows.splice(i, 0, r); return r; },
		deleteRow(i) { el.rows.splice(i, 1); },
		insertCell(i) { const c = element(); el.cells.splice(i, 0, c); return c; },
	};
	return el;
}

// A fresh page and controller; returns the controller's scope, the players table and
// the Lua the app sent to the game.
function load() {
	const page = {};
	const byId = (id) => (page[id] = page[id] || element(id));
	const table = byId("players-table");
	table.rows.push(element()); // the header row stays
	const lua = [];
	let controller = null;
	const handlers = {};
	const scope = {
		$on(name, fn) { handlers[name] = fn; },
		$evalAsync(fn) { fn(); },
		emit(name, data) { handlers[name]({}, data); },
	};
	const context = {
		angular: {module: () => ({directive() {}, controller(name, deps) { controller = deps[deps.length - 1]; }})},
		bngApi: {engineLua(cmd) { lua.push(cmd); }},
		document: {getElementById: byId, createElement: () => element(), createTextNode: (t) => ({text: t})},
		localStorage: {getItem() { return null; }, setItem() {}},
		console, JSON, TextEncoder, btoa,
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(SOURCE, "utf8"), context, {filename: SOURCE});
	controller(scope, null, {values: {}});
	return {scope, table, lua};
}

const PLAYERS = JSON.stringify([
	{id: 0, name: "Ann", formatted_name: "Ann"},
	{id: 1, name: "Bob", formatted_name: "Bob"},
]);

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

test("a player list update fills the table", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 3, "header and two players");
});

test("losing the connection empties the list and keeps it empty through BeamMP's updates", () => {
	const {scope, table} = load();
	scope.emit("onBeamMPPlayerList", PLAYERS);
	scope.emit("careerMPConnectionLost", {message: "Lost connection to the server", saveState: "saved", saved: true});
	assert.strictEqual(table.rows.length, 1, "rows after the loss");
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 1, "rows after a later update");
	assert.strictEqual(scope.connection.lost, true, "banner shown");
	assert.strictEqual(scope.connection.message, "Lost connection to the server", "banner message");
	assert.strictEqual(scope.saveText(), "Your career was saved.", "save line");
});

test("being heard again shows the players again", () => {
	const {scope, table, lua} = load();
	scope.emit("careerMPConnectionLost", {message: "Lost connection to the server", saveState: "saved"});
	scope.emit("careerMPConnectionRestored");
	assert.strictEqual(scope.connection.lost, false, "banner hidden");
	assert.ok(lua.some((cmd) => cmd.includes("UI.updatePlayersList()")), "list asked for again");
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 3, "rows after the update");
});

test("the save line follows the save state and never claims an unconfirmed save", () => {
	const {scope} = load();
	const line = (data) => { scope.emit("careerMPConnectionLost", data); return scope.saveText(); };
	assert.strictEqual(line({saveState: "saving", saved: false}), "Saving your career...");
	assert.strictEqual(line({saveState: "failed", saved: false}), "Your career could not be saved.");
	assert.strictEqual(line({saveState: "saved", saved: true}), "Your career was saved.");
	assert.strictEqual(line({}), "Your career could not be saved.", "no state at all");
});

test("the buttons ask the game to try the save again and to return to the menu", () => {
	const {scope, lua} = load();
	scope.retrySave();
	scope.returnToMenu();
	assert.ok(lua.includes("if careerMP_connectionWatch then careerMP_connectionWatch.retrySave() end"), "retry");
	assert.ok(lua.includes("MPCoreNetwork.leaveServer(true)"), "return to menu");
});

test("the app asks for the current state when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if careerMP_connectionWatch then careerMP_connectionWatch.sendState() end"));
});

let failed = 0;
for (const [name, fn] of tests) {
	try {
		fn();
		console.log("ok   " + name);
	} catch (err) {
		failed++;
		console.log("FAIL " + name + "\n     " + err.message);
	}
}
console.log(`${tests.length - failed} passed, ${failed} failed`);
process.exitCode = failed > 0 ? 1 : 0;
