const __SSR_ROWS = (function() {
    const rows = [];
    const p = ["asji", "siouo", "sioauoa", "isoiaj"];
    const n = ["asakp", "cknsksnp", "siodsamçeauoa", "isoiaj", "aaaook"];
    for (let i = 0; i < 16; i++) {
        rows.push({
            id: 10000 + i,
            name: n[i & 7],
            plan: p[i & 3],
            score: ((i * 31) ^ 0x5a5a) | 0,
            active: (i & 1) === 0,
        });
    }
    return rows;
})();

function h(tag, attrs, ...children) {
    return { tag: tag, attrs: attrs, children: children };
}

const __SSR_ESCAPE_RE = /[&<>"]/g;
const __SSR_ESCAPE_MAP = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" };
function __escapeSSR(value) {
    return value.replace(__SSR_ESCAPE_RE, (c) => __SSR_ESCAPE_MAP[c]);
}

function renderToString(node) {
    if (node === null || node === undefined) return "";
    if (typeof node === "string") return __escapeSSR(node);
    if (typeof node === "number") return "" + node;

    let html = "<" + node.tag;
    const attrs = node.attrs;
    if (attrs !== null) {
        for (const key in attrs) {
            html += " " + key + "=\"" + __escapeSSR("" + attrs[key]) + "\"";
        }
    }
    html += ">";

    const children = node.children;
    for (let i = 0; i < children.length; i++) {
        html += renderToString(children[i]);
    }
    html += "</" + node.tag + ">";
    return html;
}

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const row = __SSR_ROWS[(i + __totalCalls) & 15];
        const aria = row.active ? "true" : "false";
        const tree = h("li", { class: row.plan, "data-id": row.id },
            h("b", null, row.name),
            " ",
            h("i", null, row.score),
            " ",
            h("span", { "aria-pressed": aria }),
        );
        const html = renderToString(tree);
        digest = (Math.imul(digest ^ row.id, 16777619) ^ html.length) | 0;
    }

    return digest >>> 0;
}

