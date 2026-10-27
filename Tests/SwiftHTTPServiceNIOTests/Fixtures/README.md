# Test fixtures

**These keys are test-only. They protect nothing and must never be used for anything else.**

- `test-cert.pem`, `test-key.pem`: a self-signed ECDSA (P-256) certificate for `CN=localhost` with
  subject alternative names `localhost`, `127.0.0.1` and `::1`, valid ten years from 2026-10-27, and its
  private key.
- `mismatched-key.pem`: the private key of a different, unrelated self-signed certificate. It is used
  to prove the server refuses to start with a certificate and a key that do not belong together.

Generated with:

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1" \
  -keyout test-key.pem -out test-cert.pem

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
  -subj "/CN=other" -keyout mismatched-key.pem -out /dev/null
```

The tests trust `test-cert.pem` as an anchor for their own client only. Nothing in the package trusts it.
