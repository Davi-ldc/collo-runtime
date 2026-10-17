# One configuration per case, each a single worker behind one HTTPS socket:
#   workerd serve servers/workerd.capnp <case> --socket-addr https=<host:port>
using Workerd = import "/workerd/workerd.capnp";

const hello :Workerd.Config = (services = [(name = "main", worker = .helloWorker)], sockets = [.https]);
const api :Workerd.Config = (services = [(name = "main", worker = .apiWorker)], sockets = [.https]);
const crypto :Workerd.Config = (services = [(name = "main", worker = .cryptoWorker)], sockets = [.https]);

const helloWorker :Workerd.Worker = (modules = [(name = "hello.js", esModule = embed "../dist/hello.js")], compatibilityDate = .date);
const apiWorker :Workerd.Worker = (modules = [(name = "api.js", esModule = embed "../dist/api.js")], compatibilityDate = .date);
const cryptoWorker :Workerd.Worker = (modules = [(name = "crypto.js", esModule = embed "../dist/crypto.js")], compatibilityDate = .date);

# The newest date this workerd release supports.
const date :Text = "2026-10-12";

const https :Workerd.Socket = (
  name = "https",
  service = "main",
  https = (options = (), tlsOptions = (keypair = (privateKey = embed "../dist/key.pem", certificateChain = embed "../dist/cert.pem"))),
);
