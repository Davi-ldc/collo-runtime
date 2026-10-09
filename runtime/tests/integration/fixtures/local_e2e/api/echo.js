export default async function handler(req) {
  const body = await req.text();
  return Response.json({
    body,
    length: body.length
  });
}
