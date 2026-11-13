/** Provider-reported counts are evidence, not a replacement for the catalog
 * estimate or a supplier invoice. No prompt, reply or media is retained. */
export interface CoachTokenUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadInputTokens?: number;
  cacheCreationInputTokens?: number;
}
export function tokenUsageOf(raw: unknown): CoachTokenUsage | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const v = raw as Record<string, unknown>;
  const count = (n: unknown): n is number => Number.isSafeInteger(n) && Number(n) >= 0 && Number(n) <= 2147483647;
  if (!count(v.inputTokens) || !count(v.outputTokens)) return null;
  return {inputTokens:v.inputTokens,outputTokens:v.outputTokens,
    ...(count(v.cacheReadInputTokens)?{cacheReadInputTokens:v.cacheReadInputTokens}:{}),
    ...(count(v.cacheCreationInputTokens)?{cacheCreationInputTokens:v.cacheCreationInputTokens}:{})};
}
export class CoachUsageEvidence {
  private attempts: Array<{stage:string;provider:string;model:string;catalog_estimate_cents:number;usage:CoachTokenUsage|null}> = [];
  begin(stage: string, step: {provider:string;model:string;unit_cents:number}): (raw: unknown) => void {
    const record = {stage,provider:step.provider,model:step.model,catalog_estimate_cents:step.unit_cents,usage:null as CoachTokenUsage|null};
    this.attempts.push(record);
    return raw => {record.usage=tokenUsageOf(raw);};
  }
  metadata() {
    return this.attempts.map(v=>({stage:v.stage,provider:v.provider,model:v.model,
      catalog_estimate_cents:v.catalog_estimate_cents,counts_status:v.usage?"provider_reported":"unavailable",
      ...(v.usage?{input_tokens:v.usage.inputTokens,output_tokens:v.usage.outputTokens,
        ...(v.usage.cacheReadInputTokens!==undefined?{cache_read_input_tokens:v.usage.cacheReadInputTokens}:{}),
        ...(v.usage.cacheCreationInputTokens!==undefined?{cache_creation_input_tokens:v.usage.cacheCreationInputTokens}:{})}:{}),
      supplier_invoice_verified:false}));
  }
}
