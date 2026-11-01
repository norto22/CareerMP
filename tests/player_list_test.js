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
	return {scope, table, lua, page: byId, context};
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

// The banner's template, from the real app.html.
const TEMPLATE = fs.readFileSync("Resources/Client/CareerMP/ui/modules/apps/CareerMP-PlayerList/app.html", "utf8");

// The markup of the element opened at `start`, up to its matching </div>.
function divBlock(start) {
	const tag = /<\/?div\b/g;
	tag.lastIndex = start;
	let depth = 0, m;
	while ((m = tag.exec(TEMPLATE))) {
		depth += m[0] === "<div" ? 1 : -1;
		if (depth === 0) return TEMPLATE.slice(start, TEMPLATE.indexOf(">", m.index) + 1);
	}
	throw new Error("unclosed div");
}

// Evaluates an Angular expression from the template against the controller's scope.
function evalExpr(expr, scope) {
	return new Function("s", "with (s) { return (" + expr + "); }")(scope);
}

test("an update that arrives after the loss but before the screen redraws is ignored", () => {
	const {scope, table} = load();
	const pending = [];
	scope.$evalAsync = (fn) => pending.push(fn);
	scope.emit("onBeamMPPlayerList", PLAYERS);
	scope.emit("careerMPConnectionLost", {message: "Lost connection to the server", saveState: "saving"});
	scope.emit("onBeamMPPlayerList", PLAYERS);
	assert.strictEqual(table.rows.length, 1, "rows before the redraw");
	pending.forEach((fn) => fn());
	assert.strictEqual(scope.connection.lost, true, "banner shown after the redraw");
});

test("the banner sits outside the folding list, so it shows with the list folded away", () => {
	const start = TEMPLATE.indexOf('<div id="connection-banner"');
	assert.ok(start >= 0, "banner in the template");
	const banner = divBlock(start);
	assert.ok(!banner.includes('id="plist-container"') && !banner.includes('id="main-container"'), "banner holds no list");
	const list = TEMPLATE.indexOf('<div id="plist-container"');
	assert.ok(!divBlock(list).includes("connection-banner"), "list holds no banner");
});

test("the banner shows the message and save line as text, never as markup", () => {
	const banner = divBlock(TEMPLATE.indexOf('<div id="connection-banner"'));
	assert.ok(/class="connection-message" ng-bind="connection\.message"/.test(banner), "message bound as text");
	assert.ok(/class="connection-save" ng-bind="saveText\(\)"/.test(banner), "save line bound as text");
	assert.ok(!/ng-bind-html|innerHTML/.test(banner), "no markup binding");
});

test("Try saving again shows only after a failed save; Return to menu always", () => {
	const {scope} = load();
	const banner = divBlock(TEMPLATE.indexOf('<div id="connection-banner"'));
	const retry = banner.match(/<button[^>]*ng-show="([^"]*)"[^>]*ng-click="retrySave\(\)"[^>]*>Try saving again</);
	assert.ok(retry, "Try saving again button with ng-show");
	const shown = (state) => {
		scope.emit("careerMPConnectionLost", {message: "Lost connection to the server", saveState: state, saved: state === "saved"});
		return Boolean(evalExpr(retry[1], scope));
	};
	assert.strictEqual(shown("saving"), false, "while saving");
	assert.strictEqual(shown("saved"), false, "after a save");
	assert.strictEqual(shown("failed"), true, "after a failed save");
	assert.ok(/<button(?![^>]*ng-show)[^>]*ng-click="returnToMenu\(\)"[^>]*>Return to menu</.test(banner), "Return to menu always shown");
});

test("folding the list hides it and unfolding shows it again", () => {
	const {page, context} = load();
	context.hideList();
	assert.strictEqual(page("plist-container").style.display, "none", "folded");
	assert.strictEqual(page("show-button").innerHTML, "&lt;", "fold button");
	context.showList();
	assert.strictEqual(page("plist-container").style.display, "block", "unfolded");
	assert.strictEqual(page("show-button").innerHTML, "&gt;", "unfold button");
});

test("every function in the app script is declared once", () => {
	const source = fs.readFileSync(SOURCE, "utf8");
	const counts = {};
	for (const m of source.matchAll(/^function (\w+)\s*\(/gm)) counts[m[1]] = (counts[m[1]] || 0) + 1;
	const twice = Object.keys(counts).filter((name) => counts[name] > 1);
	assert.deepStrictEqual(twice, [], "functions declared more than once");
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
