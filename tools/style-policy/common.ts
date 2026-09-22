// Dependency-free validation. Never coerce or truncate user-provided contracts.
export function check(ok: unknown, message: string): asserts ok {
  if (!ok) throw new Error(message);
}
export function object(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  check(
    value !== null && typeof value === "object" && !Array.isArray(value),
    "expected object",
  );
  check(
    Object.getPrototypeOf(value) === Object.prototype,
    "plain JSON object required",
  );
  const descriptors = Object.getOwnPropertyDescriptors(value);
  check(
    Reflect.ownKeys(value).length === keys.length,
    "unexpected or missing keys",
  );
  for (const key of keys) {
    check(
      descriptors[key] && "value" in descriptors[key],
      "missing key or accessor",
    );
  }
  return value as Record<string, unknown>;
}
export function list(value: unknown, min: number, max: number): unknown[] {
  check(
    Array.isArray(value) && value.length >= min && value.length <= max,
    "array size outside contract",
  );
  check(
    Object.getPrototypeOf(value) === Array.prototype &&
      Reflect.ownKeys(value).length === value.length + 1,
    "sparse or decorated array",
  );
  for (let i = 0; i < value.length; i++) {
    check(
      "value" in (Object.getOwnPropertyDescriptor(value, String(i)) ?? {}),
      "array accessor or missing element",
    );
  }
  return value;
}
export function text(value: unknown, min = 0, max = 500): string {
  check(
    typeof value === "string" && value.length >= min && value.length <= max,
    "string size outside contract",
  );
  return value;
}
export function id(value: unknown): string {
  const result = text(value, 1, 64);
  check(/^[a-z0-9][a-z0-9-]*$/.test(result), "invalid opaque ID");
  return result;
}
export function number(
  value: unknown,
  min: number,
  max: number,
  integer = false,
): number {
  check(
    typeof value === "number" && Number.isFinite(value) &&
      !Object.is(value, -0) && value >= min && value <= max &&
      (!integer || Number.isSafeInteger(value)),
    "invalid finite number",
  );
  return value;
}
export function oneOf<T extends string>(
  value: unknown,
  values: readonly T[],
): T {
  check(
    typeof value === "string" && values.includes(value as T),
    "unknown enum",
  );
  return value as T;
}
export function digest(value: unknown): string {
  const result = text(value, 64, 64);
  check(/^[0-9a-f]{64}$/.test(result), "invalid SHA-256");
  return result;
}
export function unique(values: readonly unknown[]): void {
  check(new Set(values).size === values.length, "duplicate value");
}
export function canonical(value: unknown): string {
  let nodes = 0;
  function visit(v: unknown, depth: number): unknown {
    check(++nodes <= 20_000 && depth <= 16, "JSON complexity limit");
    if (v === null || typeof v === "boolean") return v;
    if (typeof v === "string") return text(v, 0, 8_000);
    if (typeof v === "number") {
      return number(v, -Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
    }
    if (Array.isArray(v)) {
      return list(v, 0, 2_000).map((item) => visit(item, depth + 1));
    }
    check(v !== null && typeof v === "object", "non-JSON value");
    const keys = Object.keys(v).sort();
    const obj = object(v, keys);
    check(
      keys.length <= 128 &&
        !keys.some((k) =>
          ["__proto__", "constructor", "prototype"].includes(k)
        ),
      "unsafe JSON keys",
    );
    return Object.fromEntries(
      keys.map((key) => [key, visit(obj[key], depth + 1)]),
    );
  }
  const encoded = JSON.stringify(visit(value, 0));
  check(
    new TextEncoder().encode(encoded).length <= 1_048_576,
    "JSON byte limit",
  );
  return encoded;
}
export function frozen<T>(value: T): Readonly<T> {
  const copy = JSON.parse(canonical(value));
  function freeze(v: unknown): void {
    if (v && typeof v === "object") {
      Object.values(v).forEach(freeze);
      Object.freeze(v);
    }
  }
  freeze(copy);
  return copy;
}
export async function hash(value: unknown): Promise<string> {
  const bytes = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical(value)),
  );
  return [...new Uint8Array(bytes)].map((n) => n.toString(16).padStart(2, "0"))
    .join("");
}
