import { Hono } from "hono";

const app = new Hono();

app.get("/users/:id", (c) => c.json({ id: c.req.param("id"), name: "Ada Lovelace" }));

app.post("/users", async (c) => {
  const user = await c.req.json();
  return c.json({ id: crypto.randomUUID(), ...user }, 201);
});

export default app;
