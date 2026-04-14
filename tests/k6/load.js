// ============================================================================
// tests/k6/load.js
//
// Stack-agnostic ramped load profile. The workload under test only needs
// to expose whatever path the user sets in `LOAD_TARGET_PATH`. The default
// is just the root `/`. Thresholds are env-overridable.
// ============================================================================

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';

const BASE_URL         = __ENV.BASE_URL             || 'https://preview.example.internal';
const TARGET_PATH      = __ENV.LOAD_TARGET_PATH     || '/';
const P95_MS           = parseInt(__ENV.THRESHOLD_P95_MS || '500', 10);
const P99_MS           = parseInt(__ENV.THRESHOLD_P99_MS || '1200', 10);
const FAIL_RATE        = parseFloat(__ENV.THRESHOLD_FAIL_RATE || '0.005');
const ERR_RATE         = parseFloat(__ENV.THRESHOLD_BUSINESS_ERROR_RATE || '0.01');

const latency        = new Trend('target_latency', true);
const businessErrors = new Rate('business_errors');

export const options = {
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 10 },
        { duration: '1m',  target: 30 },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
      exec: 'load',
    },
  },
  thresholds: {
    http_req_failed:   [`rate<${FAIL_RATE}`],
    http_req_duration: [`p(95)<${P95_MS}`, `p(99)<${P99_MS}`],
    target_latency:    [`p(95)<${P95_MS}`],
    business_errors:   [`rate<${ERR_RATE}`],
  },
};

export function load() {
  const res = http.get(`${BASE_URL}${TARGET_PATH}`, { tags: { name: 'target' } });
  latency.add(res.timings.duration);
  businessErrors.add(res.status >= 400);
  check(res, { 'target <400': r => r.status < 400 });
  sleep(0.2);
}
