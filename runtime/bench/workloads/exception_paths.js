// Caminho de exceção quente: try/catch/finally com lançamento real numa fração das iterações.
//
// O caminho de exceção do baseline tem geometria própria — handlers re-derivados na instalação a partir
// do mapa de código, cada um por índice de bytecode. Um corpus sem lançamento exercita o try e nunca o
// catch, e o handler fica sem prova.

const __KEYS = ["ok", "ok", "bad", "ok", "missing", "ok", "bad", "ok"];

function parseOne(key, n) {
    if (key === "bad")
        throw new RangeError("bad at " + n);
    if (key === "missing")
        throw { code: 404, at: n };
    return (key.length * 13 + n) | 0;
}

function workloadKernel(iterations) {
    let total = 0;
    let caught = 0;
    for (let n = 0; n < iterations; n++) {
        for (let i = 0; i < __KEYS.length; i++) {
            try {
                total = (total + parseOne(__KEYS[i], n)) | 0;
            } catch (e) {
                caught++;
                total = (total ^ (typeof e === "object" && e !== null && "code" in e ? e.code : 7)) | 0;
            } finally {
                total = (total + 1) | 0;
            }
        }
    }
    return (total ^ caught) >>> 0;
}
