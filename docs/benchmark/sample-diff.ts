// Benchmark fixture — a deliberately flawed module used to score reviewers.
// 8 planted issues (G1–G8); ground truth in ground-truth.md. No real secrets.

import { db } from "./db";

// --- handler 1 ---
export async function getUser(req: any, res: any) {
  // G1 (security): SQL injection via string concatenation of req.query.id
  const rows = db.query("SELECT * FROM users WHERE id = " + req.query.id);
  // G2 (correctness): db.query returns a Promise — not awaited, rows[0] is undefined
  return res.json(rows[0]);
}

// --- handler 2 ---
export async function updateEmail(req: any, res: any) {
  // G3 (security): IDOR — updates the row named in the body with no check that
  //                the caller owns it / is authorized.
  // G4 (correctness): req.body.email is never validated before persistence.
  await db.query("UPDATE users SET email = $1 WHERE id = $2", [
    req.body.email,
    req.body.id,
  ]);
  res.send("ok");
}

// --- util ---
export function parseConfig(raw: any) {
  // G5 (quality): `any` parameter + untyped return defeats type safety
  // G6 (correctness): JSON.parse throws on malformed input — no try/catch
  return JSON.parse(raw);
}

// --- data access ---
export async function listOrders(userId: string) {
  const orders = await db.query("SELECT * FROM orders WHERE user_id = $1", [userId]);
  // G7 (performance): N+1 — one customer query per order inside a loop
  for (const o of orders) {
    o.customer = await db.query("SELECT * FROM customers WHERE id = $1", [o.customer_id]);
  }
  return orders;
}

// G8 (testing): no test file exists for any export in this module.
