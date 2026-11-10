import { accountClient, currentSession } from "./account.js";
import {
  allianceAnswerOnline,
  allianceBoardOnline,
  allianceBrowseOnline,
  allianceCreateOnline,
  allianceDisbandOnline,
  allianceInviteOnline,
  allianceKickOnline,
  allianceLeaveOnline,
  allianceRequestOnline,
  allianceRoleOnline,
  allianceStateOnline,
  allianceTransferOnline,
  attackOnline,
  buySpyOnline,
  oddsOnline,
  reportsOnline,
  spyOnline,
  targetsOnline,
  adminBanOnline,
  adminGrantOnline,
  adminLogOnline,
  adminSearchOnline,
  adminChatDeleteOnline,
  adminChatMuteOnline,
  adminChatRecentOnline,
  adminChatUnmuteOnline,
  chatHistoryOnline,
  chatSendOnline,
  seasonsOnline,
  wipeSeasonOnline,
  adminUnbanOnline,
  buildOnline,
  createOnlineKingdom,
  exploreOnline,
  leaderboardOnline,
  logInAccount,
  logOutAccount,
  openKingdom,
  realmOnline,
  refreshKingdom,
  researchOnline,
  signUpAccount,
  trainOnline,
} from "./api.js";
import { clearDemo, freshDemo, loadDemo, saveDemo } from "./demo.js";
import {
  grantResources,
  networth,
  orderBuild,
  orderExplore,
  orderResearch,
  orderTrain,
  settle,
} from "./engine.js";
import { BUILDING_ORDER, NPC_TABLE, TICK_SECONDS, UNIT_ORDER } from "./rules.js";
import { battleBrief } from "./combat.js";
import { CHAT_CHANNELS, chatRateError, cleanChatBody } from "./chat.js";
import { buySpies, createPact, disbandPact, inviteKingdom, kickMember, leavePact, previewOdds, requestJoin, answerRequest, sendArmy, sendSpy, setOfficer, settleMarches, transferPact, warView } from "./war.js";
import { armMusic, musicState, setMuted } from "./music.js";
import { paintJobClocks, realmRowsFrom, render, tickLabel } from "./ui.js";

const root = document.querySelector("#app");

const model = {
  screen: "boot",
  mode: "demo",
  tab: "throne",
  notice: "",
  tone: "info",
  player: null,
  kingdom: null,
  npcs: [],
  realmRows: [],
  leaderboard: [],
  adminResults: [],
  adminLog: [],
  banned: false,
  banReason: "",
  hasDemo: false,
  busy: false,
  drafts: blankDrafts(),
  season: null,
  pastSeasons: [],
  seasonsLive: false,
  wipeOpen: false,
  chatOpen: false,
  chatChannel: "global",
  chatMessages: [],
  chatSeen: { global: 0, realm: 0, alliance: 0 },
  chatLive: null,
  chatDraft: "",
  chatLocked: { global: "", realm: "", alliance: "" },
  chatMutes: [],
  chatNextId: 1,
  chatStick: true,
  chatAdmin: [],
};

function blankDrafts() {
  const build = {};
  for (const id of BUILDING_ORDER) build[id] = 1;
  const train = {};
  for (const id of UNIT_ORDER) train[id] = id === "militia" ? 10 : 1;
  return { build, train, explore: 8, landType: "", foundName: "", search: "", warSearch: "", target: "", raid: "conquest" };
}

function renderApp() {
  render(root, model, actions);
}

function note(text, tone = "info") {
  model.notice = text || "";
  model.tone = tone;
}

function signed(value) {
  const n = Math.floor(Number(value) || 0);
  return n > 0 ? `+${n}` : String(n);
}

function noteFrom(summary) {
  if (!summary) return;
  const done = (summary.finished || []).filter(Boolean);
  const bits = [];
  if (summary.gold) bits.push(`gold ${signed(summary.gold)}`);
  if (summary.food) bits.push(`food ${signed(summary.food)}`);
  if (summary.peasants) bits.push(`people ${signed(summary.peasants)}`);
  if (summary.research) bits.push(`research ${signed(summary.research)}`);
  if (summary.mana) bits.push(`mana ${signed(summary.mana)}`);
  if (!summary.ticks && !bits.length && !done.length) return;
  let head = "";
  if (summary.ticks === 1) head = "A tick passed";
  else if (summary.ticks > 1) head = `${summary.ticks} ticks passed`;
  const body = [head, bits.join(" · ")].filter(Boolean).join(" · ");
  note(`${body}${body ? "." : ""} ${done.join(" ")}`.trim());
}

function persist() {
  if (model.mode !== "demo") return;
  if (!model.kingdom && !model.season) return;
  saveDemo({
    kingdom: model.kingdom,
    npcs: model.npcs || [],
    alliances: model.alliances || [],
    members: model.members || [],
    requests: model.requests || [],
    reports: model.reports || [],
    adminLog: model.adminLog,
    banned: model.banned,
    banReason: model.banReason,
    season: model.season,
    pastSeasons: model.pastSeasons || [],
    chatMessages: model.chatMessages || [],
    chatMutes: model.chatMutes || [],
    chatNextId: model.chatNextId || 1,
  });
}

function showGate(message, tone = "info") {
  model.screen = "gate";
  model.hasDemo = Boolean(loadDemo()?.kingdom?.name);
  note(message || "", tone);
  renderApp();
}

async function loadWar() {
  if (model.mode !== "online") {
    syncDemoBoard();
    return;
  }
  const [targets, reports] = await Promise.all([targetsOnline(model.drafts.warSearch || ""), reportsOnline()]);
  if (!targets.ok) note(targets.error, "bad");
  else model.targets = targets.kingdoms || [];
  if (!reports.ok) note(reports.error, "bad");
  else model.reports = reports.reports || [];
}

async function loadAlliances() {
  if (model.mode !== "online") {
    model.allianceView = warView(worldFrom(model, model.kingdom));
    return;
  }
  const [state, browse] = await Promise.all([allianceStateOnline(), allianceBrowseOnline("")]);
  if (!state.ok) {
    note(state.error, "bad");
    return;
  }
  const board = browse.ok ? browse.data.alliances || [] : [];
  model.allianceView = {
    mine: state.data.alliance,
    members: state.data.members || [],
    requests: state.data.requests || [],
    browse: board,
  };
  if (model.kingdom && state.data.alliance) {
    model.kingdom.allianceTag = state.data.alliance.tag;
    model.kingdom.allianceRole = state.data.alliance.role;
    model.kingdom.allianceId = state.data.alliance.id;
  } else if (model.kingdom) {
    model.kingdom.allianceTag = null;
    model.kingdom.allianceRole = null;
    model.kingdom.allianceId = null;
  }
}

async function absorbAlliance(data) {
  const browse = model.allianceView?.browse;
  model.allianceView = {
    mine: data.alliance,
    members: data.members || [],
    requests: data.requests || [],
    browse: browse || [],
  };
  const fresh = await allianceBrowseOnline("");
  if (fresh.ok) model.allianceView.browse = fresh.data.alliances || [];
  if (model.kingdom) {
    model.kingdom.allianceTag = data.alliance?.tag || null;
    model.kingdom.allianceRole = data.alliance?.role || null;
    model.kingdom.allianceId = data.alliance?.id || null;
  }
}

async function pactAction(local, remote) {
  if (model.mode === "demo") {
    try {
      applyWorld(local());
      syncDemoBoard();
      persist();
    } catch (error) {
      note(error.message, "bad");
    }
    renderApp();
    return;
  }
  const res = await remote();
  if (!res.ok) note(res.error, "bad");
  else await absorbAlliance(res.data);
  renderApp();
}

function worldFrom(save, kingdom) {
  return {
    kingdom,
    npcs: save.npcs || [],
    alliances: save.alliances || [],
    members: save.members || [],
    requests: save.requests || [],
    reports: save.reports || [],
  };
}

function revealBattle(before, after) {
  const seen = new Set((before || []).map((row) => String(row.id)));
  const fresh = (after || []).find((row) => battleBrief(row) && !seen.has(String(row.id)));
  if (!fresh) return;
  model.battleSheet = fresh;
  const brief = battleBrief(fresh);
  note(brief.victory ? `Victory against ${brief.foe}.` : `Defeat at the hands of ${brief.foe}.`, brief.victory ? "info" : "bad");
}

function applyWorld(world) {
  model.kingdom = world.kingdom;
  model.npcs = world.npcs;
  model.alliances = world.alliances;
  model.members = world.members;
  model.requests = world.requests;
  model.reports = world.reports;
  model.allianceView = warView(world);
  model.kingdom.underAttack = (model.kingdom.marches || []).some((march) => march.kind === "army" && march.phase === "out" && march.target === model.kingdom.name);
}

function enterDemo(save, caughtUp) {
  const result = caughtUp || settle(save.kingdom, Date.now(), { maxTicks: 100000 });
  const before = save.reports || [];
  const marched = settleMarches(worldFrom(save, result.state), Date.now());
  model.mode = "demo";
  model.player = { username: "Local ruler", admin: false };
  applyWorld(marched);
  model.adminLog = save.adminLog || [];
  model.banned = Boolean(save.banned);
  model.banReason = save.banReason || "";
  syncDemoBoard();
  model.screen = "play";
  model.tab = "throne";
  model.season = save.season || { number: 1, name: "Season 1", startedAt: save.kingdom?.createdAt || Date.now() };
  model.pastSeasons = save.pastSeasons || [];
  model.seasonsLive = true;
  model.chatMessages = save.chatMessages || model.chatMessages || [];
  model.chatMutes = save.chatMutes || [];
  model.chatNextId = save.chatNextId || model.chatNextId || 1;
  model.chatLive = true;
  noteFrom(result.summary);
  revealBattle(before, model.reports);
  persist();
  renderApp();
}

function applySeasonPayload(data) {
  model.season = data?.current || null;
  model.pastSeasons = data?.past || [];
  model.seasonsLive = Boolean(model.season);
}

async function loadSeasons() {
  const res = await seasonsOnline();
  if (!res.ok) {
    model.seasonsLive = false;
    return;
  }
  applySeasonPayload(res.data);
}

function demoStandings() {
  const crowns = [model.kingdom, ...(model.npcs || [])].filter(Boolean).map((kingdom) => ({
    name: kingdom.name,
    land: kingdom.land,
    networth: networth(kingdom),
    is_npc: Boolean(kingdom.isNpc),
    realm: kingdom.realmName || "",
    tag: kingdom.allianceTag || "",
  }));
  const byName = (a, b) => a.name.localeCompare(b.name);
  const byNetworth = [...crowns].sort((a, b) => b.networth - a.networth || byName(a, b)).slice(0, 10);
  const byLand = [...crowns].sort((a, b) => b.land - a.land || b.networth - a.networth || byName(a, b)).slice(0, 10);
  const alliances = (model.alliances || []).map((alliance) => {
    const members = (model.members || []).filter((row) => row.allianceId === alliance.id);
    const worth = members.reduce((sum, row) => {
      const kingdom = row.name === model.kingdom?.name ? model.kingdom : (model.npcs || []).find((npc) => npc.name === row.name);
      return sum + (kingdom ? networth(kingdom) : 0);
    }, 0);
    return { name: alliance.name, tag: alliance.tag, members: members.length, networth: worth };
  }).sort((a, b) => b.networth - a.networth || byName(a, b)).slice(0, 10);
  return { by_networth: byNetworth, by_land: byLand, alliances };
}

function demoAdminRows(query) {
  const q = String(query || "").trim().toLowerCase();
  const rows = [model.kingdom, ...model.npcs].filter((kingdom) => kingdom && (!q || kingdom.name.toLowerCase().includes(q)));
  return rows.map((kingdom) => ({
    name: kingdom.name,
    username: kingdom.isNpc ? null : "you",
    landType: kingdom.landType,
    land_type: kingdom.landType,
    land: kingdom.land,
    gold: kingdom.gold,
    food: kingdom.food,
    networth: networth(kingdom),
    isNpc: Boolean(kingdom.isNpc),
    is_npc: Boolean(kingdom.isNpc),
    banned: !kingdom.isNpc && model.banned,
    ban_reason: model.banReason,
  }));
}

function syncDemoBoard() {
  const rows = realmRowsFrom(model.kingdom, model.npcs).map((row) => {
    const source = row.you ? model.kingdom : model.npcs.find((npc) => npc.name === row.name);
    return { ...row, tag: source?.allianceTag || "" };
  });
  model.realmRows = rows;
  model.leaderboard = rows;
  model.adminResults = demoAdminRows(model.drafts.search);
  model.targets = demoTargets(model.drafts.warSearch);
  model.allianceView = warView(worldFrom(model, model.kingdom));
}

function demoTargets(query) {
  const q = String(query || "").trim().toLowerCase();
  return model.npcs
    .filter((npc) => !q || npc.name.toLowerCase().includes(q))
    .map((npc) => ({
      id: npc.name,
      name: npc.name,
      tag: npc.allianceTag || "",
      realm_name: npc.realmName,
      networth: networth(npc),
      land: npc.land,
      is_npc: true,
      allied: Boolean(model.kingdom.allianceId && npc.allianceId === model.kingdom.allianceId),
      protected: false,
      tier: npc.npcTier || 1,
    }))
    .sort((a, b) => b.networth - a.networth);
}

async function loadBoard() {
  if (model.mode === "demo") {
    syncDemoBoard();
    return;
  }
  const [realm, board] = await Promise.all([realmOnline(), leaderboardOnline()]);
  if (!realm.ok) note(realm.error, "bad");
  else {
    model.realmRows = realm.kingdoms || [];
    if (model.kingdom && realm.realm) model.kingdom.realmCount = realm.realm.count;
  }
  if (board.ok) model.leaderboard = board.kingdoms || [];
  else note(board.error, "bad");
}

function applyOnline(res, quiet) {
  const before = model.kingdom;
  model.mode = "online";
  model.player = res.player;
  model.kingdom = res.kingdom;
  model.banned = false;
  if (!res.kingdom) {
    model.screen = "found";
    return;
  }
  model.screen = "play";
  if (!quiet && before) {
    const summary = {
      ticks: res.kingdom.lastTickAt !== before.lastTickAt ? 1 : 0,
      gold: res.kingdom.gold - before.gold,
      food: res.kingdom.food - before.food,
      peasants: res.kingdom.peasants - before.peasants,
      research: res.kingdom.researchPoints - before.researchPoints,
      mana: res.kingdom.mana - before.mana,
      finished: [],
    };
    const previous = new Set((before.chronicle || []).map((line) => `${line.at}|${line.text}`));
    summary.finished = (res.kingdom.chronicle || []).filter((line) => !previous.has(`${line.at}|${line.text}`)).map((line) => line.text);
    if (summary.ticks || summary.finished.length || summary.gold || summary.food) noteFrom(summary);
  }
}

async function online(work, { quiet = false, board = false, log = false } = {}) {
  if (model.busy) return { ok: false, error: "Wait for the stewards." };
  model.busy = true;
  renderApp();
  try {
    const res = await work();
    if (!res.ok) {
      note(res.error, "bad");
      if (res.banned) model.screen = "gate";
      return res;
    }
    if (res.kingdom || res.player) applyOnline(res, quiet);
    if (board && model.kingdom) await loadBoard();
    if (log && model.player?.admin) {
      const recent = await adminLogOnline();
      if (recent.ok) model.adminLog = recent.data.entries || [];
    }
    return res;
  } finally {
    model.busy = false;
    renderApp();
  }
}

function demoOrder(run) {
  try {
    const settled = settle(model.kingdom, Date.now(), { maxTicks: 100000 });
    const result = run(settled.state);
    const marched = settleMarches(worldFrom(model, result.state), Date.now());
    applyWorld(marched);
    noteFrom(result.summary.ticks || result.summary.finished?.length ? result.summary : { ticks: 0, finished: [], gold: 0, food: 0, peasants: 0, research: 0, mana: 0 });
    const last = model.kingdom.chronicle[model.kingdom.chronicle.length - 1];
    if (last && !result.summary.ticks) note(last.text);
    syncDemoBoard();
    persist();
    renderApp();
  } catch (error) {
    note(error.message || "That order failed.", "bad");
    renderApp();
  }
}

const actions = {
  auth: async (mode, username, password) => {
    const result = mode === "signup" ? await signUpAccount(username, password) : await logInAccount(username, password);
    if (!result.ok) {
      note(result.error, "bad");
      renderApp();
      return;
    }
    const opened = await openKingdom();
    if (!opened.ok) {
      showGate(opened.error, opened.missing ? "info" : "bad");
      return;
    }
    model.mode = "online";
    model.player = opened.player;
    model.kingdom = opened.kingdom;
    model.screen = opened.kingdom ? "play" : "found";
    model.tab = "throne";
    note("");
    if (opened.kingdom) await loadBoard();
    await loadSeasons();
    await probeChat();
    renderApp();
  },
  demo: () => {
    const saved = loadDemo();
    if (saved?.kingdom?.name) {
      enterDemo(saved);
      return;
    }
    model.mode = "demo";
    model.season = saved?.season || { number: 1, name: "Season 1", startedAt: Date.now() };
    model.pastSeasons = saved?.pastSeasons || [];
    model.seasonsLive = true;
    model.chatMessages = saved?.chatMessages || [];
    model.chatMutes = saved?.chatMutes || [];
    model.chatNextId = saved?.chatNextId || 1;
    model.chatLive = true;
    model.screen = "found";
    model.drafts.landType = "";
    model.drafts.foundName = "";
    note("");
    renderApp();
  },
  abandon: () => {
    if (!window.confirm("Abandon this local kingdom?")) return;
    clearDemo();
    model.kingdom = null;
    model.npcs = [];
    model.hasDemo = false;
    showGate("The local banner was taken down.");
  },
  back: () => showGate(""),
  resume: () => {
    if (!model.kingdom) return;
    model.screen = "play";
    model.tab = "throne";
    note("");
    renderApp();
  },
  pickLand: (id) => {
    model.drafts.landType = id;
    renderApp();
  },
  found: async (name, landType) => {
    if (!landType) {
      note("Choose a land type.", "bad");
      renderApp();
      return;
    }
    if (model.mode === "online" && model.player) {
      await online(() => createOnlineKingdom(name, landType), { quiet: true, board: true });
      if (model.kingdom) note(`The banner of ${model.kingdom.name} was raised.`);
      renderApp();
      return;
    }
    if (NPC_TABLE.some((row) => row.name.toLowerCase() === String(name || "").trim().toLowerCase())) {
      note("That kingdom name is already claimed.", "bad");
      renderApp();
      return;
    }
    try {
      const save = freshDemo({ name, landType, now: Date.now() });
      if (model.season) save.season = model.season;
      if (model.pastSeasons?.length) save.pastSeasons = model.pastSeasons;
      save.chatMessages = model.chatMessages || [];
      save.chatMutes = model.chatMutes || [];
      save.chatNextId = model.chatNextId || 1;
      enterDemo(save, { state: save.kingdom, summary: { ticks: 0, finished: [], gold: 0, food: 0, peasants: 0, research: 0, mana: 0 } });
      note(`The banner of ${save.kingdom.name} was raised.`);
      renderApp();
    } catch (error) {
      note(error.message, "bad");
      renderApp();
    }
  },
  tab: async (id) => {
    model.tab = id;
    if (id === "realm") await loadBoard();
    if (id === "war") {
      await loadWar();
      renderApp();
      return;
    }
    if (id === "alliances") {
      await loadAlliances();
      renderApp();
      return;
    }
    if (id === "steward") await loadChatAdmin();
    if (id === "steward" && model.mode === "online") {
      const res = await online(() => adminSearchOnline(model.drafts.search || ""), { quiet: true, log: true });
      if (res?.ok) model.adminResults = res.data.kingdoms || [];
      renderApp();
      return;
    }
    if (id === "steward" && model.mode === "demo") model.adminResults = demoAdminRows(model.drafts.search);
    renderApp();
  },
  setBuild: (id, count) => {
    model.drafts.build[id] = count;
    renderApp();
  },
  setTrain: (id, count) => {
    model.drafts.train[id] = count;
    renderApp();
  },
  build: (id) => {
    if (id === "guild" && model.kingdom?.crewsLive === false) {
      note("The Masons' Guild is not on the server ledger yet.", "bad");
      renderApp();
      return;
    }
    const count = model.drafts.build[id] || 1;
    if (model.kingdom?.crewsLive === false) {
      const busy = (model.kingdom.jobs || []).filter((job) => job.kind === "build").length;
      if (busy >= 1) {
        note(`All construction crews are busy (${busy}/1).`, "bad");
        renderApp();
        return;
      }
    }
    if (model.mode === "demo") {
      demoOrder((state) => orderBuild(state, id, count, Date.now()));
      return;
    }
    online(() => buildOnline(id, count));
  },
  explore: () => {
    const acres = Math.floor(Number(model.drafts.explore));
    if (model.mode === "demo") {
      demoOrder((state) => orderExplore(state, acres, Date.now()));
      return;
    }
    online(() => exploreOnline(acres));
  },
  train: (id) => {
    const count = model.drafts.train[id] || 1;
    if (model.mode === "demo") {
      demoOrder((state) => orderTrain(state, id, count, Date.now()));
      return;
    }
    online(() => trainOnline(id, count));
  },
  research: (id) => {
    if (id === "masons" && model.kingdom?.crewsLive === false) {
      note("Master Masons is not on the server ledger yet.", "bad");
      renderApp();
      return;
    }
    if (model.mode === "demo") {
      demoOrder((state) => orderResearch(state, id, Date.now()));
      return;
    }
    online(() => researchOnline(id));
  },
  bell: () => {
    if (model.mode !== "demo" || !model.kingdom) return;
    const target = model.kingdom.lastTickAt + TICK_SECONDS * 1000;
    const before = model.reports || [];
    const result = settle(model.kingdom, target, { maxTicks: 1 });
    const marched = settleMarches(worldFrom(model, result.state), target);
    applyWorld(marched);
    noteFrom(result.summary);
    revealBattle(before, model.reports);
    syncDemoBoard();
    persist();
    renderApp();
  },
  refreshBoard: async () => {
    await loadBoard();
    renderApp();
  },
  adminSearch: async (query) => {
    model.drafts.search = String(query || "");
    if (model.mode === "demo") {
      model.adminResults = demoAdminRows(model.drafts.search);
      renderApp();
      return;
    }
    const res = await online(() => adminSearchOnline(model.drafts.search), { quiet: true, log: true });
    if (res?.ok) model.adminResults = res.data.kingdoms || [];
    renderApp();
  },
  grant: async (name, gold, food, land) => {
    if (model.mode === "demo") {
      try {
        if (name !== model.kingdom.name) throw new Error("In a demo you can grant only your own kingdom.");
        const settled = settle(model.kingdom, Date.now(), { maxTicks: 100000 });
        model.kingdom = grantResources(settled.state, { gold, food, land });
        model.adminLog.unshift({ at: Date.now(), action: "grant", label: name, gold, food, land, note: "Local desk" });
        model.adminLog = model.adminLog.slice(0, 20);
        note(`Granted ${gold} gold, ${food} food, and ${land} land to ${name}.`);
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await online(() => adminGrantOnline({ name, gold, food, land, note: "Steward grant" }), { quiet: true });
    if (!res?.ok) return;
    note(`Granted to ${name}.`);
    const found = await adminSearchOnline(model.drafts.search || name);
    if (found.ok) model.adminResults = found.data.kingdoms || [];
    const recent = await adminLogOnline();
    if (recent.ok) model.adminLog = recent.data.entries || [];
    if (model.kingdom && name.toLowerCase() === model.kingdom.name.toLowerCase()) {
      const fresh = await refreshKingdom();
      if (fresh.ok) applyOnline(fresh, true);
    }
    renderApp();
  },
  ban: async (username, reason) => {
    if (model.mode === "demo") {
      if (username !== "you") {
        note("Established houses are not accounts.", "bad");
        renderApp();
        return;
      }
      if (!String(reason || "").trim()) {
        note("A ban needs a reason.", "bad");
        renderApp();
        return;
      }
      model.banned = true;
      model.banReason = String(reason).trim();
      model.adminLog.unshift({ at: Date.now(), action: "ban", label: "you", note: model.banReason });
      note("The local banner is banished.");
      syncDemoBoard();
      persist();
      renderApp();
      return;
    }
    const res = await online(() => adminBanOnline(username, reason), { quiet: true });
    if (!res?.ok) return;
    note(`Banned ${username}.`);
    const found = await adminSearchOnline(model.drafts.search || "");
    if (found.ok) model.adminResults = found.data.kingdoms || [];
    const recent = await adminLogOnline();
    if (recent.ok) model.adminLog = recent.data.entries || [];
    renderApp();
  },
  openWipe: () => {
    model.wipeOpen = true;
    model.wipeConfirm = "";
    model.wipeName = "";
    renderApp();
  },
  closeWipe: () => {
    model.wipeOpen = false;
    renderApp();
  },
  wipeSeason: async (confirmWord, name) => {
    if (confirmWord !== "WIPE") {
      note("Type WIPE to confirm.", "bad");
      renderApp();
      return;
    }
    if (model.mode === "demo") {
      const ended = {
        ...(model.season || { number: 1, name: "Season 1", startedAt: Date.now() }),
        endedAt: Date.now(),
        standings: demoStandings(),
      };
      const nextNumber = (ended.number || 1) + 1;
      const nextName = String(name || "").trim() || `Season ${nextNumber}`;
      model.pastSeasons = [ended, ...(model.pastSeasons || [])];
      model.season = { number: nextNumber, name: nextName, startedAt: Date.now() };
      model.kingdom = null;
      model.npcs = [];
      model.alliances = [];
      model.members = [];
      model.requests = [];
      model.reports = [];
      model.adminLog = [{ at: Date.now(), action: "wipe", label: `Season ${ended.number}`, note: `Ended ${ended.name}. Started ${nextName}.` }, ...(model.adminLog || [])].slice(0, 20);
      model.wipeOpen = false;
      model.screen = "found";
      model.tab = "throne";
      note(`Season ${ended.number} is closed. Raise a banner for ${nextName}.`);
      persist();
      renderApp();
      return;
    }
    if (!model.seasonsLive) {
      note("The season ledger is not on the server yet.", "bad");
      renderApp();
      return;
    }
    const res = await wipeSeasonOnline("WIPE", name);
    if (!res.ok) {
      note(res.error, "bad");
      renderApp();
      return;
    }
    applySeasonPayload(res.data);
    model.kingdom = null;
    model.wipeOpen = false;
    model.screen = "found";
    model.tab = "throne";
    note(`Season ${res.data?.ended?.number || ""} is closed. Raise a banner for ${res.data?.current?.name || "the new season"}.`);
    renderApp();
  },
  unban: async (username) => {
    if (model.mode === "demo") {
      model.banned = false;
      model.banReason = "";
      model.adminLog.unshift({ at: Date.now(), action: "unban", label: "you" });
      note("The ban was lifted.");
      syncDemoBoard();
      persist();
      renderApp();
      return;
    }
    const res = await online(() => adminUnbanOnline(username), { quiet: true });
    if (!res?.ok) return;
    note(`Lifted the ban on ${username}.`);
    const found = await adminSearchOnline(model.drafts.search || "");
    if (found.ok) model.adminResults = found.data.kingdoms || [];
    const recent = await adminLogOnline();
    if (recent.ok) model.adminLog = recent.data.entries || [];
    renderApp();
  },
  loadTargets: async (query) => {
    model.drafts.warSearch = String(query || "");
    await loadWar();
    renderApp();
  },
  pickTarget: (row) => {
    model.drafts.target = row.name;
    model.drafts.targetId = row.id;
    model.odds = "";
    model.scrollOrders = true;
    renderApp();
  },
  toggleReports: () => {
    model.reportsOpen = !model.reportsOpen;
    renderApp();
  },
  openBattle: (report) => {
    model.battleSheet = report;
    renderApp();
  },
  closeBattle: () => {
    model.battleSheet = null;
    renderApp();
  },
  estimate: async (target, sent) => {
    if (model.mode === "demo") {
      const preview = previewOdds(worldFrom(model, model.kingdom), target.name, sent);
      model.odds = preview.note;
      renderApp();
      return;
    }
    const res = await oddsOnline(target.id, sent);
    if (!res.ok) note(res.error, "bad");
    else model.odds = `${res.data.band}. ${res.data.note} Strength on the road: ${res.data.offense}.`;
    renderApp();
  },
  attack: async (target, type, sent) => {
    if (model.mode === "demo") {
      try {
        const world = sendArmy(worldFrom(model, model.kingdom), target.name, type, sent, Date.now());
        applyWorld(world);
        note(`Your host marched on ${target.name}.`);
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    await online(() => attackOnline(target.id, type, sent));
    await loadWar();
    renderApp();
  },
  spy: async (target) => {
    if (model.mode === "demo") {
      try {
        applyWorld(sendSpy(worldFrom(model, model.kingdom), target.name, Date.now()));
        note(`A spy slipped toward ${target.name}.`);
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    await online(() => spyOnline(target.id));
    renderApp();
  },
  buySpy: async (count) => {
    if (model.mode === "demo") {
      try {
        applyWorld(buySpies(worldFrom(model, model.kingdom), count));
        note("A spy joined the household.");
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    await online(() => buySpyOnline(count));
  },
  createPact: async (name, tag, description) => {
    if (model.mode === "demo") {
      try {
        applyWorld(createPact(worldFrom(model, model.kingdom), name, tag, description));
        note(`The pact ${tag.toUpperCase()} is sworn.`);
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await allianceCreateOnline(name, tag, description);
    if (!res.ok) note(res.error, "bad");
    else {
      note("The pact is sworn.");
      await absorbAlliance(res.data);
    }
    renderApp();
  },
  joinPact: async (row) => {
    if (model.mode === "demo") {
      try {
        let world = requestJoin(worldFrom(model, model.kingdom), row.id);
        const pending = world.requests.find((request) => request.status === "pending" && request.allianceId === row.id);
        world = answerRequest(world, pending.id, true);
        applyWorld(world);
        note(`You joined ${row.name}.`);
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await allianceRequestOnline(row.id);
    if (!res.ok) note(res.error, "bad");
    else {
      note("Your request is with the pact.");
      await absorbAlliance(res.data);
    }
    renderApp();
  },
  answer: async (request, accept) => {
    if (model.mode === "demo") {
      try {
        applyWorld(answerRequest(worldFrom(model, model.kingdom), request.id, accept));
        note(accept ? "The request was accepted." : "The request was declined.");
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await allianceAnswerOnline(request.id, accept);
    if (!res.ok) note(res.error, "bad");
    else await absorbAlliance(res.data);
    renderApp();
  },
  invite: async (name) => {
    if (model.mode === "demo") {
      try {
        applyWorld(inviteKingdom(worldFrom(model, model.kingdom), String(name || "")));
        note(`An invitation went to ${name}.`);
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await allianceInviteOnline(String(name || ""));
    if (!res.ok) note(res.error, "bad");
    else await absorbAlliance(res.data);
    renderApp();
  },
  leavePact: async () => {
    if (model.mode === "demo") {
      try {
        applyWorld(leavePact(worldFrom(model, model.kingdom)));
        note("You left the pact.");
        syncDemoBoard();
        persist();
      } catch (error) {
        note(error.message, "bad");
      }
      renderApp();
      return;
    }
    const res = await allianceLeaveOnline();
    if (!res.ok) note(res.error, "bad");
    else await absorbAlliance(res.data);
    const fresh = await refreshKingdom();
    if (fresh.ok) applyOnline(fresh, true);
    renderApp();
  },
  kick: async (name) => {
    await pactAction(() => kickMember(worldFrom(model, model.kingdom), name), () => allianceKickOnline(name));
  },
  officer: async (name, officer) => {
    await pactAction(() => setOfficer(worldFrom(model, model.kingdom), name, officer), () => allianceRoleOnline(name, officer));
  },
  transfer: async (name) => {
    await pactAction(() => transferPact(worldFrom(model, model.kingdom), name), () => allianceTransferOnline(name));
  },
  disband: async () => {
    await pactAction(() => disbandPact(worldFrom(model, model.kingdom)), () => allianceDisbandOnline());
  },
  toggleChat: () => {
    model.chatOpen = !model.chatOpen;
    if (model.chatOpen) markChatSeen(model.chatChannel);
    renderApp();
  },
  chatTab: (channel) => {
    model.chatChannel = channel;
    model.chatStick = true;
    markChatSeen(channel);
    renderApp();
  },
  chatDraft: (value) => {
    model.chatDraft = value;
  },
  chatSend: async (raw) => {
    const cleaned = cleanChatBody(raw);
    if (cleaned.error) {
      note(cleaned.error, "bad");
      renderApp();
      return;
    }
    if (model.mode === "demo") {
      const problem = demoChatProblem(model.chatChannel, cleaned.body);
      if (problem) {
        note(problem, "bad");
        renderApp();
        return;
      }
      model.chatMessages.push({
        id: model.chatNextId++,
        channel: model.chatChannel,
        body: cleaned.body,
        createdAt: Date.now(),
        kingdom: model.kingdom?.name || "A ruler",
        tag: model.kingdom?.allianceTag || "",
        admin: Boolean(model.player?.admin),
        playerKey: "local",
        deleted: false,
      });
      trimDemoChat();
      model.chatDraft = "";
      model.chatStick = true;
      markChatSeen(model.chatChannel);
      persist();
      renderApp();
      return;
    }
    if (!model.chatLive) {
      note("The speaking-hall is not on the server ledger yet.", "bad");
      renderApp();
      return;
    }
    const res = await chatSendOnline(model.chatChannel, cleaned.body);
    if (!res.ok) {
      note(res.error, "bad");
      renderApp();
      return;
    }
    replaceChat(model.chatChannel, res.messages);
    model.chatLocked[model.chatChannel] = res.locked || "";
    model.chatDraft = "";
    model.chatStick = true;
    markChatSeen(model.chatChannel);
    renderApp();
  },
  chatEarlier: async () => {
    const rows = channelRows(model.chatChannel);
    const oldest = rows[0]?.id;
    if (!oldest || model.mode === "demo" || !model.chatLive) return;
    const res = await chatHistoryOnline(model.chatChannel, oldest);
    if (!res.ok) {
      note(res.error, "bad");
      renderApp();
      return;
    }
    const seen = new Set(channelRows(model.chatChannel).map((row) => row.id));
    const older = res.messages.filter((row) => !seen.has(row.id));
    model.chatMessages = [...older, ...model.chatMessages];
    model.chatStick = false;
    renderApp();
  },
  chatDelete: async (id) => {
    if (model.mode === "demo") {
      const row = model.chatMessages.find((message) => message.id === id);
      if (row) row.deleted = true;
      model.chatAdmin = recentDemoChat();
      model.adminLog.unshift({ at: Date.now(), action: "chat_delete", label: `Message ${id}`, note: row?.body || "" });
      persist();
      renderApp();
      return;
    }
    const res = await adminChatDeleteOnline(id);
    if (!res.ok) note(res.error, "bad");
    else {
      model.chatAdmin = res.messages;
      model.chatMutes = res.mutes;
      note("The message was taken down.");
    }
    renderApp();
  },
  chatMute: async (player, minutes, reason) => {
    if (model.mode === "demo") {
      const name = String(player || "").trim();
      const mins = Math.floor(Number(minutes));
      const why = String(reason || "").trim();
      if (!name) note("Name the player.", "bad");
      else if (!Number.isInteger(mins) || mins < 1 || mins > 10080) note("Mute between 1 minute and 7 days.", "bad");
      else if (!why) note("A mute needs a reason.", "bad");
      else {
        model.chatMutes = model.chatMutes.filter((row) => row.username.toLowerCase() !== name.toLowerCase());
        model.chatMutes.push({ username: name, until: Date.now() + mins * 60000, reason: why });
        model.adminLog.unshift({ at: Date.now(), action: "chat_mute", label: name, note: `${mins} minutes. ${why}` });
        note(`${name} is muted.`);
        persist();
      }
      renderApp();
      return;
    }
    const res = await adminChatMuteOnline(player, Math.floor(Number(minutes)), reason);
    if (!res.ok) note(res.error, "bad");
    else {
      model.chatAdmin = res.messages;
      model.chatMutes = res.mutes;
      note(`${player} is muted.`);
    }
    renderApp();
  },
  chatUnmute: async (player) => {
    if (model.mode === "demo") {
      model.chatMutes = model.chatMutes.filter((row) => row.username.toLowerCase() !== String(player || "").trim().toLowerCase());
      model.adminLog.unshift({ at: Date.now(), action: "chat_unmute", label: player, note: "The mute was lifted." });
      note(`The mute on ${player} was lifted.`);
      persist();
      renderApp();
      return;
    }
    const res = await adminChatUnmuteOnline(player);
    if (!res.ok) note(res.error, "bad");
    else {
      model.chatAdmin = res.messages;
      model.chatMutes = res.mutes;
      note(`The mute on ${player} was lifted.`);
    }
    renderApp();
  },
  toggleMusic: () => {
    const next = !musicState().muted;
    setMuted(next);
    if (!next) armMusic();
    renderApp();
  },
  logout: async () => {
    await logOutAccount();
    model.player = null;
    model.kingdom = null;
    model.mode = "demo";
    showGate("Signed out.");
  },
};

function within(promise, ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(null), ms);
    Promise.resolve(promise).then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        clearTimeout(timer);
        resolve(null);
      },
    );
  });
}

function channelRows(channel) {
  return (model.chatMessages || []).filter((row) => row.channel === channel && !row.deleted);
}

function markChatSeen(channel) {
  const max = channelRows(channel).reduce((best, row) => Math.max(best, row.id || 0), 0);
  model.chatSeen[channel] = max;
}

function replaceChat(channel, messages) {
  const rest = (model.chatMessages || []).filter((row) => row.channel !== channel);
  model.chatMessages = [...rest, ...messages.map((row) => ({ ...row, channel, deleted: false }))];
}

function trimDemoChat() {
  for (const channel of CHAT_CHANNELS) {
    const rows = model.chatMessages.filter((row) => row.channel === channel);
    if (rows.length <= 500) continue;
    const drop = new Set(rows.slice(0, rows.length - 500).map((row) => row.id));
    model.chatMessages = model.chatMessages.filter((row) => !drop.has(row.id));
  }
}

function demoChatProblem(channel) {
  if (channel === "realm" && !model.kingdom) return "Raise a banner before you speak in a realm.";
  if (channel === "alliance" && !model.kingdom?.allianceId) return "You are not in an alliance.";
  const muted = (model.chatMutes || []).some((row) => {
    const name = String(row.username || "").toLowerCase();
    const until = typeof row.until === "number" ? row.until : Date.parse(row.until);
    return (name === "you" || name === "local ruler") && until > Date.now();
  });
  if (muted) return "You are muted.";
  return chatRateError(model.chatMessages, "local", Date.now());
}

function recentDemoChat() {
  return model.chatMessages.filter((row) => !row.deleted).slice(-40).reverse();
}

function chatSignature() {
  return (model.chatMessages || []).map((row) => `${row.channel}:${row.id}:${row.deleted ? 1 : 0}`).join(",");
}

async function refreshOpenChat() {
  if (model.mode !== "online" || !model.chatLive) return;
  const before = chatSignature();
  for (const channel of CHAT_CHANNELS) {
    const res = await chatHistoryOnline(channel, null);
    if (!res.ok) {
      if (res.missing) model.chatLive = false;
      return;
    }
    replaceChat(channel, res.messages);
    model.chatLocked[channel] = res.locked || "";
  }
  if (chatSignature() !== before) renderChat();
}

async function loadChatAdmin() {
  if (model.mode === "demo") {
    model.chatAdmin = recentDemoChat();
    return;
  }
  if (!model.chatLive) return;
  const res = await adminChatRecentOnline();
  if (!res.ok) return;
  model.chatAdmin = res.messages;
  model.chatMutes = res.mutes;
}

async function probeChat() {
  if (model.mode === "demo") {
    model.chatLive = true;
    return;
  }
  const res = await chatHistoryOnline("global", null);
  if (!res.ok) {
    model.chatLive = false;
    return;
  }
  model.chatLive = true;
  replaceChat("global", res.messages);
  await refreshOpenChat();
  listenChat();
}

let chatPoll = 0;
let chatSub = null;

function startChatPoll() {
  if (chatPoll) return;
  chatPoll = setInterval(() => {
    if (!model.chatLive || model.chatRealtime) return;
    refreshOpenChat();
  }, 5000);
}

function listenChat() {
  const db = accountClient();
  if (!db || chatSub) {
    startChatPoll();
    return;
  }
  chatSub = db.channel("cc-chat-messages")
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "cc_chat_messages" }, () => {
      refreshOpenChat();
    })
    .subscribe((status) => {
      if (status === "SUBSCRIBED") {
        model.chatRealtime = true;
        if (chatPoll) {
          clearInterval(chatPoll);
          chatPoll = 0;
        }
        return;
      }
      if (status === "CHANNEL_ERROR" || status === "TIMED_OUT" || status === "CLOSED") {
        model.chatRealtime = false;
        startChatPoll();
      }
    });
  setTimeout(() => {
    if (!model.chatRealtime) startChatPoll();
  }, 8000);
}

function renderChat() {
  const focused = document.activeElement?.id === "chat-body";
  const caret = focused ? document.activeElement.selectionStart : null;
  renderApp();
  if (!focused) return;
  const input = document.getElementById("chat-body");
  if (!input) return;
  input.focus();
  const pos = caret ?? input.value.length;
  input.setSelectionRange(pos, pos);
}

async function boot() {
  renderApp();
  const session = await within(currentSession(), 2500);
  if (!session) {
    showGate("");
    return;
  }
  const opened = await openKingdom();
  if (!opened.ok) {
    showGate(opened.error, opened.missing || opened.banned ? "info" : "bad");
    return;
  }
  model.mode = "online";
  model.player = opened.player;
  model.kingdom = opened.kingdom;
  model.screen = opened.kingdom ? "play" : "found";
  model.tab = "throne";
  note("");
  if (opened.kingdom) await loadBoard();
  await loadSeasons();
  await probeChat();
  renderApp();
}

setInterval(() => {
  const clock = document.getElementById("tick-clock");
  if (clock && model.kingdom) clock.textContent = tickLabel(model.kingdom);
  paintJobClocks();
  if (model.busy || model.screen !== "play" || !model.kingdom) return;
  const dueJob = (model.kingdom.jobs || []).some((job) => job.completesAt <= Date.now());
  const dueTick = Date.now() >= model.kingdom.lastTickAt + TICK_SECONDS * 1000;
  if (!dueJob && !dueTick) return;
  if (dueJob && !dueTick && model.jobHold && Date.now() < model.jobHold) return;
  if (dueJob) model.jobHold = Date.now() + 4000;
  if (model.mode === "demo") {
    const before = model.reports || [];
    const result = settle(model.kingdom, Date.now(), { maxTicks: 5000 });
    const marched = settleMarches(worldFrom(model, result.state), Date.now());
    const moved = result.summary.ticks || result.summary.finished.length || (marched.reports || []).length !== before.length;
    if (!moved) return;
    applyWorld(marched);
    noteFrom(result.summary);
    revealBattle(before, model.reports);
    syncDemoBoard();
    persist();
    renderApp();
    return;
  }
  const before = model.reports || [];
  const marching = (model.kingdom.marches || []).some((march) => march.kind === "army");
  online(async () => {
    const res = await refreshKingdom();
    if (res.ok && marching) {
      const reports = await reportsOnline();
      if (reports.ok) {
        const next = reports.reports || [];
        revealBattle(before, next);
        model.reports = next;
      }
    }
    return res;
  }, { quiet: false });
}, 1000);

document.addEventListener("pointerdown", () => armMusic(), { capture: true });
document.addEventListener("keydown", () => armMusic(), { capture: true });

boot();
