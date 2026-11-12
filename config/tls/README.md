# Certificates set by the server configuration

Put a certificate and its private key here to make the edge serve them for one
host, instead of the certificate it obtains itself and instead of one uploaded
in the portal:

```
config/tls/portal.example.com.crt   # the certificate chain, leaf first, PEM
config/tls/portal.example.com.key   # its private key, PEM, without a passphrase
```

The file name is the host name exactly as it is declared in the portal. The
edge picks up a new, changed or removed pair within seconds and reloads
without a restart; Settings -> Domains then shows the host as set by the server
configuration, and the portal refuses an upload that covers it.

This is also the recovery path when a wrong certificate was uploaded for the
portal domain and the portal cannot be opened: put a working pair for that
host here.

`direct` and `manual` modes read this directory. In `manual` mode it is, with
the certificates managed in the portal, the only source of certificates: a
host without a pair here or in the portal is not served over HTTPS, and a
certificate here is neither renewed nor withdrawn by the edge: replace the
pair before it expires. In `proxy` mode your balancer terminates TLS
and holds the certificates.

The installer copies such pairs here for you: `--tls-dir DIR` (or
`ATLAS_TLS_DIR`).
