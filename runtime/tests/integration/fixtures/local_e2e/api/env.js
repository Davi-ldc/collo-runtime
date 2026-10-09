export default function handler(req, env) {
  return Response.json({
    token: env.TOKEN,
    frozen: Object.isFrozen(env),
    processEnv: Object.keys(process.env)
  });
}
