/** Fixed per-request row concurrency for read-only source catalogue validation.
 * Slots do not share authority or cursor state. Results retain input order;
 * fatal validation stops new rows, drains in-flight reads, and keeps the first
 * failing input row's original error. */
export async function mapCatalogueRows<T, R>(rows: readonly T[], validate: (row: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(rows.length);
  const failures: {index: number; error: unknown}[] = [];
  let next = 0;
  async function run(): Promise<void> {
    while (failures.length === 0) {
      const index = next++;
      if (index >= rows.length) return;
      try { results[index] = await validate(rows[index]); }
      catch (error) { failures.push({index, error}); return; }
    }
  }
  await Promise.all(Array.from({length: Math.min(4, rows.length)}, () => run()));
  if (failures.length) throw failures.sort((a, b) => a.index - b.index)[0].error;
  return results;
}
