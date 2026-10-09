// Cadeia de protótipo lida em execução: getPrototypeOf, instanceof e despacho por herança.
//
// Cobre a espécie de sítio que materializa a base do heap de formas como imediato — nove sítios do
// baseline exigem comparação com null/undefined, typeof, for-in com escrita, getPrototypeOf ou Proxy,
// e um corpus que não alcança nenhum deles dá verde sobre a espécie inteira para sempre.

function Node(id) {
    this.id = id | 0;
    this.weight = (id * 7) | 0;
}
Node.prototype.value = function() { return this.weight; };

function Leaf(id, tag) {
    Node.call(this, id);
    this.tag = tag;
}
Leaf.prototype = Object.create(Node.prototype);
Leaf.prototype.constructor = Leaf;
Leaf.prototype.value = function() { return (this.weight ^ this.tag.length) | 0; };

const __NODES = (function() {
    const out = [];
    const tags = ["a", "bb", "ccc", "dddd"];
    for (let i = 0; i < 48; i++)
        out.push((i & 1) === 0 ? new Node(i) : new Leaf(i, tags[i & 3]));
    return out;
})();

function depth(o) {
    let d = 0;
    let p = Object.getPrototypeOf(o);
    while (p !== null && d < 8) {
        d++;
        p = Object.getPrototypeOf(p);
    }
    return d;
}

function workloadKernel(iterations) {
    let total = 0;
    for (let n = 0; n < iterations; n++) {
        for (let i = 0; i < __NODES.length; i++) {
            const o = __NODES[i];
            let v = o.value();
            if (o instanceof Leaf)
                v = (v * 3) | 0;
            total = (total + v + depth(o)) | 0;
        }
    }
    return total >>> 0;
}
