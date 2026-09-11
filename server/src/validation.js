export class APIError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export function requireValue(condition, code = 'invalid_request') {
  if (!condition) throw new APIError(400, code);
}
export function object(value, keys, required = keys) {
  requireValue(value !== null && typeof value === 'object' && !Array.isArray(value));
  requireValue(Object.keys(value).every(k => keys.includes(k)) && required.every(k => Object.hasOwn(value, k)));
}
export function text(value, max) {
  requireValue(typeof value === 'string' && value.length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value));
  return value;
}
export function uuid(value) {
  requireValue(typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value));
  return value.toLowerCase();
}
export function timestamp(value, now) {
  requireValue(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/.test(value));
  const parsed = Date.parse(value);
  requireValue(Number.isFinite(parsed) && parsed <= now + 300_000);
  // Reject calendar overflow (Date.parse otherwise accepts February 30).
  requireValue(new Date(parsed).toISOString().slice(0, 19) === value.slice(0, 19));
  return new Date(parsed).toISOString();
}
export function registration(body, key, termsVersions, now) {
  object(body, ['requestID', 'email', 'termsVersion', 'acceptedAt', 'device', 'trainingConsent'],
    ['requestID', 'email', 'termsVersion', 'acceptedAt', 'trainingConsent']);
  const requestID = uuid(body.requestID);
  requireValue(uuid(key) === requestID, 'idempotency_key_mismatch');
  const email = text(body.email, 254).trim();
  requireValue(/^[^@<>\s]+@[^@<>.\s]+(?:\.[^@<>.\s]+)+$/.test(email));
  const termsVersion = text(body.termsVersion, 80);
  if (!termsVersions.includes(termsVersion)) throw new APIError(422, 'unsupported_terms_version');
  requireValue(typeof body.trainingConsent === 'boolean');
  const result = { requestID, email, termsVersion, acceptedAt: timestamp(body.acceptedAt, now), trainingConsent: body.trainingConsent };
  if (body.device !== undefined) {
    object(body.device, ['model', 'architecture', 'macOSVersion', 'appVersion', 'appBuild']);
    result.device = Object.fromEntries(['model', 'architecture', 'macOSVersion', 'appVersion', 'appBuild'].map(k => [k, text(body.device[k], 100)]));
    requireValue(result.device.architecture === 'arm64');
  }
  return result;
}
