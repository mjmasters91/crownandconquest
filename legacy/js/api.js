import { logInAccount, logOutAccount, rpc, signUpAccount } from "./account.js";
import { emptyBuildings, emptyResearch, emptyUnits } from "./rules.js";

function ms(value) {
  if (typeof value === "number") return value;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Date.now();
}

export function mapKingdom(row) {
  if (!row) return null;
  return {
    version: 1,
    id: row.id,
    name: row.name,
    landType: row.land_type,
    realmName: row.realm_name,
    realmSeat: row.realm_seat,
    realmId: row.realm_id,
    realmCount: row.realm_count,
    isNpc: false,
    createdAt: ms(row.created_at || row.last_tick_at),
    lastTickAt: ms(row.last_tick_at),
    exploreResetAt: ms(row.explore_reset_at),
    exploredToday: row.explored_today,
    nextJobId: 1,
    gold: row.gold,
    goldBank: row.gold_bank,
    food: row.food,
    foodBank: row.food_bank,
    mana: row.mana,
    manaBank: row.mana_bank,
    researchPoints: row.research_points,
    researchBank: row.research_bank,
    popProgress: row.pop_progress,
    peasants: row.peasants,
    land: row.land,
    buildings: { ...emptyBuildings(), ...(row.buildings || {}) },
    units: { ...emptyUnits(), ...(row.units || {}) },
    research: { ...emptyResearch(), ...(row.research || {}) },
    jobs: (row.jobs || []).map((job) => ({
      id: job.id,
      kind: job.kind,
      building: job.building,
      unit: job.unit,
      count: job.count,
      settlers: job.settlers,
      startedAt: ms(job.started_at),
      completesAt: ms(job.completes_at),
    })),
    marches: (row.marches || []).map((march) => ({
      id: march.id,
      kind: march.kind,
      phase: march.phase,
      attackType: march.attack_type,
      target: march.target,
      targetTag: march.target_tag,
      youAttack: march.you_attack !== false,
      startedAt: ms(march.started_at),
      arrivesAt: ms(march.arrives_at),
    })),
    morale: row.morale ?? 100,
    spies: row.spies ?? 2,
    protectedUntil: row.protected_until ? ms(row.protected_until) : null,
    attackedAt: row.attacked_at ? ms(row.attacked_at) : null,
    lastHitAt: row.last_hit_at ? ms(row.last_hit_at) : null,
    underAttack: Boolean(row.under_attack),
    allianceId: row.alliance?.id ?? null,
    allianceTag: row.alliance?.tag ?? null,
    allianceRole: row.alliance?.role ?? null,
    allianceName: row.alliance?.name ?? null,
    chronicle: (row.chronicle || []).map((line) => ({ at: ms(line.at), text: line.text })),
    crewsLive: row.crew_cap != null,
    crewCap: row.crew_cap == null ? null : Math.floor(Number(row.crew_cap)),
  };
}

export function mapPayload(payload) {
  return {
    player: {
      username: payload?.player?.username || "",
      admin: Boolean(payload?.player?.admin),
      banned: Boolean(payload?.player?.banned),
      banReason: payload?.player?.ban_reason || "",
    },
    kingdom: mapKingdom(payload?.kingdom),
    behind: Boolean(payload?.behind),
  };
}

async function follow(first) {
  if (!first.ok) return first;
  let data = first.data;
  let hops = 0;
  while (data?.behind && hops < 6) {
    const again = await rpc("cc_get_state");
    if (!again.ok) return again;
    data = again.data;
    hops += 1;
  }
  return { ok: true, ...mapPayload(data) };
}

export async function openKingdom() {
  return follow(await rpc("cc_ensure_player"));
}

export async function refreshKingdom() {
  return follow(await rpc("cc_get_state"));
}

export async function createOnlineKingdom(name, landType) {
  return follow(await rpc("cc_create_kingdom", { p_name: name, p_land_type: landType }));
}

export async function buildOnline(building, count) {
  return follow(await rpc("cc_build", { p_building: building, p_count: count }));
}

export async function exploreOnline(acres) {
  return follow(await rpc("cc_explore", { p_acres: acres }));
}

export async function trainOnline(unit, count) {
  return follow(await rpc("cc_train", { p_unit: unit, p_count: count }));
}

export async function researchOnline(track) {
  return follow(await rpc("cc_research", { p_track: track }));
}

export async function realmOnline() {
  const res = await rpc("cc_realm");
  if (!res.ok) return res;
  return { ok: true, realm: res.data.realm, kingdoms: res.data.kingdoms || [] };
}

export async function leaderboardOnline() {
  const res = await rpc("cc_leaderboard");
  if (!res.ok) return res;
  return { ok: true, kingdoms: res.data.kingdoms || [] };
}

export async function adminSearchOnline(query) {
  return rpc("cc_admin_search", { p_query: query || "" });
}

export async function adminGrantOnline({ name, gold, food, land, note }) {
  return rpc("cc_admin_grant", {
    p_name: name,
    p_gold: gold,
    p_food: food,
    p_land: land,
    p_note: note || "",
  });
}

export async function adminBanOnline(username, reason) {
  return rpc("cc_admin_ban", { p_username: username, p_reason: reason });
}

export async function adminUnbanOnline(username) {
  return rpc("cc_admin_unban", { p_username: username });
}

export async function adminLogOnline() {
  return rpc("cc_admin_log");
}

export async function seasonsOnline() {
  return rpc("cc_seasons_view");
}

function mapChatMessage(row, channel) {
  return {
    id: Number(row.id),
    body: row.body || "",
    createdAt: Date.parse(row.created_at) || Date.now(),
    kingdom: row.kingdom || "A departed crown",
    tag: row.tag || "",
    admin: Boolean(row.admin),
    channel: row.channel || channel,
    username: row.username || "",
    playerKey: row.player_id || row.username || "",
  };
}

export async function chatHistoryOnline(channel, beforeId = null) {
  const res = await rpc("cc_chat_history", { p_channel: channel, p_before: beforeId });
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, channel)),
    locked: res.data?.locked || "",
  };
}

export async function chatSendOnline(channel, body) {
  const res = await rpc("cc_chat_send", { p_channel: channel, p_body: body });
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, channel)),
    locked: res.data?.locked || "",
  };
}

export async function adminChatRecentOnline() {
  const res = await rpc("cc_admin_chat_recent");
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, row.channel)),
    mutes: res.data?.mutes || [],
  };
}

export async function adminChatDeleteOnline(id) {
  const res = await rpc("cc_admin_chat_delete", { p_message_id: id });
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, row.channel)),
    mutes: res.data?.mutes || [],
  };
}

export async function adminChatMuteOnline(player, minutes, reason) {
  const res = await rpc("cc_admin_chat_mute", { p_player: player, p_minutes: minutes, p_reason: reason });
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, row.channel)),
    mutes: res.data?.mutes || [],
  };
}

export async function adminChatUnmuteOnline(player) {
  const res = await rpc("cc_admin_chat_unmute", { p_player: player });
  if (!res.ok) return res;
  return {
    ok: true,
    messages: (res.data?.messages || []).map((row) => mapChatMessage(row, row.channel)),
    mutes: res.data?.mutes || [],
  };
}

export async function wipeSeasonOnline(confirmWord, name) {
  return rpc("cc_admin_wipe_season", { p_confirm: confirmWord, p_season_name: name || "" });
}

export async function targetsOnline(query) {
  const res = await rpc("cc_targets", { p_query: query || "" });
  if (!res.ok) return res;
  return { ok: true, kingdoms: res.data.kingdoms || [] };
}

export async function oddsOnline(target, units) {
  return rpc("cc_odds", { p_target: target, p_units: units });
}

export async function attackOnline(target, type, units) {
  return follow(await rpc("cc_attack", { p_target: target, p_type: type, p_units: units }));
}

export async function spyOnline(target) {
  return follow(await rpc("cc_spy", { p_target: target }));
}

export async function buySpyOnline(count) {
  return follow(await rpc("cc_buy_spy", { p_count: count }));
}

export async function reportsOnline() {
  const res = await rpc("cc_reports");
  if (!res.ok) return res;
  return { ok: true, reports: res.data.reports || [] };
}

export async function allianceStateOnline() {
  return rpc("cc_alliance_state");
}

export async function allianceBrowseOnline(query) {
  return rpc("cc_alliance_browse", { p_query: query || "" });
}

export async function allianceBoardOnline() {
  return rpc("cc_alliance_board");
}

export async function allianceCreateOnline(name, tag, description) {
  return rpc("cc_alliance_create", { p_name: name, p_tag: tag, p_description: description || "" });
}

export async function allianceRequestOnline(id) {
  return rpc("cc_alliance_request", { p_alliance: id });
}

export async function allianceInviteOnline(name) {
  return rpc("cc_alliance_invite", { p_name: name });
}

export async function allianceAnswerOnline(id, accept) {
  return rpc("cc_alliance_answer", { p_request: id, p_accept: accept });
}

export async function allianceLeaveOnline() {
  return rpc("cc_alliance_leave");
}

export async function allianceKickOnline(name) {
  return rpc("cc_alliance_kick", { p_name: name });
}

export async function allianceRoleOnline(name, officer) {
  return rpc("cc_alliance_set_role", { p_name: name, p_officer: officer });
}

export async function allianceTransferOnline(name) {
  return rpc("cc_alliance_transfer", { p_name: name });
}

export async function allianceDisbandOnline() {
  return rpc("cc_alliance_disband");
}

export { logInAccount, logOutAccount, signUpAccount };
