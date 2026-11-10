/**
 * Demo-world marches and pacts. Outcomes come from combat.js, never from the page.
 */

import { BUILDING_ORDER, UNIT_ORDER } from "./rules.js";
import { networth } from "./engine.js";
import {
  NPC_PACTS,
  WAR,
  applyDefenderHit,
  applyReturn,
  attackBlock,
  fuzzAmount,
  npcTier,
  defenseOf,
  oddsBand,
  offenseOf,
  regrowNpc,
  resolveBattle,
  spyFails,
  subtractUnits,
  travelSeconds,
  unitTotal,
  validateAllianceName,
  validateTag,
} from "./combat.js";

function clone(value) {
  return structuredClone(value);
}

function note(state, at, text) {
  state.chronicle = state.chronicle || [];
  state.chronicle.push({ at, text });
  if (state.chronicle.length > 14) state.chronicle.splice(0, state.chronicle.length - 14);
}

export function stampNpc(state) {
  state.morale = state.morale ?? 100;
  state.spies = 0;
  state.isNpc = true;
  state.protectedUntil = null;
  state.attackedAt = null;
  state.lastHitAt = null;
  state.marches = [];
  state.npcTier = npcTier(networth(state));
  state.npcAnchor = {
    land: state.land,
    gold: state.gold,
    food: state.food,
    morale: 100,
    units: { ...state.units },
    buildings: { ...state.buildings },
  };
  return state;
}

export function freshPacts(npcs) {
  const alliances = NPC_PACTS.map((pact) => ({
    id: pact.id,
    name: pact.name,
    tag: pact.tag,
    description: pact.description,
    leader: pact.members[0],
  }));
  const members = [];
  for (const pact of NPC_PACTS) {
    pact.members.forEach((name, index) => {
      const npc = npcs.find((row) => row.name === name);
      if (!npc) return;
      npc.allianceId = pact.id;
      npc.allianceTag = pact.tag;
      npc.allianceRole = index === 0 ? "leader" : "member";
      members.push({ allianceId: pact.id, name, role: npc.allianceRole });
    });
  }
  return { alliances, members, requests: [] };
}

function pactOf(world, name) {
  const member = world.members.find((row) => row.name === name);
  if (!member) return null;
  const alliance = world.alliances.find((row) => row.id === member.allianceId);
  return alliance ? { ...alliance, role: member.role } : null;
}

function samePact(world, a, b) {
  const left = world.members.find((row) => row.name === a);
  const right = world.members.find((row) => row.name === b);
  return Boolean(left && right && left.allianceId === right.allianceId);
}

export function warView(save) {
  const mine = pactOf(save, save.kingdom.name);
  const members = mine
    ? save.members.filter((row) => row.allianceId === mine.id).map((row) => {
      const kingdom = row.name === save.kingdom.name ? save.kingdom : save.npcs.find((npc) => npc.name === row.name);
      return {
        name: row.name,
        role: row.role,
        tag: mine.tag,
        land: kingdom?.land || 0,
        networth: kingdom ? networth(kingdom) : 0,
        npc: Boolean(kingdom?.isNpc),
        you: row.name === save.kingdom.name,
      };
    }).sort((a, b) => b.networth - a.networth)
    : [];
  const requests = (save.requests || []).filter((row) => row.status === "pending" && (
    row.name === save.kingdom.name || (mine && row.allianceId === mine.id && (mine.role === "leader" || mine.role === "officer"))
  ));
  const browse = save.alliances.map((alliance) => {
    const roster = save.members.filter((row) => row.allianceId === alliance.id);
    const total = roster.reduce((sum, row) => {
      const kingdom = row.name === save.kingdom.name ? save.kingdom : save.npcs.find((npc) => npc.name === row.name);
      return sum + (kingdom ? networth(kingdom) : 0);
    }, 0);
    return { ...alliance, members: roster.length, networth: total, yours: mine?.id === alliance.id };
  }).sort((a, b) => b.networth - a.networth);
  return { mine, members, requests, browse };
}

function requireKingdom(save, name) {
  if (save.kingdom.name === name) return save.kingdom;
  return save.npcs.find((row) => row.name === name) || null;
}

export function sendArmy(save, targetName, type, sent, now) {
  const next = clone(save);
  const attacker = next.kingdom;
  const defender = requireKingdom(next, targetName);
  const block = attackBlock({
    attacker,
    defender,
    sameAlliance: defender ? samePact(next, attacker.name, defender.name) : false,
    now,
  });
  if (block) throw new Error(block);
  if (!["conquest", "plunder", "razing"].includes(type)) throw new Error("Choose a raid.");
  const army = {};
  let total = 0;
  for (const id of UNIT_ORDER) {
    const count = Math.floor(Number(sent?.[id] || 0));
    if (!Number.isInteger(count) || count < 0) throw new Error("Choose how many to send.");
    if (count > (attacker.units[id] || 0)) throw new Error("Not enough soldiers at home.");
    army[id] = count;
    total += count;
  }
  if (total <= 0) throw new Error("Send at least one soldier.");
  const armies = (attacker.marches || []).filter((row) => row.kind === "army");
  if (armies.length >= WAR.maxArmies) throw new Error("Three hosts are already in the field.");
  if (armies.some((row) => row.target === defender.name)) throw new Error("A host is already marching on that kingdom.");
  attacker.units = subtractUnits(attacker.units, army);
  attacker.attackedAt = attacker.attackedAt || now;
  attacker.protectedUntil = now;
  const seconds = travelSeconds(attacker.realmName === defender.realmName, false);
  const clock = attacker.lastTickAt || now;
  attacker.marches = attacker.marches || [];
  attacker.marches.push({
    id: `${now}-a-${defender.name}`,
    kind: "army",
    phase: "out",
    attackType: type,
    target: defender.name,
    targetRealm: defender.realmName,
    units: army,
    result: null,
    startedAt: clock,
    arrivesAt: clock + seconds * 1000,
  });
  note(attacker, now, `Your host marched on ${defender.name}.`);
  return next;
}

export function sendSpy(save, targetName, now) {
  const next = clone(save);
  const attacker = next.kingdom;
  const defender = requireKingdom(next, targetName);
  if (!defender) throw new Error("No kingdom by that name.");
  if (attacker.name === defender.name) throw new Error("You already know your own stores.");
  if ((attacker.spies || 0) < 1) throw new Error("You have no spies to send.");
  const missions = (attacker.marches || []).filter((row) => row.kind === "spy");
  if (missions.length >= 3) throw new Error("Three spies are already abroad.");
  if (missions.some((row) => row.target === defender.name)) throw new Error("A spy is already watching that kingdom.");
  attacker.spies -= 1;
  attacker.marches = attacker.marches || [];
  const seconds = travelSeconds(attacker.realmName === defender.realmName, true);
  const clock = attacker.lastTickAt || now;
  attacker.marches.push({
    id: `${now}-s-${defender.name}`,
    kind: "spy",
    phase: "out",
    target: defender.name,
    startedAt: clock,
    arrivesAt: clock + seconds * 1000,
    roll: 1 + Math.floor(Math.random() * 100),
    fuzz: 85 + Math.floor(Math.random() * 31),
  });
  note(attacker, now, `A spy slipped toward ${defender.name}.`);
  return next;
}

export function buySpies(save, count) {
  const next = clone(save);
  const n = Math.floor(Number(count));
  if (!Number.isInteger(n) || n < 1 || n > 10) throw new Error("Buy between 1 and 10 spies.");
  const cost = n * WAR.spyCost;
  if (next.kingdom.gold < cost) throw new Error("Not enough gold.");
  if ((next.kingdom.spies || 0) + n > WAR.spyMax) throw new Error("The spyhall cannot house that many.");
  next.kingdom.gold -= cost;
  next.kingdom.spies = (next.kingdom.spies || 0) + n;
  return next;
}

function findDefender(save, name) {
  if (save.kingdom.name === name) return save.kingdom;
  return save.npcs.find((row) => row.name === name) || null;
}

export function settleMarches(save, now) {
  const next = clone(save);
  next.reports = next.reports || [];
  const clock = Math.max(now, next.kingdom.lastTickAt || now);
  for (const npc of next.npcs) {
    const steps = npc.lastTickAt ? Math.max(0, Math.floor((clock - npc.lastTickAt) / 60000)) : 0;
    regrowNpc(npc, Math.min(steps, 200));
    npc.lastTickAt = clock;
  }
  const keep = [];
  next.kingdom.marches = next.kingdom.marches || [];
  for (const march of next.kingdom.marches) {
    if (march.arrivesAt > clock) {
      keep.push(march);
      continue;
    }
    const defender = findDefender(next, march.target);
    if (!defender) continue;
    if (march.kind === "spy" && march.phase === "out") {
      const caught = spyFails(next.kingdom.research?.magic || 0, march.roll || 50);
      const report = {
        id: march.id,
        at: clock,
        kind: "spy",
        outcome: caught ? "caught" : "scouted",
        attacker: next.kingdom.name,
        defender: defender.name,
        attackerTag: next.kingdom.allianceTag || "",
        defenderTag: defender.allianceTag || "",
        text: caught
          ? `Your spy was caught at ${defender.name}.`
          : `A spy reports on ${defender.name}.`,
        scout: caught ? null : {
          land: fuzzAmount(defender.land, march.fuzz),
          gold: fuzzAmount(defender.gold, march.fuzz),
          food: fuzzAmount(defender.food, march.fuzz),
          defense: fuzzAmount(defenseOf(defender), march.fuzz),
          units: Object.fromEntries(UNIT_ORDER.map((id) => [id, fuzzAmount(defender.units[id] || 0, march.fuzz)])),
        },
      };
      next.reports.unshift(report);
      note(next.kingdom, clock, report.text);
      if (!caught) {
        keep.push({ ...march, phase: "back", arrivesAt: clock + travelSeconds(next.kingdom.realmName === defender.realmName, true) * 1000 });
      }
      continue;
    }
    if (march.kind === "spy" && march.phase === "back") {
      next.kingdom.spies = (next.kingdom.spies || 0) + 1;
      note(next.kingdom, clock, `Your spy slipped home from ${defender.name}.`);
      continue;
    }
    if (march.kind === "army" && march.phase === "out") {
      const result = resolveBattle({
        attacker: next.kingdom,
        defender,
        sent: march.units,
        type: march.attackType,
        roll: 85 + Math.floor(Math.random() * 31),
        now: clock,
      });
      applyDefenderHit(defender, result, clock);
      note(defender, clock, result.defenderText);
      next.kingdom.morale = result.attMorale;
      const report = {
        id: march.id,
        at: clock,
        kind: "battle",
        outcome: result.win ? "win" : "loss",
        attackType: march.attackType,
        attacker: next.kingdom.name,
        defender: defender.name,
        attackerTag: next.kingdom.allianceTag || "",
        defenderTag: defender.allianceTag || "",
        text: result.text,
        defenderText: result.defenderText,
        offense: result.offense,
        defense: result.defense,
        roll: result.roll,
        spoils: result.spoils,
        attLoss: result.attLoss,
        defLoss: result.defLoss,
        living: result.living,
        youAttacked: true,
      };
      next.reports.unshift(report);
      note(next.kingdom, clock, `Your host reached ${defender.name}.`);
      keep.push({
        ...march,
        phase: "back",
        result,
        arrivesAt: clock + travelSeconds(next.kingdom.realmName === defender.realmName, false) * 1000,
      });
      continue;
    }
    if (march.kind === "army" && march.phase === "back") {
      applyReturn(next.kingdom, march.result);
      note(next.kingdom, clock, march.result.text);
    }
  }
  next.kingdom.marches = keep;
  next.reports = next.reports.slice(0, 30);
  return next;
}

export function previewOdds(save, targetName, sent) {
  const defender = requireKingdom(save, targetName);
  if (!defender) return { band: "unknown", offense: 0, note: "Unknown kingdom." };
  const offense = offenseOf(save.kingdom, sent);
  const recent = (save.reports || []).find((row) => row.kind === "spy" && row.defender === defender.name && row.scout);
  if (!recent) {
    const scale = Math.round(sizeScale(networth(save.kingdom), networth(defender)));
    return {
      band: "unknown",
      offense,
      note: scale < 100
        ? `Your strength on the road is ${offense}. A heavier crown takes less from a smaller house (about ${scale}%). Scout them to judge the walls.`
        : `Your strength on the road is ${offense}. Scout them before you trust the odds.`,
    };
  }
  const band = oddsBand(offense, recent.scout.defense || 0);
  return { band, offense, note: `From the last scout, the fight looks ${band}. Your strength on the road is ${offense}.` };
}

export function createPact(save, name, tag, description) {
  const next = clone(save);
  if (pactOf(next, next.kingdom.name)) throw new Error("You already belong to a pact.");
  const named = validateAllianceName(name);
  if (named.error) throw new Error(named.error);
  const tagged = validateTag(tag);
  if (tagged.error) throw new Error(tagged.error);
  if (next.alliances.some((row) => row.name.toLowerCase() === named.name.toLowerCase())) throw new Error("That pact name is already claimed.");
  if (next.alliances.some((row) => row.tag === tagged.tag)) throw new Error("That tag is already carried.");
  const id = `pact-${named.name.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
  const blurb = String(description || "").trim().slice(0, 200);
  next.alliances.push({ id, name: named.name, tag: tagged.tag, description: blurb, leader: next.kingdom.name });
  next.members.push({ allianceId: id, name: next.kingdom.name, role: "leader" });
  next.kingdom.allianceId = id;
  next.kingdom.allianceTag = tagged.tag;
  next.kingdom.allianceRole = "leader";
  return next;
}

export function requestJoin(save, allianceId) {
  const next = clone(save);
  if (pactOf(next, next.kingdom.name)) throw new Error("You already belong to a pact.");
  const alliance = next.alliances.find((row) => row.id === allianceId);
  if (!alliance) throw new Error("That pact does not exist.");
  if (next.members.filter((row) => row.allianceId === allianceId).length >= WAR.allianceMax) throw new Error("That pact is full.");
  if (next.requests.some((row) => row.status === "pending" && row.kind === "join" && row.name === next.kingdom.name && row.allianceId === allianceId)) {
    throw new Error("You already asked to join that pact.");
  }
  next.requests.push({
    id: `req-${allianceId}-${next.kingdom.name}`,
    allianceId,
    name: next.kingdom.name,
    kind: "join",
    status: "pending",
  });
  return next;
}

export function answerRequest(save, requestId, accept) {
  const next = clone(save);
  const request = next.requests.find((row) => row.id === requestId && row.status === "pending");
  if (!request) throw new Error("That request is already settled.");
  const mine = pactOf(next, next.kingdom.name);
  const alliance = next.alliances.find((row) => row.id === request.allianceId);
  if (!alliance) throw new Error("That pact does not exist.");
  if (request.kind === "join") {
    const officer = mine && mine.id === alliance.id && (mine.role === "leader" || mine.role === "officer");
    const demoCouncil = alliance.leader !== next.kingdom.name && request.name === next.kingdom.name && NPC_PACTS.some((row) => row.id === alliance.id);
    if (!officer && !demoCouncil) throw new Error("Only the leader or an officer can answer that.");
    if (demoCouncil && accept && networth(next.kingdom) < 3500) {
      request.status = "declined";
      throw new Error("The council declined. Grow your networth and ask again.");
    }
  } else if (request.name !== next.kingdom.name) {
    throw new Error("That invitation is not yours.");
  }
  if (!accept) {
    request.status = "declined";
    return next;
  }
  if (next.members.some((row) => row.name === request.name)) throw new Error("That kingdom already has a pact.");
  if (next.members.filter((row) => row.allianceId === alliance.id).length >= WAR.allianceMax) throw new Error("That pact is full.");
  request.status = "accepted";
  next.members.push({ allianceId: alliance.id, name: request.name, role: "member" });
  const kingdom = requireKingdom(next, request.name);
  if (kingdom) {
    kingdom.allianceId = alliance.id;
    kingdom.allianceTag = alliance.tag;
    kingdom.allianceRole = "member";
  }
  return next;
}

export function inviteKingdom(save, targetName) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine || mine.role !== "leader") throw new Error("Only the leader can invite.");
  const target = requireKingdom(next, targetName);
  if (!target) throw new Error("No kingdom by that name.");
  if (pactOf(next, target.name)) throw new Error("That kingdom already has a pact.");
  if (next.members.filter((row) => row.allianceId === mine.id).length >= WAR.allianceMax) throw new Error("Your pact is full.");
  if (target.isNpc) {
    next.members.push({ allianceId: mine.id, name: target.name, role: "member" });
    target.allianceId = mine.id;
    target.allianceTag = mine.tag;
    target.allianceRole = "member";
    return next;
  }
  next.requests.push({
    id: `inv-${mine.id}-${target.name}`,
    allianceId: mine.id,
    name: target.name,
    kind: "invite",
    status: "pending",
  });
  return next;
}

export function leavePact(save) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine) throw new Error("You are not in a pact.");
  if (mine.role === "leader") throw new Error("Transfer the crown or disband the pact.");
  next.members = next.members.filter((row) => row.name !== next.kingdom.name);
  next.kingdom.allianceId = null;
  next.kingdom.allianceTag = null;
  next.kingdom.allianceRole = null;
  return next;
}

export function kickMember(save, name) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine || mine.role !== "leader") throw new Error("Only the leader can dismiss a house.");
  if (name === next.kingdom.name) throw new Error("You cannot dismiss yourself.");
  const member = next.members.find((row) => row.allianceId === mine.id && row.name === name);
  if (!member) throw new Error("That house is not in your pact.");
  next.members = next.members.filter((row) => !(row.allianceId === mine.id && row.name === name));
  const kingdom = requireKingdom(next, name);
  if (kingdom) {
    kingdom.allianceId = null;
    kingdom.allianceTag = null;
    kingdom.allianceRole = null;
  }
  return next;
}

export function setOfficer(save, name, officer) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine || mine.role !== "leader") throw new Error("Only the leader can name officers.");
  const member = next.members.find((row) => row.allianceId === mine.id && row.name === name);
  if (!member || member.role === "leader") throw new Error("That house cannot take that rank.");
  member.role = officer ? "officer" : "member";
  const kingdom = requireKingdom(next, name);
  if (kingdom) kingdom.allianceRole = member.role;
  return next;
}

export function transferPact(save, name) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine || mine.role !== "leader") throw new Error("Only the leader can hand over the pact.");
  const member = next.members.find((row) => row.allianceId === mine.id && row.name === name);
  if (!member) throw new Error("That house is not in your pact.");
  const self = next.members.find((row) => row.name === next.kingdom.name);
  self.role = "officer";
  member.role = "leader";
  const alliance = next.alliances.find((row) => row.id === mine.id);
  alliance.leader = name;
  next.kingdom.allianceRole = "officer";
  const kingdom = requireKingdom(next, name);
  if (kingdom) kingdom.allianceRole = "leader";
  return next;
}

export function disbandPact(save) {
  const next = clone(save);
  const mine = pactOf(next, next.kingdom.name);
  if (!mine || mine.role !== "leader") throw new Error("Only the leader can disband the pact.");
  for (const member of next.members.filter((row) => row.allianceId === mine.id)) {
    const kingdom = requireKingdom(next, member.name);
    if (kingdom) {
      kingdom.allianceId = null;
      kingdom.allianceTag = null;
      kingdom.allianceRole = null;
    }
  }
  next.members = next.members.filter((row) => row.allianceId !== mine.id);
  next.alliances = next.alliances.filter((row) => row.id !== mine.id);
  next.requests = next.requests.filter((row) => row.allianceId !== mine.id);
  return next;
}

export function incomingArmies(save) {
  return (save.kingdom.marches || []).filter((row) => row.kind === "army" && row.phase === "out" && row.target === save.kingdom.name);
}

export function sentSummary(sent) {
  return UNIT_ORDER.filter((id) => (sent?.[id] || 0) > 0).map((id) => `${sent[id]} ${id}`);
}
