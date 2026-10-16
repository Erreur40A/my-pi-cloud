# Network access — V1 specification

## Scope

- V1 is reachable on the **LAN only**. Nothing is exposed on the Internet: no port is opened on the router.
- Remote access comes later through a VPN, once all apps are done. Any VPN that routes the LAN subnet keeps the same server name working unchanged.

## Server name

- A free domain name at **Dynu** (e.g. `<name>.dynu.net`).
- A **public `A` record points to the Pi's LAN IP**. `A` is the DNS record type mapping a name to an IPv4 address (`AAAA` is for IPv6). The Pi is joined over IPv4 only, as its ufw rules.

Why this and not the alternatives:

| Option | Rejected because |
|---|---|
| Name given by the router (`<name>.home`) | No certificate authority signs a name nobody owns: the certificate would never match. |
| Pi as local DNS server (dnsmasq) | The Pi is not on 24/7. Unplugged, every device in the house loses DNS, so the whole Internet looks down. Adding the router as secondary DNS makes resolution random. |
| `/etc/hosts` on each device | Not editable on Android without rooting the phone. |
| DuckDNS | Known for outages. Dynu offers the same features (free, API, `acme.sh` support). |

Consequences of a public record pointing to a private IP:

- Pi unplugged: only the cloud is unreachable; nothing else changes for the household.
- Dynu down: cached answers keep working for a while, then the cloud is unreachable until Dynu is back.
- Publishing a private IP reveals almost nothing: `192.168.0.x` is used by millions of networks and is not routed on the Internet. The domain name is public anyway (Certificate Transparency logs).
- From outside the LAN (4G), the name resolves but the private IP leads nowhere: no answer.
- **To check once the record exists:** some routers block public names resolving to private IPs (DNS rebinding protection). From the LAN, `dig <name>.dynu.net` must return the Pi's IP.

## HTTPS

- HTTPS everywhere. Over plain HTTP, anyone on the Wi-Fi reads passwords, session tokens and file contents.
- Certificate from **Let's Encrypt** with the **DNS-01 challenge** through Dynu's API (`acme.sh`, `dns_dynu` plugin). Only a `TXT` record is needed: the Pi is never exposed.
- **Renewal is automatic.** Certificates last 90 days (and Let's Encrypt is shortening this): without automation, everything stops after 3 months.
- mkcert was ruled out: its root CA must be installed on every family device; on Android, apps other than the browser ignore user-installed CAs by default (ours would need a network security config to accept it); and a stolen CA key lets an attacker forge a certificate for any site on all those devices.
  - Not to be confused with the certificate installed to join an enterprise Wi-Fi (802.1X): that one only authenticates the Wi-Fi network. Websites keep working because they use public CAs, already trusted by every device.

### Clients never disable certificate validation

The TLS handshake happens **before** any HTTP byte is sent. Scenario: a family member is on a friend's Wi-Fi whose LAN also uses `192.168.0.x`; the server name resolves to a printer there. The printer cannot present a certificate for our name, the handshake fails, and the session token is never sent. Disabling certificate validation (a common shortcut while developing on Android) would hand the token to whatever device answers.

## Server address in the clients

The Android and desktop apps ask for the server address **at first launch** (like Nextcloud or Jellyfin). It is not baked in at build time: a build-time value would force a rebuild for every address change and for anyone cloning the repo.

## Reverse proxy

- **Nginx**, running in Docker with the rest of the stack (see the Docker security checklist when writing the Compose file).
- **A single `server` block**, so the web app and the API share one origin: no CORS.

```nginx
location / {
    try_files $uri $uri/ /index.html;
}

location /api/ {
    # proxy to the Spring Boot container
}
```

- `try_files`: a React app has a single `index.html`; routes such as `/trash` do not exist on disk. Nginx serves the file if it exists, otherwise `index.html`, and React renders the page from the URL.
- `client_max_body_size` just above the chunk size (e.g. `11m`): chunk bodies are raw binary (see [file-storage](../file-storage/spec.md#2-chunks)), not JSON.
- Port 80 only **redirects to HTTPS** (`301`), so that typing the bare name in a browser works. Nothing is served over HTTP.
- Only Nginx publishes ports (80 and 443). Spring Boot and PostgreSQL publish none. Ports published by Docker bypass ufw.

## Open

- Where `acme.sh` runs (host or container) and how Nginx reloads the renewed certificate: decided with the Docker setup.
