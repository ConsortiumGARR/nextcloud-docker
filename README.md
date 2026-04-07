# docker-nextcloud

Custom Nextcloud Docker image that bakes the application code into the image,
eliminating the rsync-on-startup pattern of the official image. Designed for Kubernetes
deployments on NFS storage.

## Key differences from the official image

- **No `VOLUME /var/www/html`** — the application code lives in the image layer. Only
  user-data directories (`config`, `data`, `custom_apps`, `themes`) are declared as
  volumes.
- **No rsync at startup** — code is copied at build time, not at runtime.
- **Supports both Community and Enterprise** — select the edition via build args.
- **Post-upgrade DB optimization** — runs `maintenance:repair`,
  `db:add-missing-indices`, and related commands automatically after each upgrade
  (opt-out via `NEXTCLOUD_SKIP_DATABASE_OPTIMIZATION=yes`).
- **Subscription key support** — set `SUBSCRIPTION_KEY` to configure the enterprise
  support app.

## Build arguments

|         Argument         |        Default        |                                     Description                                     |
| ------------------------ | --------------------- | ----------------------------------------------------------------------------------- |
| `NEXTCLOUD_VERSION`      | *(set in Dockerfile)* | Version to download (community)                                                     |
| `ENTERPRISE_ARCHIVE_URL` | *(set in Dockerfile)* | If set, downloads the enterprise ZIP from this URL instead of the community tarball |

## Volumes

Only user-generated data needs to persist across image updates:

|            Path             |                   Content                    |
| --------------------------- | -------------------------------------------- |
| `/var/www/html/config`      | Nextcloud configuration (`config.php`, etc.) |
| `/var/www/html/data`        | User files                                   |
| `/var/www/html/custom_apps` | User-installed apps                          |
| `/var/www/html/themes`      | Custom themes                                |

## Environment variables

Additional variables introduced by this image:

|                Variable                |  Default  |                        Description                         |
| -------------------------------------- | --------- | ---------------------------------------------------------- |
| `NEXTCLOUD_SKIP_DATABASE_OPTIMIZATION` | `no`      | Set to `yes` to skip post-upgrade DB optimization commands |
| `SUBSCRIPTION_KEY`                     | *(unset)* | Enterprise subscription key for the `support` app          |

## Upgrade behaviour

The entrypoint detects the installed version from `config/version.php` (written after
each successful install or upgrade) and compares it to the version baked in the image.

- **Fresh install** (`config/version.php` absent): runs `occ maintenance:install`, then
  writes the sentinel.
- **Upgrade** (image version > installed version): runs `occ upgrade`, DB optimizations,
  then updates the sentinel.
- **Downgrade**: refused with an error.
- **Cross-replica safety**: the init block is protected by `flock` on
  `config/nextcloud-init-sync.lock` (on the shared `config` volume).

## Files

- `Dockerfile` — multi-stage build (`source` on alpine, `final` on
  `php:8.4-apache-trixie`)
- `docker-entrypoint.sh` — install/upgrade logic, structurally identical to the official
  community entrypoint
- `cron.sh` — runs `busybox crond` for background jobs
- `config/` — default PHP config files baked into the image; also copied to
  `/usr/src/nextcloud-config/` as a reference for drift detection warnings at startup
