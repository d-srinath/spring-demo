FROM ghcr.io/aquasecurity/trivy:latest as trivy


FROM trivy as scanner
RUN mkdir -p /tmp/app
COPY . /tmp/app
RUN trivy  fs --exit-code 1 --security-checks vuln,config /tmp/app/Dockerfile > /tmp/Dockerfile-report.log && \
    cat /tmp/Dockerfile-report.log

FROM docker.io/library/gradle:8.13.0-jdk21-alpine AS jre
COPY java.modules /tmp/java.modules
RUN apk add binutils # for objcopy, needed by jlink
RUN jlink --strip-debug --add-modules $(cat /tmp/java.modules) --output /root/java

FROM docker.io/library/gradle:8.13.0-jdk21-alpine AS builder
ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION:-1.0.0}
ARG USERNAME=gradle
# COPY --from=scanner /tmp/Dockerfile-report.log /tmp/Dockerfile-report.log
COPY . /home/$USERNAME/
WORKDIR /home/$USERNAME/

#RUN mkdir -p /home/gradle/build/libs && \
#    touch /home/$USERNAME/build/libs/spring-demo-${APP_VERSION}.jar

RUN gradle --info clean build -Pversion=${APP_VERSION} && \
    ls -l /home/$USERNAME/build/libs/ && \
    ls -l /home/$USERNAME/build/libs/spring-demo-${APP_VERSION}.jar

# RUN jdeps --print-module-deps --ignore-missing-deps /home/$USERNAME/build/libs/spring-demo-${APP_VERSION}.jar > /home/$USERNAME/build/java.modules

FROM docker.io/library/alpine:latest as base
# FROM docker.io/library/ubuntu:22.04 as base
ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION:-1.0.0}

# Create a non-root user
ARG USERNAME=appuser
ARG USER_UID=1000
ARG USER_GID=$USER_UID
RUN addgroup --gid $USER_GID $USERNAME \
&& adduser --uid $USER_UID --ingroup $USERNAME $USERNAME --home /home/$USERNAME --shell /bin/sh --disabled-password
COPY --from=jre /root/java /java
COPY --from=builder /home/gradle/build/libs/spring-demo-${APP_VERSION}.jar /home/$USERNAME/spring-demo.jar
RUN chown -R $USER_UID:$USER_GID /home/$USERNAME/spring-demo.jar && \
chmod 400 /home/$USERNAME/spring-demo.jar
WORKDIR /home/$USERNAME
USER $USERNAME

EXPOSE 8081
HEALTHCHECK --interval=1m --timeout=1s --start-period=5s --retries=2 \
CMD curl -f http://localhost:8081/ || exit 1

# CMD ["ls", "-ltr", "/home/appuser/spring-demo.jar"]
CMD ["/java/bin/java", "-jar", "/home/appuser/spring-demo.jar"]

# Run vulnerability scan on final image
FROM trivy AS vulnscan
COPY --from=base / /base-file-system
RUN trivy rootfs --exit-code 0  /base-file-system > /tmp/base-image-vulnscan-report && \
    cat /tmp/base-image-vulnscan-report

FROM curlimages/curl:latest AS test
ARG USERNAME=appuser
COPY --from=vulnscan  /tmp/base-image-vulnscan-report /tmp/base-image-vulnscan-report
ARG APP_VERSION
ENV APP_VERSION=${APP_VERSION:-1.0.0}
COPY --from=builder /home/gradle/build/libs/spring-demo-${APP_VERSION}.jar /home/$USERNAME/spring-demo.jar
COPY --from=base  /java /java
RUN /java/bin/java -jar /home/$USERNAME/spring-demo.jar & echo 'Running Application' && \
    sleep 90 && \
    curl http://localhost:8081 && \
    # kill -s 9 `pidof java` && \
    date > /tmp/image-test-date

FROM base as final
LABEL description="APP_NAME=spring-demo APP_VERSION=${APP_VERSION}"
COPY --from=test  /tmp/image-test-date /tmp/image-test-date