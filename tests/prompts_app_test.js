// Mileage-Offers/app.js, the Mileage prompts app: offers and requests with their
// answers, the race countdown, panel and result, race events and the leaderboard. Runs
// the real app script against small stand-ins for the game's UI (Angular scope, bngApi),
// with Node's standard library only.
//
//   node tests/prompts_app_test.js          (from the repository root)

const fs = require("fs");
const vm = require("vm");
const assert = require("assert");

const SOURCE = "Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.js";
const TEMPLATE = fs.readFileSync("Resources/Client/Mileage/ui/modules/apps/Mileage-Offers/app.html", "utf8");

// A fresh controller; returns its scope and the Lua the app sent to the game.
function load(now) {
	const lua = [];
	let controller = null;
	const handlers = {};
	const scope = {
		$on(name, fn) { handlers[name] = fn; },
		$evalAsync(fn) { fn(); },
		emit(name, data) { handlers[name]({}, data); },
	};
	const clock = {now: now || 1000000};
	const context = {
		angular: {module: () => ({directive() {}, controller(name, deps) { controller = deps[deps.length - 1]; }})},
		bngApi: {engineLua(cmd) { lua.push(cmd); }},
		setInterval() { return 1; }, clearInterval() {},
		Date: {now: () => clock.now},
		console, JSON, TextEncoder, btoa, Math, Number, String, isFinite,
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(SOURCE, "utf8"), context, {filename: SOURCE});
	controller(scope);
	return {scope, lua, clock, context};
}

const b64 = (text) => "require('mime').unb64('" + Buffer.from(text, "utf8").toString("base64") + "')";

const tests = [];
const test = (name, fn) => tests.push([name, fn]);

//== offers =====================================================================

const REQUEST = {id: "o7", kind: "request", from: "Sam_Okafor_the_Long_Name", amount: 3500, secondsLeft: 60};
const RACE = {id: "o8", kind: "race", from: "norto22", amount: 1000, distance: 2400, prize: 500, secondsLeft: 60};

test("a request shows who asks and how much, with Pay and Decline", () => {
	const {scope} = load();
	scope.emit("MileageOffer", REQUEST);
	assert.strictEqual(scope.offers.length, 1);
	const v = scope.offers[0].view;
	assert.strictEqual(v.title, "Sam_Okafor_the_Long_Name asks you for $3,500");
	assert.strictEqual(v.accept, "Pay $3,500");
	assert.strictEqual(v.note, "Counts towards your sending limits on this server.");
});

test("a race challenge shows the finish, the stake and what the winner gets", () => {
	const {scope} = load();
	scope.emit("MileageOffer", RACE);
	const v = scope.offers[0].view;
	assert.strictEqual(v.title, "norto22 challenges you to a race");
	assert.deepStrictEqual([...v.rows].map((r) => r.label + ": " + r.value), [
		"Finish: 2.4 km from them", "Stake: $1,000 each", "Winner gets: $2,000 + $500 server prize"]);
	assert.ok(v.note.includes("Leaving mid-race loses your stake."));
	assert.strictEqual(v.accept, "Accept");
});

test("a race without a stake or prize says so", () => {
	const {scope} = load();
	scope.emit("MileageOffer", Object.assign({}, RACE, {amount: 0, prize: 0}));
	const v = scope.offers[0].view;
	assert.deepStrictEqual([...v.rows].map((r) => r.value), ["2.4 km from them", "No stake"]);
	assert.ok(!v.note.includes("stake"));
});

test("an answer goes to the game once, with the id encoded, and the card goes", () => {
	const {scope, lua} = load();
	scope.emit("MileageOffer", REQUEST);
	const offer = scope.offers[0];
	scope.answer(offer, true);
	scope.answer(offer, true);
	const sent = lua.filter((cmd) => cmd.includes("mileage_offers.answer"));
	assert.deepStrictEqual(sent, ["if mileage_offers then mileage_offers.answer(" + b64("o7") + ", true) end"]);
	assert.strictEqual(scope.offers.length, 0, "card removed");
	scope.emit("MileageOffer", RACE);
	scope.answer(scope.offers[0], false);
	assert.ok(lua.includes("if mileage_offers then mileage_offers.answer(" + b64("o8") + ", false) end"), "decline");
});

test("a closed offer leaves the app; the same offer shown twice is one card", () => {
	const {scope} = load();
	scope.emit("MileageOffer", REQUEST);
	scope.emit("MileageOffer", REQUEST);
	scope.emit("MileageOffer", RACE);
	assert.strictEqual(scope.offers.length, 2);
	scope.emit("MileageOfferClosed", {id: "o7", why: "expired"});
	assert.deepStrictEqual([...scope.offers].map((o) => o.id), ["o8"]);
});

test("the time bar runs down over the offer's seconds", () => {
	const {scope, clock} = load();
	scope.emit("MileageOffer", REQUEST);
	const offer = scope.offers[0];
	assert.strictEqual(scope.barWidth(offer), "100%");
	clock.now += 30000;
	assert.strictEqual(scope.barWidth(offer), "50%");
	clock.now += 60000;
	assert.strictEqual(scope.barWidth(offer), "0%");
});

test("the app asks the game for open offers when it loads", () => {
	const {lua} = load();
	assert.ok(lua.includes("if mileage_offers then mileage_offers.sendState() end"));
});

//== the template ================================================================

test("the template binds every text as text, never as markup", () => {
	assert.ok(!/ng-bind-html|innerHTML/.test(TEMPLATE), "no markup binding");
	assert.ok(!/\{\{/.test(TEMPLATE), "no interpolation either: ng-bind only");
	assert.ok(/ng-bind="offer\.view\.title"/.test(TEMPLATE), "title bound as text");
});

test("every top-level declaration can be evaluated twice", () => {
	const source = fs.readFileSync(SOURCE, "utf8");
	assert.ok(!/^(let|const) /m.test(source), "no top-level let or const");
	const context = {
		angular: {module: () => ({directive() {}, controller() {}})},
		bngApi: {engineLua() {}}, TextEncoder, btoa,
	};
	vm.createContext(context);
	vm.runInContext(source, context);
	vm.runInContext(source, context);
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
