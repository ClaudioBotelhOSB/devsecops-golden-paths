// ============================================================================
// tests/k6/smoke.js
//
// Stack-agnostic k6 smoke. Reads every endpoint and threshold from the
// environment so the same file works for any HTTP service.
//
// Variables (all optional, sensible defaults):
//   BASE_URL               default 'https://preview.example.internal'
//   HEALTH_ENDPOINT        default '/healthz'
//   READINESS_ENDPOINT     default '/readyz'
//   SMOKE_API_PATH         default '/'
//   THRESHOLD_P95_MS       default 400
//   THRESHOLD_P99_MS       default 900
//   THRESHOLD_FAIL_RATE    default 0.01
// ============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL        = __ENV.BASE_URL            || 'https://preview.example.internal';
const HEALTH          = __ENV.HEALTH_ENDPOINT     || '/healthz';
const READINESS       = __ENV.READINESS_ENDPOINT  || '/readyz';
const SMOKE_API       = __ENV.SMOKE_API_PATH      || '/';
const P95_MS          = parseInt(__ENV.THRESHOLD_P95_MS   || '400', 10);
const P99_MS          = parseInt(__ENV.THRESHOLD_P99_MS   || '900', 10);
const FAIL_RATE       = parseFloat(__ENV.THRESHOLD_FAIL_RATE || '0.01');

const apiErrors = new Counter('api_errors');

export const options = {
  scenarios: {
    smoke: {
      executor: 'constant-vus',
      vus: 3,
      duration: '30s',
      gracefulStop: '5s',
      exec: 'smoke',
    },
  },
  thresholds: {
    http_req_failed:   [`rate<${FAIL_RATE}`],
    http_req_duration: [`p(95)<${P95_MS}`, `p(99)<${P99_MS}`],
    checks:            ['rate==1.0'],
    api_errors:        ['count==0'],
  },
};

function url(path) {
  return `${BASE_URL}${path}`;
}

export function smoke() {
  const healthz = http.get(url(HEALTH), { tags: { name: 'health' } });
  if (!check(healthz, { 'health <400': r => r.status < 400 })) {
    apiErrors.add(1);
  }

  const readyz = http.get(url(READINESS), { tags: { name: 'readiness' } });
  check(readyz, { 'readyz <400': r => r.status < 400 });

  const root = http.get(url(SMOKE_API), { tags: { name: 'smoke_api' } });
  if (!check(root, { 'smoke_api <400': r => r.status < 400 })) {
    apiErrors.add(1);
  }

  sleep(0.5);
}
