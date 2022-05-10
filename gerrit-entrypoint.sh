#!/usr/bin/env sh
set -e

# default installed directory tree
# $GERRIT_DIR_VOLUME
#     └─┬── etc
#       ├── git
#       ├── db
#       ├── index
#       └── cache
#
#!/usr/bin/env sh

wait_for_database() {
    echo "Waiting for database connection $1:$2 ..."
        until nc -z $1 $2; do
        sleep 1
        done

# Wait to avoid "panic: Failed to open sql connection pq: the database system is starting up"
        sleep 1
}

copy_file() { # $1 : from path $2 : to path, $3 file name
    if [[ -f "$1/$3" ]]; then
        echo "copy user config $1/$3 -> $2/$3"
        if [[ -f "$2/$3" ]]; then
            echo "... rm $2/$3 before copy"
            su-exec ${GERRIT_USER} rm "$2/$3"
        fi
        su-exec ${GERRIT_USER} cp -f "$1/$3" "$2/$3"
        su-exec ${GERRIT_USER} chown ${GERRIT_USER}:${GERRIT_GROUP} "$2/$3"
        su-exec ${GERRIT_USER} ls -al "$2/$3"
        echo "... copy done"
    fi
}

if [ -n "${JAVA_HEAPLIMIT}" ]; then
    export JAVA_MEM_OPTIONS="-Xmx${JAVA_HEAPLIMIT}"
fi

if [ "$1" = "/gerrit-start.sh" ]; then
    # If you're mounting ${GERRIT_DIR_VOLUME} to your host, you this will default to root.
    # This obviously ensures the permissions are set correctly for when gerrit starts.
    find "${GERRIT_DIR_VOLUME}/" ! -user `id -u ${GERRIT_USER}` -exec chown ${GERRIT_USER} {} \;

    # Initialize Gerrit if ${GERRIT_DIR_VOLUME}/git is empty.
    if [ -z "$(ls -A "$GERRIT_DIR_VOLUME/git")" ]; then
        echo "First time initialize gerrit..."
        su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch --no-auto-start -d "${GERRIT_DIR_VOLUME}" ${GERRIT_INIT_ARGS}

        #All git repositories must be removed when database is set as postgres or mysql
        #in order to be recreated at the secondary init below.
        #Or an execption will be thrown on secondary init.
        [ ${#DATABASE_TYPE} -gt 0 ] && rm -rf "${GERRIT_DIR_VOLUME}/git"
    fi

    # Install external plugins
    # The importer plugin is not ready for 3.0.0 yet.
    # su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/events-log.jar ${GERRIT_DIR_VOLUME}/plugins/events-log.jar  # TODO. EVENT
    #su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/importer.jar ${GERRIT_DIR_VOLUME}/plugins/importer.jar

    # Provide a way to customise this image
    echo
    for f in /docker-entrypoint-init.d/*; do
        case "$f" in
            *.sh)    echo "$0: running $f"; source "$f" ;;
            *.nohup) echo "$0: running $f"; nohup  "$f" & ;;
            *)       echo "$0: ignoring $f" ;;
        esac
            echo "."
    done

    # create config file
    if [ -d ${GERRIT_DIR_EXT_CONFIG} ]; then
        copy_file ${GERRIT_DIR_EXT_CONFIG} ${GERRIT_DIR_VOLUME}/etc gerrit.config
        copy_file ${GERRIT_DIR_EXT_CONFIG} ${GERRIT_DIR_VOLUME}/etc secure.config
        copy_file ${GERRIT_DIR_EXT_CONFIG} ${GERRIT_DIR_VOLUME}/etc replication.config
        su-exec ${GERRIT_USER} chown ${GERRIT_USER}:${GERRIT_GROUP} ${GERRIT_DIR_VOLUME}/etc/*
    else
        /gerrit-create-config.sh
    fi


    if [ -d ${GERRIT_DIR_EXT_BACKUP} ]; then
#rm ${GERRIT_DIR_EXT_BACKUP}/*
        [[ -f "${GERRIT_DIR_VOLUME}/etc/gerrit.config" ]]         && su-exec ${GERRIT_USER} cp "${GERRIT_DIR_VOLUME}/etc/gerrit.config"         ${GERRIT_DIR_EXT_BACKUP}
        [[ -f "${GERRIT_DIR_VOLUME}/etc/secure.config" ]]         && su-exec ${GERRIT_USER} cp "${GERRIT_DIR_VOLUME}/etc/secure.config"         ${GERRIT_DIR_EXT_BACKUP}
        [[ -f "${GERRIT_DIR_VOLUME}/etc/replication.config" ]]    && su-exec ${GERRIT_USER} cp "${GERRIT_DIR_VOLUME}/etc/replication.config"    ${GERRIT_DIR_EXT_BACKUP}
    fi
    
    case "${DATABASE_TYPE}" in
        postgresql) [ -z "${DB_PORT_5432_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_5432_TCP_ADDR} ${DB_PORT_5432_TCP_PORT} ;;
        mysql)      [ -z "${DB_PORT_3306_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_3306_TCP_ADDR} ${DB_PORT_3306_TCP_PORT} ;;
        *)          ;;
    esac
    # docker --link is deprecated. All DB_* environment variables will be replaced by DATABASE_* below.
    [ ${#DATABASE_HOSTNAME} -gt 0 ] && [ ${#DATABASE_PORT} -gt 0 ] && wait_for_database ${DATABASE_HOSTNAME} ${DATABASE_PORT}
    
    echo "Upgrading gerrit..."
    su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch -d "${GERRIT_DIR_VOLUME}" ${GERRIT_INIT_ARGS}
    if [ $? -eq 0 ]; then
        GERRIT_VERSIONFILE="${GERRIT_DIR_VOLUME}/gerrit_version"
        
        # MIGRATE_TO_NOTEDB_OFFLINE will override IGNORE_VERSIONCHECK
        if [ -n "${IGNORE_VERSIONCHECK}" ] && [ -z "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
            echo "Don't perform a version check and never do a full reindex"
            NEED_REINDEX=0
        else
            # check whether its a good idea to do a full upgrade
            NEED_REINDEX=1
            echo "Checking version file ${GERRIT_VERSIONFILE}"
            if [ -f "${GERRIT_VERSIONFILE}" ]; then
                OLD_GERRIT_VER="V$(cat ${GERRIT_VERSIONFILE})"
                GERRIT_VER="V${GERRIT_VERSION}"
                echo " have old gerrit version ${OLD_GERRIT_VER}"
                if [ "${OLD_GERRIT_VER}" = "${GERRIT_VER}" ]; then
                    echo " same gerrit version, no upgrade necessary ${OLD_GERRIT_VER} == ${GERRIT_VER}"
                    NEED_REINDEX=0
                else
                    echo " gerrit version mismatch #${OLD_GERRIT_VER}# != #${GERRIT_VER}#"
                fi
            else
                echo " gerrit version file does not exist, upgrade necessary"
            fi
        fi # if [ -n "${IGNORE_VERSIONCHECK}" ] && [ -z "${MIGRATE_TO_NOTEDB_OFFLINE}" ]

        if [ ${NEED_REINDEX} -eq 1 ]; then
            if [ -n "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
                echo "Migrating changes from ReviewDB to NoteDB..."
                su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" migrate-to-note-db -d "${GERRIT_DIR_VOLUME}"
            else
                echo "Reindexing..."
                su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_DIR_VOLUME}"
            fi
            if [ $? -eq 0 ]; then
                echo "Upgrading is OK. Writing versionfile ${GERRIT_VERSIONFILE}"
                su-exec ${GERRIT_USER} touch "${GERRIT_VERSIONFILE}"
                su-exec ${GERRIT_USER} echo "${GERRIT_VERSION}" > "${GERRIT_VERSIONFILE}"
                echo "${GERRIT_VERSIONFILE} written."
            else
                echo "Upgrading fail!"
            fi
        fi
    else # if [ $? -eq 0 ]
        echo "Something wrong..."
        cat "${GERRIT_DIR_VOLUME}/logs/error_log"
    fi
fi # if [ "$1" = "/gerrit-start.sh" ] 

exec "$@"
