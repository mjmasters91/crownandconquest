/**
 * Combat, spies, and alliances.
 * Integer math here is repeated in sql/0002_crown_combat.sql.
 * NPC march choices are repeated in sql/0008_npc_attacks.sql (NPC_WAR).
 * A shared realm is not an alliance. Only members of the same pact are immune.
 */

import { BUILDING_ORDER, BUILDINGS, DAY_MS, LANDS, UNIT_ORDER, UNITS } from "./rules.js";
import { armyScores, builtAcres, networth } from "./engine.js";

export const WAR = {
  protectionMs: DAY_MS,
  travelSame: 180,
  travelOther: 480,
  spySame: 90,
  spyOther: 240,
  spyCost: 150,
  spyMax: 25,
  maxArmies: 3,
  moraleFloor: 40,
  allianceMax: 20,
  minLand: 40,
};

export const ATTACK_TYPES = {
  conquest: { id: "conquest", name: "Conquest", blurb: "Take acres. Buildings on that ground come with the claim." },
  plunder: { id: "plunder", name: "Plunder", blurb: "Carry off gold and food. The land stays theirs." },
  razing: { id: "razing", name: "Razing", blurb: "Pull buildings down and leave the rubble." },
};

export function emptyUnits() {
  return {
    militia: 0, footmen: 0, pikemen: 0, archers: 0, knights: 0,
    siege: 0, warden: 0, spellbow: 0, wyvern: 0,
  };
}

export function forceRaw(units, key) {
  let n = 0;
  for (const id of UNIT_ORDER) n += (units[id] || 0) * UNITS[id][key];
  return n;
}

export function offenseOf(state, sent) {
  const land = LANDS[state.landType];
  const raw = forceRaw(sent, "attack");
  const atkPct = Math.floor(land.attackPct * (100 + (state.research?.military || 0) * 3) / 100);
  const starve = state.food <= 0 ? 62 : 100;
  const moralePct = (state.morale ?? 100) >= 70 ? 100 : 95;
  return Math.floor(Math.floor(Math.floor(raw * atkPct / 100) * starve / 100) * moralePct / 100);
}

export function defenseOf(state) {
  const scored = armyScores(state);
  const moralePct = (state.morale ?? 100) >= 70 ? 100 : 95;
  return Math.floor(scored.defense * moralePct / 100);
}

export function sizeScale(attackerNw, defenderNw) {
  const a = Math.max(1, attackerNw);
  const d = Math.max(1, defenderNw);
  if (a > d * 2) return Math.max(25, Math.floor(200 * d / a));
  if (d > a) return Math.min(160, 100 + Math.floor((d - a) * 40 / a));
  return 100;
}

export function hitScale(lastHitAt, now) {
  if (!lastHitAt) return 100;
  const age = Math.floor((now - lastHitAt) / 1000);
  if (age < 30 * 60) return 25;
  if (age < 3 * 3600) return 50;
  if (age < 8 * 3600) return 75;
  return 100;
}

export function lossPercents(offense, defense, win) {
  const off = Math.max(1, offense);
  const def = Math.max(1, defense);
  let att = 10 + Math.min(35, Math.floor(def * 40 / off));
  let hold = 15 + Math.min(45, Math.floor(off * 35 / def));
  if (win) {
    att = Math.max(6, att - 8);
    hold = Math.min(70, hold + 10);
  } else {
    att = Math.min(55, att + 12);
    hold = Math.max(5, hold - 8);
  }
  return { attacker: att, defender: hold };
}

export function lossesFor(units, pct) {
  const lost = emptyUnits();
  for (const id of UNIT_ORDER) {
    const count = units[id] || 0;
    let n = Math.floor(count * pct / 100);
    if (count >= 8 && n === 0 && pct >= 8) n = 1;
    lost[id] = Math.min(count, n);
  }
  return lost;
}

export function survivors(units, lost) {
  const next = emptyUnits();
  for (const id of UNIT_ORDER) next[id] = Math.max(0, (units[id] || 0) - (lost[id] || 0));
  return next;
}

export function unitTotal(units) {
  let n = 0;
  for (const id of UNIT_ORDER) n += units[id] || 0;
  return n;
}

function takeBuildings(buildings, land, acres) {
  const removed = {};
  for (const id of BUILDING_ORDER) removed[id] = 0;
  const built = BUILDING_ORDER.reduce((sum, id) => sum + (buildings[id] || 0), 0);
  if (acres <= 0 || built <= 0 || land <= 0) return removed;
  const builtTaken = Math.min(built, Math.floor(acres * built / land));
  let assigned = 0;
  const parts = [];
  for (const id of BUILDING_ORDER) {
    const exact = builtTaken * (buildings[id] || 0) / built;
    const base = Math.floor(exact);
    removed[id] = base;
    assigned += base;
    parts.push({ id, frac: exact - base });
  }
  parts.sort((a, b) => b.frac - a.frac || a.id.localeCompare(b.id));
  let guard = 0;
  while (assigned < builtTaken && guard < builtTaken + 20) {
    let placed = false;
    for (const part of parts) {
      if (assigned >= builtTaken) break;
      if (removed[part.id] < (buildings[part.id] || 0)) {
        removed[part.id] += 1;
        assigned += 1;
        placed = true;
      }
    }
    if (!placed) break;
    guard += 1;
  }
  return removed;
}

function razeBuildings(buildings, razes) {
  const next = {};
  const removed = {};
  for (const id of BUILDING_ORDER) {
    next[id] = buildings[id] || 0;
    removed[id] = 0;
  }
  let left = razes;
  while (left > 0) {
    let best = null;
    let bestN = 0;
    for (const id of BUILDING_ORDER) {
      if (next[id] > bestN) {
        bestN = next[id];
        best = id;
      }
    }
    if (!best || bestN <= 0) break;
    next[best] -= 1;
    removed[best] += 1;
    left -= 1;
  }
  return removed;
}

export function resolveBattle({ attacker, defender, sent, type, roll, now }) {
  const offense = offenseOf(attacker, sent);
  const defense = defenseOf(defender);
  const safeRoll = Math.max(85, Math.min(115, roll));
  const struck = Math.floor(offense * safeRoll / 100);
  const win = struck > defense;
  const percents = lossPercents(offense, defense, win);
  const attLoss = lossesFor(sent, percents.attacker);
  const defLoss = lossesFor(defender.units, percents.defender);
  const living = survivors(sent, attLoss);
  const scale = sizeScale(networth(attacker), networth(defender));
  const recent = hitScale(defender.lastHitAt, now);
  const lootScale = Math.floor(scale * recent / 100);
  const spoils = {
    acres: 0,
    gold: 0,
    food: 0,
    buildings: {},
    razed: {},
  };
  for (const id of BUILDING_ORDER) {
    spoils.buildings[id] = 0;
    spoils.razed[id] = 0;
  }
  if (win && unitTotal(living) > 0) {
    if (type === "conquest") {
      let acres = Math.max(1, Math.floor(defender.land / 25));
      const margin = Math.min(150, Math.floor(struck * 100 / Math.max(1, defense)));
      acres = Math.floor(acres * margin / 100);
      acres = Math.floor(acres * lootScale / 100);
      acres = Math.min(acres, Math.floor(defender.land / 8), 80);
      acres = Math.min(acres, Math.max(0, defender.land - WAR.minLand));
      spoils.acres = acres;
      spoils.buildings = takeBuildings(defender.buildings, defender.land, acres);
    } else if (type === "plunder") {
      const goldCap = Math.min(Math.floor(defender.gold / 4), Math.max(50, offense * 2));
      const foodCap = Math.min(Math.floor(defender.food / 4), Math.max(50, offense * 2));
      spoils.gold = Math.min(Math.floor(defender.gold * 30 / 100), Math.floor(goldCap * lootScale / 100));
      spoils.food = Math.min(Math.floor(defender.food * 30 / 100), Math.floor(foodCap * lootScale / 100));
    } else if (type === "razing") {
      const built = builtAcres(defender);
      let razes = Math.max(1, Math.floor(built / 12));
      razes = Math.floor(razes * lootScale / 100);
      razes = Math.min(razes, 12, built);
      spoils.razed = razeBuildings(defender.buildings, razes);
    }
  }
  const attMorale = win
    ? Math.min(100, (attacker.morale ?? 100) + 3)
    : Math.max(WAR.moraleFloor, (attacker.morale ?? 100) - 8);
  const defMorale = win
    ? Math.max(WAR.moraleFloor, (defender.morale ?? 100) - 6)
    : Math.min(100, (defender.morale ?? 100) + 2);
  return {
    win,
    roll: safeRoll,
    offense,
    defense,
    struck,
    attLoss,
    defLoss,
    living,
    scale,
    recent,
    lootScale,
    spoils,
    attMorale,
    defMorale,
    text: battleText({ sent, defender, type, win, spoils }),
    defenderText: defenderText({ attacker, type, win, spoils }),
  };
}

function hostWord(sent) {
  let best = "host";
  let n = 0;
  for (const id of UNIT_ORDER) {
    if ((sent?.[id] || 0) > n) {
      n = sent[id];
      best = UNITS[id].name.toLowerCase();
    }
  }
  return n > 0 ? best : "host";
}

function battleText({ sent, defender, type, win, spoils }) {
  const who = hostWord(sent);
  if (!win) return `Your ${who} were thrown back from ${defender.name}.`;
  if (type === "conquest" && spoils.acres > 0) return `Your ${who} stormed ${defender.name} and took ${spoils.acres} acres.`;
  if (type === "plunder" && (spoils.gold > 0 || spoils.food > 0)) {
    return `Your ${who} plundered ${defender.name} and carried off ${spoils.gold} gold and ${spoils.food} food.`;
  }
  if (type === "razing") {
    const n = BUILDING_ORDER.reduce((sum, id) => sum + (spoils.razed[id] || 0), 0);
    return `Your ${who} razed ${n} buildings at ${defender.name}.`;
  }
  return `Your ${who} won at ${defender.name}, but there was nothing left to carry.`;
}

function defenderText({ attacker, type, win, spoils }) {
  if (!win) return `${attacker.name} broke against your walls.`;
  if (type === "conquest" && spoils.acres > 0) return `${attacker.name} stormed your gates and took ${spoils.acres} acres.`;
  if (type === "plunder") return `${attacker.name} plundered ${spoils.gold} gold and ${spoils.food} food.`;
  const n = BUILDING_ORDER.reduce((sum, id) => sum + (spoils.razed[id] || 0), 0);
  return `${attacker.name} razed ${n} of your buildings.`;
}

function asInt(value) {
  const n = Math.floor(Number(value));
  return Number.isFinite(n) ? n : 0;
}

function unitRows(bag) {
  if (!bag || typeof bag !== "object") return null;
  const rows = [];
  let total = 0;
  for (const id of UNIT_ORDER) {
    const count = asInt(bag[id]);
    total += count;
    if (count > 0) rows.push({ id, name: UNITS[id]?.name || id, count });
  }
  return { rows, total };
}

function buildingRows(bag, suffix) {
  if (!bag || typeof bag !== "object") return [];
  const rows = [];
  for (const id of BUILDING_ORDER) {
    const count = asInt(bag[id]);
    if (count > 0) rows.push(`${BUILDINGS[id]?.name || id}${suffix} ×${count}`);
  }
  return rows;
}

/**
 * One shape for a stored battle, whether it came from the demo or cc_reports.
 * Reports written before the detail fields still return a banner and the old sentence.
 */
export function battleBrief(report) {
  if (!report || report.kind === "spy" || report.outcome === "caught" || report.outcome === "scouted") return null;
  const outcome = report.outcome;
  if (outcome !== "win" && outcome !== "loss" && report.kind !== "battle") return null;
  const youAttacked = report.you_attacked !== false && report.youAttacked !== false;
  const attackerWon = outcome === "win";
  const victory = youAttacked ? attackerWon : !attackerWon;
  const attackType = report.attack_type || report.attackType || "";
  const spoils = {
    acres: asInt(report.spoils?.acres ?? report.acres),
    gold: asInt(report.spoils?.gold ?? report.gold),
    food: asInt(report.spoils?.food ?? report.food),
    buildings: report.spoils?.buildings || report.buildings || null,
    razed: report.spoils?.razed || report.razed || null,
  };
  const gained = [];
  if (!attackType || attackType === "conquest") {
    if (spoils.acres > 0) gained.push(`${spoils.acres} acres`);
    gained.push(...buildingRows(spoils.buildings, ""));
  }
  if (!attackType || attackType === "plunder") {
    if (spoils.gold > 0) gained.push(`${spoils.gold} gold`);
    if (spoils.food > 0) gained.push(`${spoils.food} food`);
  }
  if (!attackType || attackType === "razing") gained.push(...buildingRows(spoils.razed, " destroyed"));
  const morale = youAttacked ? (attackerWon ? 3 : -8) : (attackerWon ? -6 : 2);
  const yourLoss = unitRows(youAttacked ? (report.att_loss || report.attLoss) : (report.def_loss || report.defLoss));
  const enemyLoss = unitRows(youAttacked ? (report.def_loss || report.defLoss) : (report.att_loss || report.attLoss));
  const returning = youAttacked ? unitRows(report.living) : null;
  const foe = youAttacked ? report.defender : report.attacker;
  return {
    victory,
    youAttacked,
    attackType,
    foe: foe || "the enemy",
    text: report.text || "",
    gained,
    took: youAttacked ? victory : !victory,
    morale,
    yourLoss,
    enemyLoss,
    returning,
    detailed: Boolean(yourLoss || enemyLoss || returning || gained.length || spoils.buildings || spoils.razed),
    aiNote: aiAttackNote(report),
  };
}

/** Shown on a War Room report when an established house (NPC) marched on you. */
export function aiAttackNote(report) {
  if (!report) return "";
  const youAttacked = report.you_attacked !== false && report.youAttacked !== false;
  const npc = report.attacker_npc === true || report.attackerNpc === true;
  if (!youAttacked && npc) return "An established house marched.";
  return "";
}

/**
 * How often an established house marches, and whom it will march on.
 * sql/0008_npc_attacks.sql repeats these numbers.
 * The 6-hour cap of 2 is applied to every defender, not only humans.
 * A roll is an integer 0–99 unless a function says otherwise.
 */
export const NPC_WAR = {
  cooldownMinSec: 2 * 3600,
  cooldownExtraSec: 2 * 3600,
  humanWindowSec: 6 * 3600,
  humanCap: 2,
  sendMinPct: 35,
  sendExtraPct: 16,
  nwMinPct: 40,
  nwMaxPct: 140,
  nwWideMinPct: 25,
  nwWideMaxPct: 180,
  hopelessRatio: 35,
  favoredRatio: 120,
  evenRatio: 80,
  humanBonus: 40,
  sameRealmBonus: 15,
  jitterMax: 30,
  maxArmies: 3,
  incomeTickCap: 12,
};

export function npcCooldownSeconds(roll) {
  const r = clampRoll(roll);
  return NPC_WAR.cooldownMinSec + Math.floor(NPC_WAR.cooldownExtraSec * r / 100);
}

export function npcSendPercent(roll) {
  const r = clampRoll(roll);
  return NPC_WAR.sendMinPct + Math.floor(NPC_WAR.sendExtraPct * r / 100);
}

export function npcSendCounts(units, percent) {
  const pct = Math.max(0, Math.min(100, Math.floor(Number(percent) || 0)));
  const sent = {};
  let total = 0;
  let home = 0;
  for (const id of UNIT_ORDER) {
    const have = Math.max(0, Math.floor(Number(units?.[id]) || 0));
    let n = Math.floor(have * pct / 100);
    if (n > 5000) n = 5000;
    if (n > have) n = have;
    sent[id] = n;
    total += n;
    home += have - n;
  }
  if (total < 1 || home < 1) return null;
  return sent;
}

export function npcNetworthOk(attackerNw, defenderNw, wide = false) {
  const pct = Math.floor(Math.max(0, defenderNw) * 100 / Math.max(1, attackerNw));
  const min = wide ? NPC_WAR.nwWideMinPct : NPC_WAR.nwMinPct;
  const max = wide ? NPC_WAR.nwWideMaxPct : NPC_WAR.nwMaxPct;
  return pct >= min && pct <= max;
}

export function npcHumanOpen(recentHits) {
  return Math.max(0, Math.floor(Number(recentHits) || 0)) < NPC_WAR.humanCap;
}

export function npcTargetScore({ ratio, human, sameRealm, jitter }) {
  const odds = Math.floor(Number(ratio) || 0);
  if (odds < NPC_WAR.hopelessRatio) return null;
  const shake = Math.max(0, Math.min(NPC_WAR.jitterMax, Math.floor(Number(jitter) || 0)));
  return odds
    + (human ? NPC_WAR.humanBonus : 0)
    + (sameRealm ? NPC_WAR.sameRealmBonus : 0)
    + shake;
}

export function npcPickTarget(candidates) {
  let best = null;
  for (const row of candidates || []) {
    if (!row || row.score == null) continue;
    if (!best || row.score > best.score) best = row;
  }
  return best;
}

export function npcAttackType(ratio, roll) {
  const odds = Math.floor(Number(ratio) || 0);
  const r = clampRoll(roll);
  if (odds >= NPC_WAR.favoredRatio) return r < 60 ? "conquest" : "plunder";
  if (odds >= NPC_WAR.evenRatio) return r < 50 ? "plunder" : "razing";
  return r < 70 ? "plunder" : "razing";
}

function clampRoll(roll) {
  const n = Math.floor(Number(roll) || 0);
  return Math.max(0, Math.min(99, n));
}

export function oddsBand(offense, defense) {
  if (defense <= 0) return "favored";
  const ratio = Math.floor(offense * 100 / defense);
  if (ratio >= 120) return "favored";
  if (ratio <= 80) return "outmatched";
  return "even";
}

export function isProtected(state, now) {
  if (!state || state.isNpc) return false;
  if (state.attackedAt) return false;
  return (state.protectedUntil || 0) > now;
}

export function travelSeconds(sameRealm, spy) {
  if (spy) return sameRealm ? WAR.spySame : WAR.spyOther;
  return sameRealm ? WAR.travelSame : WAR.travelOther;
}

export function spyFails(magicLevel, roll) {
  const need = Math.min(90, 70 + magicLevel * 2);
  return roll > need;
}

export function fuzzAmount(value, roll) {
  return Math.floor(Math.max(0, value) * Math.max(85, Math.min(115, roll)) / 100);
}

export function validateTag(tag) {
  const text = String(tag || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{2,5}$/.test(text)) return { error: "Use a tag of 2-5 letters or numbers." };
  return { tag: text };
}

export function validateAllianceName(name) {
  const text = String(name || "").trim();
  if (!/^[A-Za-z][A-Za-z0-9' -]{1,30}[A-Za-z0-9]$/.test(text) || text.includes("  ")) {
    return { error: "Use 3-32 letters for the pact name." };
  }
  return { name: text };
}

export function tagged(name, tag) {
  return tag ? `[${tag}] ${name}` : name;
}

export const NPC_PACTS = [
  {
    id: "irn",
    name: "The Iron Covenant",
    tag: "IRN",
    description: "Ash, pikes, and the oath of the high gates.",
    members: ["Ashford Keep", "Harrowgate", "Cinderwell", "Qasira"],
  },
  {
    id: "verd",
    name: "The Green Company",
    tag: "VERD",
    description: "Timber, harbors, and a shared granary.",
    members: ["Briarholt", "Mossfen", "Pearlwatch", "Saltfen Watch"],
  },
];

export function npcTier(nw) {
  if (nw < 3500) return 1;
  if (nw < 5200) return 2;
  if (nw < 6800) return 3;
  return 4;
}

export function regrowNpc(state, steps) {
  const anchor = state.npcAnchor;
  if (!anchor || steps <= 0) return state;
  const next = state;
  for (let i = 0; i < steps; i += 1) {
    if (next.land < anchor.land) next.land += 1;
    if (next.gold < anchor.gold) next.gold += Math.max(1, Math.floor((anchor.gold - next.gold) / 30));
    if (next.food < anchor.food) next.food += Math.max(1, Math.floor((anchor.food - next.food) / 30));
    let best = null;
    let gap = 0;
    for (const id of UNIT_ORDER) {
      const missing = (anchor.units[id] || 0) - (next.units[id] || 0);
      if (missing > gap) {
        gap = missing;
        best = id;
      }
    }
    if (best) next.units[best] += Math.max(1, Math.floor(gap / 40));
    let hall = null;
    let hallGap = 0;
    for (const id of BUILDING_ORDER) {
      const missing = (anchor.buildings[id] || 0) - (next.buildings[id] || 0);
      if (missing > hallGap) {
        hallGap = missing;
        hall = id;
      }
    }
    if (hall && i % 2 === 0) next.buildings[hall] += 1;
    if ((next.morale ?? 100) < (anchor.morale ?? 100)) next.morale += 1;
  }
  return next;
}

export function buildingName(id) {
  return BUILDINGS[id]?.name || id;
}

export function subtractUnits(have, lost) {
  const next = { ...have };
  for (const id of UNIT_ORDER) next[id] = Math.max(0, (have[id] || 0) - (lost[id] || 0));
  return next;
}

export function addUnits(have, gained) {
  const next = { ...have };
  for (const id of UNIT_ORDER) next[id] = (have[id] || 0) + (gained[id] || 0);
  return next;
}

export function attackBlock({ attacker, defender, sameAlliance, now }) {
  if (!defender) return "No kingdom by that name.";
  if (attacker.name === defender.name) return "You cannot attack your own gates.";
  if (sameAlliance) return "You share an alliance.";
  if (isProtected(defender, now)) return "That kingdom is under protection.";
  return "";
}

export function applyDefenderHit(defender, result, now) {
  const next = defender;
  next.units = subtractUnits(next.units, result.defLoss);
  next.morale = result.defMorale;
  next.lastHitAt = now;
  if (result.spoils.acres > 0) {
    next.land = Math.max(0, next.land - result.spoils.acres);
    for (const id of BUILDING_ORDER) next.buildings[id] = Math.max(0, (next.buildings[id] || 0) - (result.spoils.buildings[id] || 0));
  }
  next.gold = Math.max(0, next.gold - result.spoils.gold);
  next.food = Math.max(0, next.food - result.spoils.food);
  for (const id of BUILDING_ORDER) next.buildings[id] = Math.max(0, (next.buildings[id] || 0) - (result.spoils.razed[id] || 0));
  return next;
}

export function applyReturn(attacker, result) {
  attacker.units = addUnits(attacker.units, result.living);
  attacker.morale = result.attMorale;
  attacker.land += result.spoils.acres || 0;
  attacker.gold += result.spoils.gold || 0;
  attacker.food += result.spoils.food || 0;
  for (const id of BUILDING_ORDER) attacker.buildings[id] = (attacker.buildings[id] || 0) + (result.spoils.buildings[id] || 0);
  return attacker;
}
