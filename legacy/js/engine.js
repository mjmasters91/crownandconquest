/**
 * Pure kingdom rules. No DOM, no network.
 * The SQL migration repeats this math with integer division so a server tick
 * cannot drift from a demo tick.
 */

import {
  BUILDINGS,
  BUILDING_ORDER,
  CREWS,
  DAY_MS,
  ECONOMY,
  LANDS,
  LIMITS,
  STARTING,
  TICK_SECONDS,
  TRACKS,
  TRACK_ORDER,
  UNIT_ORDER,
  UNITS,
  emptyBuildings,
  emptyResearch,
  emptyUnits,
  researchCost,
} from "./rules.js";

const BANK_HOUR = 3600;

export function validateKingdomName(name) {
  const trimmed = String(name || "").trim();
  if (!/^[A-Za-z][A-Za-z0-9' -]{1,22}[A-Za-z0-9]$/.test(trimmed) || trimmed.includes("  ")) {
    return { error: "Use 3-24 letters, and spaces or apostrophes." };
  }
  return { name: trimmed };
}

export function createKingdom({ name, landType, now, realmName, realmSeat }) {
  const named = validateKingdomName(name);
  if (named.error) throw new Error(named.error);
  if (!LANDS[landType]) throw new Error("Choose a land type.");
  const at = now;
  return {
    version: 1,
    name: named.name,
    landType,
    realmName: realmName || "The Amber March",
    realmSeat: realmSeat || "Western vales",
    realmId: null,
    isNpc: false,
    createdAt: at,
    lastTickAt: at,
    exploreResetAt: at + DAY_MS,
    exploredToday: 0,
    nextJobId: 1,
    gold: STARTING.gold,
    goldBank: 0,
    food: STARTING.food,
    foodBank: 0,
    mana: STARTING.mana,
    manaBank: 0,
    researchPoints: STARTING.researchPoints,
    researchBank: 0,
    popProgress: 0,
    peasants: STARTING.peasants,
    land: STARTING.land,
    buildings: { ...STARTING.buildings },
    units: { ...STARTING.units },
    research: emptyResearch(),
    jobs: [],
    marches: [],
    morale: 100,
    spies: 2,
    protectedUntil: at + DAY_MS,
    attackedAt: null,
    lastHitAt: null,
    allianceId: null,
    allianceTag: null,
    allianceRole: null,
    chronicle: [{ at, text: `The banner of ${named.name} was raised.` }],
  };
}

export function kingdomFromRow(row, now, realm) {
  const state = createKingdom({
    name: row.name,
    landType: row.landType,
    now,
    realmName: realm?.name,
    realmSeat: realm?.seat,
  });
  state.isNpc = true;
  state.land = row.land;
  state.gold = row.gold;
  state.food = row.food;
  state.mana = row.mana;
  state.peasants = row.peasants;
  state.researchPoints = row.researchPoints;
  state.buildings = { ...emptyBuildings(), ...row.buildings };
  state.units = { ...emptyUnits(), ...row.units };
  state.research = { ...emptyResearch(), ...row.research };
  state.chronicle = [];
  state.jobs = [];
  return state;
}

function chronicle(state, at, text) {
  state.chronicle.push({ at, text });
  if (state.chronicle.length > 14) state.chronicle.splice(0, state.chronicle.length - 14);
}

export function builtAcres(state) {
  let n = 0;
  for (const id of BUILDING_ORDER) n += state.buildings[id] || 0;
  return n;
}

export function pendingAcres(state) {
  let n = 0;
  for (const job of state.jobs) if (job.kind === "build") n += job.count;
  return n;
}

export function crewCount(state) {
  const guilds = Math.min(CREWS.guildBonusMax, Math.floor(state.buildings?.guild || 0));
  const fromGuilds = guilds * CREWS.perGuild;
  const fromStudy = (state.research?.masons || 0) >= CREWS.masonCrewLevel ? 1 : 0;
  return Math.min(CREWS.cap, CREWS.base + fromGuilds + fromStudy);
}

export function buildHastePct(state) {
  const levels = Math.max(0, Math.min(CREWS.masonMax, Math.floor(state.research?.masons || 0)));
  return levels * CREWS.speedPctPerLevel;
}

export function buildSeconds(state, buildingId, count) {
  const def = BUILDINGS[buildingId];
  const raw = Math.floor(def.seconds * count * LANDS[state.landType].buildPct / 100);
  return Math.max(1, Math.floor(raw * (100 - buildHastePct(state)) / 100));
}

export function crewStatus(state) {
  const busy = (state.jobs || []).filter((job) => job.kind === "build").length;
  const live = state.crewsLive !== false;
  const cap = live && Number.isInteger(state.crewCap) ? state.crewCap : (live ? crewCount(state) : 1);
  return { busy, cap, live, haste: live ? buildHastePct(state) : 0 };
}

export function freeLand(state) {
  return state.land - builtAcres(state) - pendingAcres(state);
}

export function housingCap(state) {
  return 30 + (state.buildings.barracks || 0) * 48;
}

export function housingUsed(state) {
  let n = 0;
  for (const id of UNIT_ORDER) n += (state.units[id] || 0) * UNITS[id].housing;
  for (const job of state.jobs) {
    if (job.kind === "train") n += job.count * UNITS[job.unit].housing;
  }
  return n;
}

export function exploreCap(state) {
  return Math.max(LIMITS.exploreDailyMin, Math.floor(state.land * LIMITS.exploreDailyPct / 100));
}

export function popCap(state) {
  const land = LANDS[state.landType];
  const housingPct = Math.floor(land.housingPct * (100 + state.research.population * 2) / 100);
  const base = Math.floor((90 + state.buildings.home * 24) * housingPct / 100);
  if (state.food <= 0) return Math.floor(base * 72 / 100);
  return base;
}

export function scholars(state) {
  return Math.min(state.peasants, (state.buildings.library || 0) * 14);
}

export function foodRates(state) {
  const land = LANDS[state.landType];
  const foodPct = Math.floor(land.foodPct * (100 + state.research.food * 4) / 100);
  const produced = Math.floor((state.buildings.farm * ECONOMY.farmFood + state.buildings.granary * ECONOMY.granaryFood) * foodPct / 100);
  let upkeep = state.peasants * ECONOMY.peasantUpkeep;
  for (const id of UNIT_ORDER) upkeep += (state.units[id] || 0) * UNITS[id].upkeep;
  const consumed = Math.floor(upkeep / 100);
  return { produced, consumed, net: produced - consumed };
}

export function goldPerHour(state) {
  const land = LANDS[state.landType];
  const pct = Math.floor(land.goldPct * (100 + state.research.economy * 4) / 100);
  const base = state.buildings.market * ECONOMY.marketGold + state.buildings.mine * ECONOMY.mineGold + Math.floor(state.peasants * ECONOMY.peasantTax / 100);
  return Math.floor(base * pct / 100);
}

export function manaRates(state) {
  const land = LANDS[state.landType];
  const pct = Math.floor(land.manaPct * (100 + state.research.magic * 5) / 100);
  const perHour = Math.floor((state.buildings.shrine || 0) * ECONOMY.shrineMana * pct / 100);
  const cap = ECONOMY.manaCapBase + (state.buildings.shrine || 0) * ECONOMY.shrineManaCap;
  return { perHour, cap };
}

export function researchPerHour(state) {
  const land = LANDS[state.landType];
  const pct = Math.floor(land.researchPct * (100 + state.research.magic * 4) / 100);
  return Math.floor(scholars(state) * ECONOMY.scholarResearch * pct / 100);
}

export function armyScores(state) {
  const land = LANDS[state.landType];
  let rawAttack = 0;
  let rawDefense = 0;
  for (const id of UNIT_ORDER) {
    const count = state.units[id] || 0;
    rawAttack += count * UNITS[id].attack;
    rawDefense += count * UNITS[id].defense;
  }
  const atkPct = Math.floor(land.attackPct * (100 + state.research.military * 3) / 100);
  const defPct = Math.floor(land.defensePct * (100 + state.research.military * 3) / 100);
  const starveAtk = state.food <= 0 ? 62 : 100;
  const starveDef = state.food <= 0 ? 75 : 100;
  const attack = Math.floor(Math.floor(rawAttack * atkPct / 100) * starveAtk / 100);
  const fortified = Math.floor(Math.floor(rawDefense * defPct / 100) * starveDef / 100);
  const fort = 1000 + (state.buildings.wall || 0) * 40 + (state.buildings.tower || 0) * 30;
  const defense = Math.floor(fortified * fort / 1000);
  return { attack, defense, rawAttack, rawDefense };
}

export function networth(state) {
  let n = state.land * 8 + Math.floor(state.peasants * 5 / 2);
  n += Math.floor(state.gold / 80) + Math.floor(state.food / 80) + Math.floor(state.mana / 40);
  for (const id of BUILDING_ORDER) n += (state.buildings[id] || 0) * BUILDINGS[id].networth;
  for (const id of UNIT_ORDER) n += (state.units[id] || 0) * UNITS[id].networth;
  for (const id of TRACK_ORDER) n += (state.research[id] || 0) * 60;
  return n;
}

export function describe(state) {
  const food = foodRates(state);
  const mana = manaRates(state);
  const army = armyScores(state);
  const capAcres = exploreCap(state);
  return {
    networth: networth(state),
    starving: state.food <= 0,
    food,
    goldPerHour: goldPerHour(state),
    mana,
    researchPerHour: researchPerHour(state),
    scholars: scholars(state),
    popCap: popCap(state),
    housingCap: housingCap(state),
    housingUsed: housingUsed(state),
    freeLand: freeLand(state),
    built: builtAcres(state),
    pending: pendingAcres(state),
    army,
    exploreCap: capAcres,
    exploreLeft: Math.max(0, capAcres - state.exploredToday),
    nextTickAt: state.lastTickAt + TICK_SECONDS * 1000,
    land: LANDS[state.landType],
  };
}

function creditBank(value, bank, perHour) {
  let nextBank = bank + perHour * TICK_SECONDS;
  let next = value;
  if (nextBank >= BANK_HOUR) {
    const gain = Math.floor(nextBank / BANK_HOUR);
    next += gain;
    nextBank -= gain * BANK_HOUR;
  }
  if (next > LIMITS.resourceCap) {
    next = LIMITS.resourceCap;
    nextBank = 0;
  }
  return { value: next, bank: nextBank };
}

function applyFood(state, produced, consumed) {
  state.foodBank += (produced - consumed) * TICK_SECONDS;
  if (state.foodBank >= BANK_HOUR) {
    const gain = Math.floor(state.foodBank / BANK_HOUR);
    state.food += gain;
    state.foodBank -= gain * BANK_HOUR;
  }
  if (state.food > LIMITS.resourceCap) {
    state.food = LIMITS.resourceCap;
    state.foodBank = 0;
  }
  if (state.foodBank < 0) {
    const pull = Math.floor((-state.foodBank + BANK_HOUR - 1) / BANK_HOUR);
    const take = Math.min(state.food, pull);
    state.food -= take;
    state.foodBank += take * BANK_HOUR;
  }
  let starveSeconds = 0;
  if (state.foodBank < 0) {
    const unpaid = -state.foodBank;
    starveSeconds = consumed > 0 ? Math.min(TICK_SECONDS, Math.floor(unpaid / consumed)) : TICK_SECONDS;
    state.foodBank = 0;
    state.food = 0;
  }
  return starveSeconds;
}

function applyPopulation(state, starveSeconds, consumed) {
  const land = LANDS[state.landType];
  const cap = popCap(state);
  if (state.food >= 1 && state.peasants < cap) {
    const thin = consumed > 0 && state.food < consumed * 6 ? 35 : 100;
    const birthPct = land.birthPct;
    const researchBirth = 100 + state.research.population * 3;
    const milliPerHour = Math.floor(state.peasants * 10 * birthPct * researchBirth * thin / 1000000);
    state.popProgress += Math.floor(milliPerHour * TICK_SECONDS / BANK_HOUR);
  }
  if (starveSeconds > 0 && state.food <= 0) {
    state.popProgress -= Math.floor(state.peasants * 18 * starveSeconds / BANK_HOUR);
  }
  if (state.peasants > cap) {
    const milliPerHour = (state.peasants - cap) * 80;
    state.popProgress -= Math.floor(milliPerHour * TICK_SECONDS / BANK_HOUR);
  }
  if (state.popProgress >= 1000 && state.peasants < cap) {
    let born = Math.floor(state.popProgress / 1000);
    born = Math.min(born, cap - state.peasants);
    state.peasants += born;
    state.popProgress -= born * 1000;
  }
  if (state.peasants >= cap && state.popProgress > 0) state.popProgress = 0;
  if (state.popProgress <= -1000) {
    let died = Math.floor(-state.popProgress / 1000);
    died = Math.min(died, state.peasants);
    state.peasants -= died;
    state.popProgress += died * 1000;
  }
  if (state.peasants > LIMITS.peopleCap) state.peasants = LIMITS.peopleCap;
}

function finishJob(state, job, at) {
  if (job.kind === "build") {
    state.buildings[job.building] += job.count;
    const label = BUILDINGS[job.building].name;
    chronicle(state, at, `${label} finished (${job.count}).`);
    return `${label} ×${job.count}`;
  }
  if (job.kind === "explore") {
    state.land += job.count;
    state.peasants += job.settlers;
    chronicle(state, at, `Scouts claimed ${job.count} acres.`);
    return `${job.count} acres`;
  }
  state.units[job.unit] += job.count;
  const label = UNITS[job.unit].name;
  chronicle(state, at, `${label} finished training (${job.count}).`);
  return `${label} ×${job.count}`;
}

function resetExploreWindow(state, now) {
  let guard = 0;
  while (state.exploreResetAt <= now && guard < 40) {
    state.exploredToday = 0;
    state.exploreResetAt += DAY_MS;
    guard += 1;
  }
}

export function settle(state, now, opts = {}) {
  const maxTicks = opts.maxTicks ?? 240;
  const next = structuredClone(state);
  resetExploreWindow(next, now);
  const before = {
    gold: next.gold,
    food: next.food,
    mana: next.mana,
    research: next.researchPoints,
    peasants: next.peasants,
  };
  const finished = [];
  let ticks = 0;
  while (ticks < maxTicks) {
    const boundary = next.lastTickAt + TICK_SECONDS * 1000;
    if (boundary > now) break;
    const keep = [];
    for (const job of next.jobs) {
      if (job.completesAt <= boundary) finished.push(finishJob(next, job, boundary));
      else keep.push(job);
    }
    next.jobs = keep;
    const food = foodRates(next);
    const gold = creditBank(next.gold, next.goldBank, goldPerHour(next));
    next.gold = gold.value;
    next.goldBank = gold.bank;
    const starveSeconds = applyFood(next, food.produced, food.consumed);
    const mana = manaRates(next);
    const manaCredit = creditBank(next.mana, next.manaBank, mana.perHour);
    next.mana = Math.min(mana.cap, manaCredit.value);
    next.manaBank = next.mana >= mana.cap ? 0 : manaCredit.bank;
    const study = creditBank(next.researchPoints, next.researchBank, researchPerHour(next));
    next.researchPoints = study.value;
    next.researchBank = study.bank;
    applyPopulation(next, starveSeconds, food.consumed);
    next.lastTickAt = boundary;
    ticks += 1;
  }
  const behind = next.lastTickAt + TICK_SECONDS * 1000 <= now;
  if (!behind) {
    const still = [];
    for (const job of next.jobs) {
      if (job.completesAt <= now) finished.push(finishJob(next, job, now));
      else still.push(job);
    }
    next.jobs = still;
  }
  return {
    state: next,
    summary: {
      ticks,
      gold: next.gold - before.gold,
      food: next.food - before.food,
      mana: next.mana - before.mana,
      research: next.researchPoints - before.research,
      peasants: next.peasants - before.peasants,
      finished,
      behind,
    },
  };
}

function needCount(count, min, max, label) {
  if (!Number.isInteger(count) || count < min || count > max) {
    throw new Error(label);
  }
}

export function orderBuild(state, buildingId, count, now) {
  const settled = settle(state, now);
  const next = settled.state;
  const def = BUILDINGS[buildingId];
  if (!def) throw new Error("Unknown building.");
  needCount(count, LIMITS.buildMin, LIMITS.buildMax, "Build between 1 and 40.");
  const crews = crewStatus(next);
  if (crews.busy >= crews.cap) throw new Error(`All construction crews are busy (${crews.busy}/${crews.cap}).`);
  if (count > freeLand(next)) throw new Error("Not enough open land.");
  const cost = def.cost * count;
  if (next.gold < cost) throw new Error("Not enough gold.");
  next.gold -= cost;
  const seconds = buildSeconds(next, buildingId, count);
  next.jobs.push({
    id: next.nextJobId++,
    kind: "build",
    building: buildingId,
    unit: null,
    count,
    settlers: 0,
    startedAt: now,
    completesAt: now + seconds * 1000,
  });
  chronicle(next, now, `Work began on ${count} ${def.name}.`);
  return { state: next, summary: settled.summary };
}

export function quoteExplore(state, acres) {
  const land = LANDS[state.landType];
  const per = land.exploreGold + Math.floor(state.land / 50);
  const safe = Math.max(0, Math.floor(Number(acres) || 0));
  return {
    per,
    cost: safe * per,
    seconds: safe * land.exploreSeconds,
    settlers: Math.floor((safe + 5) / 6),
    cap: exploreCap(state),
    left: Math.max(0, exploreCap(state) - state.exploredToday),
  };
}

export function orderExplore(state, acres, now) {
  const settled = settle(state, now);
  const next = settled.state;
  needCount(acres, LIMITS.exploreMin, LIMITS.exploreMax, "Explore between 1 and 200 acres.");
  if (next.jobs.some((job) => job.kind === "explore")) throw new Error("An expedition is already in the field.");
  const quote = quoteExplore(next, acres);
  if (next.exploredToday + acres > quote.cap) throw new Error("That exceeds today's charter.");
  if (next.gold < quote.cost) throw new Error("Not enough gold.");
  if (next.peasants - quote.settlers < LIMITS.peasantReserve) throw new Error("Leave at least 20 peasants at home.");
  next.gold -= quote.cost;
  next.peasants -= quote.settlers;
  next.exploredToday += acres;
  next.jobs.push({
    id: next.nextJobId++,
    kind: "explore",
    building: null,
    unit: null,
    count: acres,
    settlers: quote.settlers,
    startedAt: now,
    completesAt: now + quote.seconds * 1000,
  });
  chronicle(next, now, `Scouts left to claim ${acres} acres.`);
  return { state: next, summary: settled.summary };
}

export function unitUnlocked(state, unitId) {
  const def = UNITS[unitId];
  if (!def) return false;
  if (!def.req) return true;
  if (def.req.military && state.research.military < def.req.military) return false;
  if (def.req.magic && state.research.magic < def.req.magic) return false;
  return true;
}

export function quoteTrain(state, unitId, count) {
  const def = UNITS[unitId];
  const safe = Math.max(0, Math.floor(Number(count) || 0));
  if (!def || safe < 1) return null;
  const batches = Math.floor((safe + def.batch - 1) / def.batch);
  const seconds = Math.floor(batches * def.seconds * LANDS[state.landType].trainPct / 100);
  return {
    gold: def.gold * safe,
    food: def.food * safe,
    peasants: def.peasants * safe,
    housing: def.housing * safe,
    seconds,
  };
}

export function orderTrain(state, unitId, count, now) {
  const settled = settle(state, now);
  const next = settled.state;
  const def = UNITS[unitId];
  if (!def) throw new Error("Unknown unit.");
  if ((next.buildings.barracks || 0) < 1) throw new Error("Build a barracks before you train.");
  needCount(count, LIMITS.trainMin, LIMITS.trainMax, "Train between 1 and 200.");
  if (!unitUnlocked(next, unitId)) throw new Error("That college is not open yet.");
  if (next.jobs.some((job) => job.kind === "train")) throw new Error("A company is already in training.");
  const quote = quoteTrain(next, unitId, count);
  if (housingUsed(next) + quote.housing > housingCap(next)) throw new Error("The barracks cannot house them.");
  if (next.gold < quote.gold) throw new Error("Not enough gold.");
  if (next.food < quote.food) throw new Error("Not enough food.");
  if (next.peasants - quote.peasants < LIMITS.peasantReserve) throw new Error("Leave at least 20 peasants to work the land.");
  next.gold -= quote.gold;
  next.food -= quote.food;
  next.peasants -= quote.peasants;
  next.jobs.push({
    id: next.nextJobId++,
    kind: "train",
    building: null,
    unit: unitId,
    count,
    settlers: 0,
    startedAt: now,
    completesAt: now + quote.seconds * 1000,
  });
  chronicle(next, now, `${count} ${def.name} began training.`);
  return { state: next, summary: settled.summary };
}

export function orderResearch(state, trackId, now) {
  const settled = settle(state, now);
  const next = settled.state;
  if (!TRACKS[trackId]) throw new Error("Unknown college.");
  const level = next.research[trackId] || 0;
  const max = TRACKS[trackId].max || LIMITS.researchMax;
  if (level >= max) throw new Error("That college is fully studied.");
  const cost = researchCost(level);
  if (next.researchPoints < cost) throw new Error("Not enough research.");
  next.researchPoints -= cost;
  next.research[trackId] = level + 1;
  chronicle(next, now, `${TRACKS[trackId].name} reached level ${level + 1}.`);
  return { state: next, summary: settled.summary };
}

export function grantResources(state, { gold = 0, food = 0, land = 0 } = {}) {
  const addGold = gold || 0;
  const addFood = food || 0;
  const addLand = land || 0;
  if (!Number.isInteger(addGold) || !Number.isInteger(addFood) || !Number.isInteger(addLand)) {
    throw new Error("Grants must be zero or positive.");
  }
  if (addGold < 0 || addFood < 0 || addLand < 0) throw new Error("Grants must be zero or positive.");
  if (addGold === 0 && addFood === 0 && addLand === 0) throw new Error("Grant at least one thing.");
  if (addGold > LIMITS.grantGoldMax || addFood > LIMITS.grantFoodMax || addLand > LIMITS.grantLandMax) {
    throw new Error("That grant is too large.");
  }
  const next = structuredClone(state);
  next.gold = Math.min(LIMITS.resourceCap, next.gold + addGold);
  next.food = Math.min(LIMITS.resourceCap, next.food + addFood);
  next.land = Math.min(LIMITS.peopleCap, next.land + addLand);
  return next;
}

export function signedPercent(hundredths) {
  const delta = hundredths - 100;
  if (!delta) return null;
  const sign = delta > 0 ? "+" : "−";
  return `${sign}${Math.abs(delta)}%`;
}

export function landTraits(land) {
  const rows = [
    [signedPercent(land.foodPct), "food"],
    [signedPercent(land.goldPct), "gold"],
    [signedPercent(land.birthPct), "births"],
    [signedPercent(land.housingPct), "housing"],
    [signedPercent(land.attackPct), "attack"],
    [signedPercent(land.defensePct), "defense"],
    [signedPercent(land.manaPct), "mana"],
    [signedPercent(land.researchPct), "research"],
    [signedPercent(land.buildPct), "build time"],
    [signedPercent(land.trainPct), "training time"],
  ];
  return rows.filter((row) => row[0]).map((row) => `${row[0]} ${row[1]}`);
}

export function roster(player, others) {
  const rows = [
    {
      name: player.name,
      landType: player.landType,
      land: player.land,
      networth: networth(player),
      npc: false,
      you: true,
    },
    ...others.map((kingdom) => ({
      name: kingdom.name,
      landType: kingdom.landType,
      land: kingdom.land,
      networth: networth(kingdom),
      npc: true,
      you: false,
    })),
  ];
  rows.sort((a, b) => b.networth - a.networth || a.name.localeCompare(b.name));
  return rows;
}
