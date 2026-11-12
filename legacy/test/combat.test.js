import assert from "node:assert/strict";
import test from "node:test";
import {
  NPC_PACTS,
  NPC_WAR,
  aiAttackNote,
  attackBlock,
  defenseOf,
  npcAttackType,
  npcCooldownSeconds,
  npcHumanOpen,
  npcNetworthOk,
  npcPickTarget,
  npcSendCounts,
  npcSendPercent,
  npcTargetScore,
  fuzzAmount,
  hitScale,
  isProtected,
  lossPercents,
  oddsBand,
  offenseOf,
  battleBrief,
  resolveBattle,
  sizeScale,
  spyFails,
  travelSeconds,
  validateAllianceName,
  validateTag,
} from "../js/combat.js";
import { createKingdom, kingdomFromRow, networth } from "../js/engine.js";
import { NPC_TABLE } from "../js/rules.js";

const NOW = Date.UTC(2026, 10, 10, 12, 0, 0);

function player() {
  const state = createKingdom({ name: "Highcrest", landType: "highlands", now: NOW });
  state.morale = 100;
  state.spies = 2;
  state.attackedAt = null;
  state.protectedUntil = NOW + 24 * 3600 * 1000;
  return state;
}

test("a full levy's offense matches the land and research formula", () => {
  const state = player();
  const sent = { ...state.units };
  assert.equal(offenseOf(state, sent), 164);
  assert.equal(defenseOf(state), 229);
});

test("size and recent-hit scales punish bullies and repeat raids", () => {
  assert.equal(sizeScale(8000, 2000), 50);
  assert.equal(sizeScale(2000, 4000), 140);
  assert.equal(sizeScale(3000, 3000), 100);
  assert.equal(hitScale(NOW - 10 * 60 * 1000, NOW), 25);
  assert.equal(hitScale(NOW - 2 * 3600 * 1000, NOW), 50);
  assert.equal(hitScale(NOW - 5 * 3600 * 1000, NOW), 75);
  assert.equal(hitScale(null, NOW), 100);
});

test("conquest of a weak house takes acres and bloodies both sides", () => {
  const att = player();
  const moss = kingdomFromRow(NPC_TABLE.find((row) => row.name === "Mossfen"), NOW, { name: "The Amber March", seat: "Western vales" });
  moss.morale = 100;
  moss.isNpc = true;
  const sent = { militia: 0, footmen: 12, pikemen: 0, archers: 8, knights: 2, siege: 0, warden: 0, spellbow: 0, wyvern: 0 };
  const result = resolveBattle({ attacker: att, defender: moss, sent, type: "conquest", roll: 100, now: NOW });
  assert.equal(result.win, true);
  assert.ok(result.spoils.acres >= 1);
  assert.ok(result.spoils.acres <= Math.floor(moss.land / 8));
  assert.ok(result.living.footmen < 12);
  assert.ok(result.defLoss.militia >= 1);
  assert.match(result.text, /took \d+ acres/);
  const tiny = resolveBattle({
    attacker: att,
    defender: { ...moss, land: 30, buildings: { ...moss.buildings }, units: { ...moss.units } },
    sent,
    type: "conquest",
    roll: 115,
    now: NOW,
  });
  assert.equal(tiny.spoils.acres, 0);
});

test("plunder is smaller against a much richer crown and a fresh wound", () => {
  const att = player();
  att.gold = 500000;
  const rich = kingdomFromRow(NPC_TABLE.find((row) => row.name === "Qasira"), NOW, { name: "The Amber March", seat: "x" });
  rich.morale = 100;
  rich.lastHitAt = NOW - 60 * 1000;
  const sent = { ...player().units };
  const result = resolveBattle({ attacker: att, defender: rich, sent, type: "plunder", roll: 115, now: NOW });
  if (result.win) {
    assert.ok(result.spoils.gold < rich.gold / 4);
    assert.ok(result.recent === 25);
  }
  assert.equal(lossPercents(100, 100, true).attacker < lossPercents(100, 100, false).attacker, true);
});

test("protection, self, and alliance blocks", () => {
  const att = player();
  const other = player();
  other.name = "Qasira";
  other.isNpc = false;
  other.protectedUntil = NOW + 1000;
  other.attackedAt = null;
  assert.equal(isProtected(other, NOW), true);
  assert.equal(attackBlock({ attacker: att, defender: other, sameAlliance: false, now: NOW }), "That kingdom is under protection.");
  other.attackedAt = NOW - 10;
  assert.equal(isProtected(other, NOW), false);
  assert.equal(attackBlock({ attacker: att, defender: att, sameAlliance: false, now: NOW }), "You cannot attack your own gates.");
  assert.equal(attackBlock({ attacker: att, defender: other, sameAlliance: true, now: NOW }), "You share an alliance.");
  assert.equal(attackBlock({ attacker: att, defender: other, sameAlliance: false, now: NOW }), "");
});

test("spies, travel, tags, and pact names", () => {
  assert.equal(travelSeconds(true, false), 180);
  assert.equal(travelSeconds(false, false), 480);
  assert.equal(travelSeconds(true, true), 90);
  assert.equal(spyFails(0, 71), true);
  assert.equal(spyFails(0, 70), false);
  assert.equal(spyFails(10, 90), false);
  assert.equal(fuzzAmount(100, 85), 85);
  assert.equal(oddsBand(200, 100), "favored");
  assert.equal(oddsBand(100, 100), "even");
  assert.equal(oddsBand(50, 100), "outmatched");
  assert.equal(validateTag("irn").tag, "IRN");
  assert.ok(validateTag("I").error);
  assert.ok(validateAllianceName("The Iron Covenant").name);
  assert.equal(NPC_PACTS.length, 2);
  assert.ok(networth(player()) > 0);
});

test("a battle brief keeps the tally and still renders an old one-line report", () => {
  const att = player();
  const def = kingdomFromRow(NPC_TABLE.find((row) => row.name === "Mossfen"), NOW, { name: "The Amber March", seat: "Western vales" });
  const sent = { militia: 36, footmen: 12, archers: 8, knights: 2 };
  const result = resolveBattle({ attacker: att, defender: def, sent, type: "conquest", roll: 110, now: NOW });
  const brief = battleBrief({
    kind: "battle",
    outcome: result.win ? "win" : "loss",
    attackType: "conquest",
    defender: def.name,
    text: result.text,
    spoils: result.spoils,
    attLoss: result.attLoss,
    defLoss: result.defLoss,
    living: result.living,
    youAttacked: true,
  });
  assert.equal(brief.victory, result.win);
  assert.ok(brief.yourLoss.total > 0);
  assert.ok(brief.enemyLoss.total > 0);
  assert.equal(brief.yourLoss.total + brief.returning.total, 36 + 12 + 8 + 2);
  if (result.win) {
    assert.ok(brief.gained.some((line) => line.includes("acres")));
    assert.equal(brief.morale, 3);
  }
  const held = battleBrief({
    kind: "battle",
    outcome: "win",
    you_attacked: false,
    attack_type: "plunder",
    attacker: "Ashford Keep",
    text: "Ashford Keep plundered 40 gold and 10 food.",
    gold: 40,
    food: 10,
    def_loss: { militia: 4 },
    att_loss: { footmen: 9 },
  });
  assert.equal(held.victory, false);
  assert.equal(held.morale, -6);
  assert.deepEqual(held.gained, ["40 gold", "10 food"]);
  assert.equal(held.yourLoss.total, 4);
  assert.equal(held.enemyLoss.total, 9);
  assert.equal(held.returning, null);
  const old = battleBrief({ outcome: "loss", kind: "battle", text: "Your host was thrown back.", defender: "Dun Mere" });
  assert.equal(old.victory, false);
  assert.equal(old.yourLoss, null);
  assert.deepEqual(old.gained, []);
  assert.equal(old.morale, -8);
  assert.equal(battleBrief({ kind: "spy", outcome: "scouted", text: "A spy reports." }), null);
  const ai = battleBrief({
    kind: "battle",
    outcome: "loss",
    you_attacked: false,
    attacker_npc: true,
    attack_type: "plunder",
    attacker: "Ashford Keep",
    text: "Ashford Keep plundered 40 gold and 10 food.",
    gold: 40,
    food: 10,
  });
  assert.equal(ai.aiNote, "An established house marched.");
  assert.equal(aiAttackNote({ youAttacked: true, attackerNpc: true }), "");
  assert.equal(aiAttackNote({ you_attacked: false, attacker_npc: false }), "");
});

test("an established house marches on a timer and keeps a garrison", () => {
  assert.equal(npcCooldownSeconds(0), NPC_WAR.cooldownMinSec);
  assert.equal(npcCooldownSeconds(50), 3 * 3600);
  assert.equal(npcCooldownSeconds(99), 7200 + Math.floor(7200 * 99 / 100));
  assert.ok(npcCooldownSeconds(99) < 4 * 3600);
  assert.equal(npcSendPercent(0), 35);
  assert.equal(npcSendPercent(99), 50);
  const sent = npcSendCounts({ militia: 10, knights: 2, archers: 0 }, 50);
  assert.equal(sent.militia, 5);
  assert.equal(sent.knights, 1);
  assert.equal(npcSendCounts({ militia: 1 }, 50), null);
  assert.equal(npcHumanOpen(0), true);
  assert.equal(npcHumanOpen(1), true);
  assert.equal(npcHumanOpen(2), false);
});

test("established houses prefer a crown they can beat and drop a hopeless fight", () => {
  assert.equal(npcNetworthOk(1000, 400, false), true);
  assert.equal(npcNetworthOk(1000, 390, false), false);
  assert.equal(npcNetworthOk(1000, 1400, false), true);
  assert.equal(npcNetworthOk(1000, 1410, false), false);
  assert.equal(npcNetworthOk(1000, 250, true), true);
  assert.equal(npcNetworthOk(1000, 1810, true), false);
  assert.equal(npcTargetScore({ ratio: 34, human: true, sameRealm: true, jitter: 30 }), null);
  assert.equal(npcAttackType(120, 0), "conquest");
  assert.equal(npcAttackType(120, 60), "plunder");
  assert.equal(npcAttackType(80, 0), "plunder");
  assert.equal(npcAttackType(80, 50), "razing");
  assert.equal(npcAttackType(40, 0), "plunder");
  assert.equal(npcAttackType(40, 70), "razing");
  const human = { name: "Highcrest", score: npcTargetScore({ ratio: 90, human: true, sameRealm: true, jitter: 0 }) };
  const peer = { name: "Qasira", score: npcTargetScore({ ratio: 100, human: false, sameRealm: false, jitter: 0 }) };
  const hopeless = { name: "Ashford Keep", score: npcTargetScore({ ratio: 20, human: false, sameRealm: true, jitter: 30 }) };
  assert.equal(hopeless.score, null);
  assert.equal(npcPickTarget([peer, hopeless, human]).name, "Highcrest");
  assert.equal(npcPickTarget([hopeless]), null);
});
