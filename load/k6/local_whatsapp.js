import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:4000';
const USER_PREFIX = __ENV.USER_PREFIX || 'load-user';
const SESSION_PREFIX = __ENV.SESSION_PREFIX || `load-${Date.now()}`;
const MESSAGE_SLEEP = Number(__ENV.MESSAGE_SLEEP || '1');

export const sendFailures = new Rate('send_failures');
export const receiveFailures = new Rate('receive_failures');
export const messagesSent = new Counter('messages_sent');
export const messagesReceived = new Counter('messages_received');

export const options = {
  scenarios: {
    low: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: Number(__ENV.LOW_VUS || '10') },
        { duration: '1m', target: Number(__ENV.LOW_VUS || '10') },
        { duration: '15s', target: 0 },
      ],
      gracefulRampDown: '15s',
      exec: 'chatFlow',
    },
    medium: {
      executor: 'ramping-vus',
      startTime: '1m45s',
      startVUs: 0,
      stages: [
        { duration: '30s', target: Number(__ENV.MEDIUM_VUS || '50') },
        { duration: '2m', target: Number(__ENV.MEDIUM_VUS || '50') },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '30s',
      exec: 'chatFlow',
    },
    peak: {
      executor: 'ramping-vus',
      startTime: '4m45s',
      startVUs: 0,
      stages: [
        { duration: '30s', target: Number(__ENV.PEAK_VUS || '100') },
        { duration: '2m', target: Number(__ENV.PEAK_VUS || '100') },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '30s',
      exec: 'chatFlow',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    send_failures: ['rate<0.01'],
    receive_failures: ['rate<0.01'],
  },
};

export function chatFlow() {
  const userId = `${USER_PREFIX}-${__VU}`;
  const sessionId = `${SESSION_PREFIX}-${__VU}`;
  const peer = `628${String(__VU).padStart(10, '0')}@s.whatsapp.net`;

  const sessionRes = http.put(`${BASE_URL}/dev/load/whatsapp/sessions/${userId}/${sessionId}`);
  check(sessionRes, { 'session upserted': (res) => res.status === 200 });

  const body = JSON.stringify({
    session_id: sessionId,
    peer,
    body: `hello from vu=${__VU} iter=${__ITER}`,
  });

  const headers = { 'Content-Type': 'application/json' };
  const sendRes = http.post(`${BASE_URL}/dev/load/whatsapp/messages/send`, body, { headers });
  const sendOk = check(sendRes, { 'send accepted': (res) => res.status === 200 });
  sendFailures.add(!sendOk);

  if (sendOk) {
    messagesSent.add(1);
  }

  const receiveRes = http.post(`${BASE_URL}/dev/load/whatsapp/messages/receive`, body, { headers });
  const receiveOk = check(receiveRes, { 'receive accepted': (res) => res.status === 200 });
  receiveFailures.add(!receiveOk);

  if (receiveOk) {
    messagesReceived.add(1);
  }

  sleep(MESSAGE_SLEEP);
}
