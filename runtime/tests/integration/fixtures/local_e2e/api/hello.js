export default function handler(req, env) {
  return Response.json({
    message: env.GREETING + " " + req.params.name,
    x: req.query.get("x")
  });
}
