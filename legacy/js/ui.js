import { castleArt, icon, shield } from "./icons.js";
import {
  BUILDINGS,
  BUILDING_ORDER,
  LANDS,
  LAND_ORDER,
  TICK_SECONDS,
  TRACKS,
  TRACK_ORDER,
  UNITS,
  UNIT_ORDER,
  researchCost,
} from "./rules.js";
import { buildSeconds, crewStatus, describe, landTraits, quoteExplore, quoteTrain, roster, unitUnlocked } from "./engine.js";
import { ATTACK_TYPES, battleBrief, isProtected, tagged } from "./combat.js";
import { unreadCount } from "./chat.js";
import { musicState, setVolume } from "./music.js";

let lastKey = "";

export function render(root, model, act) {
  const key = `${model.screen}:${model.tab}:${model.mode}`;
  const y = key === lastKey ? window.scrollY : 0;
  const chatFocus = document.activeElement?.id === "chat-body";
  const caret = chatFocus ? document.activeElement.selectionStart : null;
  lastKey = key;
  root.replaceChildren(view(model, act));
  window.scrollTo(0, y);
  if (model.scrollOrders) {
    model.scrollOrders = false;
    document.getElementById("attack-form")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }
  const log = document.querySelector(".chat-log");
  if (log && model.chatStick !== false) log.scrollTop = log.scrollHeight;
  if (chatFocus) {
    const input = document.getElementById("chat-body");
    if (input) {
      input.focus();
      const pos = caret ?? input.value.length;
      input.setSelectionRange(pos, pos);
    }
  }
}

function el(tag, props, ...kids) {
  const node = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value == null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
      else if (key === "html") node.innerHTML = value;
      else if (key === "value") node.value = String(value);
      else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2).toLowerCase(), value);
      else node.setAttribute(key, value === true ? "" : String(value));
    }
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    node.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return node;
}

function ico(name) {
  return el("span", { class: "ico", html: icon(name) });
}

function num(value) {
  return Math.floor(Number(value) || 0).toLocaleString("en-US");
}

function countLabel(value, singular, plural) {
  const n = Math.floor(Number(value) || 0);
  return `${n} ${n === 1 ? singular : plural}`;
}

function signed(value) {
  const n = Math.floor(Number(value) || 0);
  if (n > 0) return `+${num(n)}`;
  return num(n);
}

function duration(seconds) {
  const s = Math.max(0, Math.ceil(seconds));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${String(r).padStart(2, "0")}s`;
  return `${r}s`;
}

function countdown(ms) {
  if (ms <= 0) return "Finishing…";
  const s = Math.ceil(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const r = s % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  if (m > 0) return `${m}m ${String(r).padStart(2, "0")}s`;
  return `${r}s`;
}

export function paintJobClocks(now = Date.now()) {
  document.querySelectorAll("[data-job-end]").forEach((node) => {
    const end = Number(node.dataset.jobEnd);
    const start = Number(node.dataset.jobStart);
    const clock = node.querySelector("[data-job-clock]");
    const bar = node.querySelector("[data-job-bar]");
    if (clock) clock.textContent = countdown(end - now);
    if (bar && end > start) {
      const pct = Math.max(0, Math.min(100, ((now - start) / (end - start)) * 100));
      bar.style.width = `${pct}%`;
      bar.parentElement?.setAttribute("aria-valuenow", String(Math.round(pct)));
    }
  });
}

function when(at) {
  const t = typeof at === "number" ? at : Date.parse(at);
  if (!Number.isFinite(t)) return "";
  return new Date(t).toLocaleString(undefined, { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

function view(model, act) {
  if (model.screen === "boot") return boot(act);
  if (model.screen === "gate") return gate(model, act);
  if (model.screen === "found") return found(model, act);
  return play(model, act);
}

function boot(act) {
  return el("main", { class: "gate" },
    el("div", { class: "mast-tools" }, musicControl(act)),
    el("p", { class: "eyebrow", text: "Unrolling the map…" }),
  );
}

function gate(model, act) {
  return el(
    "main",
    { class: "gate" },
    mast("Rule one castle inside a shared realm. Networth is the crown.", act, model.season),
    model.notice ? banner(model) : null,
    chatDock(model, act),
    el(
      "div",
      { class: "gate-grid" },
      el(
        "form",
        {
          class: "panel auth-card",
          onsubmit: (event) => {
            event.preventDefault();
            const data = new FormData(event.currentTarget);
            act.auth(event.submitter?.value || "login", data.get("username"), data.get("password"));
          },
        },
        el("h2", { text: "Enter the realm" }),
        el("p", { class: "lede", text: "The same username and password as Toon Orbit Battle. A new name here is a new account there." }),
        el("label", { text: "Username" }),
        el("input", { name: "username", autocomplete: "username", maxlength: "16", required: true }),
        el("label", { text: "Password" }),
        el("input", { name: "password", type: "password", autocomplete: "current-password", required: true }),
        el(
          "div",
          { class: "row" },
          el("button", { class: "btn primary", name: "mode", value: "login", type: "submit", text: "Sign in" }),
          el("button", { class: "btn wood", name: "mode", value: "signup", type: "submit", text: "Create account" }),
        ),
      ),
      el(
        "section",
        { class: "panel" },
        el("h2", { text: "Walk a demo realm" }),
        el("p", { class: "lede", text: "The kingdom is kept on this device. Build, explore, train, and study while the server ledger is still being reviewed. Nothing is sent." }),
        model.mode === "online" && model.kingdom
          ? el("button", { class: "btn wood", type: "button", text: "Return to your kingdom", onclick: () => act.resume() })
          : null,
        el("button", {
          class: "btn primary",
          type: "button",
          text: model.hasDemo ? "Return to your local kingdom" : "Raise a local banner",
          onclick: () => act.demo(),
        }),
        model.hasDemo
          ? el("button", { class: "btn ghost", type: "button", text: "Abandon the local kingdom", onclick: () => act.abandon() })
          : null,
      ),
    ),
  );
}

function found(model, act) {
  return el(
    "main",
    { class: "gate" },
    mast(model.mode === "online" ? `Signed in as ${model.player?.username || "a ruler"}.` : "This banner stays on this device.", act, model.season),
    model.notice ? banner(model) : null,
    chatDock(model, act),
    el(
      "form",
      {
        class: "panel found-card",
        onsubmit: (event) => {
          event.preventDefault();
          const data = new FormData(event.currentTarget);
          act.found(String(data.get("name") || ""), model.drafts.landType);
        },
      },
      el("h2", { text: "Choose your land" }),
      el("label", { text: "Kingdom name" }),
      el("input", {
        name: "name",
        maxlength: "24",
        required: true,
        placeholder: "Highcrest",
        value: model.drafts.foundName || "",
        oninput: (event) => {
          model.drafts.foundName = event.target.value;
        },
      }),
      el("div", { class: "land-grid" }, LAND_ORDER.map((id) => landCard(id, model, act))),
      el(
        "div",
        { class: "row" },
        el("button", { class: "btn primary", type: "submit", text: "Raise your banner" }),
        el("button", { class: "btn ghost", type: "button", text: "Back", onclick: () => act.back() }),
      ),
    ),
  );
}

function landCard(id, model, act) {
  const land = LANDS[id];
  const selected = model.drafts.landType === id;
  return el(
    "button",
    {
      type: "button",
      class: `land-card${selected ? " selected" : ""}`,
      "aria-pressed": selected ? "true" : "false",
      onclick: () => act.pickLand(id),
    },
    el("span", { class: "shield", html: shield(id) }),
    el("span", { class: "land-copy" },
      el("strong", { text: land.name }),
      el("span", { class: "lede", text: land.blurb }),
      el("span", { class: "traits", text: landTraits(land).join(" · ") }),
    ),
  );
}

function play(model, act) {
  const locked = model.mode === "demo" && model.banned && !["steward", "account", "more"].includes(model.tab);
  return el(
    "div",
    { class: "shell" },
    sidebar(model, act),
    el(
      "div",
      { class: "stage" },
      playHead(model, act),
      model.notice ? banner(model) : null,
      model.kingdom ? resources(model.kingdom) : null,
      locked ? banLock(model) : page(model, act),
      bottomNav(model, act),
      model.battleSheet ? battleSheet(model, act) : null,
      model.wipeOpen ? wipeSheet(model, act) : null,
      chatDock(model, act),
    ),
  );
}

function playHead(model, act) {
  const realm = model.kingdom?.realmName || "Realm";
  const seat = model.kingdom?.realmSeat || "";
  const count = model.mode === "demo" ? 1 + (model.npcs?.length || 0) : model.kingdom?.realmCount || 0;
  return el(
    "header",
    { class: "play-head" },
    el("div", { class: "play-title" },
      el("p", { class: "eyebrow", text: [seasonFlag(model.season), model.mode === "demo" ? "Demo realm on this device" : "Live realm"].filter(Boolean).join(" · ") }),
      el("h1", { text: model.kingdom?.name || "Crown & Conquest" }),
      el("p", { class: "seat", text: `${realm}${seat ? ` · ${seat}` : ""}${count ? ` · ${count} of 20 crowns` : ""}` }),
    ),
    el("div", { class: "head-tools" },
      musicControl(act),
      el("div", { class: "tickbox" },
        el("span", { class: "tick-label", text: "Next tick" }),
        el("strong", { id: "tick-clock", text: tickLabel(model.kingdom) }),
      ),
    ),
  );
}

function musicControl(act) {
  const state = musicState();
  const pct = String(Math.round(state.volume * 100));
  return el("div", { class: "music" },
    el("button", {
      type: "button",
      class: state.muted ? "music-btn off" : "music-btn",
      "aria-pressed": state.muted ? "true" : "false",
      "aria-label": state.muted ? "Unmute music" : "Mute music",
      title: state.muted ? "Music off" : "Music on",
      onclick: (event) => {
        event.stopPropagation();
        act.toggleMusic();
      },
    }, ico(state.muted ? "speakerOff" : "speaker")),
    el("input", {
      class: "music-vol",
      type: "range",
      min: "0",
      max: "100",
      value: pct,
      "aria-label": "Music volume",
      oninput: (event) => setVolume(Number(event.target.value) / 100),
    }),
  );
}

function resources(state) {
  const view = describe(state);
  const items = [
    ["gold", "Gold", num(state.gold), `${signed(view.goldPerHour)}/h`],
    ["food", "Food", num(state.food), `${signed(view.food.net)}/h`],
    ["peasants", "People", num(state.peasants), `cap ${num(view.popCap)}`],
    ["land", "Land", num(state.land), `${num(view.freeLand)} open`],
    ["mana", "Mana", num(state.mana), `${signed(view.mana.perHour)}/h`],
    ["crown", "Networth", num(view.networth), "score"],
  ];
  return el(
    "div",
    { class: "resources" },
    items.map(([name, label, value, sub]) => el(
      "div",
      { class: `resource ${name}` },
      ico(name === "crown" ? "crown" : name),
      el("span", {},
        el("span", { class: "res-label", text: label }),
        el("strong", { text: value }),
        el("span", { class: "res-sub", text: sub }),
      ),
    )),
  );
}

function page(model, act) {
  if (model.tab === "build") return buildPage(model, act);
  if (model.tab === "explore") return explorePage(model, act);
  if (model.tab === "host") return hostPage(model, act);
  if (model.tab === "scholars") return scholarPage(model, act);
  if (model.tab === "realm") return realmPage(model, act);
  if (model.tab === "war") return warPage(model, act);
  if (model.tab === "alliances") return alliancePage(model, act);
  if (model.tab === "steward") return stewardPage(model, act);
  if (model.tab === "account") return accountPage(model, act);
  if (model.tab === "more") return morePage(model, act);
  return throne(model, act);
}

function throne(model, act) {
  const state = model.kingdom;
  const view = describe(state);
  const land = LANDS[state.landType];
  return el(
    "section",
    { class: "throne" },
    view.starving
      ? el(
        "div",
        { class: "starve", role: "status" },
        el("strong", { text: "The granaries are empty." }),
        el("p", { text: "The army fights hungry (attack 62%, defense 75%). Births have stopped, housing is cut to 72%, and people leave while the deficit lasts." }),
      )
      : null,
    state.underAttack
      ? el("div", { class: "starve", role: "status" }, el("strong", { text: "An army is marching on your gates." }), el("p", { text: "Open the War Room to see who is coming." }))
      : null,
    isProtected(state, Date.now())
      ? el("div", { class: "notice", text: "A new charter protects this kingdom until you attack, or until a day has passed." })
      : null,
    el(
      "div",
      { class: "throne-grid" },
      el(
        "article",
        { class: "panel identity" },
        el("span", { class: "shield lg", html: shield(state.landType) }),
        el("div", {},
          el("p", { class: "eyebrow", text: land.name }),
          el("h2", { text: state.name }),
          el("p", { class: "lede", text: land.blurb }),
          el("p", { class: "traits", text: landTraits(land).join(" · ") }),
        ),
      ),
      el("div", { class: "panel castle", html: castleArt() }),
    ),
    el(
      "div",
      { class: "stat-grid" },
      stat("Attack", num(view.army.attack), view.starving ? "Hungry levy" : "Ready"),
      stat("Defense", num(view.army.defense), `${countLabel(state.buildings.wall, "wall", "walls")} · ${countLabel(state.buildings.tower, "tower", "towers")}`),
      stat("Scholars", num(view.scholars), `${signed(view.researchPerHour)} research/h`),
      stat("Barracks", `${num(view.housingUsed)}/${num(view.housingCap)}`, "Soldiers housed"),
      stat("Acres", `${num(view.built)} built`, `${num(view.freeLand)} open · ${num(view.pending)} raising`),
      stat("Stores", view.starving ? "Empty" : "Fed", `${num(view.food.produced)} grown · ${num(view.food.consumed)} eaten`),
    ),
    el(
      "div",
      { class: "split" },
      el("section", { class: "panel works" },
        el("h2", { text: "Works in progress" }),
        worksBody(state),
        model.mode === "demo"
          ? el("button", { class: "btn wood", type: "button", id: "hour-bell", text: "Sound the hour bell", onclick: () => act.bell() })
          : el("p", { class: "muted", text: "Online kingdoms advance on the server clock, once a minute." }),
      ),
      el("section", { class: "panel" },
        el("h2", { text: "Chronicle" }),
        el("ol", { class: "chronicle" }, [...state.chronicle].reverse().map((line) => el(
          "li",
          {},
          el("time", { text: when(line.at) }),
          el("span", { text: line.text }),
        ))),
      ),
    ),
  );
}

function stat(label, value, sub) {
  return el("article", { class: "stat" },
    el("span", { text: label }),
    el("strong", { text: value }),
    el("em", { text: sub }),
  );
}

function worksPanel(state) {
  return el("section", { class: "panel works" },
    el("h2", { text: "Works in progress" }),
    worksBody(state),
  );
}

function worksBody(state) {
  const jobs = state.jobs || [];
  return el(
    "div",
    {},
    crewLine(state),
    jobs.length
      ? el("div", { class: "work-list" }, jobs.map((job) => jobCard(job)))
      : el("p", { class: "muted", text: "Nothing is under way." }),
  );
}

function crewLine(state) {
  const crews = crewStatus(state);
  return el(
    "div",
    { class: "crew-line" },
    el("p", { class: "cost", text: `Crews ${crews.busy}/${crews.cap} busy` }),
    crews.live
      ? null
      : el("p", { class: "muted", text: "Extra crews wait until the server ledger learns the Masons' Guild." }),
  );
}

function jobCard(job) {
  const now = Date.now();
  const span = Math.max(1, job.completesAt - job.startedAt);
  const pct = Math.max(0, Math.min(100, ((now - job.startedAt) / span) * 100));
  return el(
    "div",
    {
      class: "job",
      "data-job-start": String(job.startedAt),
      "data-job-end": String(job.completesAt),
    },
    el("div", { class: "job-top" },
      el("strong", { text: jobTitle(job) }),
      el("span", { "data-job-clock": "1", text: countdown(job.completesAt - now) }),
    ),
    el("p", { class: "job-kind", text: jobKindLabel(job) }),
    el("div", { class: "bar", role: "progressbar", "aria-valuenow": String(Math.round(pct)), "aria-valuemin": "0", "aria-valuemax": "100" },
      el("span", { "data-job-bar": "1", style: `width:${pct}%` }),
    ),
  );
}

function jobKindLabel(job) {
  if (job.kind === "build") return `Building ×${job.count}`;
  if (job.kind === "explore") return `Exploration ×${job.count} acres`;
  if (job.kind === "train") return `Training ×${job.count}`;
  if (job.kind === "research") return "Research";
  return "Work";
}

function jobTitle(job) {
  if (job.kind === "build") return `${BUILDINGS[job.building]?.name || "Building"} ×${job.count}`;
  if (job.kind === "explore") return `Scouts ×${job.count} acres`;
  if (job.kind === "train") return `${UNITS[job.unit]?.name || "Company"} ×${job.count}`;
  if (job.kind === "research") return `${TRACKS[job.track]?.name || "Study"}`;
  return "Work";
}

function jobsFor(state, kind, id) {
  return (state.jobs || []).filter((job) => {
    if (job.kind !== kind) return false;
    if (kind === "build") return job.building === id;
    if (kind === "train") return job.unit === id;
    if (kind === "research") return job.track === id;
    return true;
  });
}

function rowCountdown(job, phrase) {
  return el(
    "p",
    {
      class: "job-inline",
      "data-job-start": String(job.startedAt),
      "data-job-end": String(job.completesAt),
    },
    el("span", { text: `${phrase}, ` }),
    el("span", { "data-job-clock": "1", text: countdown(job.completesAt - Date.now()) }),
    el("span", { text: " left" }),
  );
}

function buildPage(model, act) {
  const state = model.kingdom;
  const view = describe(state);
  return el(
    "section",
    {},
    el("div", { class: "page-intro" },
      el("h2", { text: "Build" }),
      el("p", { text: buildIntro(state, view) }),
    ),
    worksPanel(state),
    el("div", { class: "card-grid" }, BUILDING_ORDER.map((id) => {
      const def = BUILDINGS[id];
      const count = model.drafts.build[id] || 1;
      const seconds = buildSeconds(state, id, count);
      const cost = def.cost * count;
      const waiting = state.crewsLive === false && id === "guild";
      return el(
        "article",
        { class: `card${waiting ? " locked" : ""}` },
        el("header", {},
          el("h3", { text: def.name }),
          el("b", { text: `Owned ${state.buildings[id] || 0}` }),
        ),
        el("p", { text: def.effect }),
        el("p", { class: "cost", text: `${num(cost)} gold · ${duration(seconds)} · ${count} acre${count === 1 ? "" : "s"}` }),
        waiting ? el("p", { class: "lock-note", text: "The server ledger does not know this yard yet." }) : null,
        ...jobsFor(state, "build", id).map((job) => rowCountdown(job, `${def.name} +${job.count} building`)),
        stepper(count, (next) => act.setBuild(id, next)),
        el("button", {
          class: "btn primary",
          type: "button",
          text: waiting ? "Not yet" : "Build",
          disabled: model.busy || waiting,
          onclick: () => act.build(id),
        }),
      );
    })),
  );
}

function buildIntro(state, view) {
  const crews = crewStatus(state);
  const haste = crews.haste ? ` Builds are ${crews.haste}% faster.` : "";
  return `Crews ${crews.busy}/${crews.cap} busy.${haste} Each building takes an acre. ${num(view.freeLand)} acres are open, and the purse holds ${num(state.gold)} gold.`;
}

function stepper(count, onChange, max = 40) {
  return el("div", { class: "stepper" },
    el("button", { type: "button", text: "−", onclick: () => onChange(Math.max(1, count - 1)) }),
    el("span", { text: String(count) }),
    el("button", { type: "button", text: "+", onclick: () => onChange(Math.min(max, count + 1)) }),
    el("button", { type: "button", text: "+5", onclick: () => onChange(Math.min(max, count + 5)) }),
  );
}

function explorePage(model, act) {
  const state = model.kingdom;
  const acres = Math.max(0, Math.floor(Number(model.drafts.explore) || 0));
  const quote = quoteExplore(state, acres || 0);
  return el(
    "section",
    { class: "panel narrow" },
    el("h2", { text: "Explore" }),
    el("p", { text: "Scouts buy new acres. A charter allows 8% of your current land each day, and at least 8 acres. Settlers leave with the party and come home when the claim is marked." }),
    el("p", { class: "cost", id: "explore-quote", text: exploreQuote(quote, acres) }),
    el("label", { text: "Acres to claim" }),
    el("input", {
      id: "explore-acres",
      type: "number",
      min: "1",
      max: "200",
      value: String(model.drafts.explore),
      oninput: (event) => {
        model.drafts.explore = event.target.value;
        const node = document.getElementById("explore-quote");
        const next = Math.max(0, Math.floor(Number(event.target.value) || 0));
        if (node) node.textContent = exploreQuote(quoteExplore(state, next), next);
      },
    }),
    el("button", { class: "btn primary", type: "button", text: "Send scouts", disabled: model.busy, onclick: () => act.explore() }),
  );
}

function exploreQuote(quote, acres) {
  if (!acres) return `${quote.left} acres left on today's charter.`;
  return `${num(quote.cost)} gold · ${duration(quote.seconds)} · ${quote.settlers} settlers · ${quote.left} acres left on the charter.`;
}

function hostPage(model, act) {
  const state = model.kingdom;
  const view = describe(state);
  return el(
    "section",
    {},
    el("div", { class: "page-intro" },
      el("h2", { text: "Host" }),
      el("p", { text: `Training spends gold, food, and peasants. Housing ${num(view.housingUsed)} of ${num(view.housingCap)}. One company trains at a time. Attacking comes later; these numbers are what a battle will read.` }),
    ),
    el("div", { class: "card-grid" }, UNIT_ORDER.map((id) => {
      const def = UNITS[id];
      const count = model.drafts.train[id] || 1;
      const quote = quoteTrain(state, id, count);
      const open = unitUnlocked(state, id);
      return el(
        "article",
        { class: `card${open ? "" : " locked"}` },
        el("header", {},
          el("h3", { text: def.name }),
          el("b", { text: `Have ${state.units[id] || 0}` }),
        ),
        el("p", { text: def.blurb }),
        el("p", { class: "stats-line", text: `Attack ${def.attack} · Defense ${def.defense} · Housing ${def.housing}` }),
        open
          ? el("p", { class: "cost", text: `${num(quote.gold)} gold · ${num(quote.food)} food · ${quote.peasants} peasants · ${duration(quote.seconds)}` })
          : el("p", { class: "lock-note", text: lockText(def) }),
        stepper(count, (next) => act.setTrain(id, next), 200),
        el("button", {
          class: "btn primary",
          type: "button",
          text: open ? "Train" : "Locked",
          disabled: model.busy || !open,
          onclick: () => act.train(id),
        }),
      );
    })),
  );
}

function lockText(def) {
  const bits = [];
  if (def.req?.military) bits.push(`War College ${def.req.military}`);
  if (def.req?.magic) bits.push(`Ley Studies ${def.req.magic}`);
  return `Needs ${bits.join(" and ")}.`;
}

function scholarPage(model, act) {
  const state = model.kingdom;
  const view = describe(state);
  return el(
    "section",
    {},
    el("div", { class: "page-intro" },
      el("h2", { text: "Scholars" }),
      el("p", { text: `${num(view.scholars)} scholars are at the desks (${signed(view.researchPerHour)} points an hour). You hold ${num(state.researchPoints)} points. Each library employs up to 14 peasants.` }),
    ),
    worksPanel(state),
    el("div", { class: "track-list" }, TRACK_ORDER.map((id) => {
      const track = TRACKS[id];
      const level = state.research[id] || 0;
      const max = track.max || 10;
      const waiting = state.crewsLive === false && id === "masons";
      const cost = level >= max ? null : researchCost(level);
      return el(
        "article",
        { class: `panel track${waiting ? " locked" : ""}` },
        el("div", {},
          el("h3", { text: track.name }),
          el("p", { text: track.blurb }),
          el("p", { class: "cost", text: track.effect }),
          waiting ? el("p", { class: "lock-note", text: "The server ledger does not know this study yet." }) : null,
          ...jobsFor(state, "research", id).map((job) => rowCountdown(job, `${track.name} study`)),
        ),
        el("div", { class: "pips" }, Array.from({ length: max }, (_, i) => el("i", { class: i < level ? "on" : "" }))),
        el("button", {
          class: "btn primary",
          type: "button",
          text: waiting ? "Not yet" : (cost == null ? "Complete" : `Study · ${num(cost)}`),
          disabled: model.busy || waiting || cost == null,
          onclick: () => act.research(id),
        }),
      );
    })),
  );
}

function realmPage(model, act) {
  const realmRows = model.realmRows || [];
  const board = model.leaderboard || [];
  return el(
    "section",
    {},
    el("div", { class: "page-intro" },
      el("h2", { text: "Realm" }),
      el("p", { text: model.mode === "demo"
        ? "The Amber March holds your banner and ten established houses. In a demo, this list is also the continent."
        : "Kingdoms that share your realm, then the widest crowns on the continent." }),
    ),
    el("section", { class: "panel" },
      el("h3", { text: model.kingdom?.realmName || "Your realm" }),
      boardList(realmRows),
    ),
    model.mode === "online"
      ? el("section", { class: "panel" },
        el("h3", { text: "Continent" }),
        boardList(board),
      )
      : null,
    hallOfSeasons(model),
    el("button", { class: "btn ghost", type: "button", text: "Refresh the board", onclick: () => act.refreshBoard() }),
  );
}

function boardList(rows) {
  if (!rows.length) return el("p", { class: "muted", text: "The board is empty." });
  return el("ol", { class: "board" }, rows.map((row, index) => el(
    "li",
    { class: row.you || row.is_you ? "you" : "" },
    el("span", { class: "rank", text: String(index + 1) }),
    el("span", { class: "shield sm", html: shield(row.landType || row.land_type) }),
    el("span", { class: "who" },
      el("strong", { text: tagged(row.name, row.tag || row.alliance_tag || row.allianceTag) }),
      el("em", { text: `${LANDS[row.landType || row.land_type]?.name || ""} · ${num(row.land)} acres${row.npc || row.is_npc ? " · established house" : ""}` }),
    ),
    el("b", { text: num(row.networth) }),
  )));
}

function stewardPage(model, act) {
  const rows = model.adminResults || [];
  return el(
    "section",
    { class: "steward" },
    el("div", { class: "page-intro" },
      el("h2", { text: "Steward's desk" }),
      el("p", { text: model.mode === "demo"
        ? "This desk only changes the kingdom on this device. Grants, bans, and a season wipe stay on this device."
        : "Search kingdoms, grant gold, food, or land, and ban a login. Every action is written to the log." }),
    ),
    seasonsPanel(model, act),
    el("form", {
      class: "panel row",
      onsubmit: (event) => {
        event.preventDefault();
        act.adminSearch(new FormData(event.currentTarget).get("q"));
      },
    },
      el("input", { name: "q", placeholder: "Kingdom or username", value: model.drafts.search || "" }),
      el("button", { class: "btn wood", type: "submit", text: "Search" }),
    ),
    el("div", { class: "admin-list" }, rows.map((row) => adminCard(row, model, act))),
    el("section", { class: "panel" },
      el("h3", { text: "Action log" }),
      (model.adminLog || []).length
        ? el("ol", { class: "chronicle" }, model.adminLog.map((line) => el(
          "li",
          {},
          el("time", { text: when(line.created_at || line.at) }),
          el("span", { text: logLine(line) }),
        )))
        : el("p", { class: "muted", text: "No steward actions yet." }),
    ),
    chatSteward(model, act),
  );
}

function adminCard(row, model, act) {
  const name = row.name;
  const username = row.username;
  return el(
    "article",
    { class: "panel admin-card" },
    el("header", {},
      el("h3", { text: name }),
      el("span", { class: "chip", text: row.is_npc || row.isNpc ? "Established house" : (username || "Ruler") }),
    ),
    el("p", { class: "cost", text: `${LANDS[row.land_type || row.landType]?.name || ""} · networth ${num(row.networth)} · ${num(row.land)} acres · ${num(row.gold)} gold · ${num(row.food)} food` }),
    (row.banned ? el("p", { class: "lock-note", text: `Banned. ${row.ban_reason || row.banReason || ""}` }) : null),
    el("div", { class: "grant" },
      numberField(fieldId("gold", name), "Gold", "0"),
      numberField(fieldId("food", name), "Food", "0"),
      numberField(fieldId("land", name), "Land", "0"),
      el("button", {
        class: "btn primary",
        type: "button",
        text: "Grant",
        onclick: () => act.grant(name, readNum(fieldId("gold", name)), readNum(fieldId("food", name)), readNum(fieldId("land", name))),
      }),
    ),
    username && !(row.is_npc || row.isNpc)
      ? el("div", { class: "row" },
        el("input", { id: fieldId("why", username), placeholder: "Reason for a ban", maxlength: "200" }),
        row.banned
          ? el("button", { class: "btn wood", type: "button", text: "Unban", onclick: () => act.unban(username) })
          : el("button", { class: "btn ghost", type: "button", text: "Ban", onclick: () => act.ban(username, document.getElementById(fieldId("why", username))?.value || "") }),
      )
      : null,
  );
}

function numberField(id, label, value) {
  return el("label", { class: "mini" },
    el("span", { text: label }),
    el("input", { id, type: "number", min: "0", value }),
  );
}

function fieldId(prefix, name) {
  return `${prefix}-${String(name).toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
}

function readNum(id) {
  return Math.floor(Number(document.getElementById(id)?.value || 0));
}

function logLine(line) {
  const action = line.action || "note";
  const label = line.label || line.target || "";
  if (action === "grant") return `Grant to ${label}: ${num(line.gold)} gold, ${num(line.food)} food, ${num(line.land)} land. ${line.note || ""}`.trim();
  if (action === "ban") return `Banned ${label}. ${line.note || ""}`.trim();
  if (action === "unban") return `Lifted the ban on ${label}.`;
  if (action === "wipe") return `Season wipe. ${label}. ${line.note || ""}`.trim();
  if (action === "chat_delete") return `Removed a message. ${line.note || ""}`.trim();
  if (action === "chat_mute") return `Muted ${label}. ${line.note || ""}`.trim();
  if (action === "chat_unmute") return `Unmuted ${label}.`;
  return `${action} ${label}`;
}

function seasonsPanel(model, act) {
  const season = model.season;
  const ready = model.mode === "demo" || model.seasonsLive;
  return el(
    "section",
    { class: "panel seasons" },
    el("h3", { text: "Seasons" }),
    season
      ? el("p", { text: `${seasonFlag(season)}. Opened ${when(season.started_at || season.startedAt)}.` })
      : el("p", { class: "muted", text: "No season is recorded yet." }),
    ready
      ? el("button", { class: "btn danger", type: "button", text: "WIPE / Start New Season", onclick: () => act.openWipe() })
      : el("p", { class: "lock-note", text: "The season ledger is not on the server yet." }),
  );
}

function wipeSheet(model, act) {
  const nextNumber = (model.season?.number || 1) + 1;
  return el(
    "div",
    {
      class: "battle-sheet",
      role: "dialog",
      "aria-modal": "true",
      "aria-label": "Wipe the season",
      onclick: (event) => {
        if (event.target === event.currentTarget) act.closeWipe();
      },
    },
    el(
      "form",
      {
        class: "panel battle-card wipe-card",
        onsubmit: (event) => {
          event.preventDefault();
          const data = new FormData(event.currentTarget);
          act.wipeSeason(String(data.get("confirm") || ""), String(data.get("name") || ""));
        },
      },
      el("p", { class: "outcome loss", text: "Wipe" }),
      el("h3", { text: "Start a new season" }),
      el("p", { text: "This retires every kingdom, march, report, and player alliance. Accounts stay. The realms are seeded again with the established houses and the pacts [IRN] and [VERD]. Rulers found a new kingdom afterward." }),
      el("label", { text: "Name for the new season" }),
      el("input", { name: "name", maxlength: "40", placeholder: `Season ${nextNumber}`, value: model.wipeName || "" }),
      el("label", { text: "Type WIPE to confirm" }),
      el("input", {
        name: "confirm",
        maxlength: "8",
        autocomplete: "off",
        placeholder: "WIPE",
        value: model.wipeConfirm || "",
        oninput: (event) => {
          model.wipeConfirm = event.target.value;
          const button = event.currentTarget.form?.querySelector("[data-wipe-go]");
          if (button) button.disabled = event.target.value !== "WIPE";
        },
      }),
      el("div", { class: "row" },
        el("button", { class: "btn ghost", type: "button", text: "Cancel", onclick: () => act.closeWipe() }),
        el("button", { class: "btn danger", type: "submit", text: "Wipe the season", "data-wipe-go": "1", disabled: true }),
      ),
    ),
  );
}

function hallOfSeasons(model) {
  const past = model.pastSeasons || [];
  return el(
    "section",
    { class: "panel hall" },
    el("h3", { text: "Hall of Past Seasons" }),
    past.length
      ? past.map((season) => seasonCard(season))
      : el("p", { class: "muted", text: "No season has been retired." }),
  );
}

function seasonCard(season) {
  const standings = season.standings || {};
  const worth = standings.by_networth || [];
  const land = standings.by_land || [];
  const pacts = standings.alliances || [];
  const landChamp = land[0];
  const pact = pacts[0];
  return el(
    "article",
    { class: "season-card" },
    el("h3", { text: seasonFlag(season) }),
    el("p", { class: "muted", text: `${when(season.started_at || season.startedAt)} – ${when(season.ended_at || season.endedAt)}` }),
    worth.length
      ? el("ol", { class: "board compact" }, worth.slice(0, 3).map((row, index) => el(
        "li",
        {},
        el("span", { class: "rank", text: String(index + 1) }),
        el("span", { class: "who" }, el("strong", { text: tagged(row.name, row.tag) }), el("em", { text: `${num(row.land)} acres${row.is_npc ? " · house" : ""}` })),
        el("b", { text: num(row.networth) }),
      )))
      : el("p", { class: "muted", text: "No crowns were recorded." }),
    landChamp ? el("p", { text: `Widest land: ${tagged(landChamp.name, landChamp.tag)}, ${num(landChamp.land)} acres.` }) : null,
    pact ? el("p", { text: `First pact: ${tagged(pact.name, pact.tag)}, ${num(pact.networth)} networth, ${num(pact.members)} houses.` }) : null,
  );
}

function accountPage(model, act) {
  return el(
    "section",
    { class: "panel narrow" },
    el("h2", { text: "Account" }),
    model.mode === "online"
      ? el("p", { text: `Signed in as ${model.player?.username}. Logging out leaves the kingdom on the server.` })
      : el("p", { text: "This is a local realm. Abandoning it removes the banner from this device." }),
    model.mode === "online"
      ? el("button", { class: "btn wood", type: "button", text: "Log out", onclick: () => act.logout() })
      : el("button", { class: "btn wood", type: "button", text: "Abandon local kingdom", onclick: () => act.abandon() }),
    el("button", { class: "btn ghost", type: "button", text: "Back to the gate", onclick: () => act.back() }),
  );
}

function morePage(model, act) {
  const links = [
    ["explore", "Explore", "Claim acres under the daily charter."],
    ["host", "Host", "Train the levy."],
    ["alliances", "Alliances", "Pacts, tags, and requests."],
    ["scholars", "Scholars", "Spend research on the five colleges."],
    ["account", "Account", model.mode === "online" ? "Log out of this login." : "Leave or abandon the demo."],
  ];
  if (model.mode === "demo" || model.player?.admin) links.splice(2, 0, ["steward", "Steward", "Grants, bans, and the action log."]);
  return el(
    "section",
    { class: "more-list" },
    links.map(([id, title, text]) => el(
      "button",
      { class: "panel more-link", type: "button", onclick: () => act.tab(id) },
      el("strong", { text: title }),
      el("span", { text }),
    )),
  );
}

function banLock(model) {
  return el(
    "section",
    { class: "panel starve" },
    el("h2", { text: "This banner is banished" }),
    el("p", { text: model.banReason || "No reason was recorded." }),
    el("p", { text: "The steward's desk can lift it. Other orders are closed." }),
  );
}

function banner(model) {
  return el("div", { class: `notice ${model.tone || "info"}`, role: "status", text: model.notice });
}

function chatRows(model, channel) {
  return (model.chatMessages || []).filter((row) => row.channel === channel && !row.deleted);
}

function chatStamp(at) {
  const t = typeof at === "number" ? at : Date.parse(at);
  if (!Number.isFinite(t)) return "";
  return new Date(t).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
}

function chatDock(model, act) {
  if (model.screen === "boot") return null;
  const open = Boolean(model.chatOpen);
  const unread = ["global", "realm", "alliance"].reduce((sum, channel) => {
    if (open && model.chatChannel === channel) return sum;
    return sum + unreadCount(chatRows(model, channel), model.chatSeen?.[channel]);
  }, 0);
  return el(
    "div",
    { class: `chat-dock${open ? " open" : ""}` },
    el("button", { class: "btn wood chat-toggle", type: "button", onclick: () => act.toggleChat() },
      el("span", { text: "Chat" }),
      unread ? el("i", { class: "chat-badge", text: unread > 9 ? "9+" : String(unread) }) : null,
    ),
    open ? chatPanel(model, act) : null,
  );
}

function chatPanel(model, act) {
  if (model.chatLive === false) {
    return el("section", { class: "panel chat-panel" },
      el("p", { text: "The speaking-hall is not on the server ledger yet." }),
    );
  }
  const channel = model.chatChannel || "global";
  const rows = chatRows(model, channel);
  const locked = model.chatLocked?.[channel] || "";
  return el(
    "section",
    { class: "panel chat-panel" },
    el("div", { class: "chat-tabs" }, ["global", "realm", "alliance"].map((id) => {
      const waiting = unreadCount(chatRows(model, id), id === channel ? rows.at(-1)?.id : model.chatSeen?.[id]);
      return el("button", {
        type: "button",
        class: id === channel ? "on" : "",
        onclick: () => act.chatTab(id),
      },
        el("span", { text: id === "global" ? "Global" : id === "realm" ? "Realm" : "Alliance" }),
        waiting ? el("i", { class: "chat-badge", text: waiting > 9 ? "9+" : String(waiting) }) : null,
      );
    })),
    rows.length >= 100
      ? el("button", { class: "btn ghost", type: "button", text: "Earlier", onclick: () => act.chatEarlier() })
      : null,
    el("div", {
      class: "chat-log",
      onscroll: (event) => {
        const node = event.currentTarget;
        model.chatStick = node.scrollHeight - node.scrollTop - node.clientHeight < 48;
      },
    },
      rows.length
        ? rows.map((row) => el("article", { class: "chat-line" },
          el("p", { class: "chat-meta" },
            el("time", { text: chatStamp(row.createdAt) }),
            el("strong", { text: tagged(row.kingdom, row.tag) }),
            row.admin ? el("span", { class: "chip", text: "Steward" }) : null,
          ),
          el("p", { text: row.body }),
        ))
        : el("p", { class: "muted", text: locked || "The hall is quiet." }),
    ),
    locked
      ? el("p", { class: "lock-note", text: locked })
      : el("form", {
        class: "chat-compose",
        onsubmit: (event) => {
          event.preventDefault();
          const body = new FormData(event.currentTarget).get("body");
          act.chatSend(body);
        },
      },
        el("input", {
          id: "chat-body",
          name: "body",
          maxlength: "300",
          placeholder: "Speak to the hall",
          value: model.chatDraft || "",
          oninput: (event) => act.chatDraft(event.target.value),
          onkeydown: (event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              act.chatSend(event.currentTarget.value);
            }
          },
        }),
        el("button", { class: "btn primary", type: "submit", text: "Send" }),
      ),
  );
}

function chatSteward(model, act) {
  if (model.mode === "online" && model.chatLive === false) {
    return el("section", { class: "panel" },
      el("h3", { text: "Speaking-hall" }),
      el("p", { class: "lock-note", text: "Chat is not on the server ledger yet." }),
    );
  }
  const messages = model.chatAdmin?.length ? model.chatAdmin : (model.chatMessages || []).filter((row) => !row.deleted).slice(-40).reverse();
  const mutes = (model.chatMutes || []).filter((row) => {
    const until = typeof row.until === "number" ? row.until : Date.parse(row.until);
    return until > Date.now();
  });
  return el(
    "section",
    { class: "panel" },
    el("h3", { text: "Speaking-hall" }),
    messages.length
      ? el("div", { class: "chat-admin" }, messages.map((row) => el("article", { class: "chat-line" },
        el("p", { class: "chat-meta" },
          el("time", { text: chatStamp(row.createdAt) }),
          el("strong", { text: `${row.channel || ""} · ${tagged(row.kingdom, row.tag)}` }),
        ),
        el("p", { text: row.body }),
        el("button", { class: "btn ghost", type: "button", text: "Delete", onclick: () => act.chatDelete(row.id) }),
      )))
      : el("p", { class: "muted", text: "No recent messages." }),
    el("form", {
      class: "row",
      onsubmit: (event) => {
        event.preventDefault();
        const data = new FormData(event.currentTarget);
        act.chatMute(data.get("who"), data.get("minutes"), data.get("why"));
      },
    },
      el("input", { name: "who", placeholder: "Username", maxlength: "24" }),
      el("input", { name: "minutes", type: "number", min: "1", max: "10080", value: "30" }),
      el("input", { name: "why", placeholder: "Reason", maxlength: "200" }),
      el("button", { class: "btn danger", type: "submit", text: "Mute" }),
    ),
    mutes.map((row) => el("div", { class: "row" },
      el("span", { text: `${row.username} until ${chatStamp(row.until)}. ${row.reason || ""}` }),
      el("button", { class: "btn ghost", type: "button", text: "Unmute", onclick: () => act.chatUnmute(row.username) }),
    )),
  );
}

function seasonFlag(season) {
  if (!season?.number) return "";
  const plain = `Season ${season.number}`;
  const name = season.name || "";
  if (!name || name === plain) return plain;
  return `${plain} · ${name}`;
}

function mast(line, act, season) {
  const flag = seasonFlag(season);
  return el("header", { class: "mast" },
    el("div", { class: "mast-tools" }, musicControl(act)),
    el("p", { class: "eyebrow", text: flag ? `${flag} · Crown & Conquest` : "Crown & Conquest" }),
    el("h1", { text: "Crown & Conquest" }),
    el("p", { text: line }),
  );
}

function warPage(model, act) {
  const state = model.kingdom;
  const targets = model.targets || [];
  const selected = targets.find((row) => row.name === model.drafts.target || String(row.id) === String(model.drafts.target));
  return el(
    "section",
    { class: "war-page" },
    el("div", { class: "page-intro" },
      el("h2", { text: "War Room" }),
      el("p", { text: `Morale ${state.morale ?? 100}. Spies ${state.spies ?? 0}. A shared realm is not a pact: any house can be marched on, except members of your own alliance, yourself, and kingdoms still under a new-crown charter.` }),
    ),
    selected
      ? attackForm(model, act, selected)
      : el("section", { class: "panel orders", id: "attack-form" },
        el("h3", { text: "Orders" }),
        el("p", { class: "muted", text: "Choose a house below. The order sheet stays at the top of the War Room." }),
      ),
    reportsPanel(model, act),
    el("form", {
      class: "panel row",
      onsubmit: (event) => {
        event.preventDefault();
        act.loadTargets(new FormData(event.currentTarget).get("q"));
      },
    },
      el("input", { name: "q", placeholder: "Search kingdoms", value: model.drafts.warSearch || "" }),
      el("button", { class: "btn wood", type: "submit", text: "Search" }),
    ),
    el("div", { class: "target-list" }, targets.map((row) => el(
      "button",
      {
        type: "button",
        class: `panel target${selected && selected.name === row.name ? " selected" : ""}`,
        onclick: () => act.pickTarget(row),
      },
      el("strong", { text: tagged(row.name, row.tag) }),
      el("span", { text: `${row.realm_name || row.realmName || ""} · ${num(row.networth)} networth · ${num(row.land)} acres${row.allied ? " · ally" : ""}${row.protected ? " · protected" : ""}${row.is_npc || row.npc ? " · house" : ""}` }),
    ))),
    el("section", { class: "panel" },
      el("h3", { text: "On the march" }),
      (state.marches || []).length
        ? (state.marches || []).map((march) => marchCard(march, state))
        : el("p", { class: "muted", text: "No hosts are away from the castle." }),
      el("button", { class: "btn ghost", type: "button", text: "Buy a spy · 150 gold", onclick: () => act.buySpy(1) }),
    ),
  );
}

function reportsPanel(model, act) {
  const reports = model.reports || [];
  const open = !!model.reportsOpen;
  const shown = open ? reports : reports.slice(0, 5);
  return el(
    "section",
    { class: "panel reports" },
    el("div", { class: "job-top" },
      el("h3", { text: "Reports" }),
      reports.length > 5
        ? el("button", {
          class: "btn ghost",
          type: "button",
          text: open ? "Show less" : "Show more",
          onclick: () => act.toggleReports(),
        })
        : null,
    ),
    reports.length
      ? shown.map((report) => reportCard(report, act))
      : el("p", { class: "muted", text: "No reports yet." }),
  );
}

function reportCard(report, act) {
  const brief = battleBrief(report);
  if (!brief) {
    const tag = report.you_attacked === false ? report.attacker_tag || report.attackerTag : report.defender_tag || report.defenderTag;
    const name = report.you_attacked === false ? report.attacker : report.defender;
    return el(
      "article",
      { class: "report" },
      el("strong", { text: tagged(name, tag) }),
      el("p", { text: report.text || "" }),
      report.scout ? el("p", { class: "cost", text: `Scout: about ${num(report.scout.land)} acres, ${num(report.scout.gold)} gold, ${num(report.scout.food)} food, defense ${num(report.scout.defense)}.` }) : null,
    );
  }
  return el(
    "article",
    { class: `report ${brief.victory ? "win" : "loss"}` },
    battleBody(report),
    el("button", { class: "btn ghost", type: "button", text: "Open the tally", onclick: () => act.openBattle(report) }),
  );
}

function battleSheet(model, act) {
  return el(
    "div",
    {
      class: "battle-sheet",
      role: "dialog",
      "aria-modal": "true",
      "aria-label": "Battle result",
      onclick: (event) => {
        if (event.target === event.currentTarget) act.closeBattle();
      },
    },
    el(
      "section",
      { class: "panel battle-card" },
      battleBody(model.battleSheet),
      el("button", { class: "btn primary", type: "button", text: "Close", onclick: () => act.closeBattle() }),
    ),
  );
}

function battleBody(report) {
  const brief = battleBrief(report);
  if (!brief) return el("p", { text: report?.text || "" });
  const raid = ATTACK_TYPES[brief.attackType]?.name || "Battle";
  const heading = brief.youAttacked ? `${raid} of ${brief.foe}` : `${raid} by ${brief.foe}`;
  return el(
    "div",
    { class: "tally" },
    el("p", { class: `outcome ${brief.victory ? "win" : "loss"}`, text: brief.victory ? "Victory" : "Defeat" }),
    el("h3", { text: heading }),
    brief.aiNote ? el("p", { class: "eyebrow", text: brief.aiNote }) : null,
    brief.text ? el("p", { text: brief.text }) : null,
    el("div", { class: "casualty" },
      el("strong", { text: brief.youAttacked ? "Gained" : (brief.victory ? "Held" : "Lost") }),
      brief.gained.length
        ? el("ul", {}, brief.gained.map((line) => el("li", { text: line })))
        : el("p", { text: brief.youAttacked ? "Nothing was carried off." : (brief.victory ? "The walls held." : "Nothing was carried off.") }),
      el("p", { text: `Morale ${brief.morale > 0 ? "+" : "−"}${Math.abs(brief.morale)}` }),
    ),
    lossBlock("Enemy dead", brief.enemyLoss),
    lossBlock("Your losses", brief.yourLoss),
    brief.returning ? lossBlock("Returning home", brief.returning) : null,
  );
}

function lossBlock(title, group) {
  if (!group) return null;
  return el(
    "div",
    { class: "casualty" },
    el("strong", { text: `${title} · ${num(group.total)}` }),
    group.rows.length
      ? el("ul", {}, group.rows.map((row) => el("li", { text: `${row.name} ${num(row.count)}` })))
      : el("p", { text: "None." }),
  );
}

function armyFrom(form) {
  const data = new FormData(form);
  const sent = {};
  for (const id of UNIT_ORDER) sent[id] = Math.max(0, Math.floor(Number(data.get(id) || 0)));
  return sent;
}

function marchCard(march, state) {
  const clock = Math.max(Date.now(), state.lastTickAt || 0);
  const left = Math.max(0, march.arrivesAt - clock);
  const label = march.kind === "spy"
    ? `Spy ${march.phase === "back" ? "returning from" : "watching"} ${tagged(march.target, march.targetTag)}`
    : `${march.phase === "back" ? "Returning from" : "Marching on"} ${tagged(march.target, march.targetTag)}`;
  return el("div", { class: "job" },
    el("div", { class: "job-top" }, el("strong", { text: label }), el("span", { text: duration(left / 1000) })),
  );
}

function attackForm(model, act, target) {
  return el(
    "form",
    {
      class: "panel orders",
      id: "attack-form",
      onsubmit: (event) => {
        event.preventDefault();
        const data = new FormData(event.currentTarget);
        const sent = {};
        for (const id of UNIT_ORDER) sent[id] = Math.max(0, Math.floor(Number(data.get(id) || 0)));
        act.attack(target, data.get("raid") || "conquest", sent);
      },
    },
    el("h3", { text: `Orders against ${tagged(target.name, target.tag)}` }),
    target.allied ? el("p", { class: "lock-note", text: "This house shares your pact. The march will be refused." }) : null,
    target.protected ? el("p", { class: "lock-note", text: "This crown is still protected." }) : null,
    el("div", { class: "raid-types" }, Object.values(ATTACK_TYPES).map((type) => el(
      "label",
      { class: "raid" },
      el("input", { type: "radio", name: "raid", value: type.id, checked: (model.drafts.raid || "conquest") === type.id ? true : null }),
      el("span", {}, el("strong", { text: type.name }), el("em", { text: type.blurb })),
    ))),
    el("div", { class: "army-grid" }, UNIT_ORDER.filter((id) => (model.kingdom.units[id] || 0) > 0).map((id) => el(
      "label",
      { class: "unit-field" },
      el("span", { text: `${UNITS[id].name} (${model.kingdom.units[id]} home)` }),
      el("input", { id: `send-${id}`, name: id, type: "number", min: "0", max: String(model.kingdom.units[id]), value: "0" }),
    ))),
    model.odds ? el("p", { class: "cost", id: "odds-line", text: model.odds }) : el("p", { class: "muted", id: "odds-line", text: "Scout, or send and read the estimate." }),
    el("div", { class: "row" },
      el("button", { class: "btn wood", type: "button", text: "Estimate", onclick: (event) => act.estimate(target, armyFrom(event.currentTarget.form)) }),
      el("button", { class: "btn ghost", type: "button", text: "Send a spy", onclick: () => act.spy(target) }),
      el("button", { class: "btn primary", type: "submit", text: "March" }),
    ),
  );
}

function alliancePage(model, act) {
  const view = model.allianceView || { mine: null, members: [], requests: [], browse: [] };
  return el(
    "section",
    {},
    el("div", { class: "page-intro" },
      el("h2", { text: "Alliances" }),
      el("p", { text: "A pact is a choice, not a realm. Members cannot attack one another. Twenty houses is the full table." }),
    ),
    view.mine
      ? el("section", { class: "panel" },
        el("h3", { text: `[${view.mine.tag}] ${view.mine.name}` }),
        el("p", { text: view.mine.description || "No motto yet." }),
        el("p", { class: "cost", text: `You are ${view.mine.role}.` }),
        el("ol", { class: "board" }, view.members.map((row, index) => el(
          "li",
          { class: row.you ? "you" : "" },
          el("span", { class: "rank", text: String(index + 1) }),
          el("span", { class: "who" }, el("strong", { text: tagged(row.name, view.mine.tag) }), el("em", { text: `${row.role} · ${num(row.land)} acres` })),
          el("b", { text: num(row.networth) }),
          view.mine.role === "leader" && !row.you
            ? el("span", { class: "row" },
              el("button", { class: "btn ghost", type: "button", text: row.role === "officer" ? "Demote" : "Officer", onclick: () => act.officer(row.name, row.role !== "officer") }),
              el("button", { class: "btn ghost", type: "button", text: "Kick", onclick: () => act.kick(row.name) }),
              el("button", { class: "btn ghost", type: "button", text: "Crown", onclick: () => act.transfer(row.name) }),
            )
            : null,
        ))),
        (view.requests || []).map((request) => el(
          "div",
          { class: "row" },
          el("span", { text: request.kind === "invite" ? `Invitation from ${request.alliance}` : `${request.name} asks to join` }),
          el("button", { class: "btn primary", type: "button", text: "Accept", onclick: () => act.answer(request, true) }),
          el("button", { class: "btn ghost", type: "button", text: "Decline", onclick: () => act.answer(request, false) }),
        )),
        view.mine.role === "leader"
          ? el("form", {
            class: "row",
            onsubmit: (event) => {
              event.preventDefault();
              act.invite(new FormData(event.currentTarget).get("who"));
            },
          },
            el("input", { name: "who", placeholder: "Invite a kingdom by name" }),
            el("button", { class: "btn wood", type: "submit", text: "Invite" }),
          )
          : null,
        el("div", { class: "row" },
          view.mine.role !== "leader" ? el("button", { class: "btn ghost", type: "button", text: "Leave", onclick: () => act.leavePact() }) : null,
          view.mine.role === "leader" ? el("button", { class: "btn ghost", type: "button", text: "Disband", onclick: () => act.disband() }) : null,
        ),
      )
      : el("form", {
        class: "panel",
        onsubmit: (event) => {
          event.preventDefault();
          const data = new FormData(event.currentTarget);
          act.createPact(data.get("name"), data.get("tag"), data.get("description"));
        },
      },
        el("h3", { text: "Raise a pact" }),
        el("label", { text: "Name" }),
        el("input", { name: "name", maxlength: "32", required: true }),
        el("label", { text: "Tag" }),
        el("input", { name: "tag", maxlength: "5", required: true, placeholder: "IRN" }),
        el("label", { text: "Motto" }),
        el("input", { name: "description", maxlength: "200" }),
        el("button", { class: "btn primary", type: "submit", text: "Found the pact" }),
      ),
    el("section", { class: "panel" },
      el("h3", { text: "Known pacts" }),
      (view.browse || []).map((row) => el(
        "div",
        { class: "job" },
        el("div", { class: "job-top" },
          el("strong", { text: `[${row.tag}] ${row.name}` }),
          el("span", { text: `${row.members} houses · ${num(row.networth)}` }),
        ),
        el("p", { class: "muted", text: row.description || "" }),
        !view.mine && !row.yours ? el("button", { class: "btn wood", type: "button", text: "Request to join", onclick: () => act.joinPact(row) }) : null,
      )),
    ),
  );
}

function sidebar(model, act) {
  const items = navItems(model);
  return el(
    "aside",
    { class: "sidebar" },
    el("div", { class: "brand" }, ico("crown"), el("span", { text: "Crown & Conquest" })),
    el("nav", {}, items.map(([id, label, iconName]) => navButton(id, label, iconName, model, act))),
    el("p", { class: "side-foot", text: model.mode === "demo" ? "Saved on this device" : (model.player?.username || "") }),
  );
}

function bottomNav(model, act) {
  const items = [
    ["throne", "Throne", "throne"],
    ["build", "Build", "build"],
    ["war", "War", "war"],
    ["realm", "Realm", "realm"],
    ["more", "More", "more"],
  ];
  return el("nav", { class: "bottom-nav" }, items.map(([id, label, iconName]) => {
    const moreOn = id === "more" && ["explore", "scholars", "steward", "account", "host", "alliances", "more"].includes(model.tab);
    const on = model.tab === id || moreOn;
    return el(
      "button",
      { type: "button", class: on ? "on" : "", onclick: () => act.tab(id) },
      ico(iconName),
      el("span", { text: label }),
    );
  }));
}

function navItems(model) {
  const items = [
    ["throne", "Throne room", "throne"],
    ["build", "Build", "build"],
    ["explore", "Explore", "explore"],
    ["host", "Host", "army"],
    ["war", "War Room", "war"],
    ["alliances", "Alliances", "pact"],
    ["scholars", "Scholars", "book"],
    ["realm", "Realm", "realm"],
  ];
  if (model.mode === "demo" || model.player?.admin) items.push(["steward", "Steward", "shield"]);
  items.push(["account", "Account", "crown"]);
  return items;
}

function navButton(id, label, iconName, model, act) {
  return el(
    "button",
    { type: "button", class: model.tab === id ? "on" : "", onclick: () => act.tab(id) },
    ico(iconName),
    el("span", { text: label }),
  );
}

export function tickLabel(kingdom) {
  if (!kingdom) return "–";
  const remain = kingdom.lastTickAt + TICK_SECONDS * 1000 - Date.now();
  if (remain <= 0) return "now";
  const s = Math.ceil(remain / 1000);
  const m = Math.floor(s / 60);
  const r = s % 60;
  return `${m}:${String(r).padStart(2, "0")}`;
}

export function realmRowsFrom(kingdom, npcs) {
  return roster(kingdom, npcs).map((row) => ({
    ...row,
    is_you: row.you,
    is_npc: row.npc,
    land_type: row.landType,
  }));
}
