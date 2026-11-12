import type { JobReply, ProcessorConsentRecord } from './contracts.ts';

const visible = (value: unknown, maximum: number): value is string =>
  typeof value === 'string' && value.length <= maximum && /^[!-~]+$/.test(value);

/** A projection of the accepted job, never the current provider selector or a grant. */
export function savedProcessorMetadata(job: Record<string, unknown>): Pick<JobReply,
  'consent_revision' | 'processor_consent' | 'quality_profile'> {
  if (job.consent_revision === undefined && job.processor_consent === undefined && job.quality_profile === undefined) return {};
  const raw = job.processor_consent;
  let record: ProcessorConsentRecord | null = null;
  if (raw !== null && typeof raw === 'object' && !Array.isArray(raw)) {
    const value = raw as Record<string, unknown>;
    const keys = Object.keys(value).sort();
    const processors = value.processors;
    if (keys.join(',') === 'disclosure_revision,processors,recorded_at,token' &&
      value.token === 'property-video-jobs-v2' && visible(value.disclosure_revision, 200) &&
      Array.isArray(processors) && processors.length > 0 && processors.length <= 20 &&
      processors.every(item => visible(item, 64)) && new Set(processors).size === processors.length &&
      typeof value.recorded_at === 'string' && value.recorded_at.length <= 64 && Number.isFinite(Date.parse(value.recorded_at))) {
      record = { token: value.token, disclosure_revision: value.disclosure_revision,
        processors: [...processors], recorded_at: value.recorded_at };
    }
  }
  // Malformed or future metadata must not strand status/download/cancel. The
  // partial record is explicit and cannot confer permission for a paid resume.
  return {
    consent_revision: visible(job.consent_revision, 200) ? job.consent_revision : null,
    processor_consent: record,
    quality_profile: visible(job.quality_profile, 200) ? job.quality_profile : null,
  };
}
