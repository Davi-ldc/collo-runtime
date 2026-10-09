// Mesmo texto de função exercido nos dois modos de invocação, call e construct.
//
// Cobre as duas formas de o motor multiplicar estruturas a partir de um único texto de fonte, e um
// corpus que só chama funções não alcança nenhuma. Call e construct de um mesmo texto têm unlinkeds
// separados, `m_unlinkedCodeBlockForCall` e `m_unlinkedCodeBlockForConstruct`, logo duas linhagens
// de perfil independentes sobre o mesmo código. E um escopo declarante instanciado nos dois modos
// constrói suas funções internas duas vezes, o que dá dois `CodeBlock`s vivos apontando para o
// MESMO unlinked — o único arranjo em que a agregação de perfil no unlinked une instâncias em vez
// de apenas salvar e restaurar uma. O prólogo baseline também diverge por modo: construtor pula o
// argumento 0 e não perfila argumento nenhum quando tem um parâmetro ou menos.

function Accum(seed, step) {
    this.state = seed | 0;
    this.step = step | 0;
    // Declarada dentro do escopo: ganha um FunctionExecutable por CodeBlock de Accum, e Accum
    // tem um CodeBlock para call e outro para construct.
    this.mix = function(x) {
        return ((x * 0x9e3779b9) ^ (x >>> 13)) | 0;
    };
}

Accum.prototype.advance = function(x) {
    this.state = (this.state + this.mix(x) + this.step) | 0;
    return this.state;
};

function scale(x, k) {
    if (new.target === undefined)
        return ((x | 0) * (k | 0)) | 0;
    this.value = ((x | 0) * (k | 0)) | 0;
}

const __SEEDS = [3, 17, 61, 251, 1021, 4093];

function workloadKernel(iterations) {
    let digest = 0;
    for (let n = 0; n < iterations; n++) {
        for (let i = 0; i < __SEEDS.length; i++) {
            const seed = __SEEDS[i];

            // construct: m_unlinkedCodeBlockForConstruct dos dois textos.
            const a = new Accum(seed, n | 0);
            digest = (digest + a.advance(seed ^ n)) | 0;
            digest = (digest + (new scale(seed, 3)).value) | 0;

            // call: m_unlinkedCodeBlockForCall dos mesmos dois textos.
            const holder = { state: 0, step: 1 };
            Accum.call(holder, seed, n | 0);
            digest = (digest + holder.state + holder.mix(seed)) | 0;
            digest = (digest + scale(seed, 3)) | 0;
        }
    }
    return digest >>> 0;
}
