const svg = (body) => `<svg viewBox="0 0 32 32" aria-hidden="true">${body}</svg>`;

const ICONS = {
  gold: svg(`<circle cx="16" cy="16" r="11" fill="currentColor"/><circle cx="16" cy="16" r="7.5" fill="none" stroke="#fff6df" stroke-width="1.4"/><path d="M16 10.5v11M13 13.5h5.2a2.2 2.2 0 0 1 0 4.4H13.6" fill="none" stroke="#fff6df" stroke-width="1.5" stroke-linecap="round"/>`),
  food: svg(`<path fill="currentColor" d="M8 27c6-1 8-8 7.2-14 .8 6 3.4 12 7.8 14-2 1.2-6 1.6-7.5.2C14 28.6 10 28.2 8 27z"/><path fill="currentColor" d="M16 24V6m0 4c2.4-1 4.5-.4 6 1.2M16 12c-2.2-1.2-4.4-.6-6 1"/><path d="M7 27h18" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>`),
  peasants: svg(`<circle cx="12" cy="11" r="3.2" fill="currentColor"/><circle cx="21" cy="12" r="2.6" fill="currentColor"/><path fill="currentColor" d="M6.5 24c.6-4 3-6.2 5.6-6.2s5 2.2 5.6 6.2H6.5zm8.2.2c.4-3.2 2.2-5 4.4-5 2.3 0 4.1 1.8 4.6 5h-9z"/>`),
  land: svg(`<path fill="currentColor" d="M4 22 16 6l12 16H4z"/><path fill="#fff6df" d="M16 12.5 22 20h-12l6-7.5z"/><path d="M6 26h20" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>`),
  mana: svg(`<path fill="currentColor" d="M16 3 20 12l9 1.4-6.8 5.6 2.2 8.6L16 23.2 7.6 27.6 9.8 19 3 13.4 12 12z"/>`),
  crown: svg(`<path fill="currentColor" d="M5 23 7.2 11l5.2 6L16 7l3.6 10 5.2-6L27 23H5z"/><path fill="#fff6df" d="M8 23h16v2.4H8z"/>`),
  throne: svg(`<path fill="currentColor" d="M9 28V14h14v14H9z"/><path fill="currentColor" d="M7 12h18v3H7zM11 8h3v4h-3zM18 8h3v4h-3z"/><path d="M12 20h8" stroke="#fff6df" stroke-width="1.4" stroke-linecap="round"/>`),
  build: svg(`<path fill="currentColor" d="M6 26h12v-8H6v8zm2-6h8v4H8v-4zM18 14l8-8 3 3-8 8-3-3z"/><path d="M22 8l3 3" stroke="#fff6df" stroke-width="1.2"/>`),
  army: svg(`<path fill="currentColor" d="M6 26 16 6l10 20H6z"/><path fill="#fff6df" d="M16 12l5 10H11l5-10z"/>`),
  realm: svg(`<circle cx="16" cy="16" r="10" fill="none" stroke="currentColor" stroke-width="2"/><path d="M6 16h20M16 6c3 3 3 17 0 20M16 6c-3 3-3 17 0 20" fill="none" stroke="currentColor" stroke-width="1.6"/>`),
  more: svg(`<circle cx="8" cy="16" r="2.2" fill="currentColor"/><circle cx="16" cy="16" r="2.2" fill="currentColor"/><circle cx="24" cy="16" r="2.2" fill="currentColor"/>`),
  explore: svg(`<circle cx="14" cy="14" r="7" fill="none" stroke="currentColor" stroke-width="2"/><path d="M19 19l7 7" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"/>`),
  book: svg(`<path fill="currentColor" d="M6 7h9c2 0 3 1.2 3 2.4V26c-1.2-.8-2.4-1-4-1H6V7zm11 2.4C17 8.2 18 7 20 7h6v18h-8c-1.6 0-2.8.2-4 1V9.4z"/>`),
  shield: svg(`<path fill="currentColor" d="M16 3 27 7v9c0 7-4.6 11-11 13C9.6 27 5 23 5 16V7l11-4z"/>`),
  war: svg(`<path fill="currentColor" d="M7 5h4l2 8h6l2-8h4l-6 22h-6L7 5z"/><path fill="#fff6df" d="M14 15h4v8h-4z"/>`),
  pact: svg(`<path fill="currentColor" d="M8 6h10l6 6v14H8z"/><path fill="#fff6df" d="M16 8v6h6"/>`),
  speaker: svg(`<path fill="currentColor" d="M5 12h5l6-5v18l-6-5H5z"/><path d="M20 11.5a5 5 0 0 1 0 9" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M23 8.5a9 9 0 0 1 0 15" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>`),
  speakerOff: svg(`<path fill="currentColor" d="M5 12h5l6-5v18l-6-5H5z"/><path d="M20 12l8 8M28 12l-8 8" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>`),
};

const CHARGES = {
  highlands: `<path fill="#f4ead6" d="M16 8 24 22H8z"/><path d="M11 22h10" stroke="#2f3b4a" stroke-width="1.2"/>`,
  forest: `<path fill="#e7f2dc" d="M16 7 22 16h-3l3 6H10l3-6h-3z"/>`,
  desert: `<circle cx="16" cy="15" r="5" fill="#fff6df"/><path d="M8 23h16" stroke="#8a5a22" stroke-width="1.4" stroke-linecap="round"/>`,
  volcanic: `<path fill="#f3d2c4" d="M10 22 16 10l6 12z"/><path fill="#8d3b32" d="M14 14h4l-1 4h-2z"/>`,
  coastal: `<path fill="none" stroke="#f4fbff" stroke-width="1.6" stroke-linecap="round" d="M9 14c2 2 4 2 6 0s4-2 6 0M9 19c2 2 4 2 6 0s4-2 6 0"/>`,
  arcane: `<path fill="#f6f0ff" d="M16 8l1.6 4.6H22l-3.6 2.8 1.4 4.6L16 17.6 12.2 20l1.4-4.6L10 12.6h4.4z"/>`,
};

const SHIELD_COLORS = {
  highlands: ["#5d6e80", "#2f3b4a"],
  forest: ["#2f6a45", "#1e4630"],
  desert: ["#c4923e", "#8a5a22"],
  volcanic: ["#8d3b32", "#4a2420"],
  coastal: ["#2c6484", "#1d4258"],
  arcane: ["#6d5b8e", "#3c3158"],
};

export function icon(name) {
  return ICONS[name] || "";
}

export function shield(landId) {
  const colors = SHIELD_COLORS[landId] || SHIELD_COLORS.highlands;
  const charge = CHARGES[landId] || "";
  return `<svg viewBox="0 0 32 32" aria-hidden="true"><path fill="${colors[0]}" d="M16 2 28 7v9.2C28 24 22.4 28.6 16 30 9.6 28.6 4 24 4 16.2V7z"/><path fill="${colors[1]}" d="M16 5.2 24.5 8.6v6.8c0 5.2-3.4 8.6-8.5 9.8-5.1-1.2-8.5-4.6-8.5-9.8V8.6z"/>${charge}</svg>`;
}

export function castleArt() {
  return `<svg viewBox="0 0 280 160" aria-hidden="true">
    <path fill="#e7d3aa" d="M0 150h280v10H0z"/>
    <path fill="#c4a574" d="M20 150c20-28 40-28 60 0 18-36 48-52 78-40 20 8 34 8 52-6 16 10 30 14 50 6v40H20z"/>
    <path fill="#8d3140" d="M118 28h44l8 18H110z"/>
    <path fill="#f2d48a" d="M132 34h16l4 8h-24z"/>
    <path fill="#6b3f26" d="M78 78h124v72H78z"/>
    <path fill="#8a5736" d="M70 70h140v12H70z"/>
    <path fill="#5a4636" d="M92 58h20v20H92zM168 58h20v20h-20z"/>
    <path fill="#3e2618" d="M88 50h28v8H88zM164 50h28v8h-28z"/>
    <path fill="#f4e2c4" d="M96 54h6v6h-6zM172 54h6v6h-6z"/>
    <path fill="#3e2618" d="M124 104h32v46h-32z"/>
    <path fill="#e6c56a" d="M136 118h8v8h-8z"/>
    <path fill="#2c6484" d="M104 88h16v14h-16zM160 88h16v14h-16z"/>
    <path fill="#d7ecf5" d="M107 91h10v8h-10zM163 91h10v8h-10z"/>
    <path fill="#8d3140" d="M126 46h28v8h-28z"/>
  </svg>`;
}
