# Remnawave Install Script

Interactive install script for `Remnawave panel + subscription page` on one server.

It is made for the simple flow:

1. Start the script on a clean Ubuntu or Debian server.
2. Enter the admin panel domain.
3. Enter the subscription domain.
4. Wait until the script asks for the API token.
5. Create the token in the panel and paste it back.
6. Let the script finish the deployment.

## What The Script Does

`deploy-remnawave.sh` automatically:

- installs Docker, Docker Compose, UFW, curl, jq, openssl, and base packages;
- opens the required firewall ports;
- can free busy ports when they block the install;
- downloads the current official Remnawave compose files;
- starts the panel, Postgres, and Valkey;
- configures HTTPS with Caddy;
- pauses only for the manual `superadmin + API token` step;
- starts the subscription page after you paste the token;
- can create a temporary test user and check a real subscription link;
- writes detailed command output to `/var/log/remnawave-deploy.log`.

The script does not deploy a Remnawave node.

## Before You Start

You need:

- a server with Ubuntu or Debian;
- `sudo` or root access;
- two DNS `A` records already pointed to that server:
- `admin.your-domain.com -> your-server-ip`
- `sub.your-domain.com -> your-server-ip`

## Run

Upload `deploy-remnawave.sh` to the server and run:

```bash
sudo bash deploy-remnawave.sh
```

On a normal fresh run, the script asks only for:

- the admin panel domain;
- the subscription domain;
- the API token later, after the panel is already up.

It can ask extra confirmation questions only if:

- old Remnawave data is already found;
- ports are busy and must be freed;
- DNS is still pointed to another server.

## Manual Step

When the script pauses:

1. Open `https://<your-admin-domain>`.
2. Create the `superadmin`.
3. Open `Remnawave Settings -> API Tokens`.
4. Create an API token for the subscription page.
5. Paste that token back into the terminal.

After that, the script continues on its own.

## Important Note About The Subscription Domain

The root URL `https://<your-sub-domain>` can return `502` and still be acceptable.

That usually means the subscription page is used through individual user subscription links, not through a public landing page on the root domain.

## Advanced Optional Variables

The interactive wizard keeps the default flow short, but you can override a few things before launch:

```bash
export RW_LETSENCRYPT_EMAIL="you@example.com"
export RW_SSH_PORT="22"
export RW_ENABLE_TEMP_USER_CHECK="true"
export RW_AUTO_DELETE_TEMP_USER="true"
sudo bash deploy-remnawave.sh
```

## Sources

- [Remnawave panel docs](https://docs.rw/docs/install/remnawave-panel)
- [Environment variables](https://docs.rw/docs/install/environment-variables)
- [backend docker-compose-prod.yml](https://github.com/remnawave/backend/blob/main/docker-compose-prod.yml)
- [subscription-page docker-compose-prod.yml](https://github.com/remnawave/subscription-page/blob/main/docker-compose-prod.yml)
