import assert from "node:assert/strict";
import test from "node:test";
import { NPC_TABLE, TICK_SECONDS } from "../js/rules.js";
import {
  armyScores,
  buildSeconds,
  createKingdom,
  crewCount,
  describe,
  exploreCap,
  foodRates,
  freeLand,
  goldPerHour,
  kingdomFromRow,
  networth,
  orderBuild,
  orderExplore,
  orderResearch,
  orderTrain,
  popCap,
  researchPerHour,
  roster,
  settle,
  validateKingdomName,
} from "../js/engine.js";

const NOW = Date.UTC(2026, 10, 10, 12, 0, 0);

function player(landType = "highlands") {
  return createKingdom({
    name: "Highcrest",
    landType,
    now: NOW,
    realmName: "The Amber March",
    realmSeat: "Western vales",
  });
}

test("names", () => {
  assert.equal(validateKingdomName("  Highcrest ").name, "Highcrest");
  assert.equal(validateKingdomName("Isle of Vel").name, "Isle of Vel");
  assert.ok(validateKingdomName("ab").error);
  assert.ok(validateKingdomName("Has  two").error);
  assert.ok(validateKingdomName("").error);
});

test("a fresh highlands tick matches the bank math", () => {
  const state = player();
  assert.equal(freeLand(state), 195);
  assert.equal(foodRates(state).produced, 2124);
  assert.equal(foodRates(state).consumed, 649);
  assert.equal(goldPerHour(state), 730);
  assert.equal(researchPerHour(state), 280);
  assert.equal(popCap(state), 477);
  assert.equal(exploreCap(state), 19);
  const { state: next } = settle(state, NOW + TICK_SECONDS * 1000);
  assert.equal(next.food, 4224);
  assert.equal(next.foodBank, 2100);
  assert.equal(next.gold, 6512);
  assert.equal(next.goldBank, 600);
  assert.equal(next.mana, 80);
  assert.equal(next.manaBank, 2160);
  assert.equal(next.researchPoints, 74);
  assert.equal(next.researchBank, 2400);
  assert.equal(next.peasants, 300);
  assert.equal(next.popProgress, 42);
  assert.equal(next.lastTickAt, NOW + TICK_SECONDS * 1000);
});

test("one full hour pays the hourly rates exactly when the bank starts empty", () => {
  const { state } = settle(player(), NOW + 60 * TICK_SECONDS * 1000, { maxTicks: 60 });
  assert.equal(state.gold, 6500 + 730);
  assert.equal(state.goldBank, 0);
  assert.equal(state.researchPoints, 70 + 280);
  assert.equal(state.researchBank, 0);
  assert.ok(state.food > 4200);
  assert.ok(state.peasants >= 300);
});

test("build spends gold, reserves land, and finishes on a later tick", () => {
  const built = orderBuild(player(), "farm", 2, NOW);
  assert.equal(built.state.gold, 6500 - 360);
  assert.equal(built.state.buildings.farm, 16);
  assert.equal(freeLand(built.state), 193);
  assert.equal(built.state.jobs.length, 1);
  assert.throws(() => orderBuild(built.state, "home", 1, NOW), /All construction crews are busy \(1\/1\)/);
  const doneAt = built.state.jobs[0].completesAt;
  const { state } = settle(built.state, doneAt);
  assert.equal(state.buildings.farm, 18);
  assert.equal(state.jobs.length, 0);
  assert.ok(state.chronicle.some((line) => /Farmstead finished/.test(line.text)));
});

test("guilds and Master Masons field more crews and shorten builds", () => {
  const fresh = player();
  assert.equal(crewCount(fresh), 1);
  assert.equal(buildSeconds(fresh, "farm", 1), 132);
  const studied = orderResearch(fresh, "masons", NOW).state;
  assert.equal(studied.research.masons, 1);
  assert.equal(crewCount(studied), 2);
  assert.equal(buildSeconds(studied, "farm", 1), 125);
  studied.researchPoints = 200;
  const mastered = orderResearch(studied, "masons", NOW + 1000).state;
  assert.equal(mastered.research.masons, 2);
  assert.equal(crewCount(mastered), 2);
  assert.equal(buildSeconds(mastered, "farm", 1), 118);
  assert.throws(() => orderResearch(mastered, "masons", NOW + 2000), /fully studied/);

  const yard = player();
  yard.buildings.guild = 2;
  yard.research.masons = 1;
  assert.equal(crewCount(yard), 4);
  yard.buildings.guild = 5;
  assert.equal(crewCount(yard), 4);

  let state = player();
  state.buildings.guild = 1;
  state = orderBuild(state, "farm", 1, NOW).state;
  state = orderBuild(state, "granary", 1, NOW).state;
  assert.equal(state.jobs.filter((job) => job.kind === "build").length, 2);
  assert.equal(freeLand(state), 192);
  assert.throws(() => orderBuild(state, "home", 1, NOW), /All construction crews are busy \(2\/2\)/);
  const soon = state.jobs.find((job) => job.building === "farm").completesAt;
  const later = state.jobs.find((job) => job.building === "granary").completesAt;
  assert.ok(later > soon);
  const mid = settle(state, soon).state;
  assert.equal(mid.buildings.farm, 17);
  assert.equal(mid.jobs.filter((job) => job.kind === "build").length, 1);
  const done = settle(mid, later).state;
  assert.equal(done.buildings.granary, 3);
  assert.equal(done.jobs.length, 0);
});

test("explore charter, settlers, and return", () => {
  const state = player();
  assert.throws(() => orderExplore(state, 20, NOW), /charter/);
  const sent = orderExplore(state, 6, NOW);
  assert.equal(sent.state.exploredToday, 6);
  assert.equal(sent.state.peasants, 299);
  assert.ok(sent.state.gold < 6500);
  const home = settle(sent.state, sent.state.jobs[0].completesAt).state;
  assert.equal(home.land, 246);
  assert.equal(home.peasants, 300);
  assert.equal(home.jobs.length, 0);
});

test("training requires housing, food, peasants, barracks, and colleges", () => {
  const state = player();
  assert.throws(() => orderTrain(state, "wyvern", 1, NOW), /college/);
  const trained = orderTrain(state, "militia", 10, NOW);
  assert.equal(trained.state.units.militia, 36);
  assert.equal(trained.state.peasants, 290);
  assert.ok(trained.state.gold < 6500);
  assert.ok(trained.state.food < 4200);
  const done = settle(trained.state, trained.state.jobs[0].completesAt).state;
  assert.equal(done.units.militia, 46);
  const rich = player();
  rich.researchPoints = 5000;
  let stepped = rich;
  for (let i = 0; i < 4; i++) stepped = orderResearch(stepped, "military", NOW).state;
  assert.equal(stepped.research.military, 4);
  const guard = orderTrain(stepped, "warden", 1, NOW);
  assert.equal(guard.state.jobs[0].unit, "warden");
});

test("research spends points and refuses an unknown or finished college", () => {
  const studied = orderResearch(player(), "food", NOW);
  assert.equal(studied.state.research.food, 1);
  assert.equal(studied.state.researchPoints, 70 - 40);
  assert.throws(() => orderResearch(studied.state, "food", NOW), /Not enough research/);
  assert.throws(() => orderResearch(player(), "alchemy", NOW), /Unknown college/);
});

test("empty stores collapse births, shrink the cap, and weaken the army", () => {
  const fed = player();
  const hungry = player();
  hungry.food = 0;
  hungry.foodBank = 0;
  hungry.buildings.farm = 0;
  hungry.buildings.granary = 0;
  const fedArmy = armyScores(fed).attack;
  const hungryArmy = armyScores(hungry).attack;
  assert.ok(hungryArmy < fedArmy);
  assert.ok(popCap(hungry) < popCap(fed));
  assert.equal(describe(hungry).starving, true);
  const { state } = settle(hungry, NOW + TICK_SECONDS * 1000);
  assert.equal(state.food, 0);
  assert.ok(state.popProgress < 0 || state.peasants < 300);
});

test("npc realms spread networth around a new crown", () => {
  const you = player();
  const npcs = NPC_TABLE.map((row) => kingdomFromRow(row, NOW, { name: "The Amber March", seat: "Western vales" }));
  const board = roster(you, npcs);
  assert.equal(board.length, 11);
  assert.equal(new Set(board.map((row) => row.name)).size, 11);
  const yours = board.find((row) => row.you);
  assert.ok(yours.networth > board[board.length - 1].networth);
  assert.ok(yours.networth < board[0].networth);
  assert.equal(networth(you), yours.networth);
});

test("refuses a second land type and a short name at founding", () => {
  assert.throws(() => createKingdom({ name: "No", landType: "forest", now: NOW }), /3-24/);
  assert.throws(() => createKingdom({ name: "Highcrest", landType: "moon", now: NOW }), /land type/);
});
