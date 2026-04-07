#!/bin/sh
# shellcheck shell=sh
set -eu

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

version_greater() {
    [ "$(printf '%s\n' "$@" | sort -t '.' -n -k1,1 -k2,2 -k3,3 -k4,4 | head -n 1)" != "$1" ]
}

directory_empty() {
    [ -z "$(ls -A "$1/")" ]
}

run_as() {
    if [ "$(id -u)" = 0 ]; then
        su -p "$user" -s /bin/sh -c "$1"
    else
        sh -c "$1"
    fi
}

# Support VAR and VAR_FILE (Docker secrets)
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    local varValue
    local fileVarValue
    varValue=$(env | grep -E "^${var}=" | sed -E "s/^${var}=//" || true)
    fileVarValue=$(env | grep -E "^${fileVar}=" | sed -E "s/^${fileVar}=//" || true)
    if [ -n "${varValue}" ] && [ -n "${fileVarValue}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    if [ -n "${varValue}" ]; then
        export "$var"="${varValue}"
    elif [ -n "${fileVarValue}" ]; then
        export "$var"="$(cat "${fileVarValue}")"
    elif [ -n "${def}" ]; then
        export "$var"="${def}"
    fi
    unset "$fileVar"
}

# Run all executable *.sh scripts in /docker-entrypoint-hooks.d/<hook>
run_path() {
    local hook_folder_path="/docker-entrypoint-hooks.d/$1"

    echo "=> Searching for hook scripts in \"${hook_folder_path}\""

    if ! [ -d "${hook_folder_path}" ] || directory_empty "${hook_folder_path}"; then
        echo "==> Skipped: \"$1\" folder is empty or does not exist"
        return 0
    fi

    find "${hook_folder_path}" -maxdepth 1 -iname '*.sh' '(' -type f -o -type l ')' -print | sort | \
    while read -r script_file_path; do
        if ! [ -x "${script_file_path}" ]; then
            echo "==> Skipped (no +x): \"${script_file_path}\""
            continue
        fi
        echo "==> Running: \"${script_file_path}\""
        run_as "${script_file_path}" || {
            echo "==> Failed: \"${script_file_path}\" (exit $?)"
            exit 1
        }
        echo "==> Done: \"${script_file_path}\""
    done
}

# Write /usr/local/etc/php/conf.d/redis-session.ini if REDIS_HOST is set
configure_redis_session() {
    echo "=> Configuring PHP session handler..."

    if [ -z "${REDIS_HOST:-}" ]; then
        echo "==> REDIS_HOST not set, using default PHP session handler"
        return 0
    fi

    file_env REDIS_HOST_PASSWORD

    local redis_save_path redis_auth
    redis_auth=''

    case "$REDIS_HOST" in
        /*)
            redis_save_path="unix://${REDIS_HOST}"
            ;;
        *)
            redis_save_path="tcp://${REDIS_HOST}:${REDIS_HOST_PORT:=6379}"
            ;;
    esac

    if [ -n "${REDIS_HOST_PASSWORD+x}" ] && [ -n "${REDIS_HOST_USER+x}" ]; then
        redis_auth="?auth[]=${REDIS_HOST_USER}&auth[]=${REDIS_HOST_PASSWORD}"
    elif [ -n "${REDIS_HOST_PASSWORD+x}" ]; then
        redis_auth="?auth=${REDIS_HOST_PASSWORD}"
    fi

    echo "==> Using Redis as PHP session handler (${redis_save_path})"
    {
        echo 'session.save_handler = redis'
        echo "session.save_path = \"${redis_save_path}${redis_auth}\""
        echo 'redis.session.locking_enabled = 1'
        echo 'redis.session.lock_retries = -1'
        echo 'redis.session.lock_wait_time = 10000'
    } > /usr/local/etc/php/conf.d/redis-session.ini
}

get_enabled_apps() {
    run_as 'php /var/www/html/occ app:list' \
        | sed -n '/^Enabled:$/,/^Disabled:$/p' \
        | sed '1d;$d' \
        | sed -n 's/^  - \([^:]*\):.*/\1/p' \
        | sort
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if expr "$1" : "apache" 1>/dev/null; then
    if [ -n "${APACHE_DISABLE_REWRITE_IP+x}" ]; then
        a2disconf remoteip
    fi
fi

if expr "$1" : "apache" 1>/dev/null || [ "$1" = "php-fpm" ] || [ "${NEXTCLOUD_UPDATE:-0}" -eq 1 ]; then

    # Resolve user/group that Apache or php-fpm will run as
    if [ "$(id -u)" = 0 ]; then
        case "$1" in
            apache2*)
                user="${APACHE_RUN_USER:-www-data}"
                group="${APACHE_RUN_GROUP:-www-data}"
                user="${user#'#'}"
                group="${group#'#'}"
                ;;
            *)
                user='www-data'
                group='www-data'
                ;;
        esac
    else
        user="$(id -u)"
        group="$(id -g)"
    fi

    configure_redis_session

    # Serialize across replicas starting simultaneously (e.g. rolling restart)
    (
        if ! flock -n 9; then
            echo "Another instance is initializing Nextcloud. Waiting..."
            flock 9
        fi

        # The image version is always what is on disk — the code is baked in.
        image_version="$(php -r 'require "/var/www/html/version.php"; echo implode(".", $OC_Version);')"

        # The installed version is what the database knows about.
        # config/config.php is on a persistent volume; absence means fresh install.
        installed_version="0.0.0.0"
        if [ -f /var/www/html/config/config.php ]; then
            # occ status is more reliable than parsing config.php directly
            installed_version="$(php -r '
                require "/var/www/html/version.php";
                $cfg = "/var/www/html/config/config.php";
                if (!file_exists($cfg)) exit;
                $CONFIG = [];
                include $cfg;
                echo $CONFIG["version"] ?? "0.0.0.0";
            ')"
        fi

        echo "=> Image version:     ${image_version}"
        echo "=> Installed version: ${installed_version}"

        # Safety: refuse to downgrade
        if version_greater "$installed_version" "$image_version"; then
            echo "ERROR: installed version (${installed_version}) is newer than the image (${image_version})."
            echo "Downgrading is not supported. Pull the correct image version."
            exit 1
        fi

        # Safety: refuse to skip major versions
        if [ "$installed_version" != "0.0.0.0" ]; then
            image_major="${image_version%%.*}"
            installed_major="${installed_version%%.*}"
            if [ "$((image_major - installed_major))" -gt 1 ]; then
                echo "ERROR: cannot upgrade from ${installed_version} to ${image_version} directly."
                echo "Upgrade one major version at a time."
                exit 1
            fi
        fi

        # ------------------------------------------------------------------
        # Fresh installation
        # ------------------------------------------------------------------
        if [ "$installed_version" = "0.0.0.0" ]; then
            echo "=> New Nextcloud instance — running installation..."

            file_env NEXTCLOUD_ADMIN_PASSWORD
            file_env NEXTCLOUD_ADMIN_USER

            install=false

            if [ -n "${NEXTCLOUD_ADMIN_USER+x}" ] && [ -n "${NEXTCLOUD_ADMIN_PASSWORD+x}" ]; then
                # shellcheck disable=SC2016
                install_options='-n --admin-user "$NEXTCLOUD_ADMIN_USER" --admin-pass "$NEXTCLOUD_ADMIN_PASSWORD"'

                if [ -n "${NEXTCLOUD_DATA_DIR+x}" ]; then
                    # shellcheck disable=SC2016
                    install_options="${install_options} --data-dir \"\$NEXTCLOUD_DATA_DIR\""
                fi

                file_env MYSQL_DATABASE
                file_env MYSQL_PASSWORD
                file_env MYSQL_USER
                file_env POSTGRES_DB
                file_env POSTGRES_PASSWORD
                file_env POSTGRES_USER

                if [ -n "${SQLITE_DATABASE+x}" ]; then
                    echo "==> Database: SQLite"
                    # shellcheck disable=SC2016
                    install_options="${install_options} --database-name \"\$SQLITE_DATABASE\""
                    install=true
                elif [ -n "${MYSQL_DATABASE+x}" ] && [ -n "${MYSQL_USER+x}" ] && \
                     [ -n "${MYSQL_PASSWORD+x}" ] && [ -n "${MYSQL_HOST+x}" ]; then
                    echo "==> Database: MySQL/MariaDB"
                    # shellcheck disable=SC2016
                    install_options="${install_options} --database mysql --database-name \"\$MYSQL_DATABASE\" --database-user \"\$MYSQL_USER\" --database-pass \"\$MYSQL_PASSWORD\" --database-host \"\$MYSQL_HOST\""
                    install=true
                elif [ -n "${POSTGRES_DB+x}" ] && [ -n "${POSTGRES_USER+x}" ] && \
                     [ -n "${POSTGRES_PASSWORD+x}" ] && [ -n "${POSTGRES_HOST+x}" ]; then
                    echo "==> Database: PostgreSQL"
                    # shellcheck disable=SC2016
                    install_options="${install_options} --database pgsql --database-name \"\$POSTGRES_DB\" --database-user \"\$POSTGRES_USER\" --database-pass \"\$POSTGRES_PASSWORD\" --database-host \"\$POSTGRES_HOST\""
                    install=true
                fi

                if [ "$install" = true ]; then
                    run_path pre-installation

                    max_retries=10
                    try=0
                    until [ "$try" -gt "$max_retries" ] || \
                          run_as "php /var/www/html/occ maintenance:install ${install_options}"; do
                        echo "==> Installation attempt $((try+1))/${max_retries} failed, retrying in 10s..."
                        try=$((try+1))
                        sleep 10
                    done

                    if [ "$try" -gt "$max_retries" ]; then
                        echo "ERROR: Nextcloud installation failed after ${max_retries} attempts."
                        exit 1
                    fi

                    if [ -n "${NEXTCLOUD_TRUSTED_DOMAINS+x}" ]; then
                        echo "==> Setting trusted domains..."
                        set -f
                        idx=1
                        for domain in ${NEXTCLOUD_TRUSTED_DOMAINS}; do
                            domain="$(echo "${domain}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                            run_as "php /var/www/html/occ config:system:set trusted_domains ${idx} --value=\"${domain}\""
                            idx=$((idx+1))
                        done
                        set +f
                    fi

                    run_path post-installation
                fi
            fi

            if [ "$install" = false ]; then
                echo "=> Admin credentials not provided — finish installation via the web interface."
                echo "   Set NEXTCLOUD_ADMIN_USER, NEXTCLOUD_ADMIN_PASSWORD and database variables to automate this."
            fi

        # ------------------------------------------------------------------
        # Upgrade
        # ------------------------------------------------------------------
        elif version_greater "$image_version" "$installed_version"; then
            echo "=> Upgrading Nextcloud from ${installed_version} to ${image_version}..."

            get_enabled_apps > /tmp/nc_apps_before

            run_path pre-upgrade
            run_as 'php /var/www/html/occ upgrade'
            run_path post-upgrade

            get_enabled_apps > /tmp/nc_apps_after
            disabled_apps="$(comm -23 /tmp/nc_apps_before /tmp/nc_apps_after || true)"
            if [ -n "$disabled_apps" ]; then
                echo "=> The following apps were disabled during upgrade:"
                printf '%s\n' "$disabled_apps"
            fi
            rm -f /tmp/nc_apps_before /tmp/nc_apps_after

            echo "=> Upgrade complete."
        else
            echo "=> Nextcloud ${installed_version} is up to date."
        fi

        if [ -n "${NEXTCLOUD_INIT_HTACCESS+x}" ] && [ "$installed_version" != "0.0.0.0" ]; then
            run_as 'php /var/www/html/occ maintenance:update:htaccess'
        fi

    ) 9>/tmp/nextcloud-init.lock

    run_path before-starting
fi

exec "$@"
