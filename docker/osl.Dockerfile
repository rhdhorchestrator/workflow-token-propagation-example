ARG BUILDER_IMAGE
ARG RUNTIME_IMAGE

FROM ${BUILDER_IMAGE:-quay.io/orchestrator/incubator-kie-sonataflow-swf-builder:main} AS builder

ENV QUARKUS_EXTENSIONS=io.quarkiverse.openapi.generator:quarkus-openapi-generator:2.11.0-lts,org.kie:kie-addons-quarkus-monitoring-sonataflow,org.kie:kogito-addons-quarkus-jobs-knative-eventing,io.quarkus:quarkus-oidc-client-filter:3.15.6.redhat-00004,org.kie:kie-addons-quarkus-persistence-jdbc,io.quarkus:quarkus-jdbc-postgresql,io.quarkus:quarkus-agroal

ARG MAVEN_ARGS_APPEND
ENV MAVEN_ARGS_APPEND=${MAVEN_ARGS_APPEND}

COPY settings.xml /home/kogito/.m2/settings.xml

COPY --chown=1001 . .

RUN /home/kogito/launch/build-app.sh

#=============================
# Runtime
#=============================
FROM ${RUNTIME_IMAGE:-registry.access.redhat.com/ubi9/openjdk-17:1.21-2}

ENV LANGUAGE='en_US:en' LANG='en_US.UTF-8' 

COPY --from=builder --chown=185 /home/kogito/serverless-workflow-project/target/quarkus-app/lib/ /deployments/lib/
COPY --from=builder --chown=185 /home/kogito/serverless-workflow-project/target/quarkus-app/*.jar /deployments/
COPY --from=builder --chown=185 /home/kogito/serverless-workflow-project/target/quarkus-app/app/ /deployments/app/
COPY --from=builder --chown=185 /home/kogito/serverless-workflow-project/target/quarkus-app/quarkus/ /deployments/quarkus/

EXPOSE 8080
USER 185
ENV JAVA_OPTS="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"

ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
