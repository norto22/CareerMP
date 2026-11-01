// Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
// Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
// SPDX-License-Identifier: AGPL-3.0-or-later

var connected = false;
var connectionLost = false;
var players = [];
// NOTE: must be `var`, not `let`. 0.39's UI app service re-evaluates app.js in the
// same scope on refresh (see the ?uiAppRefresh= query it appends). A top-level `let`
// throws "Identifier 'pingList' has already been declared" on the second evaluation,
// which aborts the script before angular.module(...).directive() runs, so the
// careermpplayerlist directive never registers and the app silently fails to load.
var pingList = [];
var nickname = "";
var app = angular.module('beamng.apps');
app.directive('careermpplayerlist', [function () {
	return {
		templateUrl: '/ui/modules/apps/CareerMP-PlayerList/app.html',
		replace: true,
		restrict: 'EA',
		scope: true,
		controllerAs: 'ctrl'
	}
}]);
app.controller("PlayerList", ['$scope', '$filter', 'Settings', function ($scope, $filter, Settings) {
	$scope.warnVis = false;
	$scope.timer = null;
	$scope.showPlayerIDs = true
	$scope.playerlistLeftclick = 0;

	const applyPlayerListStyle = function(useNewDesign) {
		const stylesheet = document.getElementById('playerlist-style');
		if (!stylesheet) return;

		let newStylePath;
		if (useNewDesign) {
			newStylePath = '/ui/modules/apps/CareerMP-PlayerList/redesign.css';
		} else {
			newStylePath = '/ui/modules/apps/CareerMP-PlayerList/app.css';
		}
		
		if (stylesheet.getAttribute('href') !== newStylePath) {
			stylesheet.setAttribute('href', newStylePath);
		}
	};

	$scope.init = function() {
		// Set players list direction
		setPLDirection(localStorage.getItem('plHorizontal'));
		setPLDirection(localStorage.getItem('plVertical'));
		if (localStorage.getItem('plShown') == 1) showList();
		bngApi.engineLua("guihooks.trigger('onBeamMPUpdateCustomButtons', UI.getCustomButtonNames())")
		
		// Apply style on init
		applyPlayerListStyle(Settings.values.useUiAppRedesign);
      	bngApi.engineLua('settings.getValue("showPlayerIDs")', (data) => {
      		$scope.showPlayerIDs = data
    	})
		bngApi.engineLua('settings.getValue("playerlistLeftclick")', (data) => {
			$scope.playerlistLeftclick = data
	  	})
	};

	$scope.$on('SettingsChanged', function (event, data) {
		Settings.values = data.values;
		applyPlayerListStyle(Settings.values.useUiAppRedesign);
		$scope.showPlayerIDs = Settings.values.showPlayerIDs;
		$scope.playerlistLeftclick = Settings.values.playerlistLeftclick;
	});

	$scope.reset = function() {
		connected = false;
		players = [];
		$scope.init();
	};

	$scope.select = function() {
		bngApi.engineLua('setCEFFocus(true)');
	};

	$scope.disconnect = function() {
		players = [];
		connected = false;
	};

	function setPLDirection(direction) {
		const mainContainer = document.getElementById("main-container");
		const plistContainer = document.getElementById("plist-container");
		const showButton = document.getElementById("show-button");
		if (direction == "left") {
			mainContainer.style.flexDirection = "row-reverse";
			localStorage.setItem('plHorizontal', "left");
		}
		else if (direction == "right") {
			mainContainer.style.flexDirection = "row";
			localStorage.setItem('plHorizontal', "right");
		}
		else if (direction == "top") {
			plistContainer.style.marginTop = "0";
			showButton.style.marginTop = "0";
			localStorage.setItem('plVertical', "top");
		}
		else if (direction == "bottom") {
			plistContainer.style.marginTop = "auto";
			showButton.style.marginTop = "auto";
			localStorage.setItem('plVertical', "bottom");
		}
	}

	$scope.plSwapHorizontal = function() {
		const plHorizontal = localStorage.getItem('plHorizontal');
		console.log(plHorizontal);
		if (plHorizontal != "left") setPLDirection("left");
		else setPLDirection("right");
	}

	$scope.plSwapVertical = function() {
		const plVertical = localStorage.getItem('plVertical');
		if (plVertical != "bottom") setPLDirection("bottom");
		else setPLDirection("top");
	}

	$scope.$on('onBeamMPPlayerPings', function(event, data) {
		pingList = JSON.parse(data);
		for(let i = 0; i < pingList.length; i++) {
			pingList[i] = pingList[i]-16;
			if (pingList[i] > 999) pingList[i] = 999;
		}
	})

	var customButtons = []

	$scope.$on('onBeamMPUpdateCustomButtons', function(event, data) {
		if (Array.isArray(data)) {
			customButtons = data;
		}
	})

	$scope.$on('onBeamMPPlayerList', function(event, data) {
		if (connectionLost) return;
		let playersList = document.getElementById("players-table");
		let parsedList = JSON.parse(data);
		
		if(players != null && playersList != null){
			//get differences between playernames and send them as messages
			var left = players.filter((item) => { return !parsedList.includes(item) });
			var joined = parsedList.filter((item) => { return !players.includes(item) });
	
			// Clear the player list
			clearPlayerList();
	
			parsedList.sort(function(a, b) {
				var keyA = a.id,
					  keyB = b.id;
				// Compare the 2 dates
				if (keyA < keyB) return -1;
				if (keyA > keyB) return 1;
				return 0;
			});

			// And fill it with the updated players
			for (let i = 0; i < parsedList.length; i++) {
				// Insert a row at the end of the players list
				var row = playersList.insertRow(playersList.rows.length);
	
				row.setAttribute("id", "playerlist-row-" + parsedList[i].id);
				// Click handlers close over the name instead of pasting it into markup.
				const playerName = parsedList[i].name;

				// Insert a cell containing the player server id
				var idCell = row.insertCell(0);
				idCell.textContent = parsedList[i].id;
				idCell.onclick = function() { restorePlayerVehicle(playerName) };
				if ($scope.showPlayerIDs) {
					idCell.setAttribute("class", "player-id");
				} else {
					idCell.setAttribute("class", "player-id ng-hide");
				}
				


				// Insert a cell containing the player name
				var nameCell = row.insertCell(1);
				nameCell.textContent = parsedList[i].formatted_name;
				//var c = parsedList[i].color
				//nameCell.style = `color:rgba(${c[0]},${c[1]},${c[2]},255)`;

				switch ($scope.playerlistLeftclick) {
					case 0:
						nameCell.setAttribute("onclick", "applyQueuesForPlayer('"+parsedList[i].id+"')");
						break;
					case 1:
						nameCell.onclick = function() { showPlayerInfo(playerName) };
						break;
					case 2:
						break;
					case 3:
						break;
					case 4:
						break;
					case 5:
						nameCell.onclick = function() { bngApi.engineLua('setClipboard(' + luaString(playerName) + ')') };
						break;
				}

				nameCell.addEventListener("contextmenu", function(e) {
					e.preventDefault();
				
					const playerlistContextmenu = document.getElementById("playerlist-contextmenu");

					playerlistContextmenu.style.display = "block";
					playerlistContextmenu.style.top = e.clientY + "px";
					playerlistContextmenu.style.left = e.clientX + "px";
					playerlistContextmenu.style.position = "fixed";

					playerlistContextmenu.onmouseleave = function () {
						playerlistContextmenu.style.display = "none";
					};

					document.getElementById("pl-context-Pay1Button").onclick = function() {
						payPlayer(parsedList[i].name, 1);
					}

					document.getElementById("pl-context-Pay10Button").onclick = function() {
						payPlayer(parsedList[i].name, 10);
					}

					document.getElementById("pl-context-Pay100Button").onclick = function() {
						payPlayer(parsedList[i].name, 100);
					}

					document.getElementById("pl-context-Pay1000Button").onclick = function() {
						payPlayer(parsedList[i].name, 1000);
					}

					document.getElementById("pl-context-Pay10000Button").onclick = function() {
						payPlayer(parsedList[i].name, 10000);
					}

					document.getElementById("pl-context-Pay100000Button").onclick = function() {
						payPlayer(parsedList[i].name, 100000);
					}

					for (let child of playerlistContextmenu.children) {
						if (child.id === "pl-context-custom") {
							playerlistContextmenu.removeChild(child);
						}
					}

					customButtons.forEach(element => {
						let customButton = document.createElement("button");
						customButton.id = "pl-context-custom"
						customButton.textContent = element;
						customButton.onclick = function() {
							bngApi.engineLua(
								'UI.getCustomPlayerlistButtons()[' + luaString(element) + '](' + luaString(parsedList[i].name) + ', ' + Number(parsedList[i].id) + ')'
							)
						}

						playerlistContextmenu.appendChild(customButton);
					});
				});
				nameCell.setAttribute("class", "player-button");

				// Insert a cell containing the link to forum
				//var infoCell = row.insertCell(2);
				//infoCell.setAttribute("class", "view-button");

				// Insert the button inside the link to forum
				//var btn = document.createElement("BUTTON");
				//var pingText = "?";
				//btn.appendChild(document.createTextNode(pingText));
				//btn.setAttribute("onclick","viewPlayer('"+parsedList[i].name+"')");
				//btn.setAttribute("class", "view-button buttons");
				//infoCell.appendChild(btn);
	
				// Insert a cell containing the player ping
				var pingCell = row.insertCell(2);
	
				// Insert the button inside the cell
				var btn = document.createElement("BUTTON");
				var pingText = pingList[parsedList[i].name] || "?";
				btn.appendChild(document.createTextNode(pingText+='ms'));
				btn.setAttribute("onclick","teleportToPlayer('"+parsedList[i]+"')");
				btn.setAttribute("class", "tp-button buttons");
				pingCell.appendChild(btn);

				if ($scope.queuedPlayers[parsedList[i].id] == true) {
					row.style.setProperty('background-color', 'var(--bng-orange-shade1)');
				}
			}
			if(document.getElementById("plist-container").style.display == "block")
				document.getElementById("show-button").style.height = playersList.offsetHeight + "px"; 
		}
		players = parsedList; //store player list as an array for the next update
	})

	$scope.$on('onBeamMPSetNickname', function(event, data) {
		nickname = data
	})

	$scope.queuedPlayers = []

	$scope.$on('onBeamMPSetQueue', function(event, data) {
		$scope.queuedPlayers = []

		if (!data.queuedPlayers) {
			var rows = document.querySelectorAll('[id^="playerlist-row-"]');
			for (let i = 0; i < rows.length; i++) {
				rows[i].style.setProperty('background-color', 'transparent');
			}
			return
		}

		for (var key in data.queuedPlayers) {
			$scope.queuedPlayers[key] = data.queuedPlayers[key]
			var playerrow = document.getElementById("playerlist-row-" + key)
			if (playerrow) {
				playerrow.style.setProperty('background-color', data.queuedPlayers[key] ? 'var(--bng-orange-shade1)' : 'transparent')
			}
		}
	})

	// Lost server connection, from careerMP/connectionWatch. The banner sits outside the
	// folding list so it shows either way; its text is bound as text, never as markup.
	// While it shows, BeamMP's player list updates are ignored so the dead session's
	// players do not come back underneath it (connectionLost is set at once, not on the
	// next digest).
	$scope.connection = {lost: false, message: "", saveState: ""};

	var SAVE_TEXT = {
		saving: "Saving your career...",
		saved: "Your career was saved.",
		failed: "Your career could not be saved."
	};

	$scope.saveText = function() {
		return SAVE_TEXT[$scope.connection.saveState] || "";
	};

	$scope.$on('careerMPConnectionLost', function(event, data) {
		data = data || {};
		connectionLost = true;
		$scope.$evalAsync(function() {
			$scope.connection = {
				lost: true,
				message: String(data.message || "Lost connection to the server"),
				saveState: SAVE_TEXT[data.saveState] ? data.saveState : (data.saved === true ? "saved" : "failed")
			};
		});
		players = [];
		connected = false;
		clearPlayerList();
	})

	$scope.$on('careerMPConnectionRestored', function() {
		connectionLost = false;
		$scope.$evalAsync(function() {
			$scope.connection = {lost: false, message: "", saveState: ""};
		});
		bngApi.engineLua('if UI and UI.updatePlayersList then UI.updatePlayersList() end');
	})

	$scope.retrySave = function() {
		bngApi.engineLua('if careerMP_connectionWatch then careerMP_connectionWatch.retrySave() end');
	};

	$scope.returnToMenu = function() {
		bngApi.engineLua('MPCoreNetwork.leaveServer(true)');
	};

	bngApi.engineLua('UI.updatePlayersList(); UI.sendQueue()'); // instantly populate the playerlist and their queues
	// A UI reload while the connection is lost must bring the banner back.
	bngApi.engineLua('if careerMP_connectionWatch then careerMP_connectionWatch.sendState() end');
}]);

function clearPlayerList() {
	let playersList = document.getElementById("players-table");
	var rowCount = playersList.rows.length - 1;
	for(rowCount; rowCount > 0; rowCount--) playersList.deleteRow(1);
}

// Player names are chosen by other players, so they reach Lua base64-encoded (as UTF-8)
// and are decoded there: no character of a name can end the string and become code.
function luaString(text) {
	var bytes = new TextEncoder().encode(String(text));
	var binary = "";
	for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
	return "require('mime').unb64('" + btoa(binary) + "')";
}

function payPlayer(targetPlayerName, amount) {
	bngApi.engineLua('careerMPPlayerPayments.payPlayer(' + luaString(targetPlayerName) + ', ' + (parseInt(amount, 10) || 0) + ')')
}

function setOfflineInPlayerList() {
	let playersList = document.getElementById("players");
	if(playersList != null) playersList.textContent = "OFFLINE"; //added this cause it was throwing console errors
}

function showList() {
	var shownText = "&gt;";
	var hiddenText = "&lt;";
	if (localStorage.getItem('plHorizontal') == "right") { shownText = "&lt;"; hiddenText = "&gt;"; }
	var plContainer = document.getElementById("plist-container");
	var btn = document.getElementById("show-button");
	plContainer.style.display = "block";
	btn.innerHTML = shownText;
}

function hideList() {
	var hiddenText = "&lt;";
	if (localStorage.getItem('plHorizontal') == "right") { hiddenText = "&gt;"; }
	var plContainer = document.getElementById("plist-container");
	var btn = document.getElementById("show-button");
	plContainer.style.display = "block";
	btn.innerHTML = shownText;
}

function hideList() {
	var hiddenText = "&lt;";
	if (localStorage.getItem('plHorizontal') == "right") { hiddenText = "&gt;"; }
	var plContainer = document.getElementById("plist-container");
	var btn = document.getElementById("show-button");
	plContainer.style.display = "none";
	btn.innerHTML = hiddenText;
	btn.style.height = "75px";
}

function toggleList() {
	if(localStorage.getItem('plShown') != 1) {
		showList();
		localStorage.setItem('plShown', 1);
	}
	else {
		hideList();
		localStorage.setItem('plShown', 0);
	}
}
