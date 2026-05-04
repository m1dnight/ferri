![Ferri Logo. Two concentric orange circles with a black arrow pointing left to right. The text Ferri right of it.](priv/static/images/logo.svg)

# Ferri

Ferri tunnels HTTP traffic from your localhost through a free SSL-terminating endpoint. You can use it for free, or host it yourself.

To get started, install the client and use the [hosted Ferri](https://ferri.run) for free

## How It Works

Ferri runs a server online, and a local Ferri client pipes web requests through
the server, to your client, and then to your local HTTP server. This is useful
for example, for testing webhooks, or showing a webapp on your machine to
somebody over the internet. The tunnels are not meant to be used for production
scenarios, but rather only for development purposes.

```mermaid
architecture-beta

    group ferri_group(cloud)[ferri]
    service ferri(server)[Ferri] in ferri_group


    group localhost(cloud)[localhost]
    service app(server)[Webapp] in localhost

    group internet(internet)[internet]
    service browser(server)[Browser] in internet

    app:R <--> L:ferri
    ferri:R <--> L:browser
```

## Features

 - SSL termination at the Ferri host
 - Random human-readdable URLs
 - Single-binary local client

## Why?

I built this because I was looking for a fun project to build that would expose
me to new things. It started out by implementing the simple
[Yamux](https://github.com/hashicorp/yamux) protocol after reading the [Network
Programming in Elixir and Erlang
book](https://pragprog.com/titles/alnpee/network-programming-in-elixir-and-erlang/)
by Andrea Leopardi. I personally like using ngrok, and it works perfectly fine.
I find it an interesting piece of software and wondered how it all worked
exactly.

## Installing Ferri

You can install the client using the following command. Check the source of the
script
[here](https://raw.githubusercontent.com/m1dnight/ferri/refs/heads/main/scripts/install.sh).

```bash
curl -fsSL https://raw.githubusercontent.com/m1dnight/ferri/refs/heads/main/scripts/install.sh | sh
```

Or, if you wish you can compile it from source from this repo.

## Using Ferri

To run Ferri you can run the `ferri` client locally and point it to a web
application running on `localhost`. Assuming you have a webapp running at
`localhost:4444` this will give you a public-facing URL that connects to that
webapp.


```shell
ferri 4444
```

If you are hosting your own Ferri server, you can specify the endpoint, it
defaults to `ferri.run:59595`.

```shell
ferri 4444 --remote myferri.com:59595
```

![Screenshot of the Ferri terminal client running.](priv/static/images/ferri-terminal.png)



## Run a Ferri Development Server

You can run Ferri locally by cloning this repo and then doing the following.

```shell
# Start the backend
iex -S mix phx.server
```

Connecting to your local instance using Cargo is done as follows.

```shell
cargo run --manifest-path ferri-client/ferri/Cargo.toml -- 4444 --remote localhost:59595
```

Note: on macOS any subdomain to `localhost` resolves to `localhost` so when
Ferri returns `http://foo.localhost:8080` it will resolve to localhost. I have
not tested or tried this on Linux.

## Self-hosting

To self-host Ferri you need a handful of things:

 - A VPS
 - A domain name with a wildcard A-record
 - A webserver that supports wildcard domains

I currently host Ferri on a VPS with Caddy and a wildcard domain at Gandi.

To run Ferri on a VPS, you need to install Caddy and Ferri as a SystemD service.


### Ferri

You can fetch any release from the release page
[here](https://github.com/m1dnight/ferri/releases). Copy the extracted output to
`/opt/` like below.

### Environment variables

Ferri reads the following environment variables at boot. These apply to any
production release (SystemD, Docker, or directly invoking `bin/ferri start`).

| Variable                    | Description                                                                                | Optional | Default / Example                        |
|-----------------------------|--------------------------------------------------------------------------------------------|----------|------------------------------------------|
| `SECRET_KEY_BASE`           | Secret used to sign and encrypt cookies and session data                                   | No       | 64-char string from `mix phx.gen.secret` |
| `PHX_SERVER`                | Set to any non-empty value to actually start the HTTP endpoint                             | Yes      | unset — server does not start            |
| `PHX_HOST`                  | Public hostname used for URL generation                                                    | Yes      | `example.com`                            |
| `PORT`                      | HTTP port the endpoint binds to                                                            | Yes      | `4000`                                   |
| `DNS_CLUSTER_QUERY`         | DNS query string for libcluster DNS-based node discovery                                   | Yes      | unset — no clustering                    |
| `TUNNEL_RATE_BYTES_PER_SEC` | Per-session sustained rate limit (bytes/sec) on data flowing from tunnel client → visitors | Yes      | `1048576` (1 MB/s)                       |
| `TUNNEL_BURST_BYTES`        | Per-session token-bucket burst size (bytes); short spikes up to this size bypass the rate  | Yes      | `1048576` (1 MB)                         |

### SystemD

Then create `/etc/ferri/env`
```bash
PHX_SERVER=true
SECRET_KEY_BASE=GENERATE_WITH_mix phx.gen.secret # Generate this !
PORT=4000
PHX_HOST=yourvps.com
# if you want to have remote shell access (e.g., with Tailscale)
RELEASE_DISTRIBUTION=name
RELEASE_NODE=ferri@ferri.mytailnet.ts.net.
RELEASE_COOKIE=cookiesaregreat
```

Set permissions

```bash
sudo chown ferri:ferri /etc/ferri/env
sudo chmod 0600 /etc/ferri/env
```

Create the SystemD file

```bash
[Unit]
Description=Ferri tunnel server
After=network.target

[Service]
Type=exec
User=ferri
Group=ferri
WorkingDirectory=/opt/ferri
EnvironmentFile=/etc/ferri/env
ExecStart=/opt/ferri/bin/ferri start
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

Start the service

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ferri
```

### Caddy

Caddy is fairly straightforward. The only annoying thing is setting up a
wildcard Let'sEncrypt. For Gandi and Caddy, the following works.

In the `/etc/caddy/Caddyfile`:

```
{
      email foo@bar.com
}

*.ferri.run, ferri.run {
      tls {
            dns gandi {env.GANDI_API_TOKEN}
            resolvers ns1.gandi.net ns2.gandi.net ns3.gandi.net
      }
      reverse_proxy localhost:8080
}
```

In `/etc/sytemd/system/caddy.service`

```
[Unit]
Description=Caddy
After=network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
EnvironmentFile=/etc/caddy/caddy.env
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.targe
```

In `/etc/caddy/caddy.env`:

```
GANDI_API_TOKEN=your_gandi_api_token
```

### Firewall

Optionally, if you want to use UFW:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 59595/tcp
sudo ufw --force enable
```