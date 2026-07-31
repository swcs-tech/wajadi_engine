# Local Load Test

This setup is used for local load testing. K6 will send requests to the dev-only endpoint without a network connection and using a real WhatsApp number.

## Running the App

```bash
./load/local.sh
```

The load test endpoint is only active when `dev_routes` is enabled in dev.

## Running k6

```bash
./load/k6.sh
```

Override load:

```bash
LOW_VUS=20 MEDIUM_VUS=100 PEAK_VUS=250 ./load/k6.sh
```

## What Is Tested

- create/reuse local fake sessions
- mark local sessions as connected
- insert outgoing chat history
- insert incoming chat history
- DB write pressure
- Phoenix request latency
- error rate and p95/p99 from k6

## What Is Not Tested

- real WhatsApp network
- QR scan
- real WhatsApp number
- real WebSocket chat, since this project has not yet exposed any business WebSocket channels other than the LiveView socket

## Threshold Default

- `http_req_failed < 1%`
- `http_req_duration p95 < 500ms`
- `http_req_duration p99 < 1000ms`
- `send_failures < 1%`
- `receive_failures < 1%`
