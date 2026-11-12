const URL = "https://orbzytpukjywqkbkbtcs.supabase.co";
const PUBLISHABLE_KEY = "sb_publishable_g6lbXdi9r10i5d6TvHquaw_drhIG58X";

const page = document.body.dataset.page || "home";
let client = null;
let me = { signed_in: false, username: "", admin: false };

function el(tag, props, ...kids) {
  const node = document.createElement(tag);
  if (props) {
    for (const [key, value] of Object.entries(props)) {
      if (value == null || value === false) continue;
      if (key === "class") node.className = value;
      else if (key === "text") node.textContent = value;
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

function when(at) {
  const t = Date.parse(at);
  if (!Number.isFinite(t)) return "";
  return new Date(t).toLocaleString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

function missingLedger(error) {
  const text = `${error?.code || ""} ${error?.message || error || ""}`;
  return /PGRST202|PGRST205|42883|42P01|does not exist|schema cache|Could not find/i.test(text);
}

function playerEmail(username) {
  return String(username || "").trim().toLowerCase() + "@players.toonorbit.app";
}

function publicName(name) {
  const text = String(name || "").trim();
  if (!text || text.includes("@")) return "";
  return text;
}

function db() {
  if (client) return client;
  const lib = globalThis.supabase;
  if (!lib?.createClient) return null;
  client = lib.createClient(URL, PUBLISHABLE_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false },
  });
  return client;
}

async function rpc(name, args) {
  const api = db();
  if (!api) return { ok: false, error: "The account library did not load." };
  const { data, error } = await api.rpc(name, args || {});
  if (error) return { ok: false, error: error.message || "The server did not answer.", missing: missingLedger(error) };
  return { ok: true, data };
}

async function refreshWho() {
  const api = db();
  me = { signed_in: false, username: "", admin: false };
  if (!api) return me;
  const { data } = await api.auth.getSession();
  if (!data?.session) return me;
  const who = await rpc("ccs_whoami");
  if (who.ok && who.data?.signed_in) {
    me = {
      signed_in: true,
      username: publicName(who.data.username),
      admin: Boolean(who.data.admin),
    };
  } else if (data.session) {
    me = { signed_in: true, username: "", admin: false };
  }
  return me;
}

function paintAccountButton() {
  const button = document.getElementById("account-open");
  if (!button) return;
  button.textContent = me.signed_in ? me.username || "Account" : "Sign in";
}

function bindAccount() {
  const dialog = document.getElementById("account-dialog");
  const open = document.getElementById("account-open");
  const form = document.getElementById("sign-in");
  const status = document.getElementById("account-status");
  const out = document.getElementById("sign-out");
  if (!dialog || !open) return;
  open.addEventListener("click", () => {
    paintAccountStatus();
    dialog.showModal();
  });
  dialog.querySelectorAll("[data-close]").forEach((node) => {
    node.addEventListener("click", () => dialog.close());
  });
  form?.addEventListener("submit", async (event) => {
    event.preventDefault();
    const api = db();
    if (!api) {
      status.textContent = "The account library did not load.";
      return;
    }
    const data = new FormData(form);
    const username = String(data.get("username") || "").trim();
    const password = String(data.get("password") || "");
    if (!/^[A-Za-z0-9_]{3,16}$/.test(username)) {
      status.textContent = "Use 3-16 letters, numbers, or underscores.";
      return;
    }
    if (!password) {
      status.textContent = "Enter a password.";
      return;
    }
    status.textContent = "Signing in…";
    const { error } = await api.auth.signInWithPassword({ email: playerEmail(username), password });
    if (error) {
      status.textContent = /invalid login|invalid credentials/i.test(error.message || "")
        ? "Wrong username or password."
        : (error.message || "Could not sign in.");
      return;
    }
    await refreshWho();
    paintAccountButton();
    paintAccountStatus();
    dialog.close();
    await rerender();
  });
  out?.addEventListener("click", async () => {
    await db()?.auth.signOut();
    me = { signed_in: false, username: "", admin: false };
    paintAccountButton();
    paintAccountStatus();
    dialog.close();
    await rerender();
  });
}

function paintAccountStatus() {
  const status = document.getElementById("account-status");
  const form = document.getElementById("sign-in");
  const out = document.getElementById("sign-out");
  if (!status) return;
  if (me.signed_in) {
    const name = publicName(me.username);
    status.textContent = name
      ? (me.admin ? `Signed in as ${name}, steward.` : `Signed in as ${name}.`)
      : "Signed in.";
    if (form) form.hidden = true;
    if (out) out.hidden = false;
  } else {
    status.textContent = "The same username and password as Toon Orbit Battle.";
    if (form) form.hidden = false;
    if (out) out.hidden = true;
  }
}

async function rerender() {
  if (page === "news") await renderNews();
  if (page === "forums") await renderForums();
}

function notice(text, bad) {
  return el("p", { class: bad ? "notice bad" : "notice", text });
}

async function renderNews() {
  const root = document.getElementById("news-root");
  const fallback = document.getElementById("news-fallback");
  if (!root) return;
  root.replaceChildren(el("p", { class: "muted", text: "Unrolling the notices…" }));
  const res = await rpc("ccs_news_list");
  if (!res.ok) {
    root.replaceChildren(notice(res.missing
      ? "The news ledger is not on the server yet. The note below ships with the page."
      : res.error, !res.missing));
    if (fallback) fallback.hidden = false;
    return;
  }
  if (fallback) fallback.hidden = true;
  const posts = res.data?.posts || [];
  const blocks = [];
  if (me.admin) blocks.push(newsComposer());
  if (!posts.length) blocks.push(el("p", { class: "muted", text: "No notices yet." }));
  for (const post of posts) blocks.push(newsCard(post));
  root.replaceChildren(...blocks);
}

function newsCard(post) {
  return el("article", { class: "post" },
    el("header", {},
      el("h2", { text: post.title || "Notice" }),
      el("p", { class: "who", text: `${publicName(post.author_name) || "Crown & Conquest"} · ${when(post.created_at)}` }),
    ),
    el("p", { class: "body", text: post.body || "" }),
    me.admin
      ? el("div", { class: "row" },
        el("button", { class: "btn small ghost", type: "button", text: "Remove", onclick: () => removeNews(post.id) }))
      : null,
  );
}

function newsComposer() {
  return el("form", { class: "composer", onsubmit: publishNews },
    el("h2", { text: "Post a notice" }),
    el("label", { text: "Title" }),
    el("input", { name: "title", maxlength: "120", required: true }),
    el("label", { text: "Body" }),
    el("textarea", { name: "body", maxlength: "8000", required: true }),
    el("div", { class: "row" }, el("button", { class: "btn primary", type: "submit", text: "Publish" })),
    el("p", { class: "muted", id: "news-form-status" }),
  );
}

async function publishNews(event) {
  event.preventDefault();
  const form = event.currentTarget;
  const status = form.querySelector("#news-form-status");
  const data = new FormData(form);
  status.textContent = "Publishing…";
  const res = await rpc("ccs_news_publish", {
    p_title: String(data.get("title") || ""),
    p_body: String(data.get("body") || ""),
  });
  if (!res.ok) {
    status.textContent = res.error;
    return;
  }
  form.reset();
  await renderNews();
}

async function removeNews(id) {
  if (!window.confirm("Remove this notice?")) return;
  const res = await rpc("ccs_news_remove", { p_id: id });
  if (!res.ok) window.alert(res.error);
  await renderNews();
}

async function renderForums() {
  const root = document.getElementById("forum-root");
  if (!root) return;
  const params = new URLSearchParams(location.search);
  const thread = params.get("t");
  const category = params.get("c");
  if (thread) {
    root.replaceChildren(el("p", { class: "muted", text: "Opening the hall…" }));
    await renderThread(root, thread);
    return;
  }
  if (category) {
    root.replaceChildren(el("p", { class: "muted", text: "Opening the hall…" }));
    await renderCategory(root, category);
    return;
  }
  const res = await rpc("ccs_forum_board");
  if (!res.ok) {
    root.querySelector(".notice")?.remove();
    const note = notice(res.missing
      ? "The forum ledger is not on the server yet. These are the halls that open once sql/0009_site_news_forums.sql is applied."
      : res.error, !res.missing);
    if (res.missing) root.prepend(note);
    else root.replaceChildren(note);
    return;
  }
  await renderBoard(root, res.data?.categories || []);
}

async function renderBoard(root, categories) {
  root.replaceChildren(
    el("div", { class: "halls" }, categories.map((cat) => el("a", {
      class: "card",
      href: `/forums/?c=${encodeURIComponent(cat.slug)}`,
    },
      el("h3", { text: cat.name }),
      el("p", { text: cat.blurb || "" }),
      el("p", { class: "who", text: `${cat.threads || 0} threads` }),
    ))),
  );
}

async function renderCategory(root, slug) {
  const res = await rpc("ccs_forum_threads", { p_slug: slug });
  if (!res.ok) {
    root.replaceChildren(notice(res.error, true), el("p", {}, el("a", { href: "/forums/", text: "All halls" })));
    return;
  }
  const category = res.data?.category || { name: slug, slug };
  const threads = res.data?.threads || [];
  const stewardOnly = category.slug === "announcements" && !me.admin;
  root.replaceChildren(
    el("p", {}, el("a", { href: "/forums/", text: "All halls" })),
    el("h2", { text: category.name || "Hall" }),
    category.blurb ? el("p", { class: "lede", text: category.blurb }) : null,
    me.signed_in && !stewardOnly ? threadComposer(category.slug) : null,
    me.signed_in && stewardOnly ? el("p", { class: "muted", text: "Only a steward posts in Announcements." }) : null,
    !me.signed_in ? el("p", { class: "muted", text: "Sign in to start a thread." }) : null,
    threads.length
      ? el("div", { class: "stack" }, threads.map((thread) => el("article", { class: "thread" },
        el("header", {},
          thread.pinned ? el("span", { class: "chip", text: "Pinned" }) : null,
          thread.locked ? el("span", { class: "chip", text: "Locked" }) : null,
        ),
        el("h3", {}, el("a", { class: "thread-link", href: `/forums/?t=${thread.id}`, text: thread.title })),
        el("p", { class: "who", text: `${publicName(thread.author_name) || "player"} · ${when(thread.created_at)} · ${thread.replies || 0} replies` }),
      )))
      : el("p", { class: "muted", text: "No threads in this hall yet." }),
  );
}

function threadComposer(slug) {
  return el("form", { class: "composer", onsubmit: (event) => createThread(event, slug) },
    el("h3", { text: "New thread" }),
    el("label", { text: "Title" }),
    el("input", { name: "title", maxlength: "80", required: true }),
    el("label", { text: "Post" }),
    el("textarea", { name: "body", maxlength: "4000", required: true }),
    el("div", { class: "row" }, el("button", { class: "btn primary", type: "submit", text: "Post thread" })),
    el("p", { class: "muted", id: "thread-form-status" }),
  );
}

async function createThread(event, slug) {
  event.preventDefault();
  const form = event.currentTarget;
  const status = form.querySelector("#thread-form-status");
  const data = new FormData(form);
  status.textContent = "Posting…";
  const res = await rpc("ccs_forum_new_thread", {
    p_slug: slug,
    p_title: String(data.get("title") || ""),
    p_body: String(data.get("body") || ""),
  });
  if (!res.ok) {
    status.textContent = res.error;
    return;
  }
  if (res.data?.id) location.href = `/forums/?t=${res.data.id}`;
  else await renderForums();
}

async function renderThread(root, id) {
  const res = await rpc("ccs_forum_thread", { p_id: Number(id) });
  if (!res.ok) {
    root.replaceChildren(notice(res.error, true), el("p", {}, el("a", { href: "/forums/", text: "All halls" })));
    return;
  }
  const thread = res.data?.thread;
  const replies = res.data?.replies || [];
  if (!thread) {
    root.replaceChildren(notice("That thread is gone.", true));
    return;
  }
  root.replaceChildren(
    el("p", {}, el("a", { href: `/forums/?c=${encodeURIComponent(thread.category_slug || "")}`, text: thread.category_name || "Hall" })),
    el("article", { class: "post" },
      el("header", {},
        el("div", { class: "chips" },
          thread.pinned ? el("span", { class: "chip", text: "Pinned" }) : null,
          thread.locked ? el("span", { class: "chip", text: "Locked" }) : null,
        ),
        el("h2", { text: thread.title }),
        el("p", { class: "who", text: `${publicName(thread.author_name) || "player"} · ${when(thread.created_at)}` }),
      ),
      el("p", { class: "body", text: thread.body || "" }),
      me.admin ? el("div", { class: "row" },
        el("button", { class: "btn small", type: "button", text: thread.pinned ? "Unpin" : "Pin", onclick: () => moderate("ccs_forum_pin", { p_thread: thread.id, p_pinned: !thread.pinned }) }),
        el("button", { class: "btn small", type: "button", text: thread.locked ? "Unlock" : "Lock", onclick: () => moderate("ccs_forum_lock", { p_thread: thread.id, p_locked: !thread.locked }) }),
        el("button", { class: "btn small ghost", type: "button", text: "Delete thread", onclick: () => deleteThread(thread) }),
      ) : null,
    ),
    replies.length
      ? el("div", { class: "stack" }, replies.map((reply) => el("article", { class: "thread" },
        el("p", { class: "who", text: `${publicName(reply.author_name) || "player"} · ${when(reply.created_at)}` }),
        el("p", { class: "body", text: reply.body || "" }),
        me.admin ? el("div", { class: "row" },
          el("button", { class: "btn small ghost", type: "button", text: "Delete reply", onclick: () => deleteReply(reply.id) })) : null,
      )))
      : el("p", { class: "muted", text: "No replies yet." }),
    replyBox(thread),
  );
}

function replyBox(thread) {
  if (!me.signed_in) return el("p", { class: "muted", text: "Sign in to reply." });
  if (thread.locked && !me.admin) return el("p", { class: "muted", text: "This thread is locked." });
  return el("form", { class: "composer", onsubmit: (event) => sendReply(event, thread.id) },
    el("h3", { text: "Reply" }),
    el("label", { text: "Post" }),
    el("textarea", { name: "body", maxlength: "4000", required: true }),
    el("div", { class: "row" }, el("button", { class: "btn primary", type: "submit", text: "Reply" })),
    el("p", { class: "muted", id: "reply-status" }),
  );
}

async function sendReply(event, threadId) {
  event.preventDefault();
  const form = event.currentTarget;
  const status = form.querySelector("#reply-status");
  status.textContent = "Posting…";
  const res = await rpc("ccs_forum_reply", {
    p_thread: threadId,
    p_body: String(new FormData(form).get("body") || ""),
  });
  if (!res.ok) {
    status.textContent = res.error;
    return;
  }
  await renderForums();
}

async function moderate(name, args) {
  const res = await rpc(name, args);
  if (!res.ok) window.alert(res.error);
  await renderForums();
}

async function deleteThread(thread) {
  if (!window.confirm("Delete this thread?")) return;
  const res = await rpc("ccs_forum_delete_thread", { p_thread: thread.id });
  if (!res.ok) {
    window.alert(res.error);
    return;
  }
  location.href = `/forums/?c=${encodeURIComponent(thread.category_slug || "")}`;
}

async function deleteReply(id) {
  if (!window.confirm("Delete this reply?")) return;
  const res = await rpc("ccs_forum_delete_reply", { p_reply: id });
  if (!res.ok) window.alert(res.error);
  await renderForums();
}

document.querySelectorAll(".top nav a").forEach((link) => {
  if (link.dataset.nav === page) link.setAttribute("aria-current", "page");
});

bindAccount();
refreshWho().then(() => {
  paintAccountButton();
  paintAccountStatus();
  return rerender();
});
