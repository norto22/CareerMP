// Mileage prompts: race challenges and money requests to this player, the race
// countdown, race panel and result, race events and the server leaderboard. Fed by the
// game's Mileage extensions through guihooks (mileage/offers.lua and the race, event and
// leaderboard extensions); every answer goes back through bngApi.engineLua with ids and
// names base64-encoded. Every text from the server or another player is bound as text.
//
// NOTE: top-level declarations must be `var` or function declarations: the game's UI
// app service evaluates app.js again in the same scope when it refreshes apps, and a
// repeated top-level `let` or `const` would stop the directive from registering.

var mileageOffersApp = angular.module('beamng.apps');
mileageOffersApp.directive('mileageoffers', [function () {
	return {
		templateUrl: '/ui/modules/apps/Mileage-Offers/app.html',
		replace: true,
		restrict: 'EA',
		scope: true
	};
}]);

mileageOffersApp.controller('MileageOffers', ['$scope', function ($scope) {
	$scope.offers = [];

	function view(offer) {
		var from = String(offer.from || "");
		if (offer.kind === "race") {
			var stake = Number(offer.amount) || 0;
			var prize = Number(offer.prize) || 0;
			var wins = stake > 0 ? moDollars(stake * 2) : "";
			if (prize > 0) wins = (wins ? wins + " + " : "") + moDollars(prize) + " server prize";
			var rows = [
				{label: "Finish", value: moKm(offer.distance) + " from them"},
				{label: "Stake", value: stake > 0 ? moDollars(stake) + " each" : "No stake"},
			];
			if (wins) rows.push({label: "Winner gets", value: wins});
			return {
				title: from + " challenges you to a race",
				rows: rows,
				note: "Accepting moves your car next to " + from + "'s." +
					(stake > 0 ? " Leaving mid-race loses your stake." : ""),
				accept: "Accept",
			};
		}
		return {
			title: from + " asks you for " + moDollars(offer.amount),
			rows: [],
			note: "Counts towards your sending limits on this server.",
			accept: "Pay " + moDollars(offer.amount),
		};
	}

	function removeOffer(id) {
		$scope.offers = $scope.offers.filter(function (o) { return o.id !== id; });
	}

	$scope.$on('MileageOffer', function (event, data) {
		if (!data || typeof data.id !== "string") return;
		$scope.$evalAsync(function () {
			removeOffer(data.id);
			var seconds = Number(data.secondsLeft || data.expires) || 60;
			$scope.offers.push({
				id: data.id, kind: data.kind, from: data.from, amount: data.amount,
				seconds: seconds, shownAt: Date.now(), view: view(data),
			});
		});
	});

	$scope.$on('MileageOfferClosed', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () { removeOffer(data.id); });
	});

	// How much of the offer's time is left, as a CSS width.
	$scope.barWidth = function (offer) {
		var left = 1 - (Date.now() - offer.shownAt) / (offer.seconds * 1000);
		return Math.max(0, Math.min(1, left)) * 100 + "%";
	};

	$scope.answer = function (offer, accept) {
		if (offer.answered) return;
		offer.answered = true;
		removeOffer(offer.id);
		bngApi.engineLua('if mileage_offers then mileage_offers.answer(' + moLuaString(offer.id) + ', ' +
			(accept ? 'true' : 'false') + ') end');
	};

	//== a street race: countdown, race panel, result ============================

	$scope.race = null;

	function raceView(data) {
		var other = String(data.other || "");
		var stake = Number(data.stake) || 0;
		var stakeText = stake > 0 ? moDollars(stake) + " stake" : "no stake";
		switch (data.phase) {
		case "staking":
			return {title: "Race vs " + other, note: stake > 0 ? "Taking both stakes..." : "Getting ready..."};
		case "lining up":
			return {title: "Race vs " + other, note: "Lining up beside each other..."};
		case "countdown":
			return {big: String(data.count), note: "vs " + other + " · " + stakeText};
		case "go":
			return {big: "GO", note: "vs " + other + " · " + stakeText};
		case "racing":
			return {
				title: "Racing " + other,
				big: moTime(data.elapsed),
				note: (typeof data.distance === "number" ? "Finish " + moKm(data.distance) + " · " : "") +
					"follow your map route",
				giveUp: stake > 0 ? "Give up (lose " + moDollars(stake) + ")" : "Give up",
			};
		case "finished":
			return {title: "Finished in " + moTime(data.elapsed), note: "Waiting for " + other + "..."};
		case "calledOff":
			return {title: "Race called off", note: String(data.why || "") +
				(stake > 0 ? ". Your " + moDollars(stake) + " stake is back." : "."), close: true};
		case "result":
			return resultView(data);
		}
		return null;
	}

	function resultView(data) {
		var you = String(data.you || ""), other = String(data.other || "");
		var times = data.times || {};
		var stake = Number(data.stake) || 0, pot = Number(data.pot) || 0, prize = Number(data.prize) || 0;
		var rows = [];
		var mine = times[you], theirs = times[other];
		if (typeof mine === "number") {
			rows.push({label: "Your time", value: moTime(mine)});
		} else if (data.gaveUp === you) {
			rows.push({label: "Your time", value: data.why === "left" ? "did not finish: you left the race"
				: "did not finish: you gave up"});
		}
		if (typeof theirs === "number") {
			var gap = typeof mine === "number" ? " (" + (theirs >= mine ? "+" : "-") +
				Math.abs(theirs - mine).toFixed(1) + " s)" : "";
			rows.push({label: other, value: moTime(theirs) + gap});
		} else if (data.gaveUp === other) {
			rows.push({label: other, value: data.why === "left" ? "left the race" : "gave up"});
		}
		if (!data.winner) {
			return {title: "No winner", rows: rows, close: true,
				note: (data.why === "timeout" ? "Nobody reached the finish in time." : "The race ended without a winner.") +
					(stake > 0 ? " Your " + moDollars(stake) + " stake is back." : "")};
		}
		if (data.winner === you) {
			var parts = [];
			if (pot > 0) parts.push(moDollars(pot) + " stakes");
			if (prize > 0) parts.push(moDollars(prize) + " prize");
			if (parts.length > 0) rows.push({label: "You get", value: parts.join(" + ")});
			return {title: "You won", rows: rows, close: true};
		}
		if (stake > 0) rows.push({label: "You lost", value: "your " + moDollars(stake) + " stake"});
		return {title: String(data.winner) + " won", rows: rows, close: true};
	}

	$scope.$on('MileageRace', function (event, data) {
		if (!data) return;
		$scope.$evalAsync(function () {
			var shown = raceView(data);
			$scope.race = shown ? {id: data.race, phase: data.phase, view: shown} : null;
		});
	});

	$scope.giveUp = function () {
		bngApi.engineLua('if mileage_streetRace then mileage_streetRace.giveUp() end');
	};

	$scope.closeRace = function () {
		$scope.race = null;
	};

	// Redraws the time bars.
	var ticker = setInterval(function () {
		if ($scope.offers.length > 0) $scope.$evalAsync(function () {});
	}, 500);
	$scope.$on('$destroy', function () { clearInterval(ticker); });

	bngApi.engineLua('if mileage_offers then mileage_offers.sendState() end');
	bngApi.engineLua('if mileage_streetRace then mileage_streetRace.sendState() end');
}]);

// Seconds as m:ss.s.
function moTime(seconds) {
	var s = Number(seconds);
	if (!isFinite(s) || s < 0) return "-";
	var minutes = Math.floor(s / 60);
	var rest = s - minutes * 60;
	return minutes + ":" + (rest < 10 ? "0" : "") + rest.toFixed(1);
}

function moDollars(n) {
	return "$" + Number(n || 0).toLocaleString("en-US");
}

function moKm(metres) {
	var m = Number(metres);
	if (!isFinite(m)) return "?";
	return (m / 1000).toFixed(1) + " km";
}

// Text from the UI reaches Lua base64-encoded (as UTF-8) and decoded there, so nothing
// in it can end the string and become code.
function moLuaString(text) {
	var bytes = new TextEncoder().encode(String(text));
	var binary = "";
	for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
	return "require('mime').unb64('" + btoa(binary) + "')";
}
