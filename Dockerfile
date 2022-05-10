FROM adoptopenjdk/openjdk11:alpine-jre

# init default
ARG ARG_GERRIT_VERSION=3.5.1                \
    ARG_GERRIT_USER=gerrit                  \
    ARG_GERRIT_GROUP=gerrit                 \
    ARG_GERRIT_HOME=/var/gerrit             \
    ARG_GERRIT_WAR=/var/gerrit/gerrit.war   \
    ARG_GERRIT_INIT_ARGS="--install-plugin=delete-project --install-plugin=gitiles --install-plugin=plugin-manager" \
    ARG_EXT_DIR=/gerrit

# Overridable defaults
ENV GERRIT_USER=$ARG_GERRIT_USER            \
    GERRIT_GROUP=$ARG_GERRIT_GROUP          \
    GERRIT_HOME=$ARG_GERRIT_HOME            \
    GERRIT_WAR=$ARG_GERRIT_WAR              \
    GERRIT_INIT_ARGS=$ARG_GERRIT_INIT_ARGS  \
    GERRIT_DIR_VOLUME=$ARG_EXT_DIR

# Step.
# Add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN adduser -D -h "${GERRIT_HOME}" -g "${GERRIT_GROUP}" -s /sbin/nologin "${GERRIT_USER}"


# Step.
# Install Packages
RUN set -x \
    && apk add --update --no-cache git openssh-client openssl bash perl perl-cgi git-gitweb curl su-exec

# Step.
# Download gerrit.war
ADD --chown=$GERRIT_USER:$GERRIT_GROUP https://gerrit-releases.storage.googleapis.com/gerrit-${ARG_GERRIT_VERSION}.war ${GERRIT_WAR}


# Step.
# Add *.sh to image
ADD gerrit-entrypoint.sh /
ADD gerrit-start.sh /
ADD gerrit-create-config.sh /
RUN chmod +x /gerrit-*.sh


# Step.
# A directory has to be created before a volume is mounted to it.
# So gerrit user can own this directory.
RUN mkdir -p ${GERRIT_DIR_VOLUME} && \
    chown -R ${GERRIT_GROUP}:${GERRIT_USER} ${GERRIT_DIR_VOLUME}

VOLUME $GERRIT_DIR_VOLUME
ENTRYPOINT [ "/gerrit-entrypoint.sh" ]
EXPOSE 8080 29418
CMD [ "/gerrit-start.sh" ]


