// Despacho por switch, denso e por string, que são tabelas de salto diferentes.
//
// O switch denso materializa o endereço do buffer da tabela como imediato e faz farJump por ele; o de
// string não embute endereço nenhum — passa o índice da tabela para uma operação e salta no ponteiro
// devolvido, com as chaves vivendo no bloco não-linkado do consumidor. São dois mecanismos, e um corpus
// com só um deixa o outro sem prova.

const __OPS = ["get", "put", "del", "has", "scan", "count", "flush", "noop"];

function denso(code, acc) {
    switch (code & 7) {
    case 0: return (acc + 3) | 0;
    case 1: return (acc ^ 0x11) | 0;
    case 2: return (acc * 5) | 0;
    case 3: return (acc - 7) | 0;
    case 4: return (acc + 31) | 0;
    case 5: return (acc ^ 0x2222) | 0;
    case 6: return (acc >>> 1) | 0;
    default: return (acc + 1) | 0;
    }
}

function porNome(op, acc) {
    switch (op) {
    case "get":   return (acc + 2) | 0;
    case "put":   return (acc ^ 0x33) | 0;
    case "del":   return (acc * 3) | 0;
    case "has":   return (acc - 5) | 0;
    case "scan":  return (acc + 17) | 0;
    case "count": return (acc ^ 0x4444) | 0;
    case "flush": return (acc >>> 2) | 0;
    default:      return (acc + 1) | 0;
    }
}

function workloadKernel(iterations) {
    let acc = 0;
    for (let n = 0; n < iterations; n++) {
        for (let i = 0; i < __OPS.length; i++) {
            acc = denso(i + n, acc);
            acc = porNome(__OPS[i], acc);
        }
    }
    return acc >>> 0;
}
