// A Hono app answering every GET with a greeting, the smallest Hono tenant. The
// route matches any path because a Collo or workerd tenant is reached under
// its own prefix, /t<N>/, and a pod or a workerd-static tenant at its root.
import { Hono } from "hono";

const app = new Hono();

app.get("*", (c) => c.text("Hello, world!"));

export default app;
