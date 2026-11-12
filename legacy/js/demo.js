import { createKingdom, kingdomFromRow } from "./engine.js";
import { NPC_TABLE } from "./rules.js";
import { freshPacts, stampNpc } from "./war.js";

const KEY = "crown_conquest_demo_v1";

export function loadDemo() {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) || "null");
    if (!raw || raw.version !== 1) return null;
    if (!raw.kingdom?.name && !raw.season) return null;
    return raw;
  } catch {
    return null;
  }
}

export function saveDemo(save) {
  localStorage.setItem(KEY, JSON.stringify({ ...save, version: 1 }));
}

export function clearDemo() {
  localStorage.removeItem(KEY);
}

export function freshDemo({ name, landType, now }) {
  const realm = { name: "The Amber March", seat: "Western vales" };
  const kingdom = createKingdom({
    name,
    landType,
    now,
    realmName: realm.name,
    realmSeat: realm.seat,
  });
  const npcs = NPC_TABLE.map((row) => stampNpc(kingdomFromRow(row, now, realm)));
  const pacts = freshPacts(npcs);
  return {
    version: 1,
    kingdom,
    npcs,
    alliances: pacts.alliances,
    members: pacts.members,
    requests: [],
    reports: [],
    adminLog: [],
    banned: false,
    banReason: "",
    season: { number: 1, name: "Season 1", startedAt: now },
    pastSeasons: [],
  };
}
