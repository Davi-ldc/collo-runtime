// Acesso através de Proxy: get, set e has passando por armadilha em vez de por forma.
//
// É a única das cinco espécies de âncora de forma que nenhum corpus alcançava. O acesso via Proxy não
// resolve por StructureID, então o cache inline nunca especializa e o sítio fica permanentemente no
// caminho lento — o que é justamente o que precisa ser exercitado, e não o que o resto do corpus faz.
//
// Ressalva: um workload assim sobe a escada de tier mais devagar que os outros, porque o perfil não
// enche do mesmo jeito. Se ele não alcançar baseline no orçamento de chamadas, o número é dele e não do
// instrumento.

const __ALVO = { a: 1, b: 2, c: 3, d: 4 };

const __PROXY = new Proxy(__ALVO, {
    get(alvo, chave) {
        if (chave === "soma")
            return (alvo.a + alvo.b + alvo.c + alvo.d) | 0;
        return alvo[chave];
    },
    set(alvo, chave, valor) {
        alvo[chave] = valor | 0;
        return true;
    },
    has(alvo, chave) {
        return chave === "oculto" ? false : chave in alvo;
    },
});

function workloadKernel(iterations) {
    let total = 0;
    for (let n = 0; n < iterations; n++) {
        __PROXY.a = (n & 15) | 0;
        __PROXY.b = (n >>> 2) & 7;
        total = (total + __PROXY.soma) | 0;
        if ("c" in __PROXY)
            total = (total + __PROXY.c) | 0;
        if ("oculto" in __PROXY)
            total = (total - 1) | 0;
    }
    return total >>> 0;
}
