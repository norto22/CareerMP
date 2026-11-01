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

	// Redraws the time bars.
	var ticker = setInterval(function () {
		if ($scope.offers.length > 0) $scope.$evalAsync(function () {});
	}, 500);
	$scope.$on('$destroy', function () { clearInterval(ticker); });

	bngApi.engineLua('if mileage_offers then mileage_offers.sendState() end');
}]);

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
