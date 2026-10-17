// Per case: the checks, each a request with the status and body every
// runtime must answer, and the one the load repeats, whose status is the only
// one a measured window accepts. A UUID in an answer reads as <uuid> before
// the comparison, since the API makes a random one per user.
import { createHmac } from "node:crypto";

const json = { "content-type": "application/json" };

// A payment provider's webhook event, about 1 KB.
const event = JSON.stringify({
  id: "evt_3Q8x2LkJ9sT4vW1m",
  type: "invoice.paid",
  created: 1760400000,
  livemode: false,
  data: {
    object: {
      id: "in_3Q8x2LkJ9sT4vW1mA7bC",
      customer: "cus_R5tY7uI9oP1a",
      customer_email: "grace@example.com",
      customer_name: "Grace Hopper",
      currency: "usd",
      amount_due: 5800,
      amount_paid: 5800,
      amount_remaining: 0,
      attempt_count: 1,
      billing_reason: "subscription_cycle",
      status: "paid",
      subscription: "sub_9Hj3Kl5Zx7Cv",
      period_start: 1757808000,
      period_end: 1760400000,
      lines: [
        { id: "il_1A2b3C4d", description: "Pro plan, monthly", amount: 4900, quantity: 1, price: "price_pro_monthly" },
        { id: "il_5E6f7G8h", description: "Additional seat", amount: 450, quantity: 2, price: "price_seat_monthly" },
      ],
      payment: { method: "card", brand: "visa", last4: "4242", country: "BR" },
      address: { line1: "1 Navy Yard", city: "Arlington", state: "VA", postal_code: "22202", country: "US" },
      metadata: { order_id: "ord_88421", workspace: "ws_compilers", region: "sa-east-1", plan_version: "2026-09" },
    },
  },
});
const webhook = (signature) => ({ method: "POST", path: "/webhook", headers: { ...json, "x-signature": signature }, body: event });

const greeting = { request: { path: "/" }, status: 200, body: "Hello, world!" };
const getUser = { request: { path: "/users/42" }, status: 200, body: '{"id":"42","name":"Ada Lovelace"}' };
const createUser = {
  request: { method: "POST", path: "/users", headers: json, body: '{"name":"Grace Hopper","email":"grace@example.com"}' },
  status: 201,
  body: '{"id":"<uuid>","name":"Grace Hopper","email":"grace@example.com"}',
};
const signedEvent = { request: webhook(createHmac("sha256", "whsec_example").update(event).digest("hex")), status: 200, body: '{"valid":true}' };
const forgedEvent = { request: webhook("0".repeat(64)), status: 200, body: '{"valid":false}' };

export default {
  hello: { load: greeting, checks: [greeting] },
  api: { load: createUser, checks: [getUser, createUser] },
  crypto: { load: signedEvent, checks: [signedEvent, forgedEvent] },
};
