import { APIError, object, requireValue, text, timestamp, uuid } from './validation.js';
import { readJSON } from './app.js';

const version = v => { text(v, 64); requireValue(/^[A-Za-z0-9._+-]+$/.test(v)); return v; };
export function events(body, now, retentionDays) {
  object(body, ['events']);
  requireValue(Array.isArray(body.events) && body.events.length >= 1 && body.events.length <= 25);
  const ids = new Set();
  return body.events.map(event => {
    object(event, ['eventID', 'name', 'occurredAt', 'properties']);
    const eventID = uuid(event.eventID);
    requireValue(!ids.has(eventID)); ids.add(eventID);
    const occurredAt = timestamp(event.occurredAt, now);
    requireValue(Date.parse(occurredAt) >= now - retentionDays * 86400000, 'event_expired');
    const props = event.properties;
    const common = ['appVersion', 'appBuild'];
    let allowed;
    switch (event.name) {
      case 'registration_completed': allowed = common; break;
      case 'modsmith_outcome': allowed = [...common, 'operation', 'outcome', 'durationMs', 'failureCategory']; break;
      case 'crash': allowed = [...common, 'category']; break;
      default: throw new APIError(400, 'unknown_event');
    }
    object(props, allowed, common);
    const properties = { appVersion: version(props.appVersion), appBuild: version(props.appBuild) };
    if (event.name === 'modsmith_outcome') {
      requireValue(['create', 'refine', 'undo'].includes(props.operation));
      requireValue(['succeeded', 'failed', 'cancelled'].includes(props.outcome));
      properties.operation = props.operation; properties.outcome = props.outcome;
      if (props.durationMs !== undefined) {
        requireValue(Number.isInteger(props.durationMs) && props.durationMs >= 0 && props.durationMs <= 3600000);
        properties.durationMs = props.durationMs;
      }
      if (props.failureCategory !== undefined) {
        requireValue(props.outcome === 'failed' && ['provider', 'timeout', 'validation', 'runtime', 'unknown'].includes(props.failureCategory));
        properties.failureCategory = props.failureCategory;
      }
    }
    if (event.name === 'crash') {
      requireValue(['native', 'backend', 'mod', 'unknown'].includes(props.category));
      properties.category = props.category;
    }
    return { eventID, name: event.name, occurredAt, properties };
  });
}
export function telemetryRoute(store, { enabled = false, retentionDays } = {}) {
  if (enabled && (!Number.isInteger(retentionDays) || retentionDays < 1 || retentionDays > 365)) throw new Error('BOWSER_EVENT_RETENTION_DAYS must be 1..365');
  return async (req, res, { json, now }) => {
    if (!enabled) throw new APIError(503, 'telemetry_unavailable');
    let registrationID = null;
    if (req.headers.authorization !== undefined) {
      const match = /^Bearer ([A-Za-z0-9_.-]+)$/.exec(req.headers.authorization);
      registrationID = match && store.authenticateTelemetry(match[1]);
      if (!registrationID) throw new APIError(401, 'invalid_telemetry_token');
    }
    const batch = events(await readJSON(req), now(), retentionDays);
    const result = store.saveEvents(batch, registrationID, now(), retentionDays);
    json(res, 202, result);
  };
}
