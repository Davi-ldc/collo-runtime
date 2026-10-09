const __ROUTE_PATHS = [
    "/api/users/102/orders/7",
    "/api/projects/22/deploy",
    "/api/assets/app.9d31.js",
    "/healthz",
    "/api/users/77/orders/19",
    "/api/projects/9/deploy",
];
const __ROUTE_USER = /^\/api\/users\/(\d+)\/orders\/(\d+)$/;
const __ROUTE_DEPLOY = /^\/api\/projects\/(\d+)\/deploy$/;
const __ROUTE_ASSET = /^\/api\/assets\/([a-z0-9.]+)$/;

function workloadKernel(iterations) {
    let digest = 0;
    for (let i = 0; i < iterations; i++) {
        const path = __ROUTE_PATHS[(i + __totalCalls) % __ROUTE_PATHS.length];
        let m = __ROUTE_USER.exec(path);
        if (m) {
            digest = (digest + ((+m[1] * 31) | 0) + ((+m[2] * 17) | 0)) | 0;
            continue;
        }
        m = __ROUTE_DEPLOY.exec(path);
        if (m) {
            digest = (digest ^ ((+m[1] * 131) | 0)) | 0;
            continue;
        }
        m = __ROUTE_ASSET.exec(path);
        if (m) {
            digest = (digest + m[1].length * 257) | 0;
            continue;
        }
        digest = (digest ^ path.length ^ 0x9e3779b9) | 0;
    }

    return digest >>> 0;
}

